// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IStrategy {
    // ============ Events ============

    /**
     * @notice Emitted when funds are deposited into the strategy via the StrategyManager keeper path
     * @param amount The amount of ETH deposited
     */
    event FundsDeposited(uint256 amount);

    /**
     * @notice Emitted when idle native ETH on the strategy is invested via `investIdleETH()`
     * @param amount Idle native ETH invested at call start. Implementations may re-deploy
     *               additional liquidity (e.g. collected fees) in the same call without
     *               including it in this amount.
     */
    event FundsInvested(uint256 amount);

    /**
     * @notice Emitted when funds are withdrawn from the strategy
     * @param amount The amount of ETH withdrawn
     */
    event FundsWithdrawn(uint256 amount);

    /**
     * @notice Emitted when the strategy is rebalanced
     */
    event Rebalanced();

    /**
     * @notice Emitted when the strategy completes a sync (keeper path)
     * @dev Carries no payload; what was synced is implementation-defined.
     */
    event Synced();

    /**
     * @notice Emitted after native ETH is sent to StrategyManager by emergencyExit.
     * @param ethAmount Wei of native ETH transferred to StrategyManager in this call.
     */
    event EmergencyExited(uint256 ethAmount);

    /**
     * @notice Emitted when the strategy acknowledges a performance-fee settlement.
     * @param feeETH ETH-denominated fee amount settled via StrategyManager dilution mint
     */
    event PerformanceFeeSettled(uint256 feeETH);

    // ============ Errors ============

    /**
     * @notice Thrown when the strategy is healthy and rebalance is not needed
     */
    error StrategyIsHealthy();

    /**
     * @notice Thrown when the amount to deposit exceeds the maximum deposit amount
     */
    error StrategyMaxDepositExceeded();

    /**
     * @notice Thrown when the amount to withdraw exceeds the maximum withdrawal amount
     */
    error StrategyMaxWithdrawalExceeded();

    /**
     * @notice Thrown when the deposit amount is zero
     */
    error StrategyZeroDeposit();

    /**
     * @notice Thrown when the withdrawal amount is zero
     */
    error StrategyZeroWithdrawal();

    // ============ Functions ============

    /**
     * @notice Returns the name of the strategy
     * @return string Name of the strategy
     */
    function name() external view returns (string memory);

    /**
     * @notice Returns the version of the strategy implementation
     * @return string Version of the strategy
     */
    function version() external pure returns (string memory);

    /**
     * @notice Returns the genesis timestamp of the strategy (when the strategy was deployed)
     * @return uint256 Genesis timestamp of the strategy
     */
    function genesisTimestamp() external view returns (uint256);

    /**
     * @notice Returns the total NAV of the strategy in ETH (18 decimals).
     * @dev MUST account for ALL funds the strategy is economically responsible for.
     * @return uint256 NAV in ETH
     */
    function navInETH() external view returns (uint256);

    /**
     * @notice Returns the total amount of ETH that has been deposited into the strategy
     * from the beginning of the strategy
     * @return uint256 Total amount of ETH that has been deposited
     */
    function totalDeposited() external view returns (uint256);

    /**
     * @notice Returns the total amount of ETH that has been withdrawn from the strategy
     * from the beginning of the strategy
     * @return uint256 Total amount of ETH that has been withdrawn
     */
    function totalWithdrawn() external view returns (uint256);

    /**
     * @notice Returns true if the strategy is healthy
     * @return bool True if the strategy is healthy, false otherwise
     */
    function isHealthy() external view returns (bool);

    /**
     * @notice Returns the maximum amount of ETH that can be deposited into the strategy
     * @return uint256 Maximum amount of ETH that can be deposited
     */
    function maxDeposit() external view returns (uint256);

    /**
     * @notice Returns the amount of ETH that can be withdrawn from the strategy
     * @return uint256 Amount of ETH that can be withdrawn
     */
    function maxWithdrawal() external view returns (uint256);

    /**
     * @notice Returns true when the strategy is paused
     * @return bool True when paused, false otherwise
     */
    function paused() external view returns (bool);

    /**
     * @notice Deposits ETH from StrategyManager and deploys into the underlying protocol.
     * @dev Callable only by StrategyManager. Unsolicited ETH sent via `receive()` is not
     *      deployed through this path — it remains idle until an admin calls `investIdleETH()`.
     */
    function deposit() external payable;

    /**
     * @notice Deploys idle native ETH (e.g. donations) into the underlying protocol.
     * @dev Callable only by strategy admin. Not part of the normal keeper flow; does not affect
     *      strategy-local performance-fee accounting. The return value and `FundsInvested` report only the idle native ETH balance at
     *      call start. Implementations may re-deploy additional liquidity (e.g. collected fees)
     *      in the same call without including it in the return value or event amount.
     *      UniCLStrat reverts with `UniCLStratNotCalm` when the pool is not calm.
     * @return invested Idle native ETH invested at call start (0 when balance is zero)
     */
    function investIdleETH() external returns (uint256 invested);

    /**
     * @notice Withdraws ETH from the strategy to a receiver.
     * @dev StrategyManager path. May unwind deployed capital internally; capped at maxWithdrawal().
     *      MUST send the withdrawn ETH to `_receiver` net of any fees the strategy retains (e.g.
     *      performance fees) and return that amount. The StrategyManager does not rely on this
     *      return value for accounting — it measures the Controller's ETH balance delta across the
     *      call, mirroring the Converter's adapter accounting. Strategies are admin-registered and
     *      trusted to deliver the withdrawn ETH to `_receiver` rather than routing it elsewhere.
     * @param _receiver The address to receive the ETH
     * @param _amount The amount of ETH to withdraw
     * @return _withdrawn The amount of ETH actually sent to `_receiver` (net of strategy fees)
     */
    function withdraw(address _receiver, uint256 _amount) external returns (uint256 _withdrawn);

    /**
     * @notice Rebalances the strategy if it is unhealthy, reverts otherwise
     */
    function rebalance() external;

    /**
     * @notice Refreshes on-chain state via the keeper path.
     * @dev Callable only by StrategyManager (keeper path via Controller). What is synced is
     *      implementation-defined — e.g. accrued LP fees, accrued performance fees, cached snapshots, or other accounting
     *      that views alone cannot refresh. Implementations may no-op.
     */
    function sync() external;

    /**
     * @notice Returns the pending protocol performance fee in ETH terms for dilution settlement.
     * @dev Implementation-defined fee base (e.g. UniCLStrat accrues on LP trading fees). Returns 0
     *      when `_performanceFeeBps` is 0, the strategy is paused, or nothing is pending. Does not
     *      mutate state; internal accrual counters are preserved for post-unpause settlement.
     * @param _performanceFeeBps Global performance fee rate from StrategyManager (basis points)
     * @return feeETH Pending fee in wei of ETH (18 decimals)
     */
    function pendingPerformanceFeeInETH(uint256 _performanceFeeBps) external view returns (uint256 feeETH);

    /**
     * @notice Acknowledges performance fee settlement after StrategyManager mints EVE.
     * @dev Callable only by the registered StrategyManager. Returns 0 when `_performanceFeeBps` is 0,
     *      the strategy is paused, or nothing is pending. Marks the currently pending fee base as
     *      charged and returns the ETH-denominated fee amount used for dilution sizing.
     * @param _performanceFeeBps Global performance fee rate from StrategyManager (basis points)
     * @return feeETH Settled fee in wei of ETH (18 decimals); 0 when nothing was pending or paused
     */
    function settlePerformanceFee(uint256 _performanceFeeBps) external returns (uint256 feeETH);

    /**
     * @notice Sends strategy funds to StrategyManager during an emergency or recovery.
     * This function must be called by an account with the ADMIN_ROLE, not by StrategyManager.
     * @dev Transfers all native ETH on this contract to StrategyManager and emits EmergencyExited
     *      with that amount. Non-ETH inventory (e.g. paired tokens from UniCLStrat) may be
     *      transferred to StrategyManager as ERC-20 and priced into NAV when whitelisted via
     *      `IStrategyManager.addSupportedERC20()`. Implementations SHOULD make non-ETH transfers
     *      best-effort so a blacklisted/paused ERC-20 cannot block the native ETH sweep.
     *      May recover orphaned native ETH after removal from StrategyManager. Implementations
     *      SHOULD write off pending local performance fees in `emergencyExit()` (align charged to
     *      earned after any best-effort accrue) so later resume cannot re-harvest pre-exit pending
     *      as fresh fees.
     */
    function emergencyExit() external;
}
