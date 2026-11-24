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

    /// @dev Live base price read by ExitQueue at settlement (audit G1).
    uint256 public eveBasePriceInETH;

    function setEveBasePriceInETH(uint256 _price) external {
        eveBasePriceInETH = _price;
    }

    function freeBalance() external view returns (uint256) {
        return address(this).balance - lockedForClaims;
    }

    receive() external payable {}
}
