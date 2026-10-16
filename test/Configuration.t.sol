// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

contract ConfigurationTest is GameTest {
    function test_roundAndWindowMathAtGenesisBoundaries() public {
        assertEq(game.currentRound(), 0);
        assertFalse(game.hasStarted());
        assertTrue(game.isBettingOpen(0));
        vm.warp(GENESIS - 1);
        assertTrue(game.isBettingOpen(0));
        vm.warp(GENESIS);
        assertTrue(game.hasStarted());
        assertEq(game.currentRound(), 0);
        assertFalse(game.isBettingOpen(0));
        assertTrue(game.isBettingOpen(1));
        vm.warp(GENESIS + 599);
        assertEq(game.currentRound(), 0);
        vm.warp(GENESIS + 600);
        assertEq(game.currentRound(), 1);
        vm.warp(GENESIS + 3599);
        assertEq(game.currentRound(), 5);
        assertEq(game.currentWindow(), 0);
        vm.warp(GENESIS + 3600);
        assertEq(game.currentRound(), 6);
        assertEq(game.currentWindow(), 1);
        assertFalse(game.isBettingOpen(1));
        (uint64 start, uint64 end) = game.windowTimes(5);
        assertEq(start, GENESIS + 5 hours);
        assertEq(end, GENESIS + 6 hours);
        vm.expectRevert(HamsterHour.InvalidWindow.selector);
        game.windowTimes(type(uint256).max);
    }

    function test_teamOnlyForAllFourSchedulesAndExecutions() public {
        vm.startPrank(alice);
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.scheduleStakingToken(address(stakeToken));
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.setStakingToken(address(stakeToken));
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.scheduleJackpotToken(address(prize));
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.setJackpotToken(address(prize));
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.scheduleSourceUrl("https://example.org");
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.setSourceUrl("https://example.org");
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.scheduleGenesisTimestamp(GENESIS + 1);
        vm.expectRevert(HamsterHour.NotTeam.selector);
        game.setGenesisTimestamp(GENESIS + 1);
        vm.stopPrank();
    }

    function test_allSettingsRequireMatching48HourTimelocks() public {
        vm.startPrank(TEAM);
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setSourceUrl("https://example.org");
        game.scheduleStakingToken(address(stakeToken));
        game.scheduleJackpotToken(address(prize));
        game.scheduleSourceUrl("https://example.org");
        game.scheduleGenesisTimestamp(GENESIS + 1);
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setStakingToken(address(stakeToken));
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setJackpotToken(address(prize));
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setSourceUrl("https://example.org");
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setGenesisTimestamp(GENESIS + 1);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setJackpotToken(address(stakeToken));
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setSourceUrl("https://different.example.org");
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setGenesisTimestamp(GENESIS + 2);
        game.setStakingToken(address(stakeToken));
        game.setJackpotToken(address(prize));
        game.setSourceUrl("https://example.org");
        game.setGenesisTimestamp(GENESIS + 1);
        assertEq(game.stakingToken(), address(stakeToken));
        assertEq(game.jackpotToken(), address(prize));
        assertEq(game.sourceUrl(), "https://example.org");
        assertEq(game.genesisTimestamp(), GENESIS + 1);
        vm.expectRevert(HamsterHour.AlreadyConfigured.selector);
        game.scheduleStakingToken(address(prize));
        vm.expectRevert(HamsterHour.AlreadyConfigured.selector);
        game.setStakingToken(address(prize));
        vm.expectRevert(HamsterHour.AlreadyConfigured.selector);
        game.scheduleJackpotToken(address(stakeToken));
        vm.expectRevert(HamsterHour.AlreadyConfigured.selector);
        game.setJackpotToken(address(stakeToken));
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setSourceUrl("https://example.org");
        vm.stopPrank();
    }

    function test_replacingProposalRestartsDelayAndInvalidatesPreviousValue() public {
        vm.startPrank(TEAM);
        game.scheduleSourceUrl("https://first.example.org");
        vm.warp(block.timestamp + 47 hours);
        game.scheduleSourceUrl("https://second.example.org");
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setSourceUrl("https://first.example.org");
        vm.expectRevert(HamsterHour.TimelockNotReady.selector);
        game.setSourceUrl("https://second.example.org");
        vm.warp(block.timestamp + 47 hours);
        game.setSourceUrl("https://second.example.org");
        vm.stopPrank();
    }

    function test_badConfigInputsRejectedAndCodeCheckedOnlyAtExecution() public {
        vm.startPrank(TEAM);
        vm.expectRevert(HamsterHour.InvalidAddress.selector);
        game.scheduleStakingToken(address(0));
        vm.expectRevert(HamsterHour.InvalidAddress.selector);
        game.scheduleJackpotToken(address(game));
        vm.expectRevert(HamsterHour.InvalidGenesis.selector);
        game.scheduleGenesisTimestamp(0);
        vm.expectRevert(HamsterHour.InvalidGenesis.selector);
        game.scheduleGenesisTimestamp(type(uint64).max);
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl("http://example.org");
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl('https://example.org/"injection');
        vm.expectRevert(HamsterHour.InvalidSource.selector);
        game.scheduleSourceUrl("https://example.org/\n");
        game.scheduleStakingToken(alice);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(HamsterHour.UnsupportedToken.selector);
        game.setStakingToken(alice);
        assertEq(game.stakingToken(), address(0));
        vm.stopPrank();
    }

    function test_configCannotChangeExistingWindowTerms() public {
        _exact(0, alice, 1000, 1 ether);
        bytes32 hashBefore = game.questionHash(0, 100, 200);
        vm.startPrank(TEAM);
        game.scheduleSourceUrl("https://sepolia.squeekchain.com/status");
        game.scheduleGenesisTimestamp(GENESIS + 1 days);
        vm.warp(block.timestamp + 48 hours);
        game.setSourceUrl("https://sepolia.squeekchain.com/status");
        game.setGenesisTimestamp(GENESIS + 1 days);
        vm.stopPrank();
        assertEq(game.questionHash(0, 100, 200), hashBefore);
        (uint64 start, uint64 end) = game.windowTimes(0);
        assertEq(start, GENESIS);
        assertEq(end, GENESIS + 1 hours);
        _exact(1, bob, 0, 1 ether);
        assertEq(game.window(1).source, "https://sepolia.squeekchain.com/status");
        assertEq(game.window(1).startsAt, GENESIS + 25 hours);
        _settle(0, 1000);
        assertEq(_claim(0, alice), 0.91 ether);
    }

    function test_genesisCorrectionCannotReopenAnUncreatedPastWindow() public {
        vm.warp(GENESIS + 1 hours);
        vm.prank(TEAM);
        game.scheduleGenesisTimestamp(GENESIS + 100 days);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(TEAM);
        game.setGenesisTimestamp(GENESIS + 100 days);
        assertEq(game.closedWindowFloor(), 50);
        assertFalse(game.isBettingOpen(0));
        vm.expectRevert(HamsterHour.BettingClosed.selector);
        _exact(49, alice, 5, 1 ether);
        _exact(50, alice, 5, 1 ether);
    }

    function test_lineUsesSevenSettledWindowsAndFreezesAtCreation() public {
        for (uint256 i; i < 9; ++i) {
            _exact(i, alice, 1000, 1 ether);
        }
        for (uint256 i; i < 6; ++i) {
            _settle(i, (i + 1) * 100);
            assertEq(game.currentLine(), 1000);
        }
        _settle(6, 700);
        assertEq(game.currentLine(), 400);
        assertEq(game.window(8).line, 1000);
        _exact(10, bob, 0, 1 ether);
        assertEq(game.window(10).line, 400);
        _settle(7, 800);
        assertEq(game.currentLine(), 500);
        assertEq(game.window(10).line, 400);
    }

    function test_lineOfMaxUintResultsDoesNotOverflow() public {
        for (uint256 i; i < 7; ++i) {
            _exact(i, alice, 0, 1 ether);
        }
        for (uint256 i; i < 7; ++i) {
            _settle(i, type(uint256).max);
        }
        assertEq(game.currentLine(), type(uint256).max);
    }

    function test_constructorsNeedNoDeployedDependenciesAndDoNotAssignFactoryOwnership() public {
        address factory = makeAddr("factory");
        address namedVerifier = makeAddr("future verifier");
        vm.prank(factory);
        HamsterHour deployed = new HamsterHour(TEAM, namedVerifier);
        assertEq(deployed.TEAM(), TEAM);
        assertEq(address(deployed.oracleVerifier()), namedVerifier);
        (bool owns,) = address(deployed).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(owns);
        vm.expectRevert(HamsterHour.InvalidAddress.selector);
        new HamsterHour(address(0), namedVerifier);
    }
}
