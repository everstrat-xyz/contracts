// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

import {Math} from "../../libraries/Math.sol";
import {Auth} from "../../libraries/Auth.sol";

import {IRegistry} from "interfaces/IRegistry.sol";
import {IController} from "../../interfaces/IController.sol";
import {IExitQueue} from "../../interfaces/IExitQueue.sol";
import {IKeeperExecutorBase} from "../../interfaces/automation/IKeeperExecutorBase.sol";
import {IQueueKeeperExecutor} from "../../interfaces/automation/IQueueKeeperExecutor.sol";

import {KeeperExecutorBase} from "./KeeperExecutorBase.sol";

/**
 * @title QueueKeeperExecutor
 * @notice Chainlink Automation executor for the redemption queue.
 *
 * Decides between three actions (encoded in performData, re-validated on-chain):
 *  - ProcessRequests: the oldest live priced batch (from the peeked cursor) has
 *    unprocessed requests the Controller can afford right now — process the
 *    longest affordable prefix, capped at `maxUsersPerUpkeep`.
 *  - PriceBatch: no processing is actionable and the current batch is non-empty,
 *    at least `minBatchAge` old — price it via the Controller.
 *  - AdvanceCursor: no ProcessRequests/PriceBatch work, but the stored cursor
 *    can move past empty or post-commitment batches — persist that progress so
 *    batches beyond `MAX_BATCH_SCAN` become reachable.
 *
 * @dev Static (non-upgradeable). Holds KEEPER_ROLE on the Registry; only the
 * registered Chainlink Forwarder can trigger `performUpkeep`. performData is
 * untrusted per Chainlink guidance — every action is re-validated against
 * current state before execution.
 *
 * Cursor skip rule: a priced batch is skippable when it has no unprocessed
 * users, or when `block.timestamp > pricedAt + MAX_BATCH_PROCESSING_TIME`
 * (ExitQueue escape-hatch window — keeper commitment has expired; remaining
 * users must `closeRequest`). Skips are applied in `checkUpkeep` (view peek)
 * and persisted in every `performUpkeep`.
 */
contract QueueKeeperExecutor is IQueueKeeperExecutor, KeeperExecutorBase {
    using Math for uint256;
    using Auth for IRegistry;

    // ============ Constants ============

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    uint256 public constant MAX_BATCH_SCAN = 25;

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    uint256 public constant MIN_BATCH_AGE_UPPER_BOUND = 7 days;

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    uint256 public constant MIN_BATCH_AGE_LOWER_BOUND = 1 days;

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    uint256 public constant MAX_USERS_PER_UPKEEP_UPPER_BOUND = 100;

    /// @notice Default per-upkeep processing cap
    uint256 private constant _DEFAULT_MAX_USERS_PER_UPKEEP = 20;

    /// @notice Default minimum batch age before pricing
    uint256 private constant _DEFAULT_MIN_BATCH_AGE = 1 days;

    // ============ State Variables ============

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    uint256 public minBatchAge;

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    uint256 public maxUsersPerUpkeep;

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    uint256 public nextBatchIdToProcess;

    // ============ Constructor ============

    /**
     * @notice Deploys the executor against the protocol Registry
     * @param registry_ The protocol Registry (role authority and contract addresses)
     */
    constructor(address registry_) KeeperExecutorBase(registry_) {
        // Batch IDs start from 1 (ID 0 marks immediate redemptions in the AMM)
        nextBatchIdToProcess = 1;
        maxUsersPerUpkeep = _DEFAULT_MAX_USERS_PER_UPKEEP;
        minBatchAge = _DEFAULT_MIN_BATCH_AGE;
    }

    // ============ Metadata ============

    /**
     * @inheritdoc IKeeperExecutorBase
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    // ============ Automation Functions ============

    /**
     * @inheritdoc AutomationCompatibleInterface
     * @dev Simulated off-chain by Chainlink Automation nodes. Reports no work
     * while the executor or any involved protocol contract is paused.
     */
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused()) return (false, "");

        IRegistry registry_ = registry();
        address controller = registry_.controller();
        address exitQueue = registry_.exitQueue();
        address amm = registry_.amm();

        // Redemption processing routes through Controller, ExitQueue.pullRequest
        // and AMM.processRedemption — all pause-gated. Stand down if any is paused.
        if (Pausable(controller).paused() || Pausable(exitQueue).paused() || Pausable(amm).paused()) {
            return (false, "");
        }

        IExitQueue queue = IExitQueue(exitQueue);
        uint256 currentBatchId = queue.currentBatchId();

        // Peek past empty / post-commitment batches so a dead pin cannot hide
        // affordable work beyond the stored cursor's scan window.
        uint256 cursor = _peekAdvancedCursor(queue);
        uint256 scanLimit = cursor + MAX_BATCH_SCAN;

        // 1) Process the oldest actionable priced batch within the scan window.
        // Fairness tradeoff: if the oldest affordable batch is unaffordable but
        // a later one (within the window) is affordable, the later batch is
        // processed first — spending Controller liquidity on a newer batch
        // rather than blocking on the oldest, presumably longer-waiting one.
        // This keeps redemption throughput up when the oldest batch is illiquid;
        // the oldest batch is revisited once Controller liquidity recovers (or
        // skipped once past MAX_BATCH_PROCESSING_TIME).
        for (uint256 batchId = cursor; batchId < currentBatchId && batchId < scanLimit; batchId++) {
            if (_isBatchSkippable(queue, batchId)) continue;
            if (_affordableRequests(queue, controller, batchId) > 0) {
                return (true, abi.encode(QueueAction.ProcessRequests, batchId));
            }
        }

        // 2) Price the current batch once it is non-empty and old enough
        if (queue.unprocessedUsersCount(currentBatchId) > 0) {
            (,,, uint256 createdAt,) = queue.batchInfo(currentBatchId);
            if (block.timestamp - createdAt >= minBatchAge) {
                return (true, abi.encode(QueueAction.PriceBatch, currentBatchId));
            }
        }

        // 3) Persist cursor progress when nothing else is actionable — otherwise
        // empty / dead batches leave `nextBatchIdToProcess` stalled and the
        // StrategyKeeper pending-needs scan (and later ProcessRequests windows)
        // stay blinded past MAX_BATCH_SCAN.
        if (cursor > nextBatchIdToProcess) {
            return (true, abi.encode(QueueAction.AdvanceCursor, cursor));
        }

        return (false, "");
    }

    /**
     * @inheritdoc AutomationCompatibleInterface
     * @dev Only callable by the registered Chainlink Forwarder. performData is
     * untrusted and re-validated against current state; stale data reverts with
     * {KeeperExecutorNoUpkeepNeeded}. Each branch advances the cursor past
     * skippable batches immediately after its own state change (neither
     * `priceBatch()` nor `processRequests()` affects the skippability of any
     * other batch, so a single sync per branch is sufficient).
     */
    function performUpkeep(bytes calldata performData) external override onlyForwarder whenNotPaused nonReentrant {
        (QueueAction action, uint256 batchId) = abi.decode(performData, (QueueAction, uint256));

        IRegistry registry_ = registry();
        IController controller = IController(registry_.controller());
        IExitQueue queue = IExitQueue(registry_.exitQueue());

        if (action == QueueAction.PriceBatch) {
            // Only ever price the live batch; emptiness is enforced downstream
            // by ExitQueue.priceBatch
            if (batchId != queue.currentBatchId()) revert KeeperExecutorNoUpkeepNeeded();
            (,,, uint256 createdAt,) = queue.batchInfo(batchId);
            if (block.timestamp - createdAt < minBatchAge) revert KeeperExecutorNoUpkeepNeeded();

            controller.priceBatch();
            _advanceBatchCursor(queue);
            emit QueueUpkeepPerformed(action, batchId, 0);
        } else if (action == QueueAction.ProcessRequests) {
            uint256 count = _affordableRequests(queue, address(controller), batchId);
            if (count == 0) revert KeeperExecutorNoUpkeepNeeded();

            controller.processRequests(batchId, 0, count);
            _advanceBatchCursor(queue);
            emit QueueUpkeepPerformed(action, batchId, count);
        } else if (action == QueueAction.AdvanceCursor) {
            uint256 cursorBefore = nextBatchIdToProcess;
            _advanceBatchCursor(queue);
            if (nextBatchIdToProcess == cursorBefore) revert KeeperExecutorNoUpkeepNeeded();
            // Loose bound: the live recompute is the source of truth and may
            // legitimately land past the encoded target (e.g. another upkeep or
            // governance advanced the cursor first); only an undershoot — the
            // encoded target was never actually reached — indicates bogus or
            // manipulated performData.
            if (nextBatchIdToProcess < batchId) revert KeeperExecutorNoUpkeepNeeded();
            emit QueueUpkeepPerformed(action, nextBatchIdToProcess, 0);
        } else {
            revert KeeperExecutorUnknownAction();
        }
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    function nextLiveBatchIdToProcess() external view returns (uint256) {
        return _peekAdvancedCursor(IExitQueue(registry().exitQueue()));
    }

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    function affordableRequests(uint256 _batchId) external view returns (uint256 count) {
        IRegistry registry_ = registry();
        return _affordableRequests(IExitQueue(registry_.exitQueue()), registry_.controller(), _batchId);
    }

    // ============ Admin Functions ============

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    function setMinBatchAge(uint256 _minBatchAge) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minBatchAge < MIN_BATCH_AGE_LOWER_BOUND || _minBatchAge > MIN_BATCH_AGE_UPPER_BOUND) {
            revert KeeperExecutorInvalidConfig();
        }
        emit MinBatchAgeChanged(minBatchAge, _minBatchAge);
        minBatchAge = _minBatchAge;
    }

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    function setMaxUsersPerUpkeep(uint256 _maxUsersPerUpkeep) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_maxUsersPerUpkeep == 0 || _maxUsersPerUpkeep > MAX_USERS_PER_UPKEEP_UPPER_BOUND) {
            revert KeeperExecutorInvalidConfig();
        }
        emit MaxUsersPerUpkeepChanged(maxUsersPerUpkeep, _maxUsersPerUpkeep);
        maxUsersPerUpkeep = _maxUsersPerUpkeep;
    }

    /**
     * @inheritdoc IQueueKeeperExecutor
     */
    function advanceBatchCursor(uint256 _toBatchId) external onlyAuthRole(Auth.ADMIN_ROLE) {
        uint256 cursor = nextBatchIdToProcess;
        uint256 currentBatchId = IExitQueue(registry().exitQueue()).currentBatchId();
        // The cursor only moves forward, never past the live (unpriced) batch.
        if (_toBatchId <= cursor) revert QueueKeeperExecutorBatchCursorPrecedesCurrent();
        if (_toBatchId > currentBatchId) revert QueueKeeperExecutorBatchCursorPastCurrent();

        nextBatchIdToProcess = _toBatchId;
        emit BatchCursorAdvanced(cursor, _toBatchId);
    }

    // ============ Internal Functions ============

    /**
     * @notice Whether the keeper may advance the cursor past this batch
     * @dev Empty batches are always skippable. Priced batches past
     * `pricedAt + MAX_BATCH_PROCESSING_TIME` are skippable even with leftover
     * unprocessed users — the ExitQueue escape hatch is open and the keeper
     * commitment window has expired.
     * @param _queue The exit queue
     * @param _batchId The batch to inspect
     * @return True if the cursor may skip this batch
     */
    function _isBatchSkippable(IExitQueue _queue, uint256 _batchId) internal view returns (bool) {
        if (_queue.unprocessedUsersCount(_batchId) == 0) return true;

        (bool canBeProcessed,,,, uint256 pricedAt) = _queue.batchInfo(_batchId);
        if (!canBeProcessed || pricedAt == 0) return false;

        return block.timestamp > pricedAt + _queue.MAX_BATCH_PROCESSING_TIME();
    }

    /**
     * @notice View peek of where the processing cursor would sit after skipping
     * empty and post-commitment batches
     * @dev Bounded by `MAX_BATCH_SCAN` per call so gas stays predictable; deep
     * backlogs of skippable batches require repeated AdvanceCursor upkeeps.
     * @param _queue The exit queue
     * @return cursor The advanced cursor (may equal `nextBatchIdToProcess`)
     */
    function _peekAdvancedCursor(IExitQueue _queue) internal view returns (uint256 cursor) {
        uint256 currentBatchId = _queue.currentBatchId();
        cursor = nextBatchIdToProcess;
        uint256 scanLimit = cursor + MAX_BATCH_SCAN;

        while (cursor < currentBatchId && cursor < scanLimit && _isBatchSkippable(_queue, cursor)) {
            cursor++;
        }
    }

    /**
     * @notice Longest affordable prefix of a priced batch's unprocessed requests
     * @dev Mirrors Controller._processRequest cost accounting: requests outside
     * their price tolerance settle at zero ETH; the rest cost
     * `convertAssets(tokensToBurn, finalEvePrice)` from the Controller balance.
     * @param _queue The exit queue
     * @param _controller The Controller (its ETH balance is the budget)
     * @param _batchId The batch to inspect
     * @return count The number of requests processable right now
     */
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

    /**
     * @notice Advances the processing cursor past empty and post-commitment batches
     * @dev Bounded by MAX_BATCH_SCAN per call; the cursor only moves forward.
     * @param _queue The exit queue
     */
    function _advanceBatchCursor(IExitQueue _queue) internal {
        uint256 cursor = _peekAdvancedCursor(_queue);
        if (cursor != nextBatchIdToProcess) {
            nextBatchIdToProcess = cursor;
        }
    }
}
