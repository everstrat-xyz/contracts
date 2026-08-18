// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IController
 * @notice Interface for the Controller upgradeable contract
 * @dev Defines the core functionality for token management and access control
 */
interface IController {
    // ============ Errors ============

    /// @notice Thrown when amount is zero or invalid
    error ControllerZeroAmountRequested();

    /// @notice Thrown when the contract does not have sufficient ETH balance for the requested operation
    error ControllerInsufficientBalance();

    // ============ Events ============

    /// @notice Emitted when exit liquidity is provided to the AMM
    event ExitLiquidityProvided(uint256 amount);

    /// @notice Emitted when all the liquidity in the controller is transferred
    /// to the AMM in an emergency situation.
    event EmergencyExitedToAMM(uint256 amount);

    /// @notice Emitted when the contract is initialized
    event ControllerInitialized(address indexed registry);

    // ============ Operational Events ============

    /// @notice Emitted when a keeper batch deposit to strategies completes
    /// @param requestedAmount ETH amount requested by the keeper (`_amount` passed to the Controller)
    /// @param actualAmount ETH actually deposited into strategies; may be less than `requestedAmount`
    ///        when strategies hit `maxDeposit()` limits, or zero when no strategy qualifies
    ///        (`isHealthy() && maxDeposit() > 0`). Unused ETH is returned to the Controller by StrategyManager
    event DepositToStrategiesCompleted(uint256 requestedAmount, uint256 actualAmount);

    /// @notice Emitted when a keeper deposit to a single strategy completes
    /// @param strategy The strategy that received the deposit
    /// @param requestedAmount ETH amount requested by the keeper
    /// @param actualAmount ETH actually deposited; zero when `maxDeposit() == 0`. Unused ETH is
    ///        returned to the Controller by StrategyManager
    event DirectDepositCompleted(address indexed strategy, uint256 requestedAmount, uint256 actualAmount);

    /// @notice Emitted when funds are withdrawn from strategies
    event WithdrawalCompleted(uint256 requestedAmount, uint256 actualAmount);

    /// @notice Emitted when funds are withdrawn from a strategy
    event DirectWithdrawalCompleted(address indexed strategy, uint256 requestedAmount, uint256 actualAmount);

    /// @notice Emitted when performance fees are harvested from strategies in a range
    /// @param startIndex Start index (inclusive) of the harvested strategy range
    /// @param endIndex End index (exclusive) of the harvested strategy range
    /// @param eveAmount Total EVE minted to the DAO treasury
    /// @param feeETHEquivalent Total ETH-equivalent performance fee settled
    event PerformanceFeeHarvestCompleted(
        uint256 startIndex, uint256 endIndex, uint256 eveAmount, uint256 feeETHEquivalent
    );

    /// @notice Emitted when performance fees are harvested from a single strategy
    /// @param strategy The strategy that generated the fee
    /// @param eveAmount EVE minted to the DAO treasury
    /// @param feeETHEquivalent ETH-equivalent performance fee settled
    event DirectPerformanceFeeHarvestCompleted(address indexed strategy, uint256 eveAmount, uint256 feeETHEquivalent);

    // ============ Core Functions ============

    /// @notice Returns the version of the contract
    function version() external pure returns (string memory);

    // ============ Liquidity Provisioning ============

    /// @notice Provides exit liquidity to the AMM. Only callable by the Keeper.
    /// @param _amount The amount of ETH to provide
    function provideExitLiquidity(uint256 _amount) external;

    // ============ Strategy Management ============

    /// @notice Deposits ETH to a range of strategies proportionally by safety level
    /// @param _startIndex The start index (inclusive) of the strategies to deposit to
    /// @param _endIndex The end index (exclusive) of the strategies to deposit to
    /// @param _amount The amount of ETH to deposit
    /// @return actualDeposited ETH actually deposited; may be less than `_amount` on `maxDeposit`
    ///         caps or try/catch skips, or zero when no strategy qualifies
    /// @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
    function depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        returns (uint256 actualDeposited);

    /// @notice Deposits ETH to all strategies proportionally by safety level
    /// @param _amount The amount of ETH to deposit
    /// @return actualDeposited ETH actually deposited; may be less than `_amount` on `maxDeposit`
    ///         caps or try/catch skips, or zero when no strategy qualifies
    function depositToStrategies(uint256 _amount) external returns (uint256 actualDeposited);

    /// @notice Deposits ETH to a specific strategy
    /// @param _strategy The address of the strategy to deposit to
    /// @param _amount The amount of ETH to deposit
    /// @return actualDeposited ETH actually deposited; zero when `maxDeposit() == 0`
    function depositToStrategy(address _strategy, uint256 _amount) external returns (uint256 actualDeposited);

    /// @notice Withdraws ETH from a range of strategies proportionally by withdrawal priority
    /// to the controller
    /// @param _startIndex The start index (inclusive) of the strategies to withdraw from
    /// @param _endIndex The end index (exclusive) of the strategies to withdraw from
    /// @param _amount The amount of ETH to withdraw
    /// @return actualWithdrawn ETH actually withdrawn; may be less than `_amount` on try/catch
    ///         skips or when no strategy has `maxWithdrawal() > 0`
    /// @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
    function withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        returns (uint256 actualWithdrawn);

    /// @notice Withdraws ETH from all strategies proportionally by withdrawal priority
    /// to the controller
    /// @param _amount The amount of ETH to withdraw
    /// @return actualWithdrawn ETH actually withdrawn; may be less than `_amount` on try/catch
    ///         skips or when no strategy has `maxWithdrawal() > 0`
    function withdrawFromStrategies(uint256 _amount) external returns (uint256 actualWithdrawn);

    /// @notice Withdraws ETH from a specific strategy to the controller
    /// @param _strategy The address of the strategy to withdraw from
    /// @param _amount The amount of ETH to withdraw
    /// @return actualWithdrawn ETH actually withdrawn
    function withdrawFromStrategy(address _strategy, uint256 _amount) external returns (uint256 actualWithdrawn);

    /// @notice Checks and rebalances a range of strategies
    /// @param _startIndex The start index (inclusive) of the strategies to check and rebalance
    /// @param _endIndex The end index (exclusive) of the strategies to check and rebalance
    /// @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
    function checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex) external;

    /// @notice Checks and rebalances all unhealthy strategies
    function checkAndRebalanceStrategies() external;

    /// @notice Checks and rebalances a specific strategy if it is unhealthy
    /// @param _strategy The address of the strategy to rebalance
    function checkAndRebalanceStrategy(address _strategy) external;

    /// @notice Syncs a range of strategies
    /// @param _startIndex The start index (inclusive) of the strategies to sync
    /// @param _endIndex The end index (exclusive) of the strategies to sync
    /// @dev Range is [startIndex, endIndex). Keeper entry point; delegates to each strategy's `sync()`.
    ///      What is synced is implementation-defined.
    function syncStrategies(uint256 _startIndex, uint256 _endIndex) external;

    /// @notice Syncs all registered strategies
    /// @dev Keeper entry point; delegates to each strategy's `sync()`.
    function syncStrategies() external;

    /// @notice Syncs a specific strategy
    /// @param _strategy The address of the strategy to sync
    /// @dev Keeper entry point; delegates to `IStrategy.sync()`.
    function syncStrategy(address _strategy) external;

    /// @notice Harvests performance fees for a single strategy via StrategyManager
    /// @dev Callable by `ADMIN_ROLE` or `KEEPER_ROLE` on Registry. Emits `DirectPerformanceFeeHarvestCompleted`.
    /// @param _strategy The address of the strategy to harvest fees for
    /// @return eveAmount EVE minted to the DAO treasury
    /// @return feeETHEquivalent ETH-equivalent performance fee settled
    function harvestPerformanceFeeFromStrategy(address _strategy)
        external
        returns (uint256 eveAmount, uint256 feeETHEquivalent);

    /// @notice Harvests performance fees for all registered strategies via StrategyManager
    /// @dev Callable by `ADMIN_ROLE` or `KEEPER_ROLE` on Registry. Emits `PerformanceFeeHarvestCompleted`.
    /// @return eveAmount Total EVE minted to the DAO treasury
    /// @return feeETHEquivalent Total ETH-equivalent performance fee settled
    function harvestPerformanceFeeFromStrategies() external returns (uint256 eveAmount, uint256 feeETHEquivalent);

    /// @notice Harvests performance fees for a range of registered strategies via StrategyManager
    /// @dev Callable by `ADMIN_ROLE` or `KEEPER_ROLE` on Registry. Emits `PerformanceFeeHarvestCompleted`.
    /// @param _startIndex The start index (inclusive) of the strategies to harvest
    /// @param _endIndex The end index (exclusive) of the strategies to harvest
    /// @return eveAmount Total EVE minted to the DAO treasury
    /// @return feeETHEquivalent Total ETH-equivalent performance fee settled
    function harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        returns (uint256 eveAmount, uint256 feeETHEquivalent);

    /// @notice Prices the current ExitQueue batch at the live AMM base price.
    /// @dev Reads `eveBasePriceInETH()` before marking this batch priced, so the
    ///      batch being settled is still equity. Already-priced in-window batches
    ///      are already deducted from NAV and live supply.
    function priceBatch() external;

    /// @notice Processes redemption requests from a batch in the given range
    /// @param _batchId The ID of the batch
    /// @param _startIndex The start index (inclusive) of the users to process
    /// @param _endIndex The end index (exclusive) of the users to process
    /// @dev Range is [startIndex, endIndex), meaning users from startIndex up to but not including endIndex
    function processRequests(uint256 _batchId, uint256 _startIndex, uint256 _endIndex) external;

    /// @notice Processes all remaining redemption requests from a batch
    /// @param _batchId The ID of the batch
    function processRequests(uint256 _batchId) external;

    /// @notice Processes a specific redemption request
    /// @param _batchId The ID of the batch
    /// @param _user The address of the user to process
    function processRequest(uint256 _batchId, address _user) external;

    // ============ Emergency Functions ============

    /// @notice Pauses the contract
    function pause() external;

    /// @notice Unpauses the contract
    function unpause() external;

    /// @notice Transfers all the liquidity in the controller to the AMM in an emergency situation.
    /// Only callable by the ADMIN_ROLE.
    function emergencyExitToAMM() external;
}
