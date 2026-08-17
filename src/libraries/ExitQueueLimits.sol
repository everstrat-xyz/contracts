// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title ExitQueueLimits
 * @notice Shared live-priced batch cap for ExitQueue and the CRE keepers.
 * @dev `ExitQueue.MAX_LIVE_PRICED_BATCHES` and CRE `MAX_BATCH_SCAN` both alias this
 *      so a cap change cannot silently desync the keeper's gas-bounded scan.
 *      Direct `ExitQueue.MAX_LIVE_PRICED_BATCHES` references from other contracts
 *      do not compile (interface getter shadows the constant).
 *      Not a production cadence target — CRE `minBatchAge` vs
 *      `MAX_BATCH_PROCESSING_TIME` implies ~3 overlapping priced batches.
 */
library ExitQueueLimits {
    uint256 internal constant MAX_LIVE_PRICED_BATCHES = 25;
}
