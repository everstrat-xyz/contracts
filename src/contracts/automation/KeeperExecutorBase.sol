// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

import {RegistryClient} from "registry/client/RegistryClient.sol";

import {Auth} from "../../libraries/Auth.sol";

import {IKeeperExecutorBase} from "../../interfaces/automation/IKeeperExecutorBase.sol";

/**
 * @title KeeperExecutorBase
 * @notice Shared base for Chainlink Automation keeper executors.
 * @dev Static (non-upgradeable) mixin. Executors hold KEEPER_ROLE on the
 * Registry and forward privileged calls to the Controller; Chainlink
 * infrastructure never receives a protocol role. `performUpkeep` is gated to
 * the Chainlink Forwarder registered via {setForwarder}.
 */
abstract contract KeeperExecutorBase is
    IKeeperExecutorBase,
    AutomationCompatibleInterface,
    RegistryClient,
    Pausable,
    ReentrancyGuard
{
    // ============ State Variables ============

    /**
     * @inheritdoc IKeeperExecutorBase
     */
    address public forwarder;

    // ============ Modifiers ============

    /**
     * @notice Restricts a function to the registered Chainlink Forwarder
     * @dev While the forwarder is unset (zero address) every caller is rejected,
     * so the executor is inert until governance wires it up.
     */
    modifier onlyForwarder() {
        if (msg.sender != forwarder) revert KeeperExecutorOnlyForwarder();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Wires the executor to the protocol Registry
     * @param registry_ The protocol Registry (role authority and contract addresses)
     */
    constructor(address registry_) RegistryClient(registry_) {}

    // ============ Admin Functions ============

    /**
     * @inheritdoc IKeeperExecutorBase
     */
    function setForwarder(address _forwarder) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_forwarder == address(0)) revert KeeperExecutorZeroAddress();
        emit ForwarderChanged(forwarder, _forwarder);
        forwarder = _forwarder;
    }

    /**
     * @inheritdoc IKeeperExecutorBase
     */
    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IKeeperExecutorBase
     */
    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }
}
