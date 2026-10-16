// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {BrokenBalanceToken, NoReturnToken} from "./helpers/MockToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakingJackpotTest is GameTest {
    function test_stakingIsClosedUntilConfigured() public {
        vm.expectRevert(HamsterHour.TokenNotConfigured.selector);
        game.stake(1 ether);
        vm.expectRevert(HamsterHour.TokenNotConfigured.selector);
        game.unstake(1 ether);
        _configure(true, address(stakeToken));
        vm.prank(alice);
        game.stake(10 ether);
        assertEq(game.totalStaked(), 10 ether);
        vm.prank(alice);
        game.unstake(10 ether);
        assertEq(game.totalStaked(), 0);
    }

    function test_accumulatorTracksWeightsAtSettlementNotAtClaim() public {
        _configure(true, address(stakeToken));
        vm.prank(alice);
        game.stake(1 ether);
        vm.prank(bob);
        game.stake(3 ether);
        _exact(0, carol, 1000, 100 ether);
        _exact(1, carol, 1000, 100 ether);
        _settle(0, 1000);
        assertEq(game.pendingStaking(alice), 1.25 ether);
        assertEq(game.pendingStaking(bob), 3.75 ether);
        vm.prank(bob);
        game.unstake(2 ether);
        _settle(1, 1000);
        assertEq(game.pendingStaking(alice), 3.75 ether);
        assertEq(game.pendingStaking(bob), 6.25 ether);
        uint256 beforeBalance = imd.balanceOf(bob);
        vm.prank(bob);
        game.claimStaking();
        assertEq(imd.balanceOf(bob) - beforeBalance, 6.25 ether);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(bob);
        game.claimStaking();
        vm.prank(alice);
        game.unstake(1 ether);
        assertEq(game.pendingStaking(alice), 3.75 ether);
        vm.prank(alice);
        game.claimStaking();
        _assertBacked();
    }

    function test_preTokenReserveReleasedAcrossThirtyEligibleSettlements() public {
        _exact(0, carol, 10, 600 ether);
        _settle(0, 10);
        assertEq(game.preStakingReserve(), 30 ether);
        _configure(true, address(stakeToken));
        vm.prank(alice);
        game.stake(1 ether);
        uint256 first = game.currentWindow() + 1;
        for (uint256 i; i < 31; ++i) {
            _exact(first + i, carol, 10, 10 ether);
        }
        for (uint256 i; i < 30; ++i) {
            _settle(first + i, 10);
            assertEq(game.reserveReleased(), (i + 1) * 1 ether);
            assertEq(game.pendingStaking(alice), (i + 1) * 1.5 ether);
        }
        assertEq(game.preStakingReserve(), 0);
        assertEq(game.releaseWindows(), 30);
        _settle(first + 30, 10);
        assertEq(game.pendingStaking(alice), 45.5 ether);
        assertEq(game.reserveReleased(), 30 ether);
        vm.prank(alice);
        game.claimStaking();
        _assertBacked();
    }

    function test_noStakeRewardsWaitForLaterSettlementAndNoDepositRetroactiveClaim() public {
        _configure(true, address(stakeToken));
        _exact(0, carol, 1000, 100 ether);
        _exact(1, carol, 1000, 100 ether);
        _settle(0, 1000);
        assertEq(game.stakingUndistributed(), 5 ether);
        vm.prank(alice);
        game.stake(1 ether);
        assertEq(game.pendingStaking(alice), 0);
        _settle(1, 1000);
        assertEq(game.pendingStaking(alice), 10 ether);
        assertEq(game.stakingUndistributed(), 0);
    }

    function test_sameTokenJackpotExcludesPrincipalRewardsAndEarlierUnclaimedPrizes() public {
        _configure(true, address(imd));
        _configure(false, address(imd));
        vm.prank(alice);
        game.stake(200 ether);
        imd.mint(address(game), 1000 ether); // an unencumbered prize donation
        _exact(0, bob, 100, 100 ether);
        _exact(0, dave, 100, 100 ether);
        _exact(1, carol, 100, 100 ether);
        _exact(1, dave, 100, 100 ether);
        _settle(0, 100);
        assertEq(game.window(0).jackpot, 1000 ether);
        assertEq(game.jackpotLiability(), 1000 ether);
        _assertBacked();
        _settle(1, 100);
        assertEq(game.window(1).jackpot, 0);
        assertEq(_claim(1, carol), 91 ether);
        assertEq(_claim(0, bob), 591 ether);
        assertEq(_claim(0, dave), 591 ether);
        assertEq(_claim(1, dave), 91 ether);
        assertEq(game.jackpotLiability(), 0);
        vm.prank(alice);
        game.unstake(200 ether);
        vm.prank(alice);
        game.claimStaking();
        _assertBacked();
    }

    function test_loneExactTicketKeepsMarketPayoutButCannotTakeJackpot() public {
        _configure(false, address(prize));
        _exact(5, dave, 0, 0.5 ether);
        _exact(6, alice, 1000, 10 ether);
        _exact(6, bob, 1200, 10 ether);
        _exact(6, carol, 800, 10 ether);
        (, uint64 end6) = game.windowTimes(6);
        vm.warp(end6);
        prize.mint(address(game), 1000 ether);
        _settle(5, 123456);
        assertEq(game.window(5).jackpot, 0);
        assertEq(game.jackpotLiability(), 0);
        assertEq(_claim(5, dave), 0.455 ether);
        assertEq(prize.balanceOf(dave), 0);
        _settle(6, 1000);
        assertEq(game.window(6).jackpot, 1000 ether);
        _claim(6, alice);
        assertEq(prize.balanceOf(alice), 1000 ether);
        _assertBacked();
    }

    function test_jackpotSharesWithClosestTiesAndFullyPaysRemainder() public {
        _configure(false, address(prize));
        prize.mint(address(game), 101);
        _exact(0, alice, 10, 1 ether);
        _exact(0, bob, 10, 10 ether);
        _exact(0, carol, 12, 10 ether);
        _settle(0, 10);
        _claim(0, alice);
        _claim(0, bob);
        _claim(0, carol);
        assertEq(prize.balanceOf(alice), 50);
        assertEq(prize.balanceOf(bob), 51);
        assertEq(prize.balanceOf(carol), 0);
        assertEq(prize.balanceOf(address(game)), 0);
        assertEq(game.jackpotLiability(), 0);
    }

    function test_jackpotUsingStakeTokenDoesNotPayStakedPrincipal() public {
        _configure(true, address(stakeToken));
        _configure(false, address(stakeToken));
        vm.prank(alice);
        game.stake(500 ether);
        stakeToken.mint(address(game), 7 ether);
        _exact(0, bob, 0, 1 ether);
        _exact(0, carol, 3, 1 ether);
        _settle(0, 0);
        assertEq(game.window(0).jackpot, 7 ether);
        _claim(0, bob);
        assertEq(stakeToken.balanceOf(bob), 1e36 + 7 ether);
        assertEq(stakeToken.balanceOf(address(game)), 500 ether);
        vm.prank(alice);
        game.unstake(500 ether);
    }

    function test_tinyTiedJackpotRemainsClaimableAfterIMDOnlyClaims() public {
        _configure(false, address(prize));
        prize.mint(address(game), 1);
        _exact(0, alice, 10, 1 ether);
        _exact(0, bob, 10, 1 ether);
        _settle(0, 10);
        vm.prank(alice);
        game.claim(0, false);
        vm.prank(bob);
        game.claim(0, false);
        vm.prank(alice);
        game.claim(0);
        assertTrue(game.position(0, alice).jackpotClaimed);
        assertEq(prize.balanceOf(alice), 0);
        vm.prank(bob);
        game.claim(0);
        assertEq(prize.balanceOf(bob), 1);
        assertEq(game.jackpotLiability(), 0);
    }

    function test_jackpotRollsIfWindowHasNoExactAndTimeoutNeverAllocatesIt() public {
        _configure(false, address(prize));
        prize.mint(address(game), 100 ether);
        _ou(0, alice, true, 1 ether);
        _exact(1, bob, 1, 1 ether);
        _exact(60, carol, 1, 1 ether);
        _exact(60, dave, 2, 1 ether);
        _settle(0, 5);
        assertEq(game.window(0).jackpot, 0);
        vm.warp(GENESIS + 2 hours + 48 hours);
        game.voidWindow(1);
        assertEq(game.window(1).jackpot, 0);
        assertEq(_claim(1, bob), 1 ether);
        _settle(60, 1);
        assertEq(game.window(60).jackpot, 100 ether);
    }

    function test_failedPrizeTransferCannotTrapIMDAndCanRetryPrize() public {
        _configure(false, address(prize));
        prize.mint(address(game), 100 ether);
        _exact(0, alice, 0, 1 ether);
        _exact(0, bob, 5, 1 ether);
        _settle(0, 0);
        prize.setFail(true);
        vm.expectRevert();
        vm.prank(alice);
        game.claim(0);
        assertFalse(game.position(0, alice).imdClaimed);
        assertEq(game.jackpotLiability(), 100 ether);
        uint256 beforeBalance = imd.balanceOf(alice);
        vm.prank(alice);
        game.claim(0, false);
        assertEq(imd.balanceOf(alice) - beforeBalance, 1.274 ether);
        prize.setFail(false);
        vm.prank(alice);
        game.claim(0);
        assertEq(prize.balanceOf(alice), 100 ether);
        assertEq(game.jackpotLiability(), 0);
    }

    function test_badPrizeBalanceOfDoesNotStopSettlement() public {
        BrokenBalanceToken broken = new BrokenBalanceToken();
        _configure(false, address(broken));
        _exact(0, alice, 0, 1 ether);
        _exact(0, bob, 5, 1 ether);
        _settle(0, 0);
        assertEq(_claim(0, alice), 1.274 ether);
        assertEq(game.window(0).jackpot, 0);
    }

    function test_feeOnTransferAndFalseReturnDepositsFailAtomically() public {
        imd.setTaxed(true);
        vm.expectRevert(HamsterHour.UnsupportedToken.selector);
        _exact(0, alice, 0, 1 ether);
        assertEq(game.imdLiability(), 0);
        assertEq(game.exactEntries(0), 0);
        assertEq(uint256(game.window(0).status), uint256(HamsterHour.Status.Uncreated));
        imd.setTaxed(false);
        imd.setFail(true);
        vm.expectRevert();
        _ou(0, alice, true, 1 ether);
        assertEq(game.imdLiability(), 0);
        _configure(true, address(stakeToken));
        stakeToken.setTaxed(true);
        vm.expectRevert(HamsterHour.UnsupportedToken.selector);
        vm.prank(alice);
        game.stake(10 ether);
        assertEq(game.totalStaked(), 0);
    }

    function test_failedIMDPayoutLeavesEntitlementIntactForRetry() public {
        _ou(0, alice, true, 2 ether);
        _ou(0, bob, false, 3 ether);
        _settle(0, 1500);
        uint256 liability = game.imdLiability();
        imd.setFail(true);
        vm.expectRevert();
        vm.prank(alice);
        game.claim(0);
        assertFalse(game.position(0, alice).imdClaimed);
        assertEq(game.window(0).paid[0], 0);
        assertEq(game.imdLiability(), liability);
        imd.setFail(false);
        assertEq(_claim(0, alice), 4.55 ether);
        _assertBacked();
    }

    function test_nonReturningStakeAndPrizeTokensWork() public {
        NoReturnToken token = new NoReturnToken();
        _configure(true, address(token));
        _configure(false, address(token));
        token.mint(alice, 10 ether);
        token.mint(address(game), 5 ether);
        vm.startPrank(alice);
        token.approve(address(game), 10 ether);
        game.stake(10 ether);
        vm.stopPrank();
        _exact(0, bob, 0, 1 ether);
        _exact(0, carol, 3, 1 ether);
        _settle(0, 0);
        _claim(0, bob);
        assertEq(token.balanceOf(bob), 5 ether);
        vm.prank(alice);
        game.unstake(10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    function test_reentrancyBlockedOnDepositClaimAndUnstake() public {
        imd.setCallback(address(game), abi.encodeCall(game.betExact, (0, 1, 1 ether)));
        _exact(0, alice, 0, 1 ether);
        assertTrue(imd.attempted());
        assertFalse(imd.callbackSucceeded());
        assertEq(bytes4(imd.callbackReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        imd.setCallback(address(0), "");
        _settle(0, 0);
        imd.setCallback(address(game), abi.encodeWithSignature("claim(uint256)", 0));
        assertEq(_claim(0, alice), 0.91 ether);
        assertTrue(imd.attempted());
        assertFalse(imd.callbackSucceeded());
        assertEq(bytes4(imd.callbackReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        _configure(true, address(stakeToken));
        vm.prank(alice);
        game.stake(1 ether);
        stakeToken.setCallback(address(game), abi.encodeCall(game.unstake, (1 ether)));
        vm.prank(alice);
        game.unstake(1 ether);
        assertTrue(stakeToken.attempted());
        assertFalse(stakeToken.callbackSucceeded());
        _assertBacked();
        assertEq(bytes4(stakeToken.callbackReturnData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }
}
