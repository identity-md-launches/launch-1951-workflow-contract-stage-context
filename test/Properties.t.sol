// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleAttestation} from "../src/libraries/OracleAttestation.sol";

/// @notice Stateless properties at the arithmetic edges. Inputs are bounded, never assumed away.
/// forge-config: default.fuzz.runs = 1000
contract PropertiesTest is GameTest {
    function testFuzz_roundAndWindowMathAgreesWithIndependentClock(uint64 t, uint32 k) public {
        t = uint64(bound(t, 0, uint64(GENESIS) + 2000 days));
        k = uint32(bound(k, 0, 10_000));
        vm.warp(t);
        uint256 expectedRound = t < GENESIS ? 0 : (uint256(t) - GENESIS) / 600;
        assertEq(game.currentRound(), expectedRound);
        assertEq(game.currentWindow(), expectedRound / 6);
        assertEq(game.hasStarted(), t >= GENESIS);
        (uint64 startsAt, uint64 endsAt) = game.windowTimes(k);
        assertEq(startsAt, uint256(GENESIS) + uint256(k) * 3600);
        assertEq(endsAt - startsAt, 3600);
        // Window k covers rounds 6k..6k+5: it starts exactly when round 6k starts and ends when 6k+6 starts.
        assertEq(game.isBettingOpen(k), t < startsAt);
        if (t >= startsAt && t < endsAt) assertEq(game.currentWindow(), k);
    }

    function testFuzz_bettingClosesAtRoundStartNotBefore(uint32 k, uint16 before) public {
        k = uint32(bound(k, 0, 10_000));
        before = uint16(bound(before, 1, 3600));
        uint256 start = uint256(GENESIS) + uint256(k) * 3600;
        vm.warp(start - before);
        _ou(k, alice, true, 1 ether);
        vm.warp(start);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(k, alice, false, 1 ether);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _exact(k, alice, 1, 1 ether);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _sleep(k, alice, true, 1 ether);
    }

    function testFuzz_lineIsFloorAverageOfLastSevenSettlements(uint256[8] memory results) public {
        for (uint256 i; i < 8; ++i) {
            results[i] = bound(results[i], 0, type(uint256).max / 8);
            _exact(i, alice, 1, 1 ether);
        }
        for (uint256 i; i < 8; ++i) {
            _settle(i, results[i]);
        }
        uint256 sum;
        for (uint256 i = 1; i < 8; ++i) {
            sum += results[i];
        }
        assertEq(game.currentLine(), sum / 7, "line must be the floor average of the seven latest results");
        // A window created now freezes that line, even though later settlements will move it.
        uint256 next = game.currentWindow() + 1;
        _exact(next, bob, 1, 1 ether);
        assertEq(game.window(next).line, sum / 7);
    }

    function testFuzz_lineStaysBootstrapUntilSevenSettled(uint8 n, uint256 result) public {
        n = uint8(bound(n, 0, 6));
        result = bound(result, 0, 1e30);
        for (uint256 i; i < n; ++i) {
            _exact(i, alice, 1, 1 ether);
        }
        for (uint256 i; i < n; ++i) {
            _settle(i, result);
        }
        assertEq(game.currentLine(), 1000);
    }

    function testFuzz_sleepMarketSplitsNinetyOnePercentAmongWinnersOnly(
        uint128 yesA,
        uint128 yesB,
        uint128 no,
        uint256 result
    ) public {
        uint256 a = bound(yesA, 0.5 ether, 1e30);
        uint256 b = bound(yesB, 0.5 ether, 1e30);
        uint256 c = bound(no, 0.5 ether, 1e30);
        result = bound(result, 0, 1);
        _sleep(0, alice, true, a);
        _sleep(0, bob, true, b);
        _sleep(0, carol, false, c);
        _settle(0, result);
        uint256 pool = a + b + c;
        uint256 reward = pool - pool * 5 / 100 - pool * 3 / 100 - pool / 100;
        if (result == 0) {
            uint256 paid = _claim(0, alice) + _claim(0, bob);
            assertEq(paid, reward);
            vm.expectRevert(HamsterHour.NothingToClaim.selector);
            vm.prank(carol);
            game.claim(0);
        } else {
            assertEq(_claim(0, carol), reward);
            vm.expectRevert(HamsterHour.NothingToClaim.selector);
            vm.prank(alice);
            game.claim(0);
        }
        assertEq(game.window(0).teamCredit, pool / 100);
        assertEq(game.preStakingReserve(), pool * 5 / 100);
        assertEq(game.oracleReserve() + game.window(0).reimbursement, pool * 3 / 100);
        _assertBacked();
    }

    function testFuzz_overUnderOutcomeFollowsLineStrictly(uint128 overAmt, uint128 underAmt, uint256 result) public {
        uint256 o = bound(overAmt, 0.5 ether, 1e30);
        uint256 u = bound(underAmt, 0.5 ether, 1e30);
        result = bound(result, 0, 2000);
        _ou(0, alice, true, o);
        _ou(0, bob, false, u);
        _settle(0, result);
        uint256 pool = o + u;
        uint256 reward = pool - pool * 5 / 100 - pool * 3 / 100 - pool / 100;
        if (result == 1000) {
            assertEq(_claim(0, alice), o, "push refunds OVER");
            assertEq(_claim(0, bob), u, "push refunds UNDER");
            assertEq(game.window(0).teamCredit, 0);
        } else if (result > 1000) {
            assertEq(_claim(0, alice), reward);
            vm.expectRevert(HamsterHour.NothingToClaim.selector);
            vm.prank(bob);
            game.claim(0);
        } else {
            assertEq(_claim(0, bob), reward);
            vm.expectRevert(HamsterHour.NothingToClaim.selector);
            vm.prank(alice);
            game.claim(0);
        }
        _assertBacked();
    }

    function testFuzz_exactThreeTiersAreSixtyThirtyTenOfRewardAndNothingStrands(
        uint128[5] memory amounts,
        uint64 result
    ) public {
        uint256 total;
        address[5] memory who = [alice, bob, carol, dave, TEAM];
        for (uint256 i; i < 5; ++i) {
            uint256 amount = bound(amounts[i], 0.5 ether, 1e30);
            amounts[i] = uint128(amount);
            total += amount;
            // Distinct distances i+1 so the ranking is unambiguous: who[0] closest, who[4] furthest.
            _exact(0, who[i], uint256(result) + i + 1, amount);
        }
        _settle(0, result);
        HamsterHour.Window memory w = game.window(0);
        uint256 reward = total - total * 5 / 100 - total * 3 / 100 - total / 100;
        assertEq(w.rewards[1], reward);
        assertEq(w.rankCount, 3);
        assertEq(w.rankRewards[1], reward * 30 / 100);
        assertEq(w.rankRewards[2], reward * 10 / 100);
        assertEq(w.rankRewards[0] + w.rankRewards[1] + w.rankRewards[2], reward);
        assertEq(_claim(0, alice), w.rankRewards[0]);
        assertEq(_claim(0, bob), w.rankRewards[1]);
        assertEq(_claim(0, carol), w.rankRewards[2]);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(dave);
        game.claim(0);
        // TEAM's own ticket lost; it still receives the 1% fee and nothing else.
        assertEq(_claim(0, TEAM), total / 100);
        _assertBacked();
    }

    function testFuzz_stakingAccumulatorNeverOverpaysAndLosesOnlyDust(uint128[3] memory stakeSeeds, uint128 betSeed)
        public
    {
        _configure(true, address(stakeToken));
        address[3] memory who = [alice, bob, carol];
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 amount = bound(stakeSeeds[i], 1, 1e30);
            total += amount;
            vm.prank(who[i]);
            game.stake(amount);
        }
        uint256 bet = bound(betSeed, 0.5 ether, 1e30);
        _exact(0, dave, 1, bet);
        _settle(0, 1);
        uint256 share = bet * 5 / 100;
        uint256 pending;
        for (uint256 i; i < 3; ++i) {
            pending += game.pendingStaking(who[i]);
        }
        assertLe(pending, share, "stakers can never claim more than the 5% share");
        assertLe(share - pending, total / 1e27 + 3, "only accumulator dust may be lost");
        uint256 paid;
        for (uint256 i; i < 3; ++i) {
            uint256 beforeBalance = imd.balanceOf(who[i]);
            if (game.pendingStaking(who[i]) != 0) {
                vm.prank(who[i]);
                game.claimStaking();
                paid += imd.balanceOf(who[i]) - beforeBalance;
            }
            // A dust-only (or already claimed) staker has nothing to claim.
            vm.expectRevert(HamsterHour.NothingToClaim.selector);
            vm.prank(who[i]);
            game.claimStaking();
        }
        assertEq(paid, pending);
        _assertBacked();
    }

    function testFuzz_lateStakerEarnsNothingFromEarlierSettlement(uint128 early, uint128 late) public {
        _configure(true, address(stakeToken));
        uint256 a = bound(early, 1, 1e30);
        uint256 b = bound(late, 1, 1e30);
        vm.prank(alice);
        game.stake(a);
        _exact(0, carol, 1, 100 ether);
        _settle(0, 1);
        vm.prank(bob);
        game.stake(b);
        assertEq(game.pendingStaking(bob), 0);
        assertLe(game.pendingStaking(alice), 5 ether);
        assertGe(game.pendingStaking(alice), 5 ether - a / 1e27 - 1);
    }

    function testFuzz_voidedWindowRefundsEveryBetExactly(uint128 x, uint128 y, uint128 z, uint256 guess) public {
        uint256 a = bound(x, 0.5 ether, 1e30);
        uint256 b = bound(y, 0.5 ether, 1e30);
        uint256 c = bound(z, 0.5 ether, 1e30);
        _ou(0, alice, true, a);
        _exact(0, alice, guess, b);
        _sleep(0, alice, false, c);
        _ou(0, bob, false, a);
        vm.warp(GENESIS + 1 hours + 48 hours);
        assertEq(_claim(0, alice), a + b + c);
        assertEq(_claim(0, bob), a);
        assertEq(game.imdLiability(), 0);
        assertEq(imd.balanceOf(address(game)), 0);
    }

    /// @dev An existing window closes at the earlier of its snapshotted start and its start under the
    /// current genesis, whichever direction genesis moved; the view and the bet entry agree exactly.
    function testFuzz_existingWindowClosesAtEarlierOfSnapshotAndCorrectedStart(uint16 k, int32 shift, uint32 at)
        public
    {
        uint256 window = bound(k, 100, 5000);
        int256 delta = bound(shift, -int256(uint256(200 hours)), int256(uint256(200 hours)));
        _ou(window, alice, true, 1 ether);
        (uint64 snapStart,) = game.windowTimes(window);
        uint64 corrected = uint64(uint256(int256(uint256(GENESIS)) + delta));
        vm.prank(TEAM);
        game.scheduleGenesisTimestamp(corrected);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(TEAM);
        game.setGenesisTimestamp(corrected);
        uint256 scheduled = uint256(corrected) + window * 3600;
        uint256 close = scheduled < snapStart ? scheduled : snapStart;
        uint256 t = bound(at, block.timestamp, uint256(snapStart) + 1 hours);
        vm.warp(t);
        bool open = t < close;
        assertEq(game.isBettingOpen(window), open, "view disagrees with the earlier-start rule");
        if (!open) vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(window, bob, false, 1 ether);
        if (!open) vm.expectRevert(HamsterHour.BettingClosed.selector);
        _exact(window, bob, 7, 1 ether);
        if (!open) vm.expectRevert(HamsterHour.BettingClosed.selector);
        _sleep(window, bob, true, 1 ether);
        // The stored schedule never moves.
        (uint64 s, uint64 e) = game.windowTimes(window);
        assertEq(s, snapStart);
        assertEq(e, snapStart + 3600);
    }

    /// @dev Issuance strictly before the snapshotted end is refused for the whole settlement period;
    /// issuance at or after it is accepted up to the verifier's five-minute clock allowance.
    function testFuzz_attestationIssuedBeforeWindowEndIsNeverAccepted(uint32 lag, uint32 delay, uint16 lead) public {
        _exact(0, alice, 5, 1 ether);
        (, uint64 end) = game.windowTimes(0);
        uint256 lagS = bound(lag, 1, 7 days);
        uint256 delayS = bound(delay, 0, 48 hours - 1);
        uint256 leadS = bound(lead, 0, 300);
        vm.warp(uint256(end) + delayS);
        OracleAttestation.Attestation memory a = _a(0, 5);
        a.expiresAt = uint64(block.timestamp + 1 days);
        a.issuedAt = uint64(uint256(end) - lagS);
        bytes memory sig = _sign(a);
        vm.expectRevert(HamsterHour.AttestationPredatesEnd.selector);
        game.settle(0, a, sig);
        assertFalse(verifier.consumed(address(game), a.requestId));
        assertEq(uint256(game.window(0).status), uint256(HamsterHour.Status.Open));
        // Valid issuance: at least the window end and at most now + 300.
        uint256 issued = uint256(end) + delayS + leadS;
        a.issuedAt = uint64(issued);
        game.settle(0, a, _sign(a));
        assertEq(game.window(0).result, 5);
        assertEq(game.window(0).settler, address(this));
    }

    /// @dev Whatever the balance, a lone EXACT ticket never reserves a jackpot and the full amount it
    /// left behind is reserved by the next contested window.
    function testFuzz_loneTicketNeverReservesJackpot(uint128 balance, uint256 guess, uint256 result) public {
        _configure(false, address(prize));
        uint256 amount = bound(balance, 0, type(uint128).max);
        prize.mint(address(game), amount);
        _exact(0, alice, guess, 1 ether);
        _ou(0, alice, true, 1 ether);
        _ou(0, bob, false, 1 ether);
        _exact(1, bob, 1, 1 ether);
        _exact(1, carol, 2, 1 ether);
        _settle(0, result);
        assertEq(game.window(0).jackpot, 0);
        assertEq(game.window(0).jackpotAsset, address(0));
        assertEq(game.jackpotLiability(), 0);
        assertEq(game.window(0).rankCount, 1);
        // OVER wins above the bootstrap line, refunds on it, loses below it.
        uint256 overPayout = result > 1000 ? 1.82 ether : result == 1000 ? 1 ether : 0;
        assertEq(_claim(0, alice), 0.91 ether + overPayout);
        assertEq(prize.balanceOf(alice), 0);
        _settle(1, 1);
        assertEq(game.window(1).jackpot, amount);
        assertEq(game.jackpotLiability(), amount);
        _claim(1, bob);
        assertEq(prize.balanceOf(bob), amount);
    }
}
