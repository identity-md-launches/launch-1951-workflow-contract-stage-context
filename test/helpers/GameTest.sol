// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterHour} from "../../src/HamsterHour.sol";
import {OracleVerifier} from "../../src/OracleVerifier.sol";
import {OracleAttestation} from "../../src/libraries/OracleAttestation.sol";
import {MockToken} from "./MockToken.sol";

abstract contract GameTest is Test {
    uint256 internal constant SIGNER_KEY = 192837465;
    uint64 internal constant GENESIS = 1791847800;
    address internal constant TEAM = 0x6CBA4751742F6989fA224B2dC5d5d52fCef98a34;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal keeper = makeAddr("keeper");
    MockToken internal imd;
    MockToken internal stakeToken;
    MockToken internal prize;
    OracleVerifier internal verifier;
    HamsterHour internal game;
    uint256 internal nonce;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(GENESIS - 10 days);
        vm.roll(1000);
        verifier = new OracleVerifier(vm.addr(SIGNER_KEY));
        game = new HamsterHour(TEAM, address(verifier));
        MockToken template = new MockToken();
        vm.etch(game.IMD(), address(template).code);
        imd = MockToken(game.IMD());
        stakeToken = new MockToken();
        prize = new MockToken();
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(dave);
        _fund(keeper);
        _fund(TEAM);
    }

    function _fund(address who) internal {
        imd.mint(who, 1e36);
        stakeToken.mint(who, 1e36);
        vm.startPrank(who);
        imd.approve(address(game), type(uint256).max);
        stakeToken.approve(address(game), type(uint256).max);
        vm.stopPrank();
    }

    function _ou(uint256 k, address who, bool over, uint256 amount) internal {
        vm.prank(who);
        game.betOverUnder(k, over, amount);
    }

    function _sleep(uint256 k, address who, bool yes, uint256 amount) internal {
        vm.prank(who);
        game.betSleep(k, yes, amount);
    }

    function _exact(uint256 k, address who, uint256 guess, uint256 amount) internal {
        vm.prank(who);
        game.betExact(k, guess, amount);
    }

    function _a(uint256 k, uint256 result) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode(k, ++nonce));
        a.chainId = block.chainid;
        a.questionHash = game.questionHash(k, 100, 200);
        a.answerType = 3;
        a.answer = abi.encode(result);
        a.figure = result;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("published closing block");
        a.panelJobId = keccak256(abi.encode("panel", nonce));
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, verifier.attestationDigest(a, address(game)));
        return abi.encodePacked(r, s, v);
    }

    function _settle(uint256 k, uint256 result) internal {
        (, uint64 end) = game.windowTimes(k);
        if (block.timestamp < end) vm.warp(end);
        OracleAttestation.Attestation memory a = _a(k, result);
        bytes memory sig = _sign(a);
        vm.prank(keeper);
        game.settle(k, a, sig);
    }

    function _claim(uint256 k, address who) internal returns (uint256 received) {
        uint256 beforeBalance = imd.balanceOf(who);
        vm.prank(who);
        game.claim(k);
        return imd.balanceOf(who) - beforeBalance;
    }

    function _configure(bool staking, address token) internal {
        vm.prank(TEAM);
        if (staking) game.scheduleStakingToken(token);
        else game.scheduleJackpotToken(token);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(TEAM);
        if (staking) game.setStakingToken(token);
        else game.setJackpotToken(token);
    }

    function _assertBacked() internal view {
        uint256 liabilities = game.imdLiability();
        if (game.stakingToken() == address(imd)) liabilities += game.totalStaked();
        if (game.jackpotToken() == address(imd)) liabilities += game.jackpotLiability();
        assertGe(imd.balanceOf(address(game)), liabilities);
    }
}
