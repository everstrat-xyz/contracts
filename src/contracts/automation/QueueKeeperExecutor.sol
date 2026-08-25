// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Math} from "../../libraries/Math.sol";
import {Auth} from "../../libraries/Auth.sol";
import {ExitQueueLimits} from "../../libraries/ExitQueueLimits.sol";

import {IRegistry} from "interfaces/IRegistry.sol";
import {IController} from "../../interfaces/IController.sol";
import {IExitQueue} from "../../interfaces/IExitQueue.sol";
import {IQueueKeeperExecutor} from "../../interfaces/automation/IQueueKeeperExecutor.sol";

import {KeeperExecutorBase} from "./KeeperExecutorBase.sol";

/**
 * @title QueueKeeperExecutor
 * @notice Gelato keeper executor for redemption-queue actions.
 *
 * Gelato surface:
 *   - `checker()` — on-chain resolver returning canExec + calldata for `perform`.
 *     Gas-bounded to MAX_BATCH_SCAN; the TypeScript function (W1) is the
 *     deep-scan path and produces the same perform calldata.
 *   - `perform(uint8,bytes)` — execution target; allowlisted caller only.
 *
 * performData is a hint — every action is re-validated against live state
 * before Controller calls.
 *
 * Params (identical wire shapes to the previous executor generation):
 *   PriceBatch      abi.encode(batchId)
 *   ProcessRequests abi.encode(batchId, startIndex, endIndex) — endIndex exclusive
 *   AdvanceCursor   abi.encode(batchId)
 */
contract QueueKeeperExecutor is IQueueKeeperExecutor, KeeperExecutorBase {
    using Math for uint256;
    using Auth for IRegistry;

    /// @dev Gas-bounded fallback scan. Bound to `ExitQueueLimits.MAX_LIVE_PRICED_BATCHES`
    ///      (same cap as `ExitQueue.MAX_LIVE_PRICED_BATCHES`) so a change cannot silently
    ///      desync the keeper. A DoS bound, not cadence — `minBatchAge` vs
    ///      `MAX_BATCH_PROCESSING_TIME` implies ~3 overlapping priced batches.
    uint256 public constant MAX_BATCH_SCAN = ExitQueueLimits.MAX_LIVE_PRICED_BATCHES;
    uint256 public constant MIN_BATCH_AGE_UPPER_BOUND = 7 days;
    uint256 public constant MIN_BATCH_AGE_LOWER_BOUND = 1 days;
    uint256 public constant MAX_USERS_PER_UPKEEP_UPPER_BOUND = 100;

    uint256 private constant _DEFAULT_MAX_USERS_PER_UPKEEP = 20;
    uint256 private constant _DEFAULT_MIN_BATCH_AGE = 1 days;

    uint256 public minBatchAge;
    uint256 public maxUsersPerUpkeep;
    uint256 public nextBatchIdToProcess;

    constructor(address registry_) KeeperExecutorBase(registry_) {
        nextBatchIdToProcess = 1;
        maxUsersPerUpkeep = _DEFAULT_MAX_USERS_PER_UPKEEP;
        minBatchAge = _DEFAULT_MIN_BATCH_AGE;
    }

    // ============ Admin ============

    function setMinBatchAge(uint256 _minBatchAge) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minBatchAge < MIN_BATCH_AGE_LOWER_BOUND || _minBatchAge > MIN_BATCH_AGE_UPPER_BOUND) {
            revert KeeperExecutorInvalidConfig();
        }
        emit MinBatchAgeChanged(minBatchAge, _minBatchAge);
        minBatchAge = _minBatchAge;
    }

    function setMaxUsersPerUpkeep(uint256 _maxUsersPerUpkeep) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_maxUsersPerUpkeep == 0 || _maxUsersPerUpkeep > MAX_USERS_PER_UPKEEP_UPPER_BOUND) {
            revert KeeperExecutorInvalidConfig();
        }
        emit MaxUsersPerUpkeepChanged(maxUsersPerUpkeep, _maxUsersPerUpkeep);
        maxUsersPerUpkeep = _maxUsersPerUpkeep;
    }

    function advanceBatchCursor(uint256 _toBatchId) external onlyAuthRole(Auth.ADMIN_ROLE) {
        uint256 cursor = nextBatchIdToProcess;
        uint256 currentBatchId = IExitQueue(registry().exitQueue()).currentBatchId();
        if (_toBatchId <= cursor) revert QueueKeeperExecutorBatchCursorPrecedesCurrent();
        if (_toBatchId > currentBatchId) revert QueueKeeperExecutorBatchCursorPastCurrent();

        nextBatchIdToProcess = _toBatchId;
        emit BatchCursorAdvanced(cursor, _toBatchId);
    }

    // ============ Gelato surface ============

    /**
     * @notice Gelato checker. execPayload is the full calldata for `perform`,
     *         so an on-chain-driven task and the TS function emit byte-identical calls.
     * @dev `None` yields canExec=false, never a perform call.
     */
    function checker() external view returns (bool canExec, bytes memory execPayload) {
        (QueueAction action, uint256 batchId, uint256 count) = _queueUpkeepStatus();
        if (action == QueueAction.None) {
            return (false, bytes("no queue upkeep needed"));
        }
        if (action == QueueAction.ProcessRequests) {
            return (true, abi.encodeCall(this.perform, (uint8(action), abi.encode(batchId, uint256(0), count))));
        }
        return (true, abi.encodeCall(this.perform, (uint8(action), abi.encode(batchId))));
    }

    /**
     * @notice Keeper execution entrypoint. Untrusted payload from an allowlisted
     *         automation caller; every claim re-validated against live state.
     */
    function perform(uint8 action, bytes calldata params) external onlyExecutorCaller whenNotPaused nonReentrant {
        _processReport(action, params);
    }

    // ============ Views ============

    function queueUpkeepStatus() external view returns (QueueAction action, uint256 batchId, uint256 count) {
        return _queueUpkeepStatus();
    }

    function _queueUpkeepStatus() internal view returns (QueueAction action, uint256 batchId, uint256 count) {
        if (paused()) return (QueueAction.None, 0, 0);

        IRegistry registry_ = registry();
        address controller = registry_.controller();
        address exitQueue = registry_.exitQueue();
        address amm = registry_.amm();

        if (Pausable(controller).paused() || Pausable(exitQueue).paused() || Pausable(amm).paused()) {
            return (QueueAction.None, 0, 0);
        }

        IExitQueue queue = IExitQueue(exitQueue);
        uint256 currentBatchId = queue.currentBatchId();
        uint256 cursor = _peekAdvancedCursor(queue);
        uint256 scanLimit = cursor + MAX_BATCH_SCAN;

        for (uint256 id = cursor; id < currentBatchId && id < scanLimit; id++) {
            if (_isBatchSkippable(queue, id)) continue;
            uint256 affordable = _affordableRequests(queue, controller, id);
            if (affordable > 0) {
                return (QueueAction.ProcessRequests, id, affordable);
            }
        }

        if (queue.unprocessedUsersCount(currentBatchId) > 0) {
            (,,, uint256 createdAt,) = queue.batchInfo(currentBatchId);
            if (block.timestamp - createdAt >= minBatchAge) {
                return (QueueAction.PriceBatch, currentBatchId, 0);
            }
        }

        if (cursor > nextBatchIdToProcess) {
            return (QueueAction.AdvanceCursor, cursor, 0);
        }

        return (QueueAction.None, 0, 0);
    }

    function nextLiveBatchIdToProcess() external view returns (uint256) {
        return _peekAdvancedCursor(IExitQueue(registry().exitQueue()));
    }

    function affordableRequests(uint256 _batchId) external view returns (uint256 count) {
        IRegistry registry_ = registry();
        return _affordableRequests(IExitQueue(registry_.exitQueue()), registry_.controller(), _batchId);
    }

    function version() external pure returns (string memory) {
        return "2.0.0-gelato";
    }

    // ============ Processing ============

    function _processReport(uint8 action, bytes memory params) internal {
        QueueAction queueAction = QueueAction(action);
        IRegistry registry_ = registry();
        IController controller = IController(registry_.controller());
        IExitQueue queue = IExitQueue(registry_.exitQueue());

        if (queueAction == QueueAction.PriceBatch) {
            uint256 batchId = abi.decode(params, (uint256));
            if (batchId != queue.currentBatchId()) revert KeeperExecutorNoUpkeepNeeded();
            (,,, uint256 createdAt,) = queue.batchInfo(batchId);
            if (block.timestamp - createdAt < minBatchAge) revert KeeperExecutorNoUpkeepNeeded();

            controller.priceBatch();
            _advanceBatchCursor(queue);
            emit QueueUpkeepPerformed(queueAction, batchId, 0);
        } else if (queueAction == QueueAction.ProcessRequests) {
            (uint256 batchId, uint256 startIndex, uint256 endIndex) = abi.decode(params, (uint256, uint256, uint256));
            if (endIndex <= startIndex) revert KeeperExecutorNoUpkeepNeeded();

            // Re-validate: claimed range must be a prefix of the affordable set
            // starting at index 0 (the TS function may claim a shorter prefix).
            uint256 affordable = _affordableRequests(queue, address(controller), batchId);
            if (startIndex != 0 || endIndex > affordable) revert KeeperExecutorNoUpkeepNeeded();

            controller.processRequests(batchId, startIndex, endIndex);
            _advanceBatchCursor(queue);
            emit QueueUpkeepPerformed(queueAction, batchId, endIndex - startIndex);
        } else if (queueAction == QueueAction.AdvanceCursor) {
            uint256 batchId = abi.decode(params, (uint256));
            uint256 cursorBefore = nextBatchIdToProcess;
            _advanceBatchCursor(queue);
            if (nextBatchIdToProcess == cursorBefore) revert KeeperExecutorNoUpkeepNeeded();
            if (nextBatchIdToProcess < batchId) revert KeeperExecutorNoUpkeepNeeded();
            emit QueueUpkeepPerformed(queueAction, nextBatchIdToProcess, 0);
        } else {
            revert KeeperExecutorUnknownAction();
        }
    }

    // ============ Internal ============

    function _advanceBatchCursor(IExitQueue _queue) internal {
        uint256 cursor = _peekAdvancedCursor(_queue);
        if (cursor != nextBatchIdToProcess) {
            nextBatchIdToProcess = cursor;
        }
    }

    /**
     * @notice Whether the cursor may advance past `_batchId` without work being lost.
     * @dev `ExitQueue.priceBatch` sets `canBeProcessed` and `pricedAt` in the same write, so
     *      `canBeProcessed` alone is the "is priced" predicate (`pricedAt == 0` is the same check
     *      and is therefore not repeated). The unpriced guard comes FIRST so the helper is correct
     *      for any `_batchId`, not just the `_batchId < currentBatchId` range the callers use: an
     *      unpriced batch — the current one, or any future id — is never skippable, even when it
     *      is still empty, because it can still receive requests and must be priced first.
     */
    function _isBatchSkippable(IExitQueue _queue, uint256 _batchId) internal view returns (bool) {
        (bool canBeProcessed,,,, uint256 pricedAt) = _queue.batchInfo(_batchId);
        if (!canBeProcessed) return false;

        if (_queue.unprocessedUsersCount(_batchId) == 0) return true;

        // Priced but past the processing window: users may self-serve via the ExitQueue
        // escape hatch, so the keeper stops blocking on it.
        return block.timestamp > pricedAt + _queue.MAX_BATCH_PROCESSING_TIME();
    }

    function _peekAdvancedCursor(IExitQueue _queue) internal view returns (uint256 cursor) {
        uint256 currentBatchId = _queue.currentBatchId();
        cursor = nextBatchIdToProcess;
        uint256 scanLimit = cursor + MAX_BATCH_SCAN;

        while (cursor < currentBatchId && cursor < scanLimit && _isBatchSkippable(_queue, cursor)) {
            cursor++;
        }
    }

    function _affordableRequests(IExitQueue _queue, address _controller, uint256 _batchId)
        internal
        view
        returns (uint256 count)
    {
        (bool canBeProcessed, uint256 finalEvePrice,,, uint256 pricedAt) = _queue.batchInfo(_batchId);
        if (!canBeProcessed) return 0;
        if (pricedAt > 0 && block.timestamp > pricedAt + _queue.MAX_BATCH_PROCESSING_TIME()) return 0;

        uint256 unprocessedCount = _queue.unprocessedUsersCount(_batchId);
        if (unprocessedCount == 0) return 0;

        uint256 cap = unprocessedCount > maxUsersPerUpkeep ? maxUsersPerUpkeep : unprocessedCount;
        address[] memory users = _queue.unprocessedUsers(_batchId, 0, cap);

        uint256 budget = _controller.balance;
        uint256 cumulativeCost;
        for (uint256 i = 0; i < users.length; i++) {
            (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
                _queue.requestInfo(_batchId, users[i]);

            uint256 cost = finalEvePrice.isRelativelyLessThan(evePriceAtRequestTime, priceTolerance)
                ? 0
                : tokensToBurn.convertAssets(finalEvePrice);

            if (cumulativeCost + cost > budget) break;
            cumulativeCost += cost;
            count++;
        }
    }
}
