// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

import {Math} from "../../libraries/Math.sol";
import {Auth} from "../../libraries/Auth.sol";

import {IRegistry} from "interfaces/IRegistry.sol";
import {IAMM} from "../../interfaces/IAMM.sol";
import {IController} from "../../interfaces/IController.sol";
import {IExitQueue} from "../../interfaces/IExitQueue.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {IStrategyManager} from "../../interfaces/IStrategyManager.sol";
import {IKeeperExecutorBase} from "../../interfaces/automation/IKeeperExecutorBase.sol";
import {IQueueKeeperExecutor} from "../../interfaces/automation/IQueueKeeperExecutor.sol";
import {IStrategyKeeperExecutor} from "../../interfaces/automation/IStrategyKeeperExecutor.sol";

import {KeeperExecutorBase} from "./KeeperExecutorBase.sol";

/**
 * @title StrategyKeeperExecutor
 * @notice Chainlink Automation executor for strategy operations.
 *
 * Decides between six actions, in priority order (encoded in performData,
 * re-validated on-chain):
 *  - Rebalance: some registered strategy is unhealthy and not paused.
 *  - WithdrawShortfall: pending redemptions need more ETH than the Controller
 *    holds — withdraw the shortfall from strategies to the Controller.
 *  - ProvideExitLiquidity: the AMM immediate-exit float is below
 *    `exitLiquidityTargetETH` — top it up from idle Controller ETH.
 *  - DepositExcess: the Controller holds ETH above the configured reserve and the
 *    pending redemption needs — deposit the excess into strategies.
 *  - HarvestPerformanceFees: at least one registered strategy has accrued
 *    performance fees above the configured minimum harvest amount — mint the accrued fees to the
 *    DAO treasury via the Controller.
 *  - Sync: `syncInterval` elapsed since the last automated sync.
 *
 * @dev Static (non-upgradeable). Holds KEEPER_ROLE on the Registry; only the
 * registered Chainlink Forwarder can trigger `performUpkeep`. Amounts are never
 * taken from performData — they are recomputed from current state at execution
 * time (snapshot-before-execution pattern).
 */
contract StrategyKeeperExecutor is IStrategyKeeperExecutor, KeeperExecutorBase {
    using Math for uint256;
    using Auth for IRegistry;

    // ============ Constants ============

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public constant MAX_BATCH_SCAN = 25;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public constant MAX_USERS_COST_SCAN = 50;

    /// @notice Default minimum idle excess before a deposit upkeep triggers
    uint256 private constant _DEFAULT_MIN_DEPOSIT_ETH = 0.1 ether;

    /// @notice Default minimum shortfall before a withdrawal upkeep triggers
    uint256 private constant _DEFAULT_MIN_WITHDRAW_ETH = 0.01 ether;

    /// @notice Default minimum accrued fee before a harvest upkeep triggers
    uint256 private constant _DEFAULT_MIN_HARVEST_ETH = 0.01 ether;

    /// @notice Default interval between automated strategy syncs
    uint256 private constant _DEFAULT_SYNC_INTERVAL = 1 days;

    /// @notice Default minimum exit-liquidity top-up before an upkeep triggers
    uint256 private constant _DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH = 0.01 ether;

    // ============ State Variables ============

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public controllerReserveETH;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public minDepositETH;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public minWithdrawETH;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public minHarvestETH;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public syncInterval;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public lastSyncAt;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public exitLiquidityTargetETH;

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    uint256 public minExitLiquidityTopUpETH;

    // ============ Constructor ============

    /**
     * @notice Deploys the executor against the protocol Registry
     * @param registry_ The protocol Registry (role authority and contract addresses)
     * @dev Policy knobs (`controllerReserveETH`, `exitLiquidityTargetETH`) default to
     *      0 — reserve holds nothing back; ProvideExitLiquidity stays disabled until
     *      admin sets a target. Dust filters and the sync interval get non-zero defaults.
     */
    constructor(address registry_) KeeperExecutorBase(registry_) {
        minDepositETH = _DEFAULT_MIN_DEPOSIT_ETH;
        minWithdrawETH = _DEFAULT_MIN_WITHDRAW_ETH;
        minHarvestETH = _DEFAULT_MIN_HARVEST_ETH;
        syncInterval = _DEFAULT_SYNC_INTERVAL;
        minExitLiquidityTopUpETH = _DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH;
        lastSyncAt = block.timestamp;
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
     * while the executor, the Controller, or the StrategyManager is paused.
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
        address strategyManager = registry_.strategyManager();

        if (Pausable(controller).paused() || Pausable(strategyManager).paused()) return (false, "");

        IStrategyManager strategyManager_ = IStrategyManager(strategyManager);

        // 1) Health first: rebalance any unhealthy, unpaused strategy
        if (_rebalanceNeeded(strategyManager_)) {
            return (true, abi.encode(StrategyAction.Rebalance));
        }

        // 2) Liquidity for redemptions: withdraw the shortfall from strategies
        uint256 needsETH = _pendingRedemptionNeedsETH(registry_);
        uint256 controllerBalance = controller.balance;
        if (
            needsETH > controllerBalance && needsETH - controllerBalance >= minWithdrawETH
                && _totalMaxWithdrawal(strategyManager_) > 0
        ) {
            return (true, abi.encode(StrategyAction.WithdrawShortfall));
        }

        // 3) Immediate-exit liquidity: top the AMM float up to the target from
        // idle Controller ETH (outranks DepositExcess: serving user exits comes
        // before putting idle capital to work)
        if (_exitLiquidityTopUp(registry_, controllerBalance, needsETH) >= minExitLiquidityTopUpETH) {
            return (true, abi.encode(StrategyAction.ProvideExitLiquidity));
        }

        // 4) Put idle capital to work: deposit the excess above reserve and needs
        uint256 excess = _idleExcess(controllerBalance, needsETH);
        if (excess >= minDepositETH && _depositCapacityAvailable(strategyManager_)) {
            return (true, abi.encode(StrategyAction.DepositExcess));
        }

        // 5) Harvest accrued performance fees to the DAO treasury
        if (_pendingPerformanceFeeETH(strategyManager_) >= minHarvestETH) {
            return (true, abi.encode(StrategyAction.HarvestPerformanceFees));
        }

        // 6) Housekeeping: periodic strategy sync
        if (syncInterval != 0 && block.timestamp - lastSyncAt >= syncInterval && strategyManager_.strategyCount() > 0) {
            return (true, abi.encode(StrategyAction.Sync));
        }

        return (false, "");
    }

    /**
     * @inheritdoc AutomationCompatibleInterface
     * @dev Only callable by the registered Chainlink Forwarder. performData is
     * untrusted: it only selects the action, all amounts and conditions are
     * recomputed from current state; stale data reverts with
     * {KeeperExecutorNoUpkeepNeeded}.
     */
    function performUpkeep(bytes calldata performData) external override onlyForwarder whenNotPaused nonReentrant {
        StrategyAction action = abi.decode(performData, (StrategyAction));

        IRegistry registry_ = registry();
        IController controller = IController(registry_.controller());
        IStrategyManager strategyManager_ = IStrategyManager(registry_.strategyManager());

        if (action == StrategyAction.Rebalance) {
            if (!_rebalanceNeeded(strategyManager_)) revert KeeperExecutorNoUpkeepNeeded();

            controller.checkAndRebalanceStrategies();
            emit StrategyUpkeepPerformed(action, 0);
        } else if (action == StrategyAction.WithdrawShortfall) {
            uint256 needsETH = _pendingRedemptionNeedsETH(registry_);
            uint256 controllerBalance = address(controller).balance;
            if (needsETH <= controllerBalance || needsETH - controllerBalance < minWithdrawETH) {
                revert KeeperExecutorNoUpkeepNeeded();
            }

            uint256 shortfall = needsETH - controllerBalance;
            controller.withdrawFromStrategies(shortfall);
            emit StrategyUpkeepPerformed(action, shortfall);
        } else if (action == StrategyAction.ProvideExitLiquidity) {
            uint256 topUp =
                _exitLiquidityTopUp(registry_, address(controller).balance, _pendingRedemptionNeedsETH(registry_));
            if (topUp < minExitLiquidityTopUpETH) revert KeeperExecutorNoUpkeepNeeded();

            controller.provideExitLiquidity(topUp);
            emit StrategyUpkeepPerformed(action, topUp);
        } else if (action == StrategyAction.DepositExcess) {
            uint256 excess = _idleExcess(address(controller).balance, _pendingRedemptionNeedsETH(registry_));
            if (excess < minDepositETH || !_depositCapacityAvailable(strategyManager_)) {
                revert KeeperExecutorNoUpkeepNeeded();
            }

            controller.depositToStrategies(excess);
            emit StrategyUpkeepPerformed(action, excess);
        } else if (action == StrategyAction.HarvestPerformanceFees) {
            // Snapshot feeETH from views before harvest (same pattern as
            // shortfall/excess). Exact settlement amounts for indexers live on
            // PerformanceFeeHarvestCompleted / PerformanceFeePaid.
            uint256 feeETH = _pendingPerformanceFeeETH(strategyManager_);
            if (feeETH < minHarvestETH) revert KeeperExecutorNoUpkeepNeeded();

            controller.harvestPerformanceFeeFromStrategies();
            emit StrategyUpkeepPerformed(action, feeETH);
        } else if (action == StrategyAction.Sync) {
            if (syncInterval == 0 || block.timestamp - lastSyncAt < syncInterval) {
                revert KeeperExecutorNoUpkeepNeeded();
            }

            lastSyncAt = block.timestamp;
            controller.syncStrategies();
            emit StrategyUpkeepPerformed(action, 0);
        } else {
            revert KeeperExecutorUnknownAction();
        }
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    function pendingRedemptionNeedsETH() external view returns (uint256 needsETH) {
        return _pendingRedemptionNeedsETH(registry());
    }

    // ============ Admin Functions ============

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    function setControllerReserveETH(uint256 _controllerReserveETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ControllerReserveETHChanged(controllerReserveETH, _controllerReserveETH);
        controllerReserveETH = _controllerReserveETH;
    }

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    function setMinDepositETH(uint256 _minDepositETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minDepositETH == 0) revert KeeperExecutorInvalidConfig();
        emit MinDepositETHChanged(minDepositETH, _minDepositETH);
        minDepositETH = _minDepositETH;
    }

    /**
     * @inheritdoc IStrategyKeeperExecutor
     *
     * @dev `0` is intentionally allowed (unlike `setMinDepositETH`, which
     * rejects `0`): a zero threshold means the executor reacts to any
     * redemption shortfall, however small, which is desirable for liquidity
     * responsiveness. Deposit-spam on dust is the concern on the deposit side,
     * not on the withdrawal side — withdrawing to meet redemptions is never
     * wasteful even at small amounts.
     */
    function setMinWithdrawETH(uint256 _minWithdrawETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit MinWithdrawETHChanged(minWithdrawETH, _minWithdrawETH);
        minWithdrawETH = _minWithdrawETH;
    }

    /**
     * @inheritdoc IStrategyKeeperExecutor
     * @dev Non-zero like `setMinDepositETH`: dust harvests waste Automation gas
     * for negligible treasury mint; admins raise the floor to batch accrual.
     */
    function setMinHarvestETH(uint256 _minHarvestETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minHarvestETH == 0) revert KeeperExecutorInvalidConfig();
        emit MinHarvestETHChanged(minHarvestETH, _minHarvestETH);
        minHarvestETH = _minHarvestETH;
    }

    /**
     * @inheritdoc IStrategyKeeperExecutor
     */
    function setSyncInterval(uint256 _syncInterval) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit SyncIntervalChanged(syncInterval, _syncInterval);
        syncInterval = _syncInterval;
    }

    /**
     * @inheritdoc IStrategyKeeperExecutor
     *
     * @dev `0` intentionally disables the action (same opt-out pattern as
     * `setSyncInterval`): governance can turn off automated float funding
     * without pausing the executor.
     */
    function setExitLiquidityTargetETH(uint256 _exitLiquidityTargetETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExitLiquidityTargetETHChanged(exitLiquidityTargetETH, _exitLiquidityTargetETH);
        exitLiquidityTargetETH = _exitLiquidityTargetETH;
    }

    /**
     * @inheritdoc IStrategyKeeperExecutor
     * @dev Non-zero like `setMinDepositETH`: dust top-ups waste Automation gas
     * for negligible immediate-exit capacity.
     */
    function setMinExitLiquidityTopUpETH(uint256 _minExitLiquidityTopUpETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minExitLiquidityTopUpETH == 0) revert KeeperExecutorInvalidConfig();
        emit MinExitLiquidityTopUpETHChanged(minExitLiquidityTopUpETH, _minExitLiquidityTopUpETH);
        minExitLiquidityTopUpETH = _minExitLiquidityTopUpETH;
    }

    // ============ Internal Functions ============

    /**
     * @notice Whether any registered strategy is unhealthy and not paused
     * @param _strategyManager The StrategyManager
     * @return bool True when a rebalance upkeep is actionable
     */
    function _rebalanceNeeded(IStrategyManager _strategyManager) internal view returns (bool) {
        address[] memory strategies = _strategyManager.strategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            IStrategy strategy = IStrategy(strategies[i]);
            if (!strategy.paused() && !strategy.isHealthy()) return true;
        }
        return false;
    }

    /**
     * @notice Total ETH withdrawable from registered strategies right now
     * @param _strategyManager The StrategyManager
     * @return total The sum of strategy `maxWithdrawal()` values
     */
    function _totalMaxWithdrawal(IStrategyManager _strategyManager) internal view returns (uint256 total) {
        address[] memory strategies = _strategyManager.strategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            total += IStrategy(strategies[i]).maxWithdrawal();
        }
    }

    /**
     * @notice Whether any registered strategy can accept a deposit
     * @dev Mirrors StrategyManager's batch-deposit eligibility: strategies in
     * post-withdrawal deposit cooldown are skipped by the batch deposit, so they
     * must not count as capacity here — otherwise checkUpkeep selects a deposit
     * upkeep that places nothing and repeats every cycle (burning Automation
     * funding and starving lower-priority actions for the cooldown window).
     * @param _strategyManager The StrategyManager
     * @return bool True when a deposit upkeep would place funds
     */
    function _depositCapacityAvailable(IStrategyManager _strategyManager) internal view returns (bool) {
        address[] memory strategies = _strategyManager.strategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            IStrategy strategy = IStrategy(strategies[i]);
            if (
                !_strategyManager.isStrategyInDepositCooldown(address(strategy)) && strategy.isHealthy()
                    && strategy.maxDeposit() > 0
            ) return true;
        }
        return false;
    }

    /**
     * @notice Accrued performance fees across registered strategies, in ETH
     * @dev Sums `StrategyManager.pendingPerformanceFeeInETH` (strategy-local LP-fee
     * accounting). Fees are also harvested inline during deposits/withdrawals; this
     * estimate covers periods of no other keeper activity. Returns 0 when
     * `performanceFeeBps == 0` (fees disabled).
     * @param _strategyManager The StrategyManager
     * @return totalFeeETH Sum of pending fees in ETH (18 decimals)
     */
    function _pendingPerformanceFeeETH(IStrategyManager _strategyManager) internal view returns (uint256 totalFeeETH) {
        if (_strategyManager.performanceFeeBps() == 0) return 0;

        address[] memory strategies = _strategyManager.strategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            totalFeeETH += _strategyManager.pendingPerformanceFeeInETH(strategies[i]);
        }
    }

    /**
     * @notice Controller ETH above the configured reserve and pending redemption needs
     * @param _controllerBalance The Controller's current ETH balance
     * @param _needsETH The pending redemption needs estimate
     * @return uint256 The idle excess available for deposit
     */
    function _idleExcess(uint256 _controllerBalance, uint256 _needsETH) internal view returns (uint256) {
        uint256 reserved = controllerReserveETH + _needsETH;
        return _controllerBalance > reserved ? _controllerBalance - reserved : 0;
    }

    /**
     * @notice ETH to route from the Controller to the AMM immediate-exit float
     * @dev Tops the AMM free balance up to `exitLiquidityTargetETH`, capped at
     * the idle Controller excess above `controllerReserveETH` and pending
     * redemption needs — float funding never cannibalizes queued-redemption
     * liquidity or the configured reserve. A partial top-up is returned when
     * the excess cannot cover the full shortfall (the remainder is picked up
     * by later upkeeps). Returns 0 when the target is zero (action disabled)
     * or the float is already at or above the target.
     * @param _registry The protocol Registry
     * @param _controllerBalance The Controller's current ETH balance
     * @param _needsETH The pending redemption needs estimate
     * @return topUp The ETH amount to provide as exit liquidity
     */
    function _exitLiquidityTopUp(IRegistry _registry, uint256 _controllerBalance, uint256 _needsETH)
        internal
        view
        returns (uint256)
    {
        uint256 target = exitLiquidityTargetETH;
        if (target == 0) return 0;

        uint256 floatBalance = IAMM(_registry.amm()).freeBalance();
        if (floatBalance >= target) return 0;

        uint256 shortfall = target - floatBalance;
        uint256 excess = _idleExcess(_controllerBalance, _needsETH);
        return shortfall < excess ? shortfall : excess;
    }

    /**
     * @notice Estimated ETH needed to settle pending redemptions
     * @dev Sums the settlement cost of unprocessed requests in priced batches
     * (mirroring Controller._processRequest: out-of-tolerance requests cost
     * zero) plus a conservative estimate for the current unpriced batch at the
     * AMM base price (individual tolerances are unknown until pricing).
     *
     * Anchored at the QueueKeeperExecutor's live cursor peek
     * (`nextLiveBatchIdToProcess`) — which skips empty and post-commitment
     * batches the same way `checkUpkeep` does — and scans forward up to
     * `MAX_BATCH_SCAN` batches. This mirrors the queue executor's scan so the
     * *oldest live* liabilities are always covered and a dead pin cannot hide
     * newer shortfalls beyond the window. Anything beyond the window is picked
     * up by later upkeeps as the cursor advances. Each batch is additionally
     * capped at `MAX_USERS_COST_SCAN` requests.
     *
     * Reverts if the QueueKeeperExecutor is not registered on the Registry —
     * both executors are deployed and registered together via the keeper deploy
     * step, and the strategy executor's liquidity estimate is only meaningful
     * against the queue executor's authoritative cursor.
     *
     * @param _registry The protocol Registry
     * @return needsETH The estimated ETH liability
     */
    function _pendingRedemptionNeedsETH(IRegistry _registry) internal view returns (uint256 needsETH) {
        IExitQueue queue = IExitQueue(_registry.exitQueue());
        uint256 currentBatchId = queue.currentBatchId();

        // Anchor at the oldest live (non-skippable) batch — matches QueueKeeper
        // checkUpkeep so post-commitment leftovers do not pin the shortfall window.
        uint256 cursor = IQueueKeeperExecutor(_registry.queueKeeperExecutor()).nextLiveBatchIdToProcess();

        // Priced batches in the scan window, scanned forward from the cursor
        uint256 scanLimit = cursor + MAX_BATCH_SCAN;
        for (uint256 batchId = cursor; batchId < currentBatchId && batchId < scanLimit; batchId++) {
            needsETH += _batchSettlementCost(queue, batchId);
        }

        // Current (unpriced) batch, estimated at the AMM base price
        (,, uint256 totalTokensToBurn,,) = queue.batchInfo(currentBatchId);
        if (totalTokensToBurn > 0) {
            needsETH += totalTokensToBurn.convertAssets(IAMM(_registry.amm()).eveBasePriceInETH());
        }
    }

    /**
     * @notice Settlement cost of a priced batch's unprocessed requests
     * @dev Returns 0 for post-commitment batches (`pricedAt + MAX_BATCH_PROCESSING_TIME`
     * elapsed) — those users must use the ExitQueue escape hatch; reserving
     * Controller liquidity for them would pin WithdrawShortfall on dead debt.
     * @param _queue The exit queue
     * @param _batchId The priced batch
     * @return cost The ETH needed to process the batch (capped at MAX_USERS_COST_SCAN requests)
     */
    function _batchSettlementCost(IExitQueue _queue, uint256 _batchId) internal view returns (uint256 cost) {
        (bool canBeProcessed, uint256 finalEvePrice,,, uint256 pricedAt) = _queue.batchInfo(_batchId);
        if (!canBeProcessed) return 0;
        if (pricedAt > 0 && block.timestamp > pricedAt + _queue.MAX_BATCH_PROCESSING_TIME()) return 0;

        uint256 count = _queue.unprocessedUsersCount(_batchId);
        if (count == 0) return 0;

        uint256 cap = count > MAX_USERS_COST_SCAN ? MAX_USERS_COST_SCAN : count;
        address[] memory users = _queue.unprocessedUsers(_batchId, 0, cap);

        for (uint256 i = 0; i < users.length; i++) {
            (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
                _queue.requestInfo(_batchId, users[i]);

            if (!finalEvePrice.isRelativelyLessThan(evePriceAtRequestTime, priceTolerance)) {
                cost += tokensToBurn.convertAssets(finalEvePrice);
            }
        }
    }
}
