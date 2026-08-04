// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IKeeperExecutorBase
 * @notice Shared interface for Chainlink Automation keeper executor contracts.
 *
 * Executors are the ONLY protocol accounts holding KEEPER_ROLE in the automated
 * setup: Chainlink Automation never receives a protocol role. The Chainlink
 * registry calls the executor through a dedicated Forwarder contract, and the
 * executor validates the caller before forwarding privileged calls to the
 * Controller.
 *
 *   Chainlink Automation -> Forwarder -> KeeperExecutor -> Controller -> ...
 */
interface IKeeperExecutorBase {
    // ============ Events ============

    /**
     * @notice Emitted when the trusted Chainlink Forwarder address is changed
     * @param oldForwarder The previous forwarder address
     * @param newForwarder The new forwarder address
     */
    event ForwarderChanged(address indexed oldForwarder, address indexed newForwarder);

    // ============ Errors ============

    /**
     * @notice Thrown when `performUpkeep` is called by anyone other than the registered Forwarder
     */
    error KeeperExecutorOnlyForwarder();

    /**
     * @notice Thrown when a provided address is zero
     */
    error KeeperExecutorZeroAddress();

    /**
     * @notice Thrown when `performUpkeep` re-validation shows no work is needed
     * (stale or malicious performData)
     */
    error KeeperExecutorNoUpkeepNeeded();

    /**
     * @notice Thrown when performData encodes an action the executor does not know
     */
    error KeeperExecutorUnknownAction();

    /**
     * @notice Thrown when a configuration value is out of its allowed range
     */
    error KeeperExecutorInvalidConfig();

    // ============ View Functions ============

    /**
     * @notice Get the version of the executor
     * @return string The version of the executor
     */
    function version() external pure returns (string memory);

    /**
     * @notice The trusted Chainlink Automation Forwarder for this upkeep
     * @dev Obtained from the Chainlink Automation registry after registering the upkeep.
     * While unset (zero address) `performUpkeep` rejects every caller.
     * @return address The forwarder address
     */
    function forwarder() external view returns (address);

    // ============ Admin Functions ============

    /**
     * @notice Sets the trusted Chainlink Automation Forwarder
     * @dev Only callable by ADMIN_ROLE on the Registry. The forwarder address is
     * known only after the upkeep is registered with Chainlink Automation.
     * @param _forwarder The forwarder address
     */
    function setForwarder(address _forwarder) external;

    /**
     * @notice Pauses the executor (checkUpkeep reports no work; performUpkeep reverts)
     */
    function pause() external;

    /**
     * @notice Unpauses the executor
     */
    function unpause() external;
}
