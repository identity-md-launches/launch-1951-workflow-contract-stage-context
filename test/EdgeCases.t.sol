// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleVerifier} from "../src/OracleVerifier.sol";
import {OracleAttestation} from "../src/libraries/OracleAttestation.sol";

/// @notice Failure paths and boundary inputs the first suite does not pin: callers who are not who
/// the code assumed, the same call twice, exact deadlines, and events the brief requires.
contract EdgeCasesTest is GameTest {
    // ---------------------------------------------------------------- claims by the wrong people

    function test_strangerLoserAndRepeatClaimsAllRevertOnSettledWindow() public {
        _ou(0, alice, true, 2 ether);
        _ou(0, bob, false, 3 ether);
        _settle(0, 1500);
        // carol never bet on window 0.
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(carol);
        game.claim(0);
        // bob bet UNDER and lost: nothing to refund, nothing won.
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(bob);
        game.claim(0);
        assertEq(_claim(0, alice), 4.55 ether);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
        // The IMD-only overload is also a repeat for an exhausted position.
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0, false);
        _assertBacked();
    }

    function test_claimBeforeSettlementRevertsAndVoidRefundIsOnceOnly() public {
        _sleep(0, alice, true, 1 ether);
        vm.expectRevert(HamsterHour.NotFinal.selector);
        vm.prank(alice);
        game.claim(0);
        vm.warp(GENESIS + 1 hours + 10 minutes);
        vm.expectRevert(HamsterHour.NotFinal.selector);
        vm.prank(alice);
        game.claim(0);
        vm.warp(GENESIS + 1 hours + 48 hours);
        assertEq(_claim(0, alice), 1 ether);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(bob);
        game.claim(0);
        assertEq(game.imdLiability(), 0);
    }

    function test_teamGetsOnlyItsCreditAndNothingFromVoidedWindows() public {
        _ou(0, alice, true, 10 ether);
        _ou(0, bob, true, 10 ether);
        vm.warp(GENESIS + 1 hours + 48 hours);
        game.voidWindow(0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(TEAM);
        game.claim(0);
        _ou(60, alice, true, 10 ether);
        _ou(60, bob, true, 10 ether);
        _settle(60, 5);
        // One-sided market: no fee was taken, so TEAM has no credit here either.
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(TEAM);
        game.claim(60);
        assertEq(game.window(60).teamCredit, 0);
    }

    // ---------------------------------------------------------------- settlement deadlines

    function test_settlementAcceptedOneSecondBeforeTimeoutAndRefusedAtIt() public {
        _exact(0, alice, 5, 1 ether);
        (, uint64 end) = game.windowTimes(0);
        vm.warp(uint256(end) + 48 hours - 1);
        OracleAttestation.Attestation memory a = _a(0, 5);
        bytes memory sig = _sign(a);
        vm.prank(keeper);
        game.settle(0, a, sig);
        assertEq(uint256(game.window(0).status), uint256(HamsterHour.Status.Settled));
        assertEq(game.window(0).settler, keeper);

        _exact(60, alice, 5, 1 ether);
        (, end) = game.windowTimes(60);
        vm.warp(uint256(end) + 48 hours);
        a = _a(60, 5);
        sig = _sign(a);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(60, a, sig);
        assertFalse(verifier.consumed(address(game), a.requestId));
    }

    function test_settlementRefusedOneSecondBeforeWindowEnds() public {
        _exact(0, alice, 5, 1 ether);
        (, uint64 end) = game.windowTimes(0);
        vm.warp(uint256(end) - 1);
        OracleAttestation.Attestation memory early = _a(0, 5);
        bytes memory earlySig = _sign(early);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, early, earlySig);
        vm.warp(end);
        // The same attestation, now on time, was still signed one second before round 6k+5 ended.
        vm.expectRevert(HamsterHour.AttestationPredatesEnd.selector);
        game.settle(0, early, earlySig);
        assertFalse(verifier.consumed(address(game), early.requestId));
        assertEq(uint256(game.window(0).status), uint256(HamsterHour.Status.Open));
        // Issued exactly at the end is the first acceptable instant.
        OracleAttestation.Attestation memory a = _a(0, 5);
        assertEq(a.issuedAt, end);
        game.settle(0, a, _sign(a));
        assertEq(game.window(0).result, 5);
    }

    function test_attestationIssuedUpToFiveMinutesAheadOfChainIsAcceptedAtWindowEnd() public {
        _exact(0, alice, 5, 1 ether);
        (, uint64 end) = game.windowTimes(0);
        vm.warp(end);
        OracleAttestation.Attestation memory a = _a(0, 5);
        a.issuedAt = end + 300;
        a.expiresAt = end + 1 days;
        game.settle(0, a, _sign(a));
        assertEq(game.window(0).result, 5);

        _exact(60, alice, 5, 1 ether);
        (, end) = game.windowTimes(60);
        vm.warp(end);
        a = _a(60, 5);
        a.issuedAt = end + 301;
        a.expiresAt = end + 1 days;
        bytes memory sig = _sign(a);
        vm.expectRevert(OracleVerifier.InvalidValidityWindow.selector);
        game.settle(60, a, sig);
    }

    function test_predatedAttestationStaysRejectedForTheWholeSettlementPeriod() public {
        _exact(0, alice, 5, 1 ether);
        (, uint64 end) = game.windowTimes(0);
        vm.warp(end);
        OracleAttestation.Attestation memory a = _a(0, 5);
        a.issuedAt = end - 1;
        a.expiresAt = end + 3 days;
        bytes memory sig = _sign(a);
        // Waiting does not make a predated attestation valid: the bound is the window end, not the clock.
        vm.warp(uint256(end) + 47 hours);
        vm.expectRevert(HamsterHour.AttestationPredatesEnd.selector);
        game.settle(0, a, sig);
        vm.warp(uint256(end) + 48 hours - 1);
        vm.expectRevert(HamsterHour.AttestationPredatesEnd.selector);
        game.settle(0, a, sig);
        assertFalse(verifier.consumed(address(game), a.requestId));
    }

    function test_voidedWindowCannotBeSettledEvenWithValidAttestation() public {
        _exact(0, alice, 5, 1 ether);
        vm.warp(GENESIS + 1 hours + 48 hours);
        game.voidWindow(0);
        OracleAttestation.Attestation memory a = _a(0, 5);
        bytes memory sig = _sign(a);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        assertEq(game.settledWindows(), 0);
    }

    function test_settledWindowCannotBeVoidedAndSettledTwiceWithFreshRequest() public {
        _exact(0, alice, 5, 1 ether);
        _settle(0, 5);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.voidWindow(0);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.voidWindow(0);
        OracleAttestation.Attestation memory a = _a(0, 99);
        bytes memory sig = _sign(a);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        assertEq(game.window(0).result, 5);
        assertEq(game.settledWindows(), 1);
    }

    function test_windowsSettleInAnyOrderAndLineFollowsSettlementOrder() public {
        for (uint256 i; i < 8; ++i) {
            _exact(i, alice, 1, 1 ether);
        }
        vm.warp(GENESIS + 9 hours);
        uint256[8] memory results = [uint256(700), 100, 200, 300, 400, 500, 600, 800];
        // Settle 7 first, then 0..6: the ring holds the seven most recent settlements.
        _settle(7, results[7]);
        for (uint256 i; i < 7; ++i) {
            _settle(i, results[i]);
        }
        assertEq(game.settledWindows(), 8);
        assertEq(game.currentLine(), (700 + 100 + 200 + 300 + 400 + 500 + 600) / 7);
    }

    // ---------------------------------------------------------------- oracle reserve

    function test_reserveExactlyHalfIMDFundsReimbursementOneWeiLessDefers() public {
        // Fees: 3% of 16 IMD = 0.48 IMD < 0.5, so the settler is deferred.
        _exact(0, alice, 5, 8 ether);
        _exact(0, bob, 7, 8 ether);
        _settle(0, 5);
        assertEq(game.oracleReserve(), 0.48 ether);
        assertEq(game.window(0).reimbursement, 0);
        vm.prank(carol);
        game.fundOracleReserve(0.02 ether - 1);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(keeper);
        game.claim(0);
        vm.prank(carol);
        game.fundOracleReserve(1);
        assertEq(_claim(0, keeper), 0.5 ether);
        assertEq(game.oracleReserve(), 0);
        assertTrue(game.window(0).reimbursed);
        _assertBacked();
    }

    function test_eachSettlerIsReimbursedOnceAndOnlyTheRecordedSettler() public {
        _exact(0, alice, 5, 100 ether);
        _exact(1, alice, 5, 100 ether);
        _settle(0, 5);
        (, uint64 end) = game.windowTimes(1);
        vm.warp(end);
        OracleAttestation.Attestation memory a = _a(1, 5);
        bytes memory sig = _sign(a);
        vm.prank(dave);
        game.settle(1, a, sig);
        assertEq(game.oracleReserve(), 6 ether - 1 ether);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(keeper);
        game.claim(1);
        assertEq(_claim(1, dave), 0.5 ether);
        assertEq(_claim(0, keeper), 0.5 ether);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(dave);
        game.claim(1);
        _assertBacked();
    }

    function test_fundOracleReserveRejectsZeroAndNeedsAllowance() public {
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        vm.prank(alice);
        game.fundOracleReserve(0);
        address stranger = makeAddr("stranger");
        imd.mint(stranger, 1 ether);
        vm.expectRevert();
        vm.prank(stranger);
        game.fundOracleReserve(1 ether);
        assertEq(game.oracleReserve(), 0);
        assertEq(game.imdLiability(), 0);
    }

    // ---------------------------------------------------------------- staking inputs

    function test_stakeAndUnstakeRejectZeroExcessAndCaps() public {
        _configure(true, address(stakeToken));
        vm.startPrank(alice);
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        game.stake(0);
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        game.unstake(0);
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        game.unstake(1);
        game.stake(5 ether);
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        game.unstake(5 ether + 1);
        uint256 cap = type(uint128).max;
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        game.stake(cap - 5 ether + 1);
        game.unstake(5 ether);
        vm.stopPrank();
        // bob cannot unstake alice's deposit.
        vm.expectRevert(HamsterHour.InvalidAmount.selector);
        vm.prank(bob);
        game.unstake(1);
        assertEq(game.totalStaked(), 0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claimStaking();
    }

    function test_claimStakingBeforeTokenIsNothingToClaim() public {
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claimStaking();
    }

    function test_allMarketsVoidedStillCountsAsReleaseWindowWithZeroShare() public {
        _exact(0, carol, 10, 600 ether);
        _settle(0, 10);
        _configure(true, address(stakeToken));
        vm.prank(alice);
        game.stake(1 ether);
        uint256 k = game.currentWindow() + 1;
        _ou(k, alice, true, 1 ether);
        _ou(k, bob, true, 1 ether);
        _settle(k, 10);
        // No fee from the one-sided market; the reserve release alone reaches the staker.
        assertEq(game.releaseWindows(), 1);
        assertEq(game.pendingStaking(alice), 1 ether);
        assertEq(_claim(k, alice), 1 ether);
        assertEq(_claim(k, bob), 1 ether);
    }

    function test_stakingAfterReserveFullyReleasedGetsOnlyLiveShare() public {
        _configure(true, address(stakeToken));
        assertEq(game.releaseTotal(), 0);
        vm.prank(alice);
        game.stake(1 ether);
        _exact(0, carol, 10, 100 ether);
        _settle(0, 10);
        assertEq(game.reserveReleased(), 0);
        assertEq(game.pendingStaking(alice), 5 ether);
    }

    // ---------------------------------------------------------------- jackpot

    function test_jackpotReservedForEarlierWindowIsNotPaidTwice() public {
        _configure(false, address(prize));
        prize.mint(address(game), 100 ether);
        // Two tickets per window: a lone ticket is uncontested and would leave the jackpot in place.
        _exact(0, alice, 1, 1 ether);
        _exact(0, carol, 500, 1 ether);
        _exact(1, bob, 1, 1 ether);
        _exact(1, dave, 500, 1 ether);
        _settle(0, 1);
        prize.mint(address(game), 50 ether);
        _settle(1, 1);
        assertEq(game.window(0).jackpot, 100 ether);
        assertEq(game.window(1).jackpot, 50 ether);
        assertEq(game.jackpotLiability(), 150 ether);
        _claim(1, bob);
        assertEq(prize.balanceOf(bob), 50 ether);
        _claim(0, alice);
        assertEq(prize.balanceOf(alice), 100 ether);
        assertEq(prize.balanceOf(address(game)), 0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
    }

    function test_threeWayTiedJackpotPaysWholeBalanceWithRemainderToLast() public {
        _configure(false, address(prize));
        prize.mint(address(game), 100);
        _exact(0, alice, 10, 1 ether);
        _exact(0, bob, 10, 1 ether);
        _exact(0, carol, 10, 1 ether);
        _exact(0, dave, 11, 1 ether);
        _settle(0, 10);
        _claim(0, alice);
        _claim(0, bob);
        _claim(0, carol);
        assertEq(prize.balanceOf(alice), 33);
        assertEq(prize.balanceOf(bob), 33);
        assertEq(prize.balanceOf(carol), 34);
        _claim(0, dave);
        assertEq(prize.balanceOf(dave), 0);
        assertEq(game.jackpotLiability(), 0);
        assertEq(prize.balanceOf(address(game)), 0);
    }

    function test_secondPlaceNeverReceivesJackpot() public {
        _configure(false, address(prize));
        prize.mint(address(game), 10 ether);
        _exact(0, alice, 10, 1 ether);
        _exact(0, bob, 20, 1 ether);
        _settle(0, 12);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(carol);
        game.claim(0);
        _claim(0, bob);
        assertEq(prize.balanceOf(bob), 0);
        assertEq(game.jackpotLiability(), 10 ether);
        _claim(0, alice);
        assertEq(prize.balanceOf(alice), 10 ether);
    }

    function test_jackpotIsSnapshotAtSettlementNotAtClaim() public {
        _configure(false, address(prize));
        prize.mint(address(game), 1 ether);
        _exact(0, alice, 10, 1 ether);
        _exact(0, bob, 20, 1 ether);
        _settle(0, 10);
        prize.mint(address(game), 9 ether);
        _claim(0, alice);
        assertEq(prize.balanceOf(alice), 1 ether);
        assertEq(prize.balanceOf(address(game)), 9 ether);
    }

    function test_loneTicketLeavesJackpotEvenWithOtherMarketsAndAfterAContestedWindow() public {
        _configure(false, address(prize));
        prize.mint(address(game), 10 ether);
        // Window 0 is contested and takes the balance at its settlement.
        _exact(0, alice, 10, 1 ether);
        _exact(0, bob, 20, 1 ether);
        // Window 1 has one EXACT ticket plus live binary markets: still uncontested for the jackpot.
        _exact(1, carol, 10, 1 ether);
        _ou(1, alice, true, 1 ether);
        _ou(1, bob, false, 1 ether);
        _sleep(1, alice, true, 1 ether);
        _sleep(1, bob, false, 1 ether);
        // Window 2 is contested by a tie: two tickets with the same guess make a contest.
        _exact(2, alice, 10, 1 ether);
        _exact(2, bob, 10, 1 ether);
        _settle(0, 10);
        assertEq(game.window(0).jackpot, 10 ether);
        prize.mint(address(game), 4 ether);
        _settle(1, 10);
        assertEq(game.exactEntries(1), 1);
        assertEq(game.window(1).jackpot, 0);
        assertEq(game.window(1).jackpotAsset, address(0));
        assertEq(game.jackpotLiability(), 10 ether, "a lone ticket must not change jackpot liability");
        // The lone ticket still wins its whole EXACT reward (60% plus the returned lower tiers), no prize.
        assertEq(_claim(1, carol), 0.91 ether);
        assertEq(prize.balanceOf(carol), 0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(carol);
        game.claim(1);
        _settle(2, 10);
        assertEq(game.window(2).jackpot, 4 ether, "the donation skipped by the lone ticket goes to the next contest");
        _claim(2, alice);
        _claim(2, bob);
        assertEq(prize.balanceOf(alice), 2 ether);
        assertEq(prize.balanceOf(bob), 2 ether);
        _claim(0, alice);
        assertEq(prize.balanceOf(alice), 12 ether);
        assertEq(prize.balanceOf(address(game)), 0);
        assertEq(game.jackpotLiability(), 0);
    }

    function test_loneTicketWindowKeepsTheRuleWhenTheSecondTicketIsRefusedAtStart() public {
        _configure(false, address(prize));
        prize.mint(address(game), 3 ether);
        _exact(0, alice, 10, 1 ether);
        (uint64 start,) = game.windowTimes(0);
        vm.warp(start);
        // A second entry one second late does not make it a contest.
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _exact(0, bob, 11, 1 ether);
        _settle(0, 10);
        assertEq(game.window(0).jackpot, 0);
        assertEq(_claim(0, alice), 0.91 ether);
        assertEq(prize.balanceOf(address(game)), 3 ether);
    }

    // ---------------------------------------------------------------- fee-less settlements

    function test_fullyRefundedSettlementNeverReimbursesEvenAfterTheReserveIsFunded() public {
        // Every market one-sided: no fee, no reimbursement, flag set at settlement.
        _ou(0, alice, true, 5 ether);
        _sleep(0, bob, false, 5 ether);
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        _settle(0, 7);
        HamsterHour.Window memory w = game.window(0);
        assertTrue(w.reimbursed);
        assertEq(w.reimbursement, 0);
        assertTrue(w.marketVoided[0]);
        assertTrue(w.marketVoided[2]);
        assertEq(game.oracleReserve(), 1 ether, "a fee-less settlement must not touch the reserve");
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(keeper);
        game.claim(0);
        // Funding arriving later does not revive a reimbursement that was never earned.
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(keeper);
        game.claim(0);
        assertEq(game.oracleReserve(), 2 ether);
        assertEq(_claim(0, alice), 5 ether);
        assertEq(_claim(0, bob), 5 ether);
        assertEq(game.imdLiability(), 2 ether);
        _assertBacked();
    }

    function test_oneLiveMarketIsEnoughToEarnTheReimbursement() public {
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        _ou(0, alice, true, 5 ether); // one-sided: refunded
        _sleep(0, alice, true, 0.5 ether); // the smallest live market
        _sleep(0, bob, false, 0.5 ether);
        _settle(0, 7);
        HamsterHour.Window memory w = game.window(0);
        assertFalse(w.reimbursed);
        assertEq(w.reimbursement, 0.5 ether);
        assertEq(game.oracleReserve(), 1 ether + 0.03 ether - 0.5 ether);
        assertEq(_claim(0, keeper), 0.5 ether);
        assertEq(_claim(0, alice), 5 ether);
        assertEq(_claim(0, bob), 0.91 ether);
        _assertBacked();
    }

    function test_equalLineRefundIsFeelessAndTakesNoReimbursement() public {
        vm.prank(carol);
        game.fundOracleReserve(1 ether);
        _ou(0, alice, true, 5 ether);
        _ou(0, bob, false, 5 ether);
        _settle(0, 1000); // result equals the bootstrap line: the only market refunds
        assertTrue(game.window(0).reimbursed);
        assertEq(game.oracleReserve(), 1 ether);
        assertEq(game.window(0).teamCredit, 0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(keeper);
        game.claim(0);
        assertEq(_claim(0, alice), 5 ether);
        assertEq(_claim(0, bob), 5 ether);
    }

    // ---------------------------------------------------------------- genesis corrections and open windows

    function test_earlierGenesisClosesAtTheExactCorrectedSecondAndKeepsRefundSchedule() public {
        _ou(10, alice, true, 1 ether);
        (uint64 snapStart, uint64 snapEnd) = game.windowTimes(10);
        // Correct genesis so window 10's rounds begin exactly 48 hours after this proposal executes.
        uint64 executeAt = uint64(block.timestamp + 48 hours);
        uint64 corrected = executeAt + 1 hours - 10 * 3600;
        vm.prank(TEAM);
        game.scheduleGenesisTimestamp(corrected);
        vm.warp(executeAt);
        vm.prank(TEAM);
        game.setGenesisTimestamp(corrected);
        uint256 correctedStart = uint256(corrected) + 10 * 3600;
        assertLt(correctedStart, snapStart);
        vm.warp(correctedStart - 1);
        assertTrue(game.isBettingOpen(10));
        _ou(10, bob, false, 1 ether);
        vm.warp(correctedStart);
        assertFalse(game.isBettingOpen(10));
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(10, carol, true, 1 ether);
        // The stored schedule is unchanged, so the window is not settleable before its snapshotted end.
        (uint64 s, uint64 e) = game.windowTimes(10);
        assertEq(s, snapStart);
        assertEq(e, snapEnd);
        OracleAttestation.Attestation memory a = _a(10, 5);
        bytes memory sig = _sign(a);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(10, a, sig);
        // Nor voidable before the snapshotted end plus 48 hours.
        vm.warp(uint256(snapEnd) + 48 hours - 1);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.voidWindow(10);
        vm.warp(uint256(snapEnd) + 48 hours);
        game.voidWindow(10);
        assertEq(_claim(10, alice), 1 ether);
        assertEq(_claim(10, bob), 1 ether);
    }

    function test_earlierGenesisDoesNotCloseWindowsWhoseCorrectedStartIsStillAhead() public {
        _ou(100, alice, true, 1 ether);
        uint64 corrected = GENESIS - 1 hours;
        vm.prank(TEAM);
        game.scheduleGenesisTimestamp(corrected);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(TEAM);
        game.setGenesisTimestamp(corrected);
        assertTrue(game.isBettingOpen(100));
        _ou(100, bob, false, 1 ether);
        // It closes one hour before the snapshotted start, not at it.
        (uint64 snapStart,) = game.windowTimes(100);
        vm.warp(snapStart - 1 hours - 1);
        _ou(100, bob, false, 1 ether);
        vm.warp(snapStart - 1 hours);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(100, bob, false, 1 ether);
    }

    function test_jackpotTokenSetAfterSettlementDoesNotApplyRetroactively() public {
        prize.mint(address(game), 5 ether);
        _exact(0, alice, 10, 1 ether);
        _settle(0, 10);
        _configure(false, address(prize));
        assertEq(game.window(0).jackpot, 0);
        assertEq(_claim(0, alice), 0.91 ether);
        assertEq(prize.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- windows and configuration

    function test_farFutureWindowFreezesCurrentLineAndSourceAtCreation() public {
        // Any address can create a window years ahead; it keeps today's line and source forever.
        uint256 far = 100_000;
        _exact(far, alice, 1, 0.5 ether);
        HamsterHour.Window memory w = game.window(far);
        assertEq(w.line, 1000);
        assertEq(w.source, "https://sepolia.squeekchain.com");
        assertEq(w.startsAt, GENESIS + far * 3600);
        vm.expectRevert(HamsterHour.InvalidWindow.selector);
        game.windowTimes(type(uint256).max / 3600);
    }

    function test_closedWindowFloorNeverDecreasesAndIgnoresPreGenesisChanges() public {
        vm.prank(TEAM);
        game.scheduleGenesisTimestamp(GENESIS + 1);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(TEAM);
        game.setGenesisTimestamp(GENESIS + 1);
        assertEq(game.closedWindowFloor(), 0);
        vm.warp(GENESIS + 1 + 10 hours);
        vm.prank(TEAM);
        game.scheduleGenesisTimestamp(GENESIS + 200 days);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(TEAM);
        game.setGenesisTimestamp(GENESIS + 200 days);
        assertEq(game.closedWindowFloor(), 59);
        // A second correction while nothing has started under the new genesis keeps the floor.
        vm.prank(TEAM);
        game.scheduleGenesisTimestamp(GENESIS + 300 days);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(TEAM);
        game.setGenesisTimestamp(GENESIS + 300 days);
        assertEq(game.closedWindowFloor(), 59);
        assertFalse(game.isBettingOpen(58));
        assertTrue(game.isBettingOpen(59));
    }

    function test_pendingTimelockIsConsumedByExecution() public {
        vm.startPrank(TEAM);
        game.scheduleGenesisTimestamp(GENESIS + 1);
        vm.warp(block.timestamp + 48 hours);
        game.setGenesisTimestamp(GENESIS + 1);
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setGenesisTimestamp(GENESIS + 1);
        (bytes32 valueHash, uint64 readyAt) = game.pendingConfig(game.GENESIS_SETTING());
        assertEq(valueHash, bytes32(0));
        assertEq(readyAt, 0);
        vm.stopPrank();
    }

    function test_sourceLengthBoundsAndAllowedCharacters() public {
        vm.startPrank(TEAM);
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl("https://");
        game.scheduleSourceUrl("https://a");
        bytes memory long = new bytes(257);
        for (uint256 i; i < 257; ++i) {
            long[i] = "a";
        }
        bytes memory prefix = "https://";
        for (uint256 i; i < 8; ++i) {
            long[i] = prefix[i];
        }
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl(string(long));
        bytes memory maxLen = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            maxLen[i] = i < 8 ? prefix[i] : bytes1("b");
        }
        game.scheduleSourceUrl(string(maxLen));
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl("https://exa mple.org");
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl("https://example.org/\\path");
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl(unicode"https://exämple.org");
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl("HTTPS://example.org");
        vm.stopPrank();
    }

    function test_questionViewsRevertForUncreatedWindow() public {
        vm.expectRevert(HamsterHour.InvalidWindow.selector);
        game.question(3);
        vm.expectRevert(HamsterHour.InvalidWindow.selector);
        game.questionHash(3, 1, 2);
    }

    // ---------------------------------------------------------------- events the brief requires

    function test_betSettleSplitAndClaimEvents() public {
        vm.expectEmit(true, false, false, true);
        emit HamsterHour.WindowCreated(0, GENESIS, GENESIS + 3600, 1000, "https://sepolia.squeekchain.com");
        vm.expectEmit(true, true, true, true);
        emit HamsterHour.Bet(0, alice, HamsterHour.Market.OverUnder, 1, 10 ether);
        _ou(0, alice, true, 10 ether);
        vm.expectEmit(true, true, true, true);
        emit HamsterHour.Bet(0, bob, HamsterHour.Market.Exact, 777, 10 ether);
        _exact(0, bob, 777, 10 ether);
        vm.expectEmit(true, true, true, true);
        emit HamsterHour.Bet(0, carol, HamsterHour.Market.Sleep, 1, 10 ether);
        _sleep(0, carol, true, 10 ether);
        _ou(0, bob, false, 10 ether);

        vm.warp(GENESIS + 1 hours);
        OracleAttestation.Attestation memory a = _a(0, 900);
        bytes memory sig = _sign(a);
        vm.expectEmit(true, true, false, false);
        emit HamsterHour.MarketVoided(0, HamsterHour.Market.Sleep);
        vm.expectEmit(true, true, false, true);
        emit HamsterHour.OracleRewardReserved(0, keeper, 0.5 ether);
        vm.expectEmit(true, false, false, true);
        emit HamsterHour.Split(0, 27.3 ether, 1.5 ether, 0.9 ether, 0.3 ether);
        vm.expectEmit(true, true, true, true);
        emit HamsterHour.Settled(0, 900, a.requestId, keeper);
        vm.prank(keeper);
        game.settle(0, a, sig);

        // bob: UNDER wins the whole 91% of the 20 IMD O/U pool, plus 91% of his lone EXACT ticket.
        vm.expectEmit(true, true, false, true);
        emit HamsterHour.Claimed(0, bob, 18.2 ether + 9.1 ether, address(0), 0);
        vm.prank(bob);
        game.claim(0);
        vm.expectEmit(true, true, false, true);
        emit HamsterHour.Claimed(0, carol, 10 ether, address(0), 0);
        vm.prank(carol);
        game.claim(0);
    }

    function test_voidStakeUnstakeAndConfigEvents() public {
        _exact(0, alice, 1, 1 ether);
        vm.warp(GENESIS + 1 hours + 48 hours);
        vm.expectEmit(true, false, false, false);
        emit HamsterHour.WindowVoided(0);
        vm.prank(alice);
        game.claim(0);

        uint64 readyAt = uint64(block.timestamp + 48 hours);
        vm.expectEmit(true, false, false, true);
        emit HamsterHour.ConfigScheduled(game.STAKING_SETTING(), abi.encode(address(stakeToken)), readyAt);
        vm.prank(TEAM);
        game.scheduleStakingToken(address(stakeToken));
        vm.warp(readyAt);
        vm.expectEmit(true, false, false, true);
        emit HamsterHour.ConfigChanged(game.STAKING_SETTING(), abi.encode(address(stakeToken)));
        vm.prank(TEAM);
        game.setStakingToken(address(stakeToken));
        assertEq(game.stakingActivatedAt(), readyAt);

        vm.expectEmit(true, false, false, true);
        emit HamsterHour.Staked(alice, 3 ether);
        vm.prank(alice);
        game.stake(3 ether);
        vm.expectEmit(true, false, false, true);
        emit HamsterHour.Unstaked(alice, 2 ether);
        vm.prank(alice);
        game.unstake(2 ether);

        uint256 k = game.currentWindow() + 1;
        _exact(k, bob, 1, 100 ether);
        (, uint64 end) = game.windowTimes(k);
        vm.warp(end);
        OracleAttestation.Attestation memory a = _a(k, 1);
        bytes memory sig = _sign(a);
        vm.expectEmit(false, false, false, true);
        emit HamsterHour.StakingDistributed(5 ether, 5 ether * 1e27 / 1 ether, 0);
        game.settle(k, a, sig);
        vm.expectEmit(true, false, false, true);
        emit HamsterHour.StakingClaimed(alice, 5 ether);
        vm.prank(alice);
        game.claimStaking();
    }

    function test_oracleConsumedEventNamesGameAsConsumer() public {
        _exact(0, alice, 1, 1 ether);
        vm.warp(GENESIS + 1 hours);
        OracleAttestation.Attestation memory a = _a(0, 1);
        bytes memory sig = _sign(a);
        vm.expectEmit(true, true, true, false, address(verifier));
        emit OracleVerifier.AttestationConsumed(address(game), a.requestId, a.questionHash);
        game.settle(0, a, sig);
    }
}
