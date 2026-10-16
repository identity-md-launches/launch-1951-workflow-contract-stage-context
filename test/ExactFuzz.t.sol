// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameTest} from "./helpers/GameTest.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

contract ExactFuzzTest is GameTest {
    function testFuzz_rankingMatchesIndependentSort(uint256[8] memory guesses, uint256 result) public {
        uint256[8] memory distance;
        for (uint256 i; i < 8; ++i) {
            address account = address(uint160(10000 + i));
            _fund(account);
            _exact(0, account, guesses[i], (i + 1) * 1 ether);
            distance[i] = guesses[i] > result ? guesses[i] - result : result - guesses[i];
        }
        // Independent insertion-sort oracle, not the contract's streaming top-three algorithm.
        for (uint256 i = 1; i < 8; ++i) {
            uint256 item = distance[i];
            uint256 j = i;
            while (j > 0 && distance[j - 1] > item) {
                distance[j] = distance[j - 1];
                --j;
            }
            distance[j] = item;
        }
        _settle(0, result);
        HamsterHour.Window memory w = game.window(0);
        uint256 rank;
        uint256 count;
        for (uint256 i; i < 8; ++i) {
            if (i != 0 && distance[i] != distance[i - 1]) {
                assertEq(w.ties[rank], count);
                ++rank;
                count = 0;
                if (rank == 3) break;
            }
            assertEq(w.distances[rank], distance[i]);
            ++count;
        }
        if (rank < 3) {
            assertEq(w.ties[rank], count);
            assertEq(w.rankCount, rank + 1);
        }
        uint256 paid;
        for (uint256 i; i < 8; ++i) {
            address account = address(uint160(10000 + i));
            uint256 d = guesses[i] > result ? guesses[i] - result : result - guesses[i];
            if (d <= w.distances[w.rankCount - 1]) paid += _claim(0, account);
        }
        assertEq(paid, w.rewards[1]);
        _assertBacked();
    }
}
