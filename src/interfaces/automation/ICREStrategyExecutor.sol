// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ICREReceiverBase} from "./ICREReceiverBase.sol";

/**
 * @title ICREStrategyExecutor
 * @notice CRE receiver for strategy keeper actions.
 * @dev Amounts are never taken from the report — recomputed at execution time.
 */
interface ICREStrategyExecutor is ICREReceiverBase {
    enum StrategyAction {
        None,
        Rebalance,
        WithdrawShortfall,
        DepositExcess,
        HarvestPerformanceFees,
        Sync,
        ProvideExitLiquidity
    }

    event ControllerReserveETHChanged(uint256 oldReserve, uint256 newReserve);
    event MinDepositETHChanged(uint256 oldMinDeposit, uint256 newMinDeposit);
    event MinWithdrawETHChanged(uint256 oldMinWithdraw, uint256 newMinWithdraw);
    event MinHarvestETHChanged(uint256 oldMinHarvest, uint256 newMinHarvest);
    event SyncIntervalChanged(uint256 oldInterval, uint256 newInterval);
    event ExitLiquidityTargetETHChanged(uint256 oldTarget, uint256 newTarget);
    event MinExitLiquidityTopUpETHChanged(uint256 oldMin, uint256 newMin);
    event StrategyUpkeepPerformed(StrategyAction indexed action, uint256 amount);

    error KeeperExecutorNoUpkeepNeeded();
    error KeeperExecutorUnknownAction();
    error KeeperExecutorInvalidConfig();

    /// @notice Gas-bounded scan of priced batches. Matches `CREQueueExecutor.MAX_BATCH_SCAN`.
    function MAX_BATCH_SCAN() external pure returns (uint256);
    function MAX_USERS_COST_SCAN() external pure returns (uint256);

    function controllerReserveETH() external view returns (uint256);
    function minDepositETH() external view returns (uint256);
    function minWithdrawETH() external view returns (uint256);
    function minHarvestETH() external view returns (uint256);
    function syncInterval() external view returns (uint256);
    function lastSyncAt() external view returns (uint256);
    function exitLiquidityTargetETH() external view returns (uint256);
    function minExitLiquidityTopUpETH() external view returns (uint256);
    function pendingRedemptionNeedsETH() external view returns (uint256 needsETH);

    /**
     * @notice Fallback / cross-check view for CRE workflows
     * @return action Recommended action
     * @return amount Estimated ETH amount for the action (0 for Rebalance/Sync)
     */
    function strategyUpkeepStatus() external view returns (StrategyAction action, uint256 amount);

    function setControllerReserveETH(uint256 _controllerReserveETH) external;
    function setMinDepositETH(uint256 _minDepositETH) external;
    function setMinWithdrawETH(uint256 _minWithdrawETH) external;
    function setMinHarvestETH(uint256 _minHarvestETH) external;
    function setSyncInterval(uint256 _syncInterval) external;
    function setExitLiquidityTargetETH(uint256 _exitLiquidityTargetETH) external;
    function setMinExitLiquidityTopUpETH(uint256 _minExitLiquidityTopUpETH) external;
}
