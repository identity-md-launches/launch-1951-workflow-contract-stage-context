// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleAttestation} from "../src/libraries/OracleAttestation.sol";

contract MarketsTest is GameTest {
    function test_allMarketsAndFullSplitConservation() public {
        _ou(0, alice, true, 10 ether);
        _ou(0, bob, true, 30 ether);
        _ou(0, carol, false, 60 ether);
        _exact(0, alice, 1200, 10 ether);
        _exact(0, bob, 1201, 30 ether);
        _exact(0, carol, 1250, 60 ether);
        _sleep(0, alice, true, 10 ether);
        _sleep(0, bob, false, 30 ether);
        _sleep(0, carol, false, 60 ether);
        _settle(0, 1200);
        HamsterHour.Window memory w = game.window(0);
        assertEq(w.rewards[0], 91 ether);
        assertEq(w.rewards[1], 91 ether);
        assertEq(w.rewards[2], 91 ether);
        assertEq(w.teamCredit, 3 ether);
        assertEq(game.preStakingReserve(), 15 ether);
        assertEq(game.oracleReserve(), 8.5 ether);
        assertEq(w.reimbursement, 0.5 ether);
        assertEq(_claim(0, alice), 22.75 ether + 54.6 ether);
        uint256 b = _claim(0, bob);
        uint256 c = _claim(0, carol);
        assertEq(b + c, 273 ether - 22.75 ether - 54.6 ether);
        assertEq(_claim(0, TEAM), 3 ether);
        assertEq(_claim(0, keeper), 0.5 ether);
        assertEq(imd.balanceOf(address(game)), 23.5 ether);
        assertEq(game.imdLiability(), 23.5 ether);
        _assertBacked();
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(alice);
        game.claim(0);
    }

    function test_sleepYesAndUnderWinAtZero() public {
        _sleep(0, alice, true, 2 ether);
        _sleep(0, bob, false, 3 ether);
        _ou(0, alice, false, 4 ether);
        _ou(0, bob, true, 6 ether);
        _settle(0, 0);
        assertEq(_claim(0, alice), 13.65 ether);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(bob);
        game.claim(0);
        _assertBacked();
    }

    function test_oneSidedMarketsRefundWithoutTakingFees() public {
        _ou(0, alice, true, 10 ether);
        _ou(0, bob, true, 20 ether);
        _sleep(0, carol, false, 40 ether);
        _exact(0, dave, 1200, 100 ether);
        _settle(0, 1200);
        assertEq(_claim(0, alice), 10 ether);
        assertEq(_claim(0, bob), 20 ether);
        assertEq(_claim(0, carol), 40 ether);
        assertEq(_claim(0, dave), 91 ether);
        assertEq(game.window(0).teamCredit, 1 ether);
        assertEq(game.preStakingReserve(), 5 ether);
        _assertBacked();
    }

    function test_equalToLinePushesOverUnder() public {
        _ou(0, alice, true, 7 ether);
        _ou(0, bob, false, 13 ether);
        _settle(0, 1000);
        assertEq(_claim(0, alice), 7 ether);
        assertEq(_claim(0, bob), 13 ether);
        assertEq(game.window(0).teamCredit, 0);
        assertEq(game.imdLiability(), 0);
    }

    function test_exactTiesSplitEachDistinctDistanceTierEqually() public {
        _exact(0, alice, 1000, 10 ether);
        _exact(0, bob, 1000, 30 ether);
        _exact(0, carol, 999, 20 ether);
        _exact(0, dave, 1001, 20 ether);
        _exact(0, TEAM, 1010, 20 ether);
        _settle(0, 1000);
        assertEq(_claim(0, alice), 27.3 ether);
        assertEq(_claim(0, bob), 27.3 ether);
        assertEq(_claim(0, carol), 13.65 ether);
        assertEq(_claim(0, dave), 13.65 ether);
        assertEq(_claim(0, TEAM), 9.1 ether + 1 ether);
        _assertBacked();
    }

    function test_twoExactRanksReturnMissingThirdPrizeToClosest() public {
        _exact(0, alice, 9, 5 ether);
        _exact(0, bob, 12, 5 ether);
        _settle(0, 10);
        assertEq(_claim(0, alice), 6.37 ether);
        assertEq(_claim(0, bob), 2.73 ether);
    }

    function test_timeoutFullRefundAtExactDeadlineAndNoSettlementAfter() public {
        _ou(0, alice, true, 1 ether);
        _exact(0, alice, 10, 2 ether);
        _sleep(0, alice, false, 3 ether);
        _ou(0, bob, false, 4 ether);
        vm.warp(GENESIS + 1 hours + 48 hours - 1);
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.voidWindow(0);
        vm.warp(block.timestamp + 1);
        OracleAttestation.Attestation memory a = _a(0, 99);
        bytes memory sig = _sign(a);
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        assertEq(_claim(0, alice), 6 ether);
        assertEq(_claim(0, bob), 4 ether);
        assertEq(game.imdLiability(), 0);
        assertEq(game.settledWindows(), 0);
        assertEq(uint256(game.window(0).status), uint256(HamsterHour.Status.Voided));
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.voidWindow(0);
    }

    function test_uncreatedWindowsCannotSettleVoidOrClaim() public {
        vm.warp(GENESIS + 60 hours);
        OracleAttestation.Attestation memory a;
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, "");
        vm.expectRevert(HamsterHour.NotTimedOut.selector);
        game.voidWindow(0);
        vm.expectRevert(HamsterHour.NotFinal.selector);
        game.claim(0);
    }

    function test_minimumDuplicateAndLateBets() public {
        vm.expectRevert(HamsterHour.BelowMinimum.selector);
        _exact(0, alice, 0, 0.5 ether - 1);
        _exact(0, alice, type(uint256).max, 0.5 ether);
        vm.expectRevert(HamsterHour.DuplicateExactBet.selector);
        _exact(0, alice, 10, 0.5 ether);
        vm.warp(GENESIS);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _ou(0, alice, true, 1 ether);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _sleep(0, alice, true, 1 ether);
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _exact(0, bob, 0, 1 ether);
        _settle(0, 0);
        assertEq(_claim(0, alice), 0.455 ether);
    }

    function test_reimbursementDeferredUntilReserveCanFundFullAmount() public {
        _exact(0, alice, 1000, 0.5 ether);
        _settle(0, 1000);
        assertEq(game.window(0).reimbursement, 0);
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(keeper);
        game.claim(0);
        vm.prank(bob);
        game.fundOracleReserve(0.485 ether);
        assertEq(_claim(0, keeper), 0.5 ether);
        assertEq(_claim(0, alice), 0.455 ether);
        assertEq(game.oracleReserve(), 0);
        _assertBacked();
        vm.expectRevert(HamsterHour.NothingToClaim.selector);
        vm.prank(keeper);
        game.claim(0);
    }

    function test_exactCapacitySettlementFitsInBlock() public {
        for (uint256 i; i < 256; ++i) {
            address who = address(uint160(10000 + i));
            _fund(who);
            _exact(0, who, 255 - i, 0.5 ether);
        }
        vm.expectRevert(HamsterHour.ExactFull.selector);
        _exact(0, alice, 999, 0.5 ether);
        vm.warp(GENESIS + 1 hours);
        OracleAttestation.Attestation memory a = _a(0, 0);
        bytes memory sig = _sign(a);
        vm.cool(address(game));
        vm.cool(address(verifier));
        uint256 beforeGas = gasleft();
        game.settle(0, a, sig);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("256-ticket settlement gas (cooled storage)", used);
        assertLt(used, 8_000_000);
        assertEq(game.window(0).distances[0], 0);
        assertEq(game.window(0).distances[1], 1);
        assertEq(game.window(0).distances[2], 2);
    }

    function testFuzz_binaryConservationAndRounding(uint128 x, uint128 y, uint128 z, bool reverse) public {
        uint256 a = bound(x, 0.5 ether, 1e30);
        uint256 b = bound(y, 0.5 ether, 1e30);
        uint256 c = bound(z, 0.5 ether, 1e30);
        _ou(0, alice, true, a);
        _ou(0, bob, true, b);
        _ou(0, carol, false, c);
        _settle(0, 1001);
        uint256 pool = a + b + c;
        uint256 reward = pool - pool * 5 / 100 - pool * 3 / 100 - pool / 100;
        uint256 paid;
        if (reverse) {
            paid = _claim(0, bob);
            paid += _claim(0, alice);
        } else {
            paid = _claim(0, alice);
            paid += _claim(0, bob);
        }
        assertEq(paid, reward);
        assertEq(
            game.window(0).teamCredit + game.preStakingReserve() + game.oracleReserve() + game.window(0).reimbursement
                + paid,
            pool
        );
        _assertBacked();
    }
}
