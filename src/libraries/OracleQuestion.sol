// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Canonical IMD panel question, without optional definitions or guards.
library OracleQuestion {
    function question(uint256 windowId, string memory source) internal pure returns (string memory) {
        return string.concat(
            "What is the total number of wheel passes recorded by Squeekchain for rounds ",
            Strings.toString(windowId * 6),
            " through ",
            Strings.toString(windowId * 6 + 5),
            " inclusive, as published at ",
            source,
            "? Answer as a single uint256."
        );
    }

    /// @dev All text supplied here is generated from integers and a validated URL (no JSON escapes).
    function document(string memory text, uint256 chainId, uint64 fromBlock, uint64 toBlock)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"answerType":"uint256","chainId":',
            Strings.toString(chainId),
            ',"evidence":"panel","question":"',
            text,
            '","v":1,"window":{"fromBlock":',
            Strings.toString(fromBlock),
            ',"toBlock":',
            Strings.toString(toBlock),
            "}}"
        );
    }
}
