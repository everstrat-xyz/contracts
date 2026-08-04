// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockAMMStub
 * @notice Minimal code-bearing contract used as a valid (non-EOA) target in tests.
 *         Implements freeBalance() for StrategyManager NAV tests.
 */
contract MockAMMStub {
    uint256 public lockedForClaims;

    function setLockedForClaims(uint256 _locked) external {
        lockedForClaims = _locked;
    }

    function freeBalance() external view returns (uint256) {
        return address(this).balance - lockedForClaims;
    }

    receive() external payable {}
}
