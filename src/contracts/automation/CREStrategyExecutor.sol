// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Math} from "../../libraries/Math.sol";
import {Auth} from "../../libraries/Auth.sol";
import {ExitQueueLimits} from "../../libraries/ExitQueueLimits.sol";

import {IRegistry} from "interfaces/IRegistry.sol";
import {IAMM} from "../../interfaces/IAMM.sol";
import {IController} from "../../interfaces/IController.sol";
import {IExitQueue} from "../../interfaces/IExitQueue.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {IStrategyManager} from "../../interfaces/IStrategyManager.sol";
import {ICREQueueExecutor} from "../../interfaces/automation/ICREQueueExecutor.sol";
import {ICREStrategyExecutor} from "../../interfaces/automation/ICREStrategyExecutor.sol";

import {CREReceiverBase} from "./CREReceiverBase.sol";

/**
 * @title CREStrategyExecutor
 * @notice CRE / Keystone receiver for strategy keeper actions.
 *
 * Priority order (unchanged from CLA): Rebalance → WithdrawShortfall →
 * ProvideExitLiquidity → DepositExcess → HarvestPerformanceFees → Sync.
 *
 * Report params are ignored for amounts — every ETH quantity is recomputed
 * from live Controller / StrategyManager / ExitQueue / AMM state.
 *
 * Couples to the registered queue keeper via Registry `QUEUE_KEEPER_EXECUTOR`
 * and `nextLiveBatchIdToProcess()`.
 */
contract CREStrategyExecutor is ICREStrategyExecutor, CREReceiverBase {
    using Math for uint256;
    using Auth for IRegistry;

    /// @dev Gas-bounded scan of priced batches. Bound to `ExitQueueLimits.MAX_LIVE_PRICED_BATCHES`
    ///      (same cap as `ExitQueue.MAX_LIVE_PRICED_BATCHES`) so a change cannot silently
    ///      desync the keeper. A DoS bound, not cadence — CRE `minBatchAge` vs
    ///      `MAX_BATCH_PROCESSING_TIME` implies ~3 overlapping batches.
    uint256 public constant MAX_BATCH_SCAN = ExitQueueLimits.MAX_LIVE_PRICED_BATCHES;
    uint256 public constant MAX_USERS_COST_SCAN = 50;

    uint256 private constant _DEFAULT_MIN_DEPOSIT_ETH = 0.1 ether;
    uint256 private constant _DEFAULT_MIN_WITHDRAW_ETH = 0.01 ether;
    uint256 private constant _DEFAULT_MIN_HARVEST_ETH = 0.01 ether;
    uint256 private constant _DEFAULT_SYNC_INTERVAL = 1 days;
    uint256 private constant _DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH = 0.01 ether;

    uint256 public controllerReserveETH;
    uint256 public minDepositETH;
    uint256 public minWithdrawETH;
    uint256 public minHarvestETH;
    uint256 public syncInterval;
    uint256 public lastSyncAt;
    uint256 public exitLiquidityTargetETH;
    uint256 public minExitLiquidityTopUpETH;

    constructor(address registry_, address forwarder_, uint64 chainSelector_, uint64 maxReportAge_)
        CREReceiverBase(registry_, forwarder_, chainSelector_, maxReportAge_)
    {
        minDepositETH = _DEFAULT_MIN_DEPOSIT_ETH;
        minWithdrawETH = _DEFAULT_MIN_WITHDRAW_ETH;
        minHarvestETH = _DEFAULT_MIN_HARVEST_ETH;
        syncInterval = _DEFAULT_SYNC_INTERVAL;
        minExitLiquidityTopUpETH = _DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH;
        lastSyncAt = block.timestamp;
    }

    // ============ Admin ============

    function setControllerReserveETH(uint256 _controllerReserveETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ControllerReserveETHChanged(controllerReserveETH, _controllerReserveETH);
        controllerReserveETH = _controllerReserveETH;
    }

    function setMinDepositETH(uint256 _minDepositETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minDepositETH == 0) revert KeeperExecutorInvalidConfig();
        emit MinDepositETHChanged(minDepositETH, _minDepositETH);
        minDepositETH = _minDepositETH;
    }

    function setMinWithdrawETH(uint256 _minWithdrawETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit MinWithdrawETHChanged(minWithdrawETH, _minWithdrawETH);
        minWithdrawETH = _minWithdrawETH;
    }

    function setMinHarvestETH(uint256 _minHarvestETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minHarvestETH == 0) revert KeeperExecutorInvalidConfig();
        emit MinHarvestETHChanged(minHarvestETH, _minHarvestETH);
        minHarvestETH = _minHarvestETH;
    }

    function setSyncInterval(uint256 _syncInterval) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit SyncIntervalChanged(syncInterval, _syncInterval);
        syncInterval = _syncInterval;
    }

    function setExitLiquidityTargetETH(uint256 _exitLiquidityTargetETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExitLiquidityTargetETHChanged(exitLiquidityTargetETH, _exitLiquidityTargetETH);
        exitLiquidityTargetETH = _exitLiquidityTargetETH;
    }

    function setMinExitLiquidityTopUpETH(uint256 _minExitLiquidityTopUpETH) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_minExitLiquidityTopUpETH == 0) revert KeeperExecutorInvalidConfig();
        emit MinExitLiquidityTopUpETHChanged(minExitLiquidityTopUpETH, _minExitLiquidityTopUpETH);
        minExitLiquidityTopUpETH = _minExitLiquidityTopUpETH;
    }

    // ============ Views ============

    function strategyUpkeepStatus() external view returns (StrategyAction action, uint256 amount) {
        if (paused()) return (StrategyAction.None, 0);

        IRegistry registry_ = registry();
        address controller = registry_.controller();
        address strategyManager = registry_.strategyManager();

        if (Pausable(controller).paused() || Pausable(strategyManager).paused()) {
            return (StrategyAction.None, 0);
        }

        IStrategyManager strategyManager_ = IStrategyManager(strategyManager);

        if (_rebalanceNeeded(strategyManager_)) {
            return (StrategyAction.Rebalance, 0);
        }

        uint256 needsETH = _pendingRedemptionNeedsETH(registry_);
        uint256 controllerBalance = controller.balance;
        if (
            needsETH > controllerBalance && needsETH - controllerBalance >= minWithdrawETH
                && _totalMaxWithdrawal(strategyManager_) > 0
        ) {
            return (StrategyAction.WithdrawShortfall, needsETH - controllerBalance);
        }

        uint256 topUp = _exitLiquidityTopUp(registry_, controllerBalance, needsETH);
        if (topUp >= minExitLiquidityTopUpETH) {
            return (StrategyAction.ProvideExitLiquidity, topUp);
        }

        uint256 excess = _idleExcess(controllerBalance, needsETH);
        if (excess >= minDepositETH && _depositCapacityAvailable(strategyManager_)) {
            return (StrategyAction.DepositExcess, excess);
        }

        uint256 feeETH = _pendingPerformanceFeeETH(strategyManager_);
        if (feeETH >= minHarvestETH) {
            return (StrategyAction.HarvestPerformanceFees, feeETH);
        }

        if (syncInterval != 0 && block.timestamp - lastSyncAt >= syncInterval && strategyManager_.strategyCount() > 0) {
            return (StrategyAction.Sync, 0);
        }

        return (StrategyAction.None, 0);
    }

    function pendingRedemptionNeedsETH() external view returns (uint256 needsETH) {
        return _pendingRedemptionNeedsETH(registry());
    }

    function version() external pure returns (string memory) {
        return "1.0.0-cre";
    }

    // ============ CRE processing ============

    function _processReport(uint8 action, bytes memory /* params */ ) internal override {
        StrategyAction strategyAction = StrategyAction(action);

        IRegistry registry_ = registry();
        IController controller = IController(registry_.controller());
        IStrategyManager strategyManager_ = IStrategyManager(registry_.strategyManager());

        if (strategyAction == StrategyAction.Rebalance) {
            if (!_rebalanceNeeded(strategyManager_)) revert KeeperExecutorNoUpkeepNeeded();
            controller.checkAndRebalanceStrategies();
            emit StrategyUpkeepPerformed(strategyAction, 0);
        } else if (strategyAction == StrategyAction.WithdrawShortfall) {
            uint256 needsETH = _pendingRedemptionNeedsETH(registry_);
            uint256 controllerBalance = address(controller).balance;
            if (needsETH <= controllerBalance || needsETH - controllerBalance < minWithdrawETH) {
                revert KeeperExecutorNoUpkeepNeeded();
            }
            uint256 shortfall = needsETH - controllerBalance;
            controller.withdrawFromStrategies(shortfall);
            emit StrategyUpkeepPerformed(strategyAction, shortfall);
        } else if (strategyAction == StrategyAction.ProvideExitLiquidity) {
            uint256 topUp =
                _exitLiquidityTopUp(registry_, address(controller).balance, _pendingRedemptionNeedsETH(registry_));
            if (topUp < minExitLiquidityTopUpETH) revert KeeperExecutorNoUpkeepNeeded();
            controller.provideExitLiquidity(topUp);
            emit StrategyUpkeepPerformed(strategyAction, topUp);
        } else if (strategyAction == StrategyAction.DepositExcess) {
            uint256 excess = _idleExcess(address(controller).balance, _pendingRedemptionNeedsETH(registry_));
            if (excess < minDepositETH || !_depositCapacityAvailable(strategyManager_)) {
                revert KeeperExecutorNoUpkeepNeeded();
            }
            controller.depositToStrategies(excess);
            emit StrategyUpkeepPerformed(strategyAction, excess);
        } else if (strategyAction == StrategyAction.HarvestPerformanceFees) {
            uint256 feeETH = _pendingPerformanceFeeETH(strategyManager_);
            if (feeETH < minHarvestETH) revert KeeperExecutorNoUpkeepNeeded();
            controller.harvestPerformanceFeeFromStrategies();
            emit StrategyUpkeepPerformed(strategyAction, feeETH);
        } else if (strategyAction == StrategyAction.Sync) {
            if (syncInterval == 0 || block.timestamp - lastSyncAt < syncInterval) {
                revert KeeperExecutorNoUpkeepNeeded();
            }
            lastSyncAt = block.timestamp;
            controller.syncStrategies();
            emit StrategyUpkeepPerformed(strategyAction, 0);
        } else {
            revert KeeperExecutorUnknownAction();
        }
    }
    // ============ Internal ============

    function _rebalanceNeeded(IStrategyManager _strategyManager) internal view returns (bool) {
        address[] memory strategies = _strategyManager.strategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            IStrategy strategy = IStrategy(strategies[i]);
            if (!strategy.paused() && !strategy.isHealthy()) return true;
        }
        return false;
    }

    function _totalMaxWithdrawal(IStrategyManager _strategyManager) internal view returns (uint256 total) {
        address[] memory strategies = _strategyManager.strategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            total += IStrategy(strategies[i]).maxWithdrawal();
        }
    }

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

    function _pendingPerformanceFeeETH(IStrategyManager _strategyManager) internal view returns (uint256 totalFeeETH) {
        if (_strategyManager.performanceFeeBps() == 0) return 0;

        address[] memory strategies = _strategyManager.strategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            totalFeeETH += _strategyManager.pendingPerformanceFeeInETH(strategies[i]);
        }
    }

    function _idleExcess(uint256 _controllerBalance, uint256 _needsETH) internal view returns (uint256) {
        uint256 reserved = controllerReserveETH + _needsETH;
        return _controllerBalance > reserved ? _controllerBalance - reserved : 0;
    }

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

    function _pendingRedemptionNeedsETH(IRegistry _registry) internal view returns (uint256 needsETH) {
        IExitQueue queue = IExitQueue(_registry.exitQueue());
        uint256 currentBatchId = queue.currentBatchId();

        uint256 cursor = ICREQueueExecutor(_registry.queueKeeperExecutor()).nextLiveBatchIdToProcess();

        uint256 scanLimit = cursor + MAX_BATCH_SCAN;
        for (uint256 batchId = cursor; batchId < currentBatchId && batchId < scanLimit; batchId++) {
            needsETH += _batchSettlementCost(queue, batchId);
        }

        (,, uint256 totalTokensToBurn,,) = queue.batchInfo(currentBatchId);
        if (totalTokensToBurn > 0) {
            // Current (unpriced) batch is still cancellable equity. Size residual need
            // at the live base price, which is already net of in-window priced liability.
            needsETH += totalTokensToBurn.convertAssets(IAMM(_registry.amm()).eveBasePriceInETH());
        }
    }

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
