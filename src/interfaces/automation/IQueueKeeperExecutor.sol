// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IKeeperExecutorBase} from "./IKeeperExecutorBase.sol";

/**
 * @title IQueueKeeperExecutor
 * @notice Keeper executor for redemption-queue actions, driven by an external
 *         automation network.
 */
interface IQueueKeeperExecutor is IKeeperExecutorBase {
    enum QueueAction {
        None,
        PriceBatch,
        ProcessRequests,
        AdvanceCursor
    }

    event MinBatchAgeChanged(uint256 oldMinBatchAge, uint256 newMinBatchAge);
    event MaxUsersPerUpkeepChanged(uint256 oldMaxUsersPerUpkeep, uint256 newMaxUsersPerUpkeep);
    event QueueUpkeepPerformed(QueueAction indexed action, uint256 indexed batchId, uint256 processedUsers);
    event BatchCursorAdvanced(uint256 fromBatchId, uint256 toBatchId);

    error KeeperExecutorNoUpkeepNeeded();
    error KeeperExecutorUnknownAction();
    error KeeperExecutorInvalidConfig();
    error QueueKeeperExecutorBatchCursorPrecedesCurrent();
    error QueueKeeperExecutorBatchCursorPastCurrent();

    /// @notice Keeper execution entrypoint (allowlisted caller; untrusted payload)
    function perform(uint8 action, bytes calldata params) external;

    function setMinBatchAge(uint256 _minBatchAge) external;
    function setMaxUsersPerUpkeep(uint256 _maxUsersPerUpkeep) external;
    function advanceBatchCursor(uint256 _toBatchId) external;

    function minBatchAge() external view returns (uint256);
    function maxUsersPerUpkeep() external view returns (uint256);
    function nextBatchIdToProcess() external view returns (uint256);
    function nextLiveBatchIdToProcess() external view returns (uint256);
    function affordableRequests(uint256 _batchId) external view returns (uint256 count);

    /**
     * @notice Fallback / cross-check view (gas-bounded scan). Also the decision
     *         engine behind `checker()`.
     * @return action Recommended action
     * @return batchId Target batch (or advanced cursor for AdvanceCursor)
     * @return count Affordable user count for ProcessRequests; else 0
     */
    function queueUpkeepStatus() external view returns (QueueAction action, uint256 batchId, uint256 count);

    /// @notice On-chain checker; execPayload targets `perform`
    function checker() external view returns (bool canExec, bytes memory execPayload);

    /// @notice Gas-bounded scan width. Aliased from `ExitQueueLimits.MAX_LIVE_PRICED_BATCHES`.
    function MAX_BATCH_SCAN() external pure returns (uint256);
    function MIN_BATCH_AGE_UPPER_BOUND() external pure returns (uint256);
    function MIN_BATCH_AGE_LOWER_BOUND() external pure returns (uint256);
    function MAX_USERS_PER_UPKEEP_UPPER_BOUND() external pure returns (uint256);
}
