// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RegistryClient} from "../registry/client/RegistryClient.sol";

import {Auth} from "../../libraries/Auth.sol";

import {IKeeperExecutorBase} from "../../interfaces/automation/IKeeperExecutorBase.sol";

/**
 * @title KeeperExecutorBase
 * @notice Keeper executor base for EverStrat, driven by an external automation
 *         network (Mimic).
 *
 * Auth: an explicit allowlist of executor callers, managed by Registry
 * ADMIN_ROLE. Automation executors call perform() from a per-operator smart
 * account whose address is only known after the automation task exists —
 * so the gate is admin-settable rather than constructor-immutable. Executors
 * start inert (zero allowed callers) and accept no work until one is allowed.
 *
 * Every action is re-validated against live state before execution —
 * performData is untrusted. Amounts are never taken from it; subclasses
 * recompute from live protocol state (the same property the executors
 * held).
 */
abstract contract KeeperExecutorBase is IKeeperExecutorBase, RegistryClient, Pausable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ State ============

    /// @notice Allowed automation callers (Mimic smart accounts / relays)
    EnumerableSet.AddressSet private _executorCallers;

    // ============ Constructor ============

    /**
     * @param registry_ Protocol Registry
     */
    constructor(address registry_) RegistryClient(registry_) {}

    // ============ Entrypoint guard ============

    /**
     * @notice Gate shared by the perform() entrypoints: allowlisted caller, not
     *         paused, no reentrancy.
     */
    modifier onlyExecutorCaller() {
        if (_executorCallers.length() == 0) revert KeeperExecutorNoAllowedCallers();
        if (!_executorCallers.contains(msg.sender)) {
            revert KeeperExecutorUnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ============ Admin (Registry ADMIN_ROLE) ============

    /// @inheritdoc IKeeperExecutorBase
    function allowExecutorCaller(address _caller) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_caller == address(0)) revert KeeperExecutorUnauthorizedCaller(_caller);
        if (_executorCallers.add(_caller)) {
            emit ExecutorCallerAllowed(_caller);
        }
    }

    /// @inheritdoc IKeeperExecutorBase
    function removeExecutorCaller(address _caller) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_executorCallers.remove(_caller)) {
            emit ExecutorCallerRemoved(_caller);
        }
    }

    // ============ Views ============

    /// @inheritdoc IKeeperExecutorBase
    function isExecutorCaller(address _caller) public view returns (bool) {
        return _executorCallers.contains(_caller);
    }

    /// @inheritdoc IKeeperExecutorBase
    function executorCallerCount() public view returns (uint256) {
        return _executorCallers.length();
    }

    // ============ Emergency controls ============

    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }
}
