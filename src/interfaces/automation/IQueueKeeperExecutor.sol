// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IKeeperExecutorBase} from "./IKeeperExecutorBase.sol";

/**
 * @title IQueueKeeperExecutor
 * @notice Interface for the Chainlink Automation executor that drives the
 * redemption queue: pricing the current batch and processing priced batches.
 */
interface IQueueKeeperExecutor is IKeeperExecutorBase {
    // ============ Types ============

    /**
     * @notice Action encoded in performData by `checkUpkeep` and validated
     * against current state in `performUpkeep`.
     * @dev `AdvanceCursor` persists progress past empty or post-commitment
     *      (past `pricedAt + MAX_BATCH_PROCESSING_TIME`) batches when there is
     *      no ProcessRequests/PriceBatch work — without it the stored cursor
     *      would stall and batches beyond `MAX_BATCH_SCAN` would never be seen.
     */
    enum QueueAction {
        None,
        PriceBatch,
        ProcessRequests,
        AdvanceCursor
    }

    // ============ Events ============

    /**
     * @notice Emitted when the minimum current-batch age required before pricing is changed
     * @param oldMinBatchAge The previous minimum age in seconds
     * @param newMinBatchAge The new minimum age in seconds
     */
    event MinBatchAgeChanged(uint256 oldMinBatchAge, uint256 newMinBatchAge);

    /**
     * @notice Emitted when the per-upkeep processing cap is changed
     * @param oldMaxUsersPerUpkeep The previous cap
     * @param newMaxUsersPerUpkeep The new cap
     */
    event MaxUsersPerUpkeepChanged(uint256 oldMaxUsersPerUpkeep, uint256 newMaxUsersPerUpkeep);

    /**
     * @notice Emitted when an upkeep was performed
     * @param action The queue action performed
     * @param batchId The batch the action was performed on
     * @param processedUsers Number of requests processed (zero for PriceBatch)
     */
    event QueueUpkeepPerformed(QueueAction indexed action, uint256 indexed batchId, uint256 processedUsers);

    /**
     * @notice Emitted when the processing cursor is force-advanced by governance
     * @dev Escape hatch for batches whose unprocessed requests cannot be settled
     * and whose users have not closed them — the cursor moves forward so the
     * keeper resumes processing newer batches. Skipped requests remain in the
     * ExitQueue and can still be closed by their owners.
     * @param fromBatchId The previous cursor
     * @param toBatchId The new cursor
     */
    event BatchCursorAdvanced(uint256 fromBatchId, uint256 toBatchId);

    // ============ Errors ============

    /**
     * @notice Thrown when `advanceBatchCursor` targets a batch at or behind the
     * current processing cursor (cursor must move strictly forward)
     */
    error QueueKeeperExecutorBatchCursorPrecedesCurrent();

    /**
     * @notice Thrown when `advanceBatchCursor` targets a batch past the live
     * (unpriced) batch
     */
    error QueueKeeperExecutorBatchCursorPastCurrent();

    // ============ Constants ============

    /**
     * @notice Maximum number of priced batches scanned ahead of the processing
     * cursor in a single checkUpkeep/performUpkeep
     */
    function MAX_BATCH_SCAN() external pure returns (uint256);

    /**
     * @notice Upper bound for `minBatchAge`
     */
    function MIN_BATCH_AGE_UPPER_BOUND() external pure returns (uint256);

    /**
     * @notice Lower bound for `minBatchAge` — batches always age at least this
     * long before pricing, so requests accumulate instead of pricing a new
     * batch for every single request
     */
    function MIN_BATCH_AGE_LOWER_BOUND() external pure returns (uint256);

    /**
     * @notice Upper bound for `maxUsersPerUpkeep` (bounds performUpkeep gas)
     */
    function MAX_USERS_PER_UPKEEP_UPPER_BOUND() external pure returns (uint256);

    // ============ View Functions ============

    /**
     * @notice Minimum age (seconds since creation) the current batch must reach
     * before the executor prices it. Lets requests accumulate instead of pricing
     * a new batch for every single request. Bounded to
     * [MIN_BATCH_AGE_LOWER_BOUND, MIN_BATCH_AGE_UPPER_BOUND].
     */
    function minBatchAge() external view returns (uint256);

    /**
     * @notice Maximum number of redemption requests processed per performUpkeep
     * (bounds performUpkeep gas). Bounded to [1, MAX_USERS_PER_UPKEEP_UPPER_BOUND].
     */
    function maxUsersPerUpkeep() external view returns (uint256);

    /**
     * @notice Cursor below which every batch is fully processed or keeper-skippable.
     * The batch scan starts from the live peek of this cursor (see
     * `nextLiveBatchIdToProcess`) and covers at most `MAX_BATCH_SCAN` batches.
     */
    function nextBatchIdToProcess() external view returns (uint256);

    /**
     * @notice Where `nextBatchIdToProcess` would sit after skipping empty and
     * post-commitment batches (bounded by `MAX_BATCH_SCAN` per peek). Used by
     * `checkUpkeep` and by StrategyKeeperExecutor's pending-redemption scan so
     * dead batches do not pin the scan window.
     */
    function nextLiveBatchIdToProcess() external view returns (uint256);

    /**
     * @notice Number of requests in a priced batch that the Controller can afford
     * to process right now (longest affordable prefix of the unprocessed users,
     * capped at `maxUsersPerUpkeep`)
     * @param _batchId The priced batch to inspect
     * @return count The number of affordable requests
     */
    function affordableRequests(uint256 _batchId) external view returns (uint256 count);

    // ============ Admin Functions ============

    /**
     * @notice Sets the minimum current-batch age required before pricing
     * @param _minBatchAge The new minimum age in seconds
     * (within [MIN_BATCH_AGE_LOWER_BOUND, MIN_BATCH_AGE_UPPER_BOUND])
     */
    function setMinBatchAge(uint256 _minBatchAge) external;

    /**
     * @notice Sets the per-upkeep processing cap
     * @param _maxUsersPerUpkeep The new cap (1..MAX_USERS_PER_UPKEEP_UPPER_BOUND)
     */
    function setMaxUsersPerUpkeep(uint256 _maxUsersPerUpkeep) external;

    /**
     * @notice Force-advances the processing cursor past stuck batches
     * @dev Governance escape hatch for batches that are still inside the
     * `MAX_BATCH_PROCESSING_TIME` commitment window, whose unprocessed
     * requests cannot be settled (e.g. permanently illiquid), and whose users
     * cannot yet `closeRequest`. Once `pricedAt + MAX_BATCH_PROCESSING_TIME`
     * has elapsed the keeper skips those batches automatically via
     * `AdvanceCursor` / cursor peek — this admin path is only needed inside
     * the commitment window. Skipped requests remain in the ExitQueue for
     * owners to close.
     *
     * Only moves the cursor forward and never past the live (unpriced) batch.
     * @param _toBatchId The new cursor (must be > current cursor and <= currentBatchId)
     */
    function advanceBatchCursor(uint256 _toBatchId) external;
}
