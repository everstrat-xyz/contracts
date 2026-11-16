// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ExitQueueLimits
 * @notice Shared sealed-batch scan width for the keeper executors.
 * @dev `QueueKeeperExecutor.MAX_BATCH_SCAN` and `StrategyKeeperExecutor.MAX_BATCH_SCAN` both
 *      alias this so the two gas-bounded scans cannot silently desync.
 *      Not a production cadence target — keeper `minBatchAge` vs
 *      `MAX_BATCH_PROCESSING_TIME` implies ~3 overlapping sealed batches.
 */
library ExitQueueLimits {
    uint256 internal constant MAX_BATCH_SCAN = 25;
}
