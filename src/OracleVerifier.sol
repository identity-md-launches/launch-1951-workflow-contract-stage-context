// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OracleAttestation} from "./libraries/OracleAttestation.sol";

/// @notice IMD v2 verifier. Each caller consumes attestations in its own EIP-712 domain.
/// @dev No owner, rotation, callback or registration. The launch pins IMD's published EOA signer.
contract OracleVerifier {
    address public immutable oracleSigner;
    uint64 public constant ISSUED_AT_TOLERANCE = 5 minutes;
    uint16 public constant MIN_PANEL_SIZE = 5;
    uint16 public constant MIN_QUORUM = 4;
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    mapping(address => mapping(bytes32 => bool)) public consumed;

    error ZeroSigner();
    error BadSignature();
    error WrongQuestion();
    error WrongChain();
    error InvalidValidityWindow();
    error InvalidBlockWindow();
    error InvalidAnswer();
    error WeakPanel();
    error AlreadyConsumed();
    event AttestationConsumed(address indexed consumer, bytes32 indexed requestId, bytes32 indexed questionHash);

    constructor(address signer_) {
        if (signer_ == address(0)) revert ZeroSigner();
        oracleSigner = signer_;
    }

    function attestationDigest(OracleAttestation.Attestation calldata a, address consumer)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, consumer)
        );
        return keccak256(abi.encodePacked(hex"1901", domain, OracleAttestation.hashStruct(a)));
    }

    function verify(OracleAttestation.Attestation calldata a, bytes calldata signature, bytes32 expectedQuestion)
        external
        returns (uint256 answer)
    {
        if (a.questionHash != expectedQuestion) revert WrongQuestion();
        if (a.chainId != block.chainid) revert WrongChain();
        if (
            a.issuedAt > block.timestamp + ISSUED_AT_TOLERANCE || block.timestamp > a.expiresAt
                || a.issuedAt > a.expiresAt
        ) revert InvalidValidityWindow();
        if (a.fromBlock > a.toBlock) revert InvalidBlockWindow();
        if (a.answerType != OracleAttestation.ANSWER_UINT256 || a.answer.length != 32) revert InvalidAnswer();
        if (a.panelSize < MIN_PANEL_SIZE || a.quorum < MIN_QUORUM || a.agreed < a.quorum || a.agreed > a.panelSize) {
            revert WeakPanel();
        }
        if (consumed[msg.sender][a.requestId]) revert AlreadyConsumed();
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(attestationDigest(a, msg.sender), signature);
        if (err != ECDSA.RecoverError.NoError || recovered != oracleSigner) revert BadSignature();
        consumed[msg.sender][a.requestId] = true;
        answer = abi.decode(a.answer, (uint256));
        emit AttestationConsumed(msg.sender, a.requestId, a.questionHash);
    }
}
