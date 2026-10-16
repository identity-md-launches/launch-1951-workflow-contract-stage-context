// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleVerifier} from "../src/OracleVerifier.sol";
import {OracleAttestation} from "../src/libraries/OracleAttestation.sol";
import {MockToken} from "./helpers/MockToken.sol";

/// @notice Drives the game with separate stake and prize tokens, several windows open at once, real
/// time passing, timeouts, and TEAM configuration changes. Ghost variables record what the contract
/// must owe so the invariants do not re-implement its accounting.
contract GameHandler is Test {
    HamsterHour public game;
    OracleVerifier private verifier;
    MockToken private imd;
    MockToken private stakeToken;
    MockToken private prize;
    uint256 private key;
    address public team;
    address[4] public actors;
    uint256[] private touched;
    mapping(uint256 => bool) private seen;
    uint256 private sequence;

    // Ghost accounting.
    uint256 public ghostSettled;
    uint256 public ghostVoided;
    uint256 public ghostImdIn; // bets + reserve funding + donations
    uint256 public ghostImdOut; // every IMD the game ever paid
    uint256 public ghostPrizeIn;
    uint256 public ghostPrizeOut;
    mapping(uint256 => uint256) public ghostBets; // per window: total IMD bet
    mapping(uint256 => uint256) public ghostPaid; // per window: IMD paid to bettors and TEAM
    mapping(uint256 => mapping(address => uint256)) public ghostActorBets;
    mapping(uint256 => HamsterHour.Status) public ghostFinal;

    constructor(
        HamsterHour game_,
        MockToken imd_,
        MockToken stakeToken_,
        MockToken prize_,
        uint256 key_,
        address[4] memory actors_
    ) {
        game = game_;
        verifier = game_.oracleVerifier();
        imd = imd_;
        stakeToken = stakeToken_;
        prize = prize_;
        key = key_;
        team = game_.TEAM();
        actors = actors_;
    }

    function windows() external view returns (uint256[] memory) {
        return touched;
    }

    function _touch(uint256 k) private {
        if (!seen[k]) {
            seen[k] = true;
            touched.push(k);
        }
    }

    function _target(uint256 windowSeed) private view returns (uint256) {
        return game.currentWindow() + 1 + windowSeed % 3;
    }

    function bet(uint256 actorSeed, uint256 windowSeed, uint256 market, uint256 value, uint256 amountSeed) external {
        uint256 k = _target(windowSeed);
        if (!game.isBettingOpen(k)) return;
        address actor = actors[actorSeed % 4];
        uint256 amount = 0.5 ether + amountSeed % 50 ether;
        vm.startPrank(actor);
        if (market % 3 == 0) {
            game.betOverUnder(k, value % 2 == 0, amount);
        } else if (market % 3 == 1) {
            if (game.position(k, actor).exactAmount != 0) {
                vm.stopPrank();
                return;
            }
            game.betExact(k, value % 1500, amount);
        } else {
            game.betSleep(k, value % 4 == 0, amount);
        }
        vm.stopPrank();
        _touch(k);
        ghostBets[k] += amount;
        ghostActorBets[k][actor] += amount;
        ghostImdIn += amount;
    }

    function advance(uint256 seed) external {
        vm.warp(block.timestamp + seed % 3 hours);
    }

    function settle(uint256 windowSeed, uint256 resultSeed) external {
        if (touched.length == 0) return;
        uint256 k = touched[windowSeed % touched.length];
        HamsterHour.Window memory w = game.window(k);
        if (w.status != HamsterHour.Status.Open) return;
        if (block.timestamp >= uint256(w.endsAt) + 48 hours) return;
        if (block.timestamp < w.endsAt) vm.warp(w.endsAt);
        uint256 result = resultSeed % 5 == 0 ? 0 : resultSeed % 1500;
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode(++sequence));
        a.chainId = 1;
        a.questionHash = game.questionHash(k, 100, 200);
        a.answerType = 3;
        a.answer = abi.encode(result);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, verifier.attestationDigest(a, address(game)));
        game.settle(k, a, abi.encodePacked(r, s, v));
        ++ghostSettled;
        ghostFinal[k] = HamsterHour.Status.Settled;
        assertEq(game.window(k).result, result, "settled result must be the signed answer");
    }

    function expire(uint256 windowSeed) external {
        if (touched.length == 0) return;
        uint256 k = touched[windowSeed % touched.length];
        HamsterHour.Window memory w = game.window(k);
        if (w.status != HamsterHour.Status.Open) return;
        if (block.timestamp < uint256(w.endsAt) + 48 hours) vm.warp(uint256(w.endsAt) + 48 hours);
        game.voidWindow(k);
        ++ghostVoided;
        ghostFinal[k] = HamsterHour.Status.Voided;
    }

    function claim(uint256 actorSeed, uint256 windowSeed) external {
        if (touched.length == 0) return;
        uint256 k = touched[windowSeed % touched.length];
        uint256 pick = actorSeed % 6;
        address who = pick < 4 ? actors[pick] : pick == 4 ? team : address(this);
        HamsterHour.Status before = game.window(k).status;
        uint256 imdBefore = imd.balanceOf(who);
        uint256 prizeBefore = prize.balanceOf(who);
        vm.prank(who);
        try game.claim(k) {
            uint256 got = imd.balanceOf(who) - imdBefore;
            uint256 gotPrize = prize.balanceOf(who) - prizeBefore;
            ghostImdOut += got;
            ghostPrizeOut += gotPrize;
            HamsterHour.Status later = game.window(k).status;
            if (later == HamsterHour.Status.Voided) {
                if (before == HamsterHour.Status.Open) {
                    ++ghostVoided;
                    ghostFinal[k] = HamsterHour.Status.Voided;
                }
                assertEq(got, ghostActorBets[k][who], "void refund must equal the claimant's bets");
                assertEq(gotPrize, 0, "voided windows pay no prize");
            }
            if (who == address(this)) {
                assertLe(got, 0.5 ether, "the settler only ever receives the reimbursement");
            } else {
                ghostPaid[k] += got;
            }
        } catch (bytes memory reason) {
            bool stillRunning =
                before == HamsterHour.Status.Open && block.timestamp < uint256(game.window(k).endsAt) + 48 hours;
            if (stillRunning) {
                assertEq(bytes4(reason), HamsterHour.NotFinal.selector, "an unfinished window is NotFinal");
            } else {
                assertEq(
                    bytes4(reason),
                    HamsterHour.NothingToClaim.selector,
                    "a final window fails only for lack of entitlement"
                );
            }
        }
    }

    function stake(uint256 actorSeed, uint256 amountSeed) external {
        vm.prank(actors[actorSeed % 4]);
        game.stake(1 + amountSeed % 100 ether);
    }

    function unstake(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 4];
        (uint256 balance,,) = game.stakes(actor);
        if (balance == 0) return;
        vm.prank(actor);
        game.unstake(1 + amountSeed % balance);
    }

    function claimStaking(uint256 actorSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 pending = game.pendingStaking(actor);
        if (pending == 0) return;
        uint256 before = imd.balanceOf(actor);
        vm.prank(actor);
        game.claimStaking();
        uint256 got = imd.balanceOf(actor) - before;
        assertEq(got, pending, "staking claim pays exactly the pending view");
        ghostImdOut += got;
    }

    function donatePrize(uint256 amountSeed) external {
        uint256 amount = amountSeed % 20 ether;
        prize.mint(address(game), amount);
        ghostPrizeIn += amount;
    }

    function donateImd(uint256 amountSeed) external {
        uint256 amount = amountSeed % 5 ether;
        imd.mint(address(game), amount);
        ghostImdIn += amount;
    }

    function fundReserve(uint256 actorSeed, uint256 amountSeed) external {
        uint256 amount = 1 + amountSeed % 1 ether;
        vm.prank(actors[actorSeed % 4]);
        game.fundOracleReserve(amount);
        ghostImdIn += amount;
    }

    function changeSource(uint256 seed) external {
        string memory source =
            seed % 2 == 0 ? "https://sepolia.squeekchain.com/status" : "https://squeekchain.example/a";
        vm.prank(team);
        game.scheduleSourceUrl(source);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(team);
        game.setSourceUrl(source);
    }

    function postponeGenesis(uint256 seed) external {
        uint64 genesis = uint64(game.genesisTimestamp() + 1 + seed % 2 days);
        vm.prank(team);
        game.scheduleGenesisTimestamp(genesis);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(team);
        game.setGenesisTimestamp(genesis);
    }

    /// @dev A correction that moves genesis earlier closes betting on windows whose corrected start has
    /// passed while their stored schedule still governs settlement and the timeout.
    function advanceGenesis(uint256 seed) external {
        uint64 genesis = uint64(game.genesisTimestamp() - (1 + seed % 2 days));
        vm.prank(team);
        game.scheduleGenesisTimestamp(genesis);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(team);
        game.setGenesisTimestamp(genesis);
    }

    function drain() external {
        for (uint256 i; i < touched.length; ++i) {
            uint256 k = touched[i];
            HamsterHour.Window memory w = game.window(k);
            if (w.status == HamsterHour.Status.Open) {
                if (block.timestamp < uint256(w.endsAt) + 48 hours) vm.warp(uint256(w.endsAt) + 48 hours);
                game.voidWindow(k);
            }
            for (uint256 j; j < 6; ++j) {
                address who = j < 4 ? actors[j] : j == 4 ? team : address(this);
                uint256 before = imd.balanceOf(who);
                uint256 prizeBefore = prize.balanceOf(who);
                vm.prank(who);
                try game.claim(k) {} catch {}
                ghostImdOut += imd.balanceOf(who) - before;
                ghostPrizeOut += prize.balanceOf(who) - prizeBefore;
            }
        }
        for (uint256 j; j < 4; ++j) {
            (uint256 amount,,) = game.stakes(actors[j]);
            if (amount != 0) {
                vm.prank(actors[j]);
                game.unstake(amount);
            }
            if (game.pendingStaking(actors[j]) != 0) {
                uint256 before = imd.balanceOf(actors[j]);
                vm.prank(actors[j]);
                game.claimStaking();
                ghostImdOut += imd.balanceOf(actors[j]) - before;
            }
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GameInvariantTest is GameTest {
    GameHandler internal handler;
    address[4] private actors;

    function setUp() public override {
        super.setUp();
        _configure(true, address(stakeToken));
        _configure(false, address(prize));
        actors = [alice, bob, carol, dave];
        handler = new GameHandler(game, imd, stakeToken, prize, SIGNER_KEY, actors);
        bytes4[] memory selectors = new bytes4[](14);
        selectors[13] = handler.advanceGenesis.selector;
        selectors[0] = handler.bet.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.expire.selector;
        selectors[4] = handler.claim.selector;
        selectors[5] = handler.stake.selector;
        selectors[6] = handler.unstake.selector;
        selectors[7] = handler.claimStaking.selector;
        selectors[8] = handler.donatePrize.selector;
        selectors[9] = handler.donateImd.selector;
        selectors[10] = handler.fundReserve.selector;
        selectors[11] = handler.changeSource.selector;
        selectors[12] = handler.postponeGenesis.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @dev What the contract holds covers what it has recorded as owed, for each asset separately.
    function invariant_everyAssetBacksItsLiability() public view {
        assertGe(imd.balanceOf(address(game)), game.imdLiability(), "IMD liability unbacked");
        assertEq(stakeToken.balanceOf(address(game)), game.totalStaked(), "stake principal must stay whole");
        assertGe(prize.balanceOf(address(game)), game.jackpotLiability(), "jackpot liability unbacked");
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            (uint256 amount,,) = game.stakes(actors[i]);
            sum += amount;
        }
        assertEq(sum, game.totalStaked());
    }

    /// @dev Nothing is created: all IMD ever paid out came from bets, funding or donations.
    function invariant_noValueCreated() public view {
        assertLe(handler.ghostImdOut(), handler.ghostImdIn(), "paid more IMD than ever received");
        assertLe(handler.ghostPrizeOut(), handler.ghostPrizeIn(), "paid more prize than ever received");
        assertEq(imd.balanceOf(address(game)), handler.ghostImdIn() - handler.ghostImdOut());
    }

    /// @dev Finished windows never reopen and the settlement counter only counts real settlements.
    function invariant_finalStatesAreFinalAndCounted() public view {
        assertEq(game.settledWindows(), handler.ghostSettled());
        uint256[] memory ids = handler.windows();
        uint256 voided;
        for (uint256 i; i < ids.length; ++i) {
            HamsterHour.Status status = game.window(ids[i]).status;
            HamsterHour.Status final_ = handler.ghostFinal(ids[i]);
            if (final_ != HamsterHour.Status.Uncreated) {
                assertEq(uint256(status), uint256(final_), "final state reopened");
            }
            if (status == HamsterHour.Status.Voided) ++voided;
            assertTrue(status != HamsterHour.Status.Uncreated, "a bet-on window must exist");
        }
        assertEq(voided, handler.ghostVoided());
    }

    /// @dev Per window: the split is exactly 91/5/3/1 of each live market and nobody is paid more
    /// than the window took in; voided markets keep every unit for refunds.
    function invariant_windowSplitAndPayoutBounds() public view {
        uint256[] memory ids = handler.windows();
        uint256 jackpotOwed;
        for (uint256 i; i < ids.length; ++i) {
            uint256 k = ids[i];
            HamsterHour.Window memory w = game.window(k);
            assertEq(w.pools[0] + w.pools[1] + w.pools[2], handler.ghostBets(k), "pools must equal bets taken");
            assertEq(w.over[0] + w.over[1], w.pools[0]);
            assertEq(w.sleep[0] + w.sleep[1], w.pools[2]);
            assertLe(handler.ghostPaid(k), handler.ghostBets(k), "window paid out more than it took in");
            jackpotOwed += w.jackpot - w.jackpotPaid;
            if (w.status != HamsterHour.Status.Settled) {
                assertEq(w.teamCredit + w.reimbursement, 0);
                assertEq(w.jackpot, 0);
                continue;
            }
            uint256 team;
            for (uint256 m; m < 3; ++m) {
                if (w.marketVoided[m] || w.pools[m] == 0) {
                    assertEq(w.rewards[m], 0);
                    continue;
                }
                uint256 pool = w.pools[m];
                assertEq(w.rewards[m], pool - pool * 5 / 100 - pool * 3 / 100 - pool / 100, "91% to winners");
                assertLe(w.paid[m], w.rewards[m]);
                team += pool / 100;
            }
            assertLe(w.teamCredit, team, "TEAM credit exceeds 1%");
            assertTrue(w.marketVoided[0] == (w.over[0] == 0 || w.over[1] == 0 || w.result == w.line), "O/U void rule");
            assertTrue(w.marketVoided[2] == (w.sleep[0] == 0 || w.sleep[1] == 0), "SLEEP void rule");
            assertFalse(w.marketVoided[1], "EXACT never voids");
            if (w.pools[1] != 0) {
                assertGt(w.rankCount, 0);
                assertEq(w.rankRewards[0] + w.rankRewards[1] + w.rankRewards[2], w.rewards[1], "EXACT tiers sum");
                for (uint256 r; r < 3; ++r) {
                    assertLe(w.rankPaid[r], w.rankRewards[r]);
                    assertLe(w.rankClaimed[r], w.ties[r]);
                }
                if (w.rankCount > 1) assertLt(w.distances[0], w.distances[1]);
                if (w.rankCount > 2) assertLt(w.distances[1], w.distances[2]);
            } else {
                assertEq(w.rankCount, 0);
                assertEq(w.jackpot, 0, "no EXACT ticket, no jackpot");
            }
            assertLe(w.jackpotClaimed, w.ties[0]);
            assertLe(w.jackpotPaid, w.jackpot);
        }
        assertEq(jackpotOwed, game.jackpotLiability(), "jackpot liability must equal unpaid snapshots");
    }

    /// @dev Reserve release never exceeds what was accrued before the token was set.
    function invariant_reserveReleaseIsBoundedAndMonotone() public view {
        assertLe(game.releaseWindows(), 30);
        assertLe(game.reserveReleased(), game.releaseTotal());
        assertEq(game.preStakingReserve(), game.releaseTotal() - game.reserveReleased());
    }

    function afterInvariant() public virtual {
        handler.drain();
        assertEq(game.totalStaked(), 0);
        assertEq(game.jackpotLiability(), 0);
        assertEq(prize.balanceOf(address(game)), handler.ghostPrizeIn() - handler.ghostPrizeOut());
        uint256 reserves = game.oracleReserve() + game.preStakingReserve() + game.stakingUndistributed();
        assertGe(game.imdLiability(), reserves);
        assertLe(game.imdLiability() - reserves, 4096, "claimable IMD left after everyone drained");
        assertGe(imd.balanceOf(address(game)), game.imdLiability());
    }
}
