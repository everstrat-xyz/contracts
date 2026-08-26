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
 * the perform payload is untrusted. Amounts are never taken from it;
 * subclasses recompute from live protocol state.
 */
abstract contract KeeperExecutorBase is IKeeperExecutorBase, RegistryClient, Pausable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ State ============

    /// @notice Allowed automation callers (Mimic smart accounts / relays)
    EnumerableSet.AddressSet private _executorCallers;

    // ============ Entrypoint guard ============

    /**
     * @notice Caller gate shared by the perform() entrypoints. This checks the
     *         allowlist ONLY — each perform() adds `whenNotPaused nonReentrant`
     *         at its own call site, and a subclass that omits them gets neither.
     */
    modifier onlyExecutorCaller() {
        if (_executorCallers.length() == 0) revert KeeperExecutorNoAllowedCallers();
        if (!_executorCallers.contains(msg.sender)) {
            revert KeeperExecutorUnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @param registry_ Protocol Registry
     */
    constructor(address registry_) RegistryClient(registry_) {}

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

    // ============ Emergency controls ============

    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
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
}
