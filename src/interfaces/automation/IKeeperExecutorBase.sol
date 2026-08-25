// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IKeeperExecutorBase
 * @notice Shared interface for Gelato-driven keeper executors.
 *
 * Auth model: an explicit, admin-managed allowlist of executor callers.
 * Gelato executes tasks through a dedicated msg.sender proxy per task creator
 * (per chain), and that address is only known after task creation — so the
 * gate must be settable, not constructor-immutable. Executors remain
 * inert until at least one caller is allowed, preserving the unbound-inert
 * property of the previous report-driven receivers.
 *
 * performData is untrusted per keeper-network guidance — every action is
 * re-validated against live state before execution, and amounts are never
 * taken from it.
 */
interface IKeeperExecutorBase {
    // ============ Events ============

    event ExecutorCallerAllowed(address indexed caller);
    event ExecutorCallerRemoved(address indexed caller);

    // ============ Errors ============

    /// @notice perform() called by an address not on the executor-caller allowlist
    error KeeperExecutorUnauthorizedCaller(address caller);
    /// @notice No caller is allowed yet — the executor is deliberately inert
    error KeeperExecutorNoAllowedCallers();

    // ============ Admin ============

    /// @notice Allows a Gelato dedicated msg.sender (or other approved automation caller)
    function allowExecutorCaller(address _caller) external;
    /// @notice Removes a caller; removing the last one returns the executor to inert
    function removeExecutorCaller(address _caller) external;
    /// @notice Whether `_caller` may call perform()
    function isExecutorCaller(address _caller) external view returns (bool);
    /// @notice Number of allowed callers (0 = inert)
    function executorCallerCount() external view returns (uint256);

    function pause() external;
    function unpause() external;
}
