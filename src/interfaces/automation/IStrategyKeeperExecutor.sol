// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IKeeperExecutorBase} from "./IKeeperExecutorBase.sol";

/**
 * @title IStrategyKeeperExecutor
 * @notice Interface for the Chainlink Automation executor that drives strategy
 * operations: rebalancing unhealthy strategies, withdrawing redemption liquidity,
 * funding the AMM immediate-exit float, depositing idle Controller ETH, and
 * periodic strategy syncs.
 */
interface IStrategyKeeperExecutor is IKeeperExecutorBase {
    // ============ Types ============

    /**
     * @notice Action encoded in performData by `checkUpkeep` and validated
     * against current state in `performUpkeep`.
     * @dev New actions are appended to keep existing ordinals stable for
     * off-chain performData encoding. The evaluation priority order is:
     * Rebalance, WithdrawShortfall, ProvideExitLiquidity, DepositExcess,
     * HarvestPerformanceFees, Sync.
     */
    enum StrategyAction {
        None,
        Rebalance,
        WithdrawShortfall,
        DepositExcess,
        HarvestPerformanceFees,
        Sync,
        ProvideExitLiquidity
    }

    // ============ Events ============

    /**
     * @notice Emitted when the Controller ETH reserve target is changed
     * @param oldReserve The previous reserve in wei
     * @param newReserve The new reserve in wei
     */
    event ControllerReserveETHChanged(uint256 oldReserve, uint256 newReserve);

    /**
     * @notice Emitted when the minimum deposit trigger is changed
     * @param oldMinDeposit The previous minimum in wei
     * @param newMinDeposit The new minimum in wei
     */
    event MinDepositETHChanged(uint256 oldMinDeposit, uint256 newMinDeposit);

    /**
     * @notice Emitted when the minimum withdrawal-shortfall trigger is changed
     * @param oldMinWithdraw The previous minimum in wei
     * @param newMinWithdraw The new minimum in wei
     */
    event MinWithdrawETHChanged(uint256 oldMinWithdraw, uint256 newMinWithdraw);

    /**
     * @notice Emitted when the minimum accrued performance-fee trigger is changed
     * @param oldMinHarvest The previous minimum in wei
     * @param newMinHarvest The new minimum in wei
     */
    event MinHarvestETHChanged(uint256 oldMinHarvest, uint256 newMinHarvest);

    /**
     * @notice Emitted when the sync interval is changed
     * @param oldInterval The previous interval in seconds
     * @param newInterval The new interval in seconds
     */
    event SyncIntervalChanged(uint256 oldInterval, uint256 newInterval);

    /**
     * @notice Emitted when the AMM immediate-exit float target is changed
     * @param oldTarget The previous target in wei
     * @param newTarget The new target in wei
     */
    event ExitLiquidityTargetETHChanged(uint256 oldTarget, uint256 newTarget);

    /**
     * @notice Emitted when the minimum exit-liquidity top-up trigger is changed
     * @param oldMin The previous minimum in wei
     * @param newMin The new minimum in wei
     */
    event MinExitLiquidityTopUpETHChanged(uint256 oldMin, uint256 newMin);

    /**
     * @notice Emitted when an upkeep was performed
     * @param action The strategy action performed
     * @param amount ETH amount for the action: shortfall withdrawn / excess
     * deposited / exit liquidity provided to the AMM float, or the view-estimated
     * pending performance fee in ETH. Zero for Rebalance and Sync.
     */
    event StrategyUpkeepPerformed(StrategyAction indexed action, uint256 amount);

    // ============ Constants ============

    /**
     * @notice Number of most recent batches scanned when estimating pending
     * redemption liquidity needs
     */
    function MAX_BATCH_SCAN() external pure returns (uint256);

    /**
     * @notice Per-batch cap on unprocessed requests included in the pending
     * redemption needs estimate
     */
    function MAX_USERS_COST_SCAN() external pure returns (uint256);

    // ============ View Functions ============

    /**
     * @notice ETH the executor keeps idle on the Controller (not deposited to
     * strategies) as a buffer for redemptions
     */
    function controllerReserveETH() external view returns (uint256);

    /**
     * @notice Minimum idle excess (above reserve and pending redemption needs)
     * before a deposit upkeep triggers
     */
    function minDepositETH() external view returns (uint256);

    /**
     * @notice Minimum redemption liquidity shortfall before a withdrawal upkeep triggers
     */
    function minWithdrawETH() external view returns (uint256);

    /**
     * @notice Minimum accrued performance fee (ETH) before a harvest upkeep
     * triggers. Filters dust fees that would waste Automation gas.
     */
    function minHarvestETH() external view returns (uint256);

    /**
     * @notice Interval between automated strategy syncs; zero disables sync automation
     */
    function syncInterval() external view returns (uint256);

    /**
     * @notice Timestamp of the last automated sync
     */
    function lastSyncAt() external view returns (uint256);

    /**
     * @notice Target AMM free balance (immediate-exit float) the executor tops
     * up from idle Controller ETH. Defaults to 0 (ProvideExitLiquidity disabled),
     * matching `controllerReserveETH` as an admin-set policy knob; zero disables
     * the action.
     */
    function exitLiquidityTargetETH() external view returns (uint256);

    /**
     * @notice Minimum exit-liquidity top-up before a ProvideExitLiquidity
     * upkeep triggers. Filters dust top-ups that would waste Automation gas.
     */
    function minExitLiquidityTopUpETH() external view returns (uint256);

    /**
     * @notice Estimated ETH needed to settle pending redemptions: the cost of
     * unprocessed requests in recently priced batches plus an estimate for the
     * current (unpriced) batch at the AMM base price.
     * @dev Bounded by `MAX_BATCH_SCAN` batches and `MAX_USERS_COST_SCAN` requests
     * per batch; requests outside the scan window are picked up by later upkeeps.
     * @return needsETH The estimated ETH liability
     */
    function pendingRedemptionNeedsETH() external view returns (uint256 needsETH);

    // ============ Admin Functions ============

    /**
     * @notice Sets the Controller ETH reserve target
     * @param _controllerReserveETH The new reserve in wei
     */
    function setControllerReserveETH(uint256 _controllerReserveETH) external;

    /**
     * @notice Sets the minimum deposit trigger
     * @param _minDepositETH The new minimum in wei (must be non-zero)
     */
    function setMinDepositETH(uint256 _minDepositETH) external;

    /**
     * @notice Sets the minimum withdrawal-shortfall trigger
     * @param _minWithdrawETH The new minimum in wei
     */
    function setMinWithdrawETH(uint256 _minWithdrawETH) external;

    /**
     * @notice Sets the minimum accrued performance-fee trigger
     * @param _minHarvestETH The new minimum in wei (must be non-zero)
     */
    function setMinHarvestETH(uint256 _minHarvestETH) external;

    /**
     * @notice Sets the sync interval; zero disables sync automation
     * @param _syncInterval The new interval in seconds
     */
    function setSyncInterval(uint256 _syncInterval) external;

    /**
     * @notice Sets the AMM immediate-exit float target; zero disables the
     * ProvideExitLiquidity action (also the deploy default)
     * @param _exitLiquidityTargetETH The new target in wei
     */
    function setExitLiquidityTargetETH(uint256 _exitLiquidityTargetETH) external;

    /**
     * @notice Sets the minimum exit-liquidity top-up trigger
     * @param _minExitLiquidityTopUpETH The new minimum in wei (must be non-zero)
     */
    function setMinExitLiquidityTopUpETH(uint256 _minExitLiquidityTopUpETH) external;
}
