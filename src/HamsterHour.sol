// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleVerifier} from "./OracleVerifier.sol";
import {OracleAttestation} from "./libraries/OracleAttestation.sol";
import {OracleQuestion} from "./libraries/OracleQuestion.sol";

/// @title Hamster Hour
/// @notice Immutable pari-mutuel IMD markets. TEAM can only execute four delayed settings.
contract HamsterHour is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 public constant MIN_BET = 0.5 ether;
    uint256 public constant ORACLE_REIMBURSEMENT = 0.5 ether;
    uint64 public constant ROUND_DURATION = 600;
    uint64 public constant WINDOW_DURATION = 3600;
    uint64 public constant TIMEOUT = 48 hours;
    uint64 public constant CONFIG_DELAY = 48 hours;
    uint256 public constant BOOTSTRAP_LINE = 1000;
    uint256 public constant MAX_EXACT_ENTRIES = 256;
    uint256 public constant MAX_POOL = type(uint128).max;
    uint256 public constant ACC_PRECISION = 1e27;
    uint256 public constant RESERVE_RELEASE_WINDOWS = 30;
    uint256 public constant MAX_SOURCE_LENGTH = 256;
    bytes32 public constant STAKING_SETTING = keccak256("stakingToken");
    bytes32 public constant JACKPOT_SETTING = keccak256("jackpotToken");
    bytes32 public constant SOURCE_SETTING = keccak256("sourceUrl");
    bytes32 public constant GENESIS_SETTING = keccak256("genesisTimestamp");

    address public immutable TEAM;
    OracleVerifier public immutable oracleVerifier;
    uint64 public genesisTimestamp = 1791847800;
    string public sourceUrl = "https://sepolia.squeekchain.com";
    address public stakingToken;
    address public jackpotToken;
    // Number of past/started window ids which a genesis change may never reopen.
    uint256 public closedWindowFloor;

    enum Status {
        Uncreated,
        Open,
        Settled,
        Voided
    }
    enum Market {
        OverUnder,
        Exact,
        Sleep
    }

    struct Window {
        Status status;
        uint64 startsAt;
        uint64 endsAt;
        uint256 line;
        string source;
        uint256 result;
        uint256[3] pools;
        uint256[2] over;
        uint256[2] sleep;
        uint256[3] rewards;
        bool[3] marketVoided;
        uint256[3] paid;
        uint256[3] claimedWeight;
        uint256[3] distances;
        uint256[3] ties;
        uint256[3] rankRewards;
        uint256[3] rankClaimed;
        uint256[3] rankPaid;
        uint8 rankCount;
        address settler;
        uint256 teamCredit;
        uint256 reimbursement;
        bool reimbursed;
        address jackpotAsset;
        uint256 jackpot;
        uint256 jackpotPaid;
        uint256 jackpotClaimed;
        bytes32 requestId;
    }

    struct Position {
        uint256[2] over;
        uint256[2] sleep;
        uint256 exactAmount;
        uint256 guess;
        bool imdClaimed;
        bool jackpotClaimed;
    }

    struct PendingConfig {
        bytes32 valueHash;
        uint64 readyAt;
    }

    struct StakeAccount {
        uint256 amount;
        uint256 index;
        uint256 pending;
    }

    mapping(uint256 => Window) private _windows;
    mapping(uint256 => mapping(address => Position)) private _positions;
    mapping(uint256 => uint256[]) private _guesses;
    mapping(bytes32 => PendingConfig) public pendingConfig;
    mapping(address => StakeAccount) public stakes;

    uint256[7] public recentResults;
    uint256 public settledWindows;
    // Every accounted IMD unit remains reserved until transferred, including rounding dust.
    uint256 public imdLiability;
    uint256 public oracleReserve;
    uint256 public jackpotLiability;
    uint256 public totalStaked;
    uint256 public accIMDPerStake;
    uint256 public preStakingReserve;
    uint256 public releaseTotal;
    uint256 public reserveReleased;
    uint256 public releaseWindows;
    uint64 public stakingActivatedAt;
    uint256 public stakingUndistributed;

    error NotTeam();
    error InvalidAddress();
    error InvalidWindow();
    error BettingClosed();
    error BelowMinimum();
    error PoolLimit();
    error DuplicateExactBet();
    error ExactFull();
    error NotSettleable();
    error NotTimedOut();
    error NotFinal();
    error NothingToClaim();
    error AttestationPredatesEnd();
    error TokenNotConfigured();
    error AlreadyConfigured();
    error TimelockNotReady();
    error InvalidSource();
    error InvalidGenesis();
    error InvalidAmount();
    error UnsupportedToken();

    event WindowCreated(uint256 indexed windowId, uint64 startsAt, uint64 endsAt, uint256 line, string source);
    event Bet(
        uint256 indexed windowId, address indexed bettor, Market indexed market, uint256 selection, uint256 amount
    );
    event Settled(uint256 indexed windowId, uint256 result, bytes32 indexed requestId, address indexed settler);
    event Split(uint256 indexed windowId, uint256 winners, uint256 stakers, uint256 oracle, uint256 team);
    event MarketVoided(uint256 indexed windowId, Market indexed market);
    event WindowVoided(uint256 indexed windowId);
    event Claimed(
        uint256 indexed windowId, address indexed account, uint256 imd, address jackpotAsset, uint256 jackpot
    );
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event StakingClaimed(address indexed account, uint256 amount);
    event StakingDistributed(uint256 amount, uint256 accumulator, uint256 reserveRelease);
    event OracleFunded(address indexed funder, uint256 amount);
    event OracleRewardReserved(uint256 indexed windowId, address indexed settler, uint256 amount);
    event OracleRewardDeferred(uint256 indexed windowId);
    event JackpotReserved(uint256 indexed windowId, address indexed token, uint256 amount);
    event JackpotUnavailable(uint256 indexed windowId, address indexed token);
    event ConfigScheduled(bytes32 indexed setting, bytes value, uint64 readyAt);
    event ConfigChanged(bytes32 indexed setting, bytes value);

    modifier onlyTeam() {
        if (msg.sender != TEAM) revert NotTeam();
        _;
    }

    constructor(address team_, address verifier_) {
        if (team_ == address(0) || verifier_ == address(0)) revert InvalidAddress();
        TEAM = team_;
        oracleVerifier = OracleVerifier(verifier_);
    }

    function window(uint256 k) external view returns (Window memory) {
        return _windows[k];
    }

    function position(uint256 k, address account) external view returns (Position memory) {
        return _positions[k][account];
    }

    function exactEntries(uint256 k) external view returns (uint256) {
        return _guesses[k].length;
    }

    function exactGuess(uint256 k, uint256 index) external view returns (uint256) {
        return _guesses[k][index];
    }

    /// @notice Before genesis, returns round zero; use hasStarted to distinguish pre-genesis.
    function currentRound() public view returns (uint256) {
        return block.timestamp < genesisTimestamp ? 0 : (block.timestamp - genesisTimestamp) / ROUND_DURATION;
    }

    function currentWindow() public view returns (uint256) {
        return currentRound() / 6;
    }

    function hasStarted() external view returns (bool) {
        return block.timestamp >= genesisTimestamp;
    }

    /// @notice Average of the last seven successful settlements, in settlement order; floor division.
    function currentLine() public view returns (uint256 line) {
        if (settledWindows < 7) return BOOTSTRAP_LINE;
        // Sum quotients/remainders so even seven uint256-max answers cannot overflow.
        uint256 remainder;
        for (uint256 i; i < 7; ++i) {
            line += recentResults[i] / 7;
            remainder += recentResults[i] % 7;
        }
        return line + remainder / 7;
    }

    function windowTimes(uint256 k) public view returns (uint64 startsAt, uint64 endsAt) {
        Window storage w = _windows[k];
        if (w.status != Status.Uncreated) return (w.startsAt, w.endsAt);
        if (k > (type(uint64).max - uint256(genesisTimestamp) - WINDOW_DURATION - TIMEOUT) / WINDOW_DURATION) {
            revert InvalidWindow();
        }
        startsAt = uint64(uint256(genesisTimestamp) + k * WINDOW_DURATION);
        endsAt = startsAt + WINDOW_DURATION;
    }

    function isBettingOpen(uint256 k) external view returns (bool) {
        Window storage w = _windows[k];
        if (w.status == Status.Uncreated && k < closedWindowFloor) return false;
        (uint64 startsAt,) = windowTimes(k);
        return (w.status == Status.Uncreated || w.status == Status.Open) && block.timestamp < startsAt;
    }

    function question(uint256 k) public view returns (string memory) {
        Window storage w = _windows[k];
        if (w.status == Status.Uncreated) revert InvalidWindow();
        return OracleQuestion.question(k, w.source);
    }

    function questionDocument(uint256 k, uint64 fromBlock, uint64 toBlock) public view returns (string memory) {
        return OracleQuestion.document(question(k), block.chainid, fromBlock, toBlock);
    }

    function questionHash(uint256 k, uint64 fromBlock, uint64 toBlock) public view returns (bytes32) {
        return keccak256(bytes(questionDocument(k, fromBlock, toBlock)));
    }

    function betOverUnder(uint256 k, bool over, uint256 amount) external nonReentrant {
        Window storage w = _open(k, amount, Market.OverUnder);
        uint256 side = over ? 1 : 0;
        w.over[side] += amount;
        _positions[k][msg.sender].over[side] += amount;
        _takeBet(k, Market.OverUnder, side, amount);
    }

    function betSleep(uint256 k, bool sleeping, uint256 amount) external nonReentrant {
        Window storage w = _open(k, amount, Market.Sleep);
        uint256 side = sleeping ? 1 : 0;
        w.sleep[side] += amount;
        _positions[k][msg.sender].sleep[side] += amount;
        _takeBet(k, Market.Sleep, side, amount);
    }

    /// @notice One immutable EXACT ticket per address/window. Tied tickets split their rank equally.
    function betExact(uint256 k, uint256 guess, uint256 amount) external nonReentrant {
        _open(k, amount, Market.Exact);
        Position storage p = _positions[k][msg.sender];
        if (p.exactAmount != 0) revert DuplicateExactBet();
        if (_guesses[k].length == MAX_EXACT_ENTRIES) revert ExactFull();
        p.exactAmount = amount;
        p.guess = guess;
        _guesses[k].push(guess);
        _takeBet(k, Market.Exact, guess, amount);
    }

    function _open(uint256 k, uint256 amount, Market market) private returns (Window storage w) {
        if (amount < MIN_BET) revert BelowMinimum();
        w = _windows[k];
        if (w.status == Status.Uncreated) {
            if (k < closedWindowFloor) revert BettingClosed();
            (uint64 startsAt, uint64 endsAt) = windowTimes(k);
            if (block.timestamp >= startsAt) revert BettingClosed();
            w.status = Status.Open;
            w.startsAt = startsAt;
            w.endsAt = endsAt;
            w.line = currentLine();
            w.source = sourceUrl;
            emit WindowCreated(k, startsAt, endsAt, w.line, w.source);
        }
        if (w.status != Status.Open || block.timestamp >= w.startsAt) revert BettingClosed();
        if (amount > MAX_POOL - w.pools[uint256(market)]) revert PoolLimit();
        w.pools[uint256(market)] += amount;
    }

    function _takeBet(uint256 k, Market market, uint256 selection, uint256 amount) private {
        imdLiability += amount;
        _pull(IMD, amount);
        emit Bet(k, msg.sender, market, selection, amount);
    }

    function settle(uint256 k, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Window storage w = _windows[k];
        if (w.status != Status.Open || block.timestamp < w.endsAt || block.timestamp >= uint256(w.endsAt) + TIMEOUT) {
            revert NotSettleable();
        }
        if (uint256(a.issuedAt) + oracleVerifier.ISSUED_AT_TOLERANCE() < w.endsAt) revert AttestationPredatesEnd();
        w.status = Status.Settled;
        w.result = oracleVerifier.verify(a, signature, questionHash(k, a.fromBlock, a.toBlock));
        w.settler = msg.sender;
        w.requestId = a.requestId;
        w.marketVoided[0] = w.over[0] == 0 || w.over[1] == 0 || w.result == w.line;
        w.marketVoided[2] = w.sleep[0] == 0 || w.sleep[1] == 0;
        if (w.pools[1] != 0) _rank(k, w);

        uint256 stakingShare;
        uint256 oracleShare;
        uint256 winnerShare;
        for (uint256 i; i < 3; ++i) {
            uint256 pool = w.pools[i];
            if (pool == 0) continue;
            if (w.marketVoided[i]) {
                emit MarketVoided(k, Market(i));
                continue;
            }
            uint256 stakers = pool * 5 / 100;
            uint256 oracle = pool * 3 / 100;
            uint256 team = pool / 100;
            w.rewards[i] = pool - stakers - oracle - team;
            stakingShare += stakers;
            oracleShare += oracle;
            w.teamCredit += team;
            winnerShare += w.rewards[i];
        }
        _rankRewards(w);
        oracleReserve += oracleShare;
        _reserveReimbursement(k, w);
        _distributeStaking(stakingShare, w.endsAt);
        _snapshotJackpot(k, w);
        recentResults[settledWindows % 7] = w.result;
        ++settledWindows;
        emit Split(k, winnerShare, stakingShare, oracleShare, w.teamCredit);
        emit Settled(k, w.result, a.requestId, msg.sender);
    }

    function voidWindow(uint256 k) external nonReentrant {
        _void(k);
    }

    function _void(uint256 k) private {
        Window storage w = _windows[k];
        if (w.status != Status.Open || block.timestamp < uint256(w.endsAt) + TIMEOUT) revert NotTimedOut();
        w.status = Status.Voided;
        emit WindowVoided(k);
    }

    function _rank(uint256 k, Window storage w) private {
        uint256[] storage guesses = _guesses[k];
        uint256[3] memory d;
        uint256[3] memory ties;
        uint8 count;
        for (uint256 i; i < guesses.length; ++i) {
            uint256 distance = _distance(guesses[i], w.result);
            for (uint256 j; j < 3; ++j) {
                if (j < count && distance == d[j]) {
                    ++ties[j];
                    break;
                }
                if (j == count || distance < d[j]) {
                    for (uint256 r = 2; r > j; --r) {
                        d[r] = d[r - 1];
                        ties[r] = ties[r - 1];
                    }
                    d[j] = distance;
                    ties[j] = 1;
                    if (count < 3) ++count;
                    break;
                }
            }
        }
        w.distances = d;
        w.ties = ties;
        w.rankCount = count;
    }

    function _rankRewards(Window storage w) private {
        if (w.rankCount == 0) return;
        uint256 reward = w.rewards[1];
        // Missing second/third tiers return to the closest tier; no pot is stranded.
        if (w.rankCount > 1) w.rankRewards[1] = reward * 30 / 100;
        if (w.rankCount > 2) w.rankRewards[2] = reward * 10 / 100;
        w.rankRewards[0] = reward - w.rankRewards[1] - w.rankRewards[2];
    }

    function _distance(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _exactRank(Window storage w, Position storage p) private view returns (uint256) {
        if (p.exactAmount == 0) return 3;
        uint256 d = _distance(p.guess, w.result);
        for (uint256 i; i < w.rankCount; ++i) {
            if (d == w.distances[i]) return i;
        }
        return 3;
    }

    /// @notice Claims IMD and jackpot. The overload permits IMD-only claims if a jackpot token fails.
    function claim(uint256 k) external nonReentrant {
        _claim(k, true);
    }

    function claim(uint256 k, bool includeJackpot) external nonReentrant {
        _claim(k, includeJackpot);
    }

    function _claim(uint256 k, bool includeJackpot) private {
        Window storage w = _windows[k];
        if (w.status == Status.Open && block.timestamp >= uint256(w.endsAt) + TIMEOUT) _void(k);
        if (w.status != Status.Settled && w.status != Status.Voided) revert NotFinal();
        Position storage p = _positions[k][msg.sender];
        uint256 imd = _claimBets(w, p);
        if (w.status == Status.Settled) {
            if (msg.sender == TEAM) {
                imd += w.teamCredit;
                w.teamCredit = 0;
            }
            if (msg.sender == w.settler && !w.reimbursed) {
                _reserveReimbursement(k, w);
                if (w.reimbursement != 0) {
                    imd += w.reimbursement;
                    w.reimbursement = 0;
                    w.reimbursed = true;
                }
            }
        }
        uint256 jackpot;
        bool jackpotProcessed;
        if (includeJackpot && !p.jackpotClaimed && w.jackpot != 0 && _exactRank(w, p) == 0) {
            jackpotProcessed = true;
            p.jackpotClaimed = true;
            ++w.jackpotClaimed;
            jackpot = w.jackpotClaimed == w.ties[0] ? w.jackpot - w.jackpotPaid : w.jackpot / w.ties[0];
            w.jackpotPaid += jackpot;
            jackpotLiability -= jackpot;
        }
        // A sub-unit tied prize still needs to count a zero-share claimant so the last winner
        // can collect its rounding remainder, including after an earlier IMD-only claim.
        if (imd == 0 && jackpot == 0 && !jackpotProcessed) revert NothingToClaim();
        imdLiability -= imd;
        if (imd != 0) _pay(IMD, msg.sender, imd);
        if (jackpot != 0) _pay(w.jackpotAsset, msg.sender, jackpot);
        emit Claimed(k, msg.sender, imd, w.jackpotAsset, jackpot);
    }

    function _claimBets(Window storage w, Position storage p) private returns (uint256 payout) {
        if (p.imdClaimed) return 0;
        p.imdClaimed = true;
        if (w.status == Status.Voided) return p.over[0] + p.over[1] + p.sleep[0] + p.sleep[1] + p.exactAmount;
        payout = _binaryClaim(w, 0, p.over, w.over, w.result > w.line);
        payout += _binaryClaim(w, 2, p.sleep, w.sleep, w.result == 0);
        uint256 rank = _exactRank(w, p);
        if (rank < 3) {
            ++w.rankClaimed[rank];
            uint256 prize = w.rankClaimed[rank] == w.ties[rank]
                ? w.rankRewards[rank] - w.rankPaid[rank]
                : w.rankRewards[rank] / w.ties[rank];
            w.rankPaid[rank] += prize;
            payout += prize;
        }
    }

    function _binaryClaim(
        Window storage w,
        uint256 market,
        uint256[2] storage bets,
        uint256[2] storage sides,
        bool outcome
    ) private returns (uint256 payout) {
        if (w.marketVoided[market]) return bets[0] + bets[1];
        uint256 side = outcome ? 1 : 0;
        uint256 weight = bets[side];
        if (weight == 0) return 0;
        w.claimedWeight[market] += weight;
        payout = w.claimedWeight[market] == sides[side]
            ? w.rewards[market] - w.paid[market]
            : Math.mulDiv(w.rewards[market], weight, sides[side]);
        w.paid[market] += payout;
    }

    function fundOracleReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        oracleReserve += amount;
        imdLiability += amount;
        _pull(IMD, amount);
        emit OracleFunded(msg.sender, amount);
    }

    function _reserveReimbursement(uint256 k, Window storage w) private {
        if (w.reimbursed || w.reimbursement != 0) return;
        if (oracleReserve >= ORACLE_REIMBURSEMENT) {
            oracleReserve -= ORACLE_REIMBURSEMENT;
            w.reimbursement = ORACLE_REIMBURSEMENT;
            emit OracleRewardReserved(k, w.settler, ORACLE_REIMBURSEMENT);
        } else {
            emit OracleRewardDeferred(k);
        }
    }

    function _snapshotJackpot(uint256 k, Window storage w) private {
        address token = jackpotToken;
        if (token == address(0) || w.rankCount == 0) return;
        // A broken optional prize token must not prevent settling/refunding the IMD markets.
        (bool ok, uint256 balance) = _jackpotBalance(token);
        if (!ok) {
            emit JackpotUnavailable(k, token);
            return;
        }
        uint256 reserved = jackpotLiability;
        if (token == IMD) reserved += imdLiability;
        if (token == stakingToken) reserved += totalStaked;
        if (balance < reserved) {
            emit JackpotUnavailable(k, token);
            return;
        }
        w.jackpotAsset = token;
        w.jackpot = balance - reserved;
        jackpotLiability += w.jackpot;
        emit JackpotReserved(k, token, w.jackpot);
    }

    function _jackpotBalance(address token) private view returns (bool ok, uint256 tokenBalance) {
        // Copy exactly one return word: even a malicious token cannot force a returndata allocation.
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x70a08231))
            mstore(add(ptr, 4), address())
            ok := staticcall(50000, token, ptr, 36, ptr, 32)
            ok := and(ok, eq(returndatasize(), 32))
            tokenBalance := mload(ptr)
        }
    }

    function stake(uint256 amount) external nonReentrant {
        if (stakingToken == address(0)) revert TokenNotConfigured();
        if (amount == 0 || amount > MAX_POOL - totalStaked) revert InvalidAmount();
        _checkpoint(msg.sender);
        stakes[msg.sender].amount += amount;
        totalStaked += amount;
        _pull(stakingToken, amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (stakingToken == address(0)) revert TokenNotConfigured();
        if (amount == 0 || amount > stakes[msg.sender].amount) revert InvalidAmount();
        _checkpoint(msg.sender);
        stakes[msg.sender].amount -= amount;
        totalStaked -= amount;
        _pay(stakingToken, msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function pendingStaking(address account) public view returns (uint256) {
        StakeAccount storage s = stakes[account];
        return s.pending + Math.mulDiv(s.amount, accIMDPerStake - s.index, ACC_PRECISION);
    }

    function _checkpoint(address account) private {
        StakeAccount storage s = stakes[account];
        s.pending = pendingStaking(account);
        s.index = accIMDPerStake;
    }

    function claimStaking() external nonReentrant {
        _checkpoint(msg.sender);
        uint256 amount = stakes[msg.sender].pending;
        if (amount == 0) revert NothingToClaim();
        stakes[msg.sender].pending = 0;
        imdLiability -= amount;
        _pay(IMD, msg.sender, amount);
        emit StakingClaimed(msg.sender, amount);
    }

    function _distributeStaking(uint256 share, uint64 windowEnd) private {
        if (stakingToken == address(0)) {
            preStakingReserve += share;
            return;
        }
        uint256 released;
        // Lazy windows: count successful nonempty settlements ending after activation, once each.
        if (windowEnd > stakingActivatedAt && releaseWindows < RESERVE_RELEASE_WINDOWS) {
            ++releaseWindows;
            uint256 cumulative = Math.mulDiv(releaseTotal, releaseWindows, RESERVE_RELEASE_WINDOWS);
            released = cumulative - reserveReleased;
            reserveReleased = cumulative;
            preStakingReserve -= released;
        }
        uint256 amount = share + released + stakingUndistributed;
        if (totalStaked == 0) {
            stakingUndistributed = amount;
            return;
        }
        stakingUndistributed = 0;
        accIMDPerStake += Math.mulDiv(amount, ACC_PRECISION, totalStaked);
        emit StakingDistributed(amount, accIMDPerStake, released);
    }

    function scheduleStakingToken(address token) external onlyTeam {
        if (stakingToken != address(0)) revert AlreadyConfigured();
        _validateToken(token);
        _schedule(STAKING_SETTING, abi.encode(token));
    }

    function setStakingToken(address token) external onlyTeam nonReentrant {
        if (stakingToken != address(0)) revert AlreadyConfigured();
        _validateToken(token);
        _execute(STAKING_SETTING, abi.encode(token));
        if (token.code.length == 0) revert UnsupportedToken();
        stakingToken = token;
        stakingActivatedAt = uint64(block.timestamp);
        releaseTotal = preStakingReserve;
    }

    function scheduleJackpotToken(address token) external onlyTeam {
        if (jackpotToken != address(0)) revert AlreadyConfigured();
        _validateToken(token);
        _schedule(JACKPOT_SETTING, abi.encode(token));
    }

    function setJackpotToken(address token) external onlyTeam nonReentrant {
        if (jackpotToken != address(0)) revert AlreadyConfigured();
        _validateToken(token);
        _execute(JACKPOT_SETTING, abi.encode(token));
        if (token.code.length == 0) revert UnsupportedToken();
        jackpotToken = token;
    }

    function scheduleSourceUrl(string calldata source) external onlyTeam {
        _validateSource(source);
        _schedule(SOURCE_SETTING, abi.encode(source));
    }

    function setSourceUrl(string calldata source) external onlyTeam {
        _validateSource(source);
        _execute(SOURCE_SETTING, abi.encode(source));
        sourceUrl = source;
    }

    function scheduleGenesisTimestamp(uint64 genesis) external onlyTeam {
        _validateGenesis(genesis);
        _schedule(GENESIS_SETTING, abi.encode(genesis));
    }

    function setGenesisTimestamp(uint64 genesis) external onlyTeam {
        _validateGenesis(genesis);
        _execute(GENESIS_SETTING, abi.encode(genesis));
        if (block.timestamp >= genesisTimestamp) {
            uint256 closed = (block.timestamp - genesisTimestamp) / WINDOW_DURATION + 1;
            if (closed > closedWindowFloor) closedWindowFloor = closed;
        }
        genesisTimestamp = genesis;
    }

    function _validateToken(address token) private view {
        if (token == address(0) || token == address(this)) revert InvalidAddress();
    }

    function _validateGenesis(uint64 genesis) private pure {
        if (genesis == 0 || genesis > type(uint64).max - WINDOW_DURATION - TIMEOUT) revert InvalidGenesis();
    }

    function _validateSource(string calldata source) private pure {
        bytes memory value = bytes(source);
        if (value.length < 9 || value.length > MAX_SOURCE_LENGTH) revert InvalidSource();
        if (bytes8(value) != bytes8("https://")) revert InvalidSource();
        for (uint256 i; i < value.length; ++i) {
            uint8 c = uint8(value[i]);
            if (c < 0x21 || c > 0x7e || c == 0x22 || c == 0x5c) revert InvalidSource();
        }
    }

    function _schedule(bytes32 key, bytes memory value) private {
        uint64 readyAt = uint64(block.timestamp + CONFIG_DELAY);
        pendingConfig[key] = PendingConfig(keccak256(value), readyAt);
        emit ConfigScheduled(key, value, readyAt);
    }

    function _execute(bytes32 key, bytes memory value) private {
        PendingConfig memory p = pendingConfig[key];
        if (p.readyAt == 0 || block.timestamp < p.readyAt || p.valueHash != keccak256(value)) {
            revert TimelockNotReady();
        }
        delete pendingConfig[key];
        emit ConfigChanged(key, value);
    }

    /// @dev Reject fee-on-transfer deposits and tokens which report success without moving funds.
    function _pull(address token, uint256 amount) private {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnsupportedToken();
    }

    function _pay(address token, address to, uint256 amount) private {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        if (afterBalance > beforeBalance || beforeBalance - afterBalance != amount) revert UnsupportedToken();
    }
}
