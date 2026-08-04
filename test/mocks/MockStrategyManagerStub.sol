// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockStrategyManagerStub
 * @notice Minimal code-bearing contract used as a valid (non-EOA) target in tests.
 *         Mirror of MockAMMStub.
 */
contract MockStrategyManagerStub {
    receive() external payable {}
}
