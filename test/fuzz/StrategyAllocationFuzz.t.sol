// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {StrategyManager} from "../../src/contracts/StrategyManager.sol";

/**
 * @title StrategyAllocationFuzzTest
 * @notice Invariants of the water-filling split behind batch deposits and withdrawals (audit G6).
 */
contract StrategyAllocationFuzzTest is Test, StrategyManager {
    uint256 public constant MAX_STRATEGIES = 8;
    uint256 public constant MAX_WEIGHT = 100;
    uint256 public constant MAX_CAP = 1_000_000 ether;

    /// @dev Never over-allocates, never exceeds a cap, never funds weight-0 / cap-0 entries, and
    ///      places everything the caps allow, up to one wei of rounding dust per entry.
    function testFuzz_AllocateByWeight_FillsUpToCaps(uint256 _amount, uint256 _seed, uint256 _n) public pure {
        uint256 n = bound(_n, 1, MAX_STRATEGIES);
        _amount = bound(_amount, 0, MAX_CAP * MAX_STRATEGIES);

        uint256[] memory weights = new uint256[](n);
        uint256[] memory caps = new uint256[](n);
        uint256 reachable;
        for (uint256 i; i < n; ++i) {
            weights[i] = uint256(keccak256(abi.encode(_seed, i, "w"))) % (MAX_WEIGHT + 1);
            caps[i] = uint256(keccak256(abi.encode(_seed, i, "c"))) % (MAX_CAP + 1);
            if (weights[i] > 0) reachable += caps[i];
        }

        uint256[] memory amounts = _allocateByWeight(_amount, weights, caps);

        uint256 total;
        for (uint256 i; i < n; ++i) {
            assertLe(amounts[i], caps[i], "above cap");
            if (weights[i] == 0) assertEq(amounts[i], 0, "weight-0 funded");
            total += amounts[i];
        }

        uint256 target = _amount < reachable ? _amount : reachable;
        assertLe(total, target, "over-allocated");
        assertGe(total + n, target, "under-filled beyond rounding dust");
    }

    /// @dev With no cap binding, the split is the plain proportional one.
    function testFuzz_AllocateByWeight_ProportionalWhenUncapped(uint256 _amount, uint256 _seed, uint256 _n)
        public
        pure
    {
        uint256 n = bound(_n, 1, MAX_STRATEGIES);
        _amount = bound(_amount, 0, MAX_CAP);

        uint256[] memory weights = new uint256[](n);
        uint256[] memory caps = new uint256[](n);
        uint256 totalWeight;
        for (uint256 i; i < n; ++i) {
            weights[i] = 1 + uint256(keccak256(abi.encode(_seed, i))) % MAX_WEIGHT;
            caps[i] = type(uint128).max;
            totalWeight += weights[i];
        }

        uint256[] memory amounts = _allocateByWeight(_amount, weights, caps);

        for (uint256 i; i < n; ++i) {
            // First round is the proportional split; later rounds only spread its rounding dust.
            assertApproxEqAbs(amounts[i], _amount * weights[i] / totalWeight, n, "not proportional");
        }
    }
}
