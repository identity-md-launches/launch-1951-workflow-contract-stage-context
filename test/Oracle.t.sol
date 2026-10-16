// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleVerifier} from "../src/OracleVerifier.sol";
import {OracleAttestation} from "../src/libraries/OracleAttestation.sol";
import {OracleQuestion} from "../src/libraries/OracleQuestion.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract OracleTest is GameTest {
    function _openEnded() internal returns (OracleAttestation.Attestation memory a, bytes memory sig) {
        _exact(0, alice, 1000, 1 ether);
        vm.warp(GENESIS + 1 hours);
        a = _a(0, 1000);
        sig = _sign(a);
    }

    function _reject(OracleAttestation.Attestation memory a, bytes memory sig, bytes4 reason) internal {
        vm.expectRevert(reason);
        game.settle(0, a, sig);
        assertEq(uint256(game.window(0).status), uint256(HamsterHour.Status.Open));
        assertFalse(verifier.consumed(address(game), a.requestId));
        _assertBacked();
    }

    function test_earlyAndPredatedAttestationsRejected() public {
        _exact(0, alice, 1000, 1 ether);
        OracleAttestation.Attestation memory a = _a(0, 1000);
        bytes memory sig = _sign(a);
        _reject(a, sig, HamsterHour.NotSettleable.selector);
        vm.warp(GENESIS + 1 hours);
        a.issuedAt = uint64(block.timestamp - 301);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        _reject(a, _sign(a), HamsterHour.AttestationPredatesEnd.selector);
        a.issuedAt += 1;
        game.settle(0, a, _sign(a));
    }

    function test_expiryAndFutureValidityBoundaries() public {
        (OracleAttestation.Attestation memory a,) = _openEnded();
        a.expiresAt = uint64(block.timestamp - 1);
        _reject(a, _sign(a), OracleVerifier.InvalidValidityWindow.selector);
        a.expiresAt = uint64(block.timestamp + 1 hours);
        a.issuedAt = uint64(block.timestamp + 301);
        _reject(a, _sign(a), OracleVerifier.InvalidValidityWindow.selector);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp);
        game.settle(0, a, _sign(a));
        assertEq(game.window(0).result, 1000);
    }

    function test_wrongQuestionAndWrongWindowCannotConsumeValidAttestation() public {
        _exact(1, bob, 1000, 1 ether);
        (OracleAttestation.Attestation memory a,) = _openEnded();
        a.questionHash = game.questionHash(1, 100, 200);
        _reject(a, _sign(a), OracleVerifier.WrongQuestion.selector);
        a.questionHash = keccak256("unrelated question");
        _reject(a, _sign(a), OracleVerifier.WrongQuestion.selector);
    }

    function test_tamperedAnswerAndBadSignerRejected() public {
        (OracleAttestation.Attestation memory a, bytes memory sig) = _openEnded();
        a.answer = abi.encode(uint256(999));
        _reject(a, sig, OracleVerifier.BadSignature.selector);
        a.answer = abi.encode(uint256(1000));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY + 1, verifier.attestationDigest(a, address(game)));
        _reject(a, abi.encodePacked(r, s, v), OracleVerifier.BadSignature.selector);
        _reject(a, "", OracleVerifier.BadSignature.selector);
        _reject(a, new bytes(66), OracleVerifier.BadSignature.selector);
    }

    function test_highSAndInvalidVRejected() public {
        (OracleAttestation.Attestation memory a,) = _openEnded();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, verifier.attestationDigest(a, address(game)));
        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        _reject(
            a,
            abi.encodePacked(r, bytes32(n - uint256(s)), uint8(v == 27 ? 28 : 27)),
            OracleVerifier.BadSignature.selector
        );
        _reject(a, abi.encodePacked(r, s, uint8(0)), OracleVerifier.BadSignature.selector);
    }

    function test_domainChainConsumerAndQuestionChainAreBound() public {
        (OracleAttestation.Attestation memory a,) = _openEnded();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, verifier.attestationDigest(a, alice));
        _reject(a, abi.encodePacked(r, s, v), OracleVerifier.BadSignature.selector);
        vm.chainId(2);
        bytes memory otherChainSig = _sign(a);
        vm.chainId(1);
        _reject(a, otherChainSig, OracleVerifier.BadSignature.selector);
        a.chainId = 2;
        _reject(a, _sign(a), OracleVerifier.WrongChain.selector);
    }

    function test_onlyCanonicalUint256EncodingAccepted() public {
        (OracleAttestation.Attestation memory a,) = _openEnded();
        a.answerType = 0;
        _reject(a, _sign(a), OracleVerifier.InvalidAnswer.selector);
        a.answerType = 3;
        a.answer = hex"01";
        _reject(a, _sign(a), OracleVerifier.InvalidAnswer.selector);
        a.answer = abi.encode(uint256(1), uint256(2));
        _reject(a, _sign(a), OracleVerifier.InvalidAnswer.selector);
    }

    function test_panelThresholdsAndInconsistentPanelRejected() public {
        (OracleAttestation.Attestation memory a,) = _openEnded();
        a.panelSize = 4;
        a.agreed = 4;
        _reject(a, _sign(a), OracleVerifier.WeakPanel.selector);
        a.panelSize = 5;
        a.quorum = 3;
        _reject(a, _sign(a), OracleVerifier.WeakPanel.selector);
        a.quorum = 4;
        a.agreed = 3;
        _reject(a, _sign(a), OracleVerifier.WeakPanel.selector);
        a.agreed = 6;
        _reject(a, _sign(a), OracleVerifier.WeakPanel.selector);
    }

    function test_reversedBlockRangeRejected() public {
        (OracleAttestation.Attestation memory a,) = _openEnded();
        a.fromBlock = 201;
        a.questionHash = game.questionHash(0, a.fromBlock, a.toBlock);
        _reject(a, _sign(a), OracleVerifier.InvalidBlockWindow.selector);
    }

    function test_replayFailsAndStrangerCannotPreconsumeGameSignature() public {
        (OracleAttestation.Attestation memory a, bytes memory sig) = _openEnded();
        vm.expectRevert(OracleVerifier.BadSignature.selector);
        vm.prank(bob);
        verifier.verify(a, sig, a.questionHash);
        assertFalse(verifier.consumed(address(game), a.requestId));
        game.settle(0, a, sig);
        assertTrue(verifier.consumed(address(game), a.requestId));
        vm.expectRevert(HamsterHour.NotSettleable.selector);
        game.settle(0, a, sig);
        vm.expectRevert(OracleVerifier.AlreadyConsumed.selector);
        vm.prank(address(game));
        verifier.verify(a, sig, a.questionHash);
    }

    function test_failureDoesNotTrapFundsOrPreventRetry() public {
        (OracleAttestation.Attestation memory a, bytes memory sig) = _openEnded();
        _reject(a, "bad", OracleVerifier.BadSignature.selector);
        game.settle(0, a, sig);
        assertEq(_claim(0, alice), 0.91 ether);
    }

    function test_delegatedEOAStillVerifiesECDSASignatures() public {
        (OracleAttestation.Attestation memory a, bytes memory sig) = _openEnded();
        // EIP-7702 code designator does not replace the key's ECDSA identity.
        vm.etch(vm.addr(SIGNER_KEY), abi.encodePacked(hex"ef0100", alice));
        game.settle(0, a, sig);
        assertEq(game.window(0).result, 1000);
    }

    function test_zeroSignerRefused() public {
        vm.expectRevert(OracleVerifier.ZeroSigner.selector);
        new OracleVerifier(address(0));
    }

    /// @dev Independent viem-generated vector published in IMD's oracle-consumer reference.
    function test_protocolPublishedDigestAndSignature() public {
        vm.chainId(11155111);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
        bytes32 digest = verifier.attestationDigest(a, address(0x2748));
        assertEq(digest, 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c);
        bytes memory sig =
            hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
        assertEq(ECDSA.recover(digest, sig), 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
    }

    /// @dev Actual signed result, not a signature generated by this test's signer.
    /// Source: https://api.imd.fun/oracle/requests/753b4996-34e7-420a-8768-d784231195da/attestation
    function test_realSqueekchainQuestionHashSignatureAndUintAnswer() public {
        string memory text =
            "What is the total number of wheel passes recorded by Squeekchain for rounds 468, 469 and 470 combined, as published on the public console at https://sepolia.squeekchain.com/status in the CORE SETTLED events (field PASSES for each round)? Answer as a single uint256 equal to the sum of the three values.";
        bytes32 expected = 0x5dc1af7336e9a05027d84f9e4682b92b36e8df019aaf6fedbbc1f2914396d412;
        assertEq(keccak256(bytes(OracleQuestion.document(text, 1, 26196534, 26203713))), expected);
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: 0x753b499634e7420a8768d784231195da00000000000000000000000000000000,
            chainId: 1,
            questionHash: expected,
            answerType: 3,
            answer: abi.encode(uint256(1470)),
            figure: 1470,
            fromBlock: 26196534,
            toBlock: 26203713,
            blockHash: 0x131b644f711ff28bdb1054d8d8ab71bdc27a6baecc1b98868ec78ee87bddf766,
            panelJobId: 0x354a39ee97cf4e9284a1eaa3b55c90e200000000000000000000000000000000,
            panelSize: 20,
            quorum: 14,
            agreed: 14,
            issuedAt: 1792137438,
            expiresAt: 1792223838
        });
        bytes memory sig =
            hex"f47514dae00f795150c1620b7773f44b94e61df978cdfe3ad753d767eedd35822e0900c6c55e64c0e0e2f085b97f6a5ea677d116296c0c63f301dd3887da8e3a1c";
        address signer = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
        OracleVerifier real = new OracleVerifier(signer);
        // This historic public attestation has a zero-consumer domain, not HamsterHour's domain.
        // The prank reproduces that domain ONLY for this protocol conformance fixture.
        assertEq(ECDSA.recover(real.attestationDigest(a, address(0)), sig), signer);
        vm.warp(a.issuedAt);
        vm.prank(address(0));
        assertEq(real.verify(a, sig, expected), 1470);
        vm.expectRevert(OracleVerifier.BadSignature.selector);
        vm.prank(address(game));
        real.verify(a, sig, expected);
    }

    function test_gameQuestionTemplateExactlyMatchesBrief() public {
        _exact(78, alice, 1000, 1 ether);
        assertEq(
            game.question(78),
            "What is the total number of wheel passes recorded by Squeekchain for rounds 468 through 473 inclusive, as published at https://sepolia.squeekchain.com? Answer as a single uint256."
        );
        assertEq(
            game.questionDocument(78, 1, 2),
            '{"answerType":"uint256","chainId":1,"evidence":"panel","question":"What is the total number of wheel passes recorded by Squeekchain for rounds 468 through 473 inclusive, as published at https://sepolia.squeekchain.com? Answer as a single uint256.","v":1,"window":{"fromBlock":1,"toBlock":2}}'
        );
    }
}
