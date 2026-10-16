// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleVerifier} from "../src/OracleVerifier.sol";
import {OracleAttestation} from "../src/libraries/OracleAttestation.sol";
import {MockToken} from "./helpers/MockToken.sol";

contract AccountingHandler is Test {
    HamsterHour public game;
    OracleVerifier private verifier;
    MockToken private token;
    uint256 private key;
    address[4] private actors;
    uint256 public activeWindow;
    uint256[] private touched;
    uint256 private sequence;

    constructor(HamsterHour game_, MockToken token_, uint256 key_, address[4] memory actors_) {
        game = game_;
        verifier = game_.oracleVerifier();
        token = token_;
        key = key_;
        actors = actors_;
    }

    function windows() external view returns (uint256[] memory) {
        return touched;
    }

    function bet(uint256 actorSeed, uint256 market, uint256 value, uint256 amountSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = 0.5 ether + amountSeed % 100 ether;
        vm.startPrank(actor);
        if (market % 3 == 0) {
            game.betOverUnder(activeWindow, value % 2 == 0, amount);
        } else if (market % 3 == 1) {
            if (game.position(activeWindow, actor).exactAmount != 0) {
                vm.stopPrank();
                return;
            }
            game.betExact(activeWindow, value % 2001, amount);
        } else {
            game.betSleep(activeWindow, value % 2 == 0, amount);
        }
        vm.stopPrank();
        if (touched.length == 0 || touched[touched.length - 1] != activeWindow) touched.push(activeWindow);
    }

    function settle(uint256 resultSeed) external {
        HamsterHour.Window memory w = game.window(activeWindow);
        if (w.status != HamsterHour.Status.Open) return;
        vm.warp(w.endsAt);
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode(++sequence));
        a.chainId = 1;
        a.questionHash = game.questionHash(activeWindow, 100, 200);
        a.answerType = 3;
        a.answer = abi.encode(resultSeed % 2001);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, verifier.attestationDigest(a, address(game)));
        game.settle(activeWindow, a, abi.encodePacked(r, s, v));
        activeWindow = game.currentWindow() + 1;
    }

    function expire() public {
        HamsterHour.Window memory w = game.window(activeWindow);
        if (w.status != HamsterHour.Status.Open) return;
        vm.warp(uint256(w.endsAt) + 48 hours);
        game.voidWindow(activeWindow);
        activeWindow = game.currentWindow() + 1;
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
        if (game.pendingStaking(actor) == 0) return;
        vm.prank(actor);
        game.claimStaking();
    }

    function claim(uint256 actorSeed, uint256 windowSeed) external {
        if (touched.length == 0) return;
        uint256 k = touched[windowSeed % touched.length];
        address actor = actorSeed % 6 < 4 ? actors[actorSeed % 6] : actorSeed % 6 == 4 ? address(this) : game.TEAM();
        vm.prank(actor);
        try game.claim(k) {} catch {}
    }

    function donate(uint256 amountSeed) external {
        token.mint(address(game), amountSeed % 100 ether);
    }

    function fundReserve(uint256 actorSeed, uint256 amountSeed) external {
        vm.prank(actors[actorSeed % 4]);
        game.fundOracleReserve(1 + amountSeed % 1 ether);
    }

    function drain() external {
        expire();
        address team = game.TEAM();
        for (uint256 i; i < touched.length; ++i) {
            for (uint256 j; j < 4; ++j) {
                vm.prank(actors[j]);
                try game.claim(touched[i]) {} catch {}
            }
            try game.claim(touched[i]) {} catch {}
            vm.prank(team);
            try game.claim(touched[i]) {} catch {}
        }
        for (uint256 j; j < 4; ++j) {
            (uint256 amount,,) = game.stakes(actors[j]);
            if (amount != 0) {
                vm.prank(actors[j]);
                game.unstake(amount);
            }
            if (game.pendingStaking(actors[j]) != 0) {
                vm.prank(actors[j]);
                game.claimStaking();
            }
        }
    }
}

contract AccountingInvariantTest is GameTest {
    AccountingHandler private handler;
    address[4] private actors;

    function setUp() public override {
        super.setUp();
        _configure(true, address(imd));
        _configure(false, address(imd));
        actors = [alice, bob, carol, dave];
        handler = new AccountingHandler(game, imd, SIGNER_KEY, actors);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.bet.selector;
        selectors[1] = handler.settle.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.stake.selector;
        selectors[4] = handler.unstake.selector;
        selectors[5] = handler.claimStaking.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.fundReserve.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allTokenBalancesCoverEveryRecordedLiability() public view {
        _assertBacked();
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            (uint256 amount,,) = game.stakes(actors[i]);
            sum += amount;
        }
        assertEq(sum, game.totalStaked());
    }

    function invariant_independentClaimModelIsBacked() public view {
        uint256 owed = game.oracleReserve() + game.preStakingReserve() + game.stakingUndistributed();
        for (uint256 i; i < 4; ++i) {
            owed += game.pendingStaking(actors[i]);
        }
        uint256[] memory ids = handler.windows();
        uint256 jackpotOwed;
        for (uint256 i; i < ids.length; ++i) {
            HamsterHour.Window memory w = game.window(ids[i]);
            if (w.status == HamsterHour.Status.Open) {
                owed += w.pools[0] + w.pools[1] + w.pools[2];
                continue;
            }
            jackpotOwed += w.jackpot - w.jackpotPaid;
            if (w.status == HamsterHour.Status.Settled) {
                owed += w.teamCredit + w.reimbursement;
                if (!w.marketVoided[0]) owed += w.rewards[0] - w.paid[0];
                if (!w.marketVoided[2]) owed += w.rewards[2] - w.paid[2];
                for (uint256 r; r < 3; ++r) {
                    owed += w.rankRewards[r] - w.rankPaid[r];
                }
            }
            for (uint256 j; j < 4; ++j) {
                HamsterHour.Position memory p = game.position(ids[i], actors[j]);
                if (p.imdClaimed) continue;
                if (w.status == HamsterHour.Status.Voided || w.marketVoided[0]) owed += p.over[0] + p.over[1];
                if (w.status == HamsterHour.Status.Voided || w.marketVoided[2]) owed += p.sleep[0] + p.sleep[1];
                if (w.status == HamsterHour.Status.Voided) owed += p.exactAmount;
            }
        }
        assertLe(owed, game.imdLiability(), "claims exceed IMD accounting");
        assertEq(jackpotOwed, game.jackpotLiability());
    }

    function afterInvariant() public {
        handler.drain();
        assertEq(game.totalStaked(), 0);
        assertEq(game.jackpotLiability(), 0);
        uint256 reserves = game.oracleReserve() + game.preStakingReserve() + game.stakingUndistributed();
        assertGe(game.imdLiability(), reserves);
        assertLe(game.imdLiability() - reserves, 4096, "claimable funds left after draining all actors");
        _assertBacked();
    }
}
