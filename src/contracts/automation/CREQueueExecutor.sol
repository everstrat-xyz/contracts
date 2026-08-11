// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Math} from "../../libraries/Math.sol";
import {Auth} from "../../libraries/Auth.sol";

import {IRegistry} from "interfaces/IRegistry.sol";
import {IController} from "../../interfaces/IController.sol";
import {IExitQueue} from "../../interfaces/IExitQueue.sol";
import {ICREQueueExecutor} from "../../interfaces/automation/ICREQueueExecutor.sol";

import {CREReceiverBase} from "./CREReceiverBase.sol";

/**
 * @title CREQueueExecutor
 * @notice CRE / Keystone receiver for redemption-queue keeper actions.
 *
 * Decision logic mirrors {QueueKeeperExecutor} (CLA). The CRE workflow may scan
 * the full queue off-chain; on-chain {queueUpkeepStatus} remains the gas-bounded
 * fallback / cross-check. Report params are hints — every action is re-validated
 * against live state before Controller calls.
 *
 * ProcessRequests params: `abi.encode(batchId, startIndex, endIndex)` —
 * `endIndex` is exclusive (matches Controller.processRequests).
 * PriceBatch / AdvanceCursor params: `abi.encode(batchId)`.
 */
contract CREQueueExecutor is ICREQueueExecutor, CREReceiverBase {
    using Math for uint256;
    using Auth for IRegistry;

    uint256 public constant MAX_BATCH_SCAN = 25;
    uint256 public constant MIN_BATCH_AGE_UPPER_BOUND = 7 days;
    uint256 public constant MIN_BATCH_AGE_LOWER_BOUND = 1 days;
    uint256 public constant MAX_USERS_PER_UPKEEP_UPPER_BOUND = 100;

    uint256 private constant _DEFAULT_MAX_USERS_PER_UPKEEP = 20;
    uint256 private constant _DEFAULT_MIN_BATCH_AGE = 1 days;

    uint256 public minBatchAge;
    uint256 public maxUsersPerUpkeep;
    uint256 public nextBatchIdToProcess;

    constructor(address registry_, address forwarder_, uint64 chainSelector_, uint64 maxReportAge_)
        CREReceiverBase(registry_, forwarder_, chainSelector_, maxReportAge_)
    {
        nextBatchIdToProcess = 1;
        maxUsersPerUpkeep = _DEFAULT_MAX_USERS_PER_UPKEEP;
        minBatchAge = _DEFAULT_MIN_BATCH_AGE;
    }

    function version() external pure returns (string memory) {
        return "1.0.0-cre";
    }

    // ============ CRE processing ============

    function _processReport(uint8 action, bytes memory params) internal override {
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
            // (CLA always starts at 0; CRE workflows may claim a shorter prefix).
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

    // ============ Views ============

    function queueUpkeepStatus() external view returns (QueueAction action, uint256 batchId, uint256 count) {
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

    // ============ Internal (byte-identical to CLA QueueKeeperExecutor) ============

    function _isBatchSkippable(IExitQueue _queue, uint256 _batchId) internal view returns (bool) {
        if (_queue.unprocessedUsersCount(_batchId) == 0) return true;

        (bool canBeProcessed,,,, uint256 pricedAt) = _queue.batchInfo(_batchId);
        if (!canBeProcessed || pricedAt == 0) return false;

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
        (bool canBeProcessed, uint256 finalEvePrice,,,) = _queue.batchInfo(_batchId);
        if (!canBeProcessed) return 0;

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

    function _advanceBatchCursor(IExitQueue _queue) internal {
        uint256 cursor = _peekAdvancedCursor(_queue);
        if (cursor != nextBatchIdToProcess) {
            nextBatchIdToProcess = cursor;
        }
    }
}
