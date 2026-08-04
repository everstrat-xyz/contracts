// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockReentrantAMM
 * @notice Malicious AMM stand-in that attempts to re-enter the Controller from its receive() hook.
 * @dev The Controller forwards ETH to the AMM via Address.sendValue (a value-bearing call that
 *      forwards all gas), so the AMM's receive() can attempt to call back into the Controller.
 *      To prove the nonReentrant guard works, the reentrant call is wrapped in a low-level call:
 *      the inner failure is captured (selector recorded) rather than bubbled up, so the outer
 *      Controller call still succeeds while the test asserts the reentrant attempt was rejected.
 *      Implements freeBalance() for parity with the real AMM.
 */
contract MockReentrantAMM {
    address public controller;
    bytes public attackCalldata;
    bool public attackArmed;
    bool public reentryReverted;
    bytes4 public lastRevertSelector;

    function setController(address _controller) external {
        controller = _controller;
    }

    /// @notice Arms a single reentrant attempt with the given calldata, fired on the next receive().
    function arm(bytes calldata _attackCalldata) external {
        attackCalldata = _attackCalldata;
        attackArmed = true;
    }

    function freeBalance() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        if (!attackArmed) {
            return;
        }
        attackArmed = false;

        (bool success, bytes memory data) = controller.call(attackCalldata);
        reentryReverted = !success;
        if (!success && data.length >= 4) {
            lastRevertSelector = bytes4(data);
        }
    }
}
