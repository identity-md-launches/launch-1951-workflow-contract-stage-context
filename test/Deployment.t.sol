// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterHour} from "../src/HamsterHour.sol";
import {OracleVerifier} from "../src/OracleVerifier.sol";

contract DeploymentProbe {
    function deploy(bytes memory creation, bytes32 salt) external returns (address result) {
        assembly ("memory-safe") { result := create2(0, add(creation, 32), mload(creation), salt) }
        require(result != address(0), "deployment failed");
    }
}

contract DeploymentTest is Test {
    function test_factoryDeploymentRuntimeLimitsAndForbiddenOpcodes() public {
        DeploymentProbe factory = new DeploymentProbe();
        address signer = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
        address team = 0x6CBA4751742F6989fA224B2dC5d5d52fCef98a34;
        bytes memory verifierCode = abi.encodePacked(type(OracleVerifier).creationCode, abi.encode(signer));
        address verifier = factory.deploy(verifierCode, keccak256("OracleVerifier"));
        bytes memory gameCode = abi.encodePacked(type(HamsterHour).creationCode, abi.encode(team, verifier));
        address game = factory.deploy(gameCode, keccak256("HamsterHour"));
        assertLe(verifierCode.length, 49_152);
        assertLe(gameCode.length, 49_152);
        assertEq(OracleVerifier(verifier).oracleSigner(), signer);
        assertEq(HamsterHour(game).TEAM(), team);
        assertEq(address(HamsterHour(game).oracleVerifier()), verifier);
        _checkRuntime(verifier);
        _checkRuntime(game);
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
