// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IStrategyManager
 * @notice Interface for the Strategy Manager contract
 * @dev This manager handles strategy registration and NAV calculations, designed to be upgradable while keeping the AMM math stable
 */
interface IStrategyManager {
    // ============ Structs ============

    /// @notice Performance fee configuration set at initialization and updatable by admin.
    struct FeeConfig {
        address daoTreasury;
        uint256 performanceFeeBps;
    }

    // ============ Errors ============
    /// @notice Thrown when strategy is already registered
    error StrategyManagerStrategyAlreadyRegistered();

    /// @notice Thrown when strategy is not registered
    error StrategyManagerStrategyNotRegistered();

    /// @notice Thrown when NAV value is invalid
    error StrategyManagerInvalidNAVValue();

    /// @notice Thrown when strategy address is invalid
    error StrategyManagerZeroAddress();

    /// @notice Thrown when a contract-address argument has no code — e.g. a strategy passed to
    ///         addStrategy(). Note: checks for the absence of code, not for
    ///         "not a contract" — an EIP-7702 EOA with a delegation does have code and passes this
    ///         check. Correct wiring is verified in the deployment script.
    error StrategyManagerNoCode();

    /// @notice Thrown when a strategy has more than the allowed NAV residue during removal
    error StrategyManagerStrategyNAVResidueTooHigh(address strategy);

    /// @notice Thrown when no strategies are registered
    error StrategyManagerNoStrategiesRegistered();

    /// @notice Thrown when a range of strategies is invalid
    error StrategyManagerInvalidRange();

    /// @notice Thrown when a deposit weight exceeds MAX_DEPOSIT_WEIGHT
    error StrategyManagerInvalidDepositWeight(address strategy);

    /// @notice Thrown when a withdrawal weight exceeds MAX_WITHDRAWAL_WEIGHT
    error StrategyManagerInvalidWithdrawalWeight(address strategy);

    /// @notice Thrown when parallel calldata arrays have mismatched lengths
    error StrategyManagerInvalidLength();

    /// @notice Thrown when there is no idle ETH balance to sweep to the Controller
    error StrategyManagerNoBalanceToRecover();

    /// @notice Thrown when a token is already on the supported-ERC-20 whitelist
    error StrategyManagerERC20AlreadySupported(address token);

    /// @notice Thrown when a token is not on the supported-ERC-20 whitelist
    error StrategyManagerERC20NotSupported(address token);

    /// @notice Thrown when a token cannot be priced by the protocol Oracle (no registered feed),
    ///         so whitelisting it would freeze NAV as soon as a non-zero balance appears
    error StrategyManagerERC20NotPriceable(address token);

    /// @notice Thrown when the DAO treasury address is zero
    error StrategyManagerZeroDaoTreasury();

    /// @notice Thrown when total NAV cannot cover the fee (degenerate case)
    error StrategyManagerFeeMintOverflow();

    /// @notice Thrown when in-window priced redemption liability exceeds gross NAV
    error StrategyManagerQueuedLiabilityExceedsNAV();

    /// @notice Thrown when in-window escrowed EVE exceeds `totalSupply`
    error StrategyManagerEscrowExceedsSupply();

    /// @notice Thrown when performance fee bps exceeds MAX_PERFORMANCE_FEE_BPS
    error StrategyManagerInvalidPerformanceFeeBps();

    /// @notice Thrown when depositing to a strategy that is still cooling down after a withdrawal
    error StrategyManagerStrategyInDepositCooldown(address strategy);

    /// @notice Thrown when a strategy deposit cooldown exceeds MAX_STRATEGY_DEPOSIT_COOLDOWN
    error StrategyManagerInvalidStrategyDepositCooldown();

    // ============ Events ============
    /**
     * @notice Emitted when a new strategy is added
     * @param strategy The address of the strategy
     */
    event StrategyAdded(address indexed strategy);

    /**
     * @notice Emitted when a strategy's deposit weight is updated
     * @param strategy The strategy address
     * @param oldWeight Previous deposit weight (0 on first set)
     * @param newWeight New deposit weight (0 = no share of batch deposits)
     */
    event DepositWeightUpdated(address indexed strategy, uint8 oldWeight, uint8 newWeight);

    /**
     * @notice Emitted when a strategy's withdrawal weight is updated
     * @param strategy The strategy address
     * @param oldWeight Previous withdrawal weight (0 on first set)
     * @param newWeight New withdrawal weight (0 = no share of batch withdrawals)
     */
    event WithdrawalWeightUpdated(address indexed strategy, uint8 oldWeight, uint8 newWeight);

    /**
     * @notice Emitted when a strategy is cleanly removed from the registry.
     * @param strategy The address of the removed strategy.
     * @dev Emitted only after a successful `navInETH()` read at or below `MAX_NAV_RESIDUE`.
     *      Broken strategies (reverting or over-reporting NAV) must use `forceRemoveStrategy()`.
     */
    event StrategyRemoved(address indexed strategy);

    /**
     * @notice Emitted when a strategy is force-removed from the registry without a NAV residue check.
     * @param strategy The address of the force-removed strategy.
     * @param reportedNAV The NAV in ETH reported by `navInETH()` at removal time; zero when
     *        `navInETH()` reverted.
     * @param navReverted True if navInETH() reverted, false if it returned `reportedNAV`.
     */
    event StrategyForceRemoved(address indexed strategy, uint256 reportedNAV, bool navReverted);

    /**
     * @notice Emitted when funds are deposited to a strategy
     * @param strategy The address of the strategy
     * @param amount The amount of ETH deposited
     */
    event FundsDepositedToStrategy(address indexed strategy, uint256 amount);

    /**
     * @notice Emitted when funds are withdrawn from a strategy
     * @param strategy The address of the strategy
     * @param amount The amount of ETH withdrawn
     */
    event FundsWithdrawnFromStrategy(address indexed strategy, uint256 amount);

    /**
     * @notice Emitted when a strategy is rebalanced
     * @param strategy The address of the strategy that was rebalanced
     */
    event StrategyRebalanced(address indexed strategy);

    /**
     * @notice Emitted when a strategy is synced
     * @param strategy The address of the strategy that was synced
     * @dev Indicates `IStrategy.sync()` completed; what was synced is implementation-defined.
     */
    event StrategySynced(address indexed strategy);

    /**
     * @notice Emitted when a batch deposit attempt for a strategy reverts
     * @param strategy The address of the strategy whose `deposit()` call failed
     * @param reason The revert data returned by the failed `deposit()` call
     */
    event StrategyDepositFailed(address indexed strategy, bytes reason);

    /**
     * @notice Emitted when a batch withdrawal attempt for a strategy reverts
     * @param strategy The address of the strategy whose `withdraw()` call failed
     * @param reason The revert data returned by the failed `withdraw()` call
     */
    event StrategyWithdrawFailed(address indexed strategy, bytes reason);

    /**
     * @notice Emitted when a batch rebalance attempt for a strategy reverts
     * @param strategy The address of the strategy whose `rebalance()` call failed
     * @param reason The revert data returned by the failed `rebalance()` call
     */
    event StrategyRebalanceFailed(address indexed strategy, bytes reason);

    /**
     * @notice Emitted when a batch harvest attempt for a strategy reverts
     * @param strategy The address of the strategy whose `settlePerformanceFee()` call failed
     * @param reason The revert data returned by the failed `settlePerformanceFee()` call
     */
    event StrategyHarvestFailed(address indexed strategy, bytes reason);

    /**
     * @notice Emitted when a batch sync attempt for a strategy reverts
     * @param strategy The address of the strategy whose `sync()` call failed
     * @param reason The revert data returned by the failed `sync()` call
     */
    event StrategySyncFailed(address indexed strategy, bytes reason);

    /**
     * @notice Emitted when revoking CONVERTER_CALLER_ROLE from a removed strategy fails on the Converter.
     * @param strategy The address of the strategy whose CONVERTER_CALLER_ROLE could not be revoked
     */
    event CallerRoleRevokeFailed(address indexed strategy);

    /**
     * @notice Emitted when idle StrategyManager ETH is swept back to the Controller.
     * @param amount The amount of native ETH transferred to the Controller
     */
    event EmergencyWithdrawnToController(uint256 amount);

    /**
     * @notice Emitted when a token is added to the supported-ERC-20 whitelist.
     * @param token The ERC-20 token the StrategyManager may now hold (priced into NAV)
     */
    event SupportedERC20Added(address indexed token);

    /**
     * @notice Emitted when a token is removed from the supported-ERC-20 whitelist.
     * @param token The ERC-20 token that is no longer priced into NAV
     */
    event SupportedERC20Removed(address indexed token);

    /**
     * @notice Emitted when performance fees are harvested and EVE is minted to the treasury.
     * @param strategy The strategy that generated the fee
     * @param treasury The address that received the EVE tokens
     * @param eveAmount The amount of EVE tokens minted
     * @param feeETHEquivalent Performance fee settled for this strategy, in wei of ETH (18 decimals).
     *        Strategy-reported fee base (e.g. LP fees) used as the bonding-curve mint input —
     *        no ETH is withdrawn from the strategy.
     */
    event PerformanceFeePaid(
        address indexed strategy, address indexed treasury, uint256 eveAmount, uint256 feeETHEquivalent
    );

    /**
     * @notice Emitted when the per-strategy deposit cooldown is updated.
     * @param oldCooldown The previous cooldown duration in seconds
     * @param newCooldown The new cooldown duration in seconds (0 disables the cooldown)
     */
    event StrategyDepositCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    /**
     * @notice The performance fee rate has been changed from `initial` to `current` basis points.
     * @dev Emitted by `initialize()` (`initial` is zero) and by `setPerformanceFeeBps()`
     * (`initial` is the prior stored value). A `current` of zero disables fee harvesting.
     */
    event PerformanceFeeBpsChanged(uint256 initial, uint256 current);

    /**
     * @notice The DAO treasury receiving performance fees has been changed from `initial` to `current`.
     * @dev Emitted by `initialize()` (`initial` is the zero address) and by `setDaoTreasury()`
     * (`initial` is the prior stored value).
     */
    event DaoTreasuryChanged(address initial, address current);

    // ============ Functions ============

    /**
     * @notice Returns the version of the contract
     * @return string The version number
     */
    function version() external pure returns (string memory);

    /**
     * @notice Add a new strategy to the NAV calculation with allocation weights
     * @dev Weights are proportional (not percentages that must sum to 100). A weight of 0
     *      registers the strategy for NAV but excludes it from batch deposit/withdrawal
     *      allocation until updated. Weights are owned by StrategyManager — strategies cannot
     *      self-report allocation share.
     * @param _strategy The strategy address
     * @param _depositWeight Proportional weight for batch deposits (0–MAX_DEPOSIT_WEIGHT)
     * @param _withdrawalWeight Proportional weight for batch withdrawals (0–MAX_WITHDRAWAL_WEIGHT)
     */
    function addStrategy(address _strategy, uint8 _depositWeight, uint8 _withdrawalWeight) external;

    /**
     * @notice Set deposit and withdrawal weights for many strategies in one call
     * @dev Prefer this over individual setters when rebalancing across multiple strategies
     *      (one timelock op). Arrays must be the same length; every address must be registered.
     * @param _strategies Strategy addresses to update
     * @param _depositWeights New deposit weights (parallel to `_strategies`)
     * @param _withdrawalWeights New withdrawal weights (parallel to `_strategies`)
     */
    function setStrategyWeights(
        address[] calldata _strategies,
        uint8[] calldata _depositWeights,
        uint8[] calldata _withdrawalWeights
    ) external;

    /**
     * @notice Set the deposit weight for a registered strategy
     * @param _strategy The strategy address
     * @param _depositWeight Proportional weight for batch deposits (0–MAX_DEPOSIT_WEIGHT)
     */
    function setDepositWeight(address _strategy, uint8 _depositWeight) external;

    /**
     * @notice Set the withdrawal weight for a registered strategy
     * @param _strategy The strategy address
     * @param _withdrawalWeight Proportional weight for batch withdrawals (0–MAX_WITHDRAWAL_WEIGHT)
     */
    function setWithdrawalWeight(address _strategy, uint8 _withdrawalWeight) external;

    /**
     * @notice Remove a strategy from the NAV calculation after verifying dust NAV
     * @dev Requires a successful `navInETH()` read and reverts with
     *      `StrategyManagerStrategyNAVResidueTooHigh` if NAV exceeds `MAX_NAV_RESIDUE`.
     *      A reverting `navInETH()` bubbles up — use `forceRemoveStrategy()` for that case
     *      (and for over-reporting strategies). Emits `StrategyRemoved(strategy)`. Callable
     *      while paused (unlike `addStrategy()`). Does not clear `lastStrategyWithdrawal` —
     *      see that getter for remove → re-add cooldown semantics.
     * @param _strategy The strategy address
     */
    function removeStrategy(address _strategy) external;

    /**
     * @notice Force-remove a strategy from the NAV calculation, skipping the NAV residue check
     * @dev Emergency escape hatch for a strategy whose `navInETH()` over-reports or reverts
     *      (bug or malice) and can therefore never pass the clean `removeStrategy()` path.
     *      Without it, one broken strategy freezes `totalNAVInETH()` (and thus all protocol
     *      pricing) forever. Accepts the NAV dip from dropping the strategy's reported NAV;
     *      capital recovery goes through `IStrategy.emergencyExit()`. Reads `navInETH()` via
     *      `try/catch` for reporting only — the result never blocks removal. Strategy-local
     *      LP-fee accounting lives on the strategy itself, so there is no StrategyManager-side
     *      counter to clear. Emits `StrategyForceRemoved(strategy, reportedNAV, navReverted)` —
     *      `reportedNAV` is the NAV read at removal time (zero when `navInETH()` reverted).
     *      Callable while paused (like `removeStrategy()`). Restricted to `ADMIN_ROLE`, which
     *      in production sits behind the 48h timelock — accidental removal of a live strategy
     *      is guarded by process, not by the residue check.
     * @param _strategy The strategy address
     */
    function forceRemoveStrategy(address _strategy) external;

    /**
     * @notice Deposit funds to a range of strategies
     *
     * IMPORTANT: The actual distribution amount may be less if some of the strategies
     * hit their max deposit limits at the time of distribution.
     * Reverts with StrategyManagerNoStrategiesRegistered when the registry is empty.
     * Returns 0 when strategies exist but none qualify (`isHealthy() && maxDeposit() > 0`);
     * unused ETH is returned to the controller. Strategies still cooling down after a
     * withdrawal (see `strategyDepositCooldown()`) are skipped like unhealthy ones. Batch calls are
     * best-effort: a reverting `deposit()` on one strategy emits
     * `StrategyDepositFailed(strategy, reason)` (`reason` is the revert data) and the loop
     * continues.
     * @param _startIndex The start index (inclusive) of the strategies to deposit to
     * @param _endIndex The end index (exclusive) of the strategies to deposit to
     * @param _amount The amount of ETH to deposit to the strategies
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
     * @return totalDeposited Total amount of ETH deposited
     */
    function depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        returns (uint256 totalDeposited);

    /**
     * @notice Deposit funds to all strategies
     *
     * IMPORTANT: The actual distribution amount may be less if some of the strategies
     * hit their max deposit limits at the time of distribution.
     * Reverts with StrategyManagerNoStrategiesRegistered when the registry is empty.
     * Returns 0 when strategies exist but none qualify (`isHealthy() && maxDeposit() > 0`);
     * unused ETH is returned to the controller. Strategies still cooling down after a
     * withdrawal (see `strategyDepositCooldown()`) are skipped like unhealthy ones. Batch calls are
     * best-effort: a reverting `deposit()` on one strategy emits
     * `StrategyDepositFailed(strategy, reason)` (`reason` is the revert data) and the loop
     * continues.
     * @param _amount The amount of ETH to deposit to the strategies
     * @return totalDeposited Total amount of ETH deposited
     */
    function depositToStrategies(uint256 _amount) external returns (uint256 totalDeposited);

    /**
     * @notice Deposit funds to a specific strategy
     *
     * IMPORTANT: The actual deposit amount may be less if the strategy
     * hits its max deposit limit at the time of deposit.
     * Returns 0 when `maxDeposit() == 0`; unused ETH is returned to the controller.
     * Reverts with `StrategyManagerStrategyInDepositCooldown` when the strategy is still cooling
     * down after a withdrawal (see `strategyDepositCooldown()`).
     * @param _strategy The strategy address
     * @param _amount The amount of ETH to deposit to the strategy
     * @return depositAmount Total amount of ETH deposited
     */
    function depositToStrategy(address _strategy, uint256 _amount) external returns (uint256 depositAmount);

    /**
     * @notice Withdraw funds from a range of strategies to the controller
     *
     * IMPORTANT: The actual withdrawal amount may be less if some of the strategies
     * hit their max withdraw limits at the time of withdrawal.
     * Reverts with StrategyManagerNoStrategiesRegistered when the registry is empty.
     * Returns 0 when strategies exist but none have maxWithdrawal() > 0.
     * Batch calls are best-effort: a reverting `withdraw()` on one strategy emits
     * `StrategyWithdrawFailed(strategy, reason)` (`reason` is the revert data) and the loop continues.
     * @param _startIndex The start index (inclusive) of the strategies to withdraw from
     * @param _endIndex The end index (exclusive) of the strategies to withdraw from
     * @param _amount The amount of ETH to withdraw from the strategies
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
     * @return totalWithdrawn Total ETH actually received by the controller (net of strategy fees)
     */
    function withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        returns (uint256 totalWithdrawn);

    /**
     * @notice Withdraw funds from all strategies to the controller
     *
     * IMPORTANT: The actual withdrawal amount may be less if some of the strategies
     * hit their max withdraw limits at the time of withdrawal.
     * Reverts with StrategyManagerNoStrategiesRegistered when the registry is empty.
     * Returns 0 when strategies exist but none have maxWithdrawal() > 0.
     * Batch calls are best-effort: a reverting `withdraw()` on one strategy emits
     * `StrategyWithdrawFailed(strategy, reason)` (`reason` is the revert data) and the loop continues.
     * @param _amount The amount of ETH to withdraw from the strategies
     * @return totalWithdrawn Total ETH actually received by the controller (net of strategy fees)
     */
    function withdrawFromStrategies(uint256 _amount) external returns (uint256 totalWithdrawn);

    /**
     * @notice Withdraw funds from a specific strategy to the controller
     *
     * IMPORTANT: The actual withdrawal amount may be less if the strategy
     * hits its max withdraw limit at the time of withdrawal.
     * @param _strategy The strategy address
     * @param _amount The amount of ETH to withdraw
     * @return withdrawalAmount Total ETH actually received by the controller (net of strategy fees)
     */
    function withdrawFromStrategy(address _strategy, uint256 _amount) external returns (uint256 withdrawalAmount);

    /**
     * @notice Check and rebalance a range of strategies
     * @param _startIndex The start index (inclusive) of the strategies to check and rebalance
     * @param _endIndex The end index (exclusive) of the strategies to check and rebalance
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex.
     *      Batch calls are best-effort: a reverting `rebalance()` on one strategy emits
     *      `StrategyRebalanceFailed(strategy, reason)` (`reason` is the revert data) and the loop continues.
     *      Paused strategies are skipped.
     */
    function checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex) external;

    /**
     * @notice Check and rebalance all unhealthy strategies
     * @dev Best-effort across the registry; skips paused strategies. See
     *      `checkAndRebalanceStrategies(uint256,uint256)`.
     */
    function checkAndRebalanceStrategies() external;

    /**
     * @notice Check and rebalance a specific strategy if it is unhealthy
     * @param _strategy The strategy address
     * @dev No-op when the strategy is paused.
     */
    function checkAndRebalanceStrategy(address _strategy) external;

    /**
     * @notice Sync a range of strategies
     * @param _startIndex The start index (inclusive) of the strategies to sync
     * @param _endIndex The end index (exclusive) of the strategies to sync
     * @dev Range is [startIndex, endIndex). Delegates to each strategy's `sync()`.
     *      Skips strategies where `paused()` is true. Batch path: wraps each `sync()` in
     *      `try/catch` — emits `StrategySyncFailed(strategy, reason)` (`reason` is the revert
     *      data) and continues on failure.
     */
    function syncStrategies(uint256 _startIndex, uint256 _endIndex) external;

    /**
     * @notice Sync all registered strategies
     * @dev Delegates to each strategy's `sync()`. Skips strategies where `paused()` is true.
     *      Batch path: wraps each `sync()` in `try/catch` — emits `StrategySyncFailed(strategy,
     *      reason)` (`reason` is the revert data) and continues on failure.
     */
    function syncStrategies() external;

    /**
     * @notice Sync a specific strategy
     * @param _strategy The strategy address
     * @dev Delegates to `IStrategy.sync()`. Skips strategies where `paused()` is true.
     *      Strict: reverts if `sync()` fails.
     */
    function syncStrategy(address _strategy) external;

    /**
     * @notice Sweep idle native ETH held by the StrategyManager back to the Controller.
     * @dev Emergency capital-recovery path completing the chain
     *      `IStrategy.emergencyExit()` (strategy -> StrategyManager) ->
     *      `emergencyWithdrawToController()` (StrategyManager -> Controller) ->
     *      `IController.emergencyExitToAMM()` (Controller -> AMM), so funds parked on the
     *      StrategyManager after a strategy emergency exit can reach the AMM for redemptions.
     *      Callable by `ADMIN_ROLE` or `SECURITY_ROLE`. Reverts with
     *      `StrategyManagerNoBalanceToRecover` when the StrategyManager holds no idle ETH.
     *      Emits `EmergencyWithdrawnToController`.
     */
    function emergencyWithdrawToController() external;

    /**
     * @notice Whitelist an ERC-20 token the StrategyManager may hold.
     * @dev Whitelisted balances are priced into `totalNAVInETH()` via the protocol Oracle, so
     *      paired tokens delivered by `IStrategy.emergencyExit()` (e.g. `UniCLStrat` transfers
     *      its paired token here during an emergency unwind) do not silently vanish from NAV —
     *      users must not enter or exit at prices that ignore recoverable value. On-chain swap
     *      recovery of stranded supported ERC-20s back to native ETH via the shared Converter is
     *      deferred to a follow-up PR; this release ships ERC-20 accounting only. Callable only
     *      by `ADMIN_ROLE` (48h timelock in production); whitelist a strategy's paired token
     *      when the strategy is added, not during the emergency. Callable while paused so a
     *      missed whitelisting can still be fixed mid-emergency. Reverts with
     *      `StrategyManagerZeroAddress` on the zero address, `StrategyManagerNoCode` when
     *      `_token` has no code, `StrategyManagerERC20NotPriceable` when the Oracle has no
     *      feed for `_token` (a non-zero balance of an unpriceable token would freeze NAV),
     *      and `StrategyManagerERC20AlreadySupported` when already whitelisted. Emits
     *      `SupportedERC20Added`.
     * @param _token The ERC-20 token to whitelist
     */
    function addSupportedERC20(address _token) external;

    /**
     * @notice Remove an ERC-20 token from the supported-ERC-20 whitelist.
     * @dev Callable by `ADMIN_ROLE` or `SECURITY_ROLE` (instant circuit-breaker escape hatch for
     *      stale-feed / dust freezes; `addSupportedERC20` stays ADMIN-only); callable while paused.
     *      Removal is allowed even when the StrategyManager still holds a balance of `_token` —
     *      this is the escape hatch when a supported ERC-20's Oracle feed goes permanently stale
     *      (a stale feed on a non-zero supported balance freezes NAV, see `totalNAVInETH()`).
     *      NOTE: removing a token with a non-zero balance drops that balance's value out of NAV
     *      in the same block — exits priced after the removal no longer count it. Intentionally
     *      performs no external calls (not even `balanceOf`) so a bricked token contract can never
     *      block its own removal. Reverts with `StrategyManagerERC20NotSupported` when `_token`
     *      is not whitelisted. Emits `SupportedERC20Removed`.
     * @param _token The ERC-20 token to remove from the whitelist
     */
    function removeSupportedERC20(address _token) external;

    /**
     * @notice Get all whitelisted supported ERC-20s.
     * @return address[] Array of whitelisted ERC-20 token addresses
     */
    function supportedERC20() external view returns (address[] memory);

    /**
     * @notice Check if a token is on the supported-ERC-20 whitelist.
     * @param _token The token address
     * @return bool True if the token is whitelisted
     */
    function isSupportedERC20(address _token) external view returns (bool);

    /**
     * @notice Get the total NAV in ETH terms (18 decimals)
     * @dev Sums each registered strategy's `navInETH()` (any revert freezes the protocol),
     *      then adds StrategyManager, Controller, and AMM ETH balances, then adds the ETH
     *      value of each whitelisted supported-ERC-20 balance priced via the protocol Oracle
     *      (see `addSupportedERC20()`), then deducts in-window priced ExitQueue liability
     *      (`liveRedemptionOffsets`). Unpriced queued EVE is still equity and is not deducted.
     *      Liability lapses when a batch exceeds `MAX_BATCH_PROCESSING_TIME` (view-only).
     *      Reverts if liability exceeds gross NAV (fail-closed). Zero supported-ERC-20
     *      balances skip the Oracle entirely; a non-zero balance with a stale or invalid feed
     *      reverts and freezes NAV. Recover via `forceRemoveStrategy()` (ADMIN) or
     *      `removeSupportedERC20()` (ADMIN or SECURITY).
     * @return uint256 Total NAV in ETH
     */
    function totalNAVInETH() external view returns (uint256);

    /**
     * @notice Get the total NAV in USD terms (18 decimals)
     * @return uint256 Total NAV in USD
     */
    function totalNAVInUSD() external view returns (uint256);

    /**
     * @notice Get the NAV for a specific strategy
     * @param _strategy The strategy address
     * @return uint256 NAV for the strategy in ETH (18 decimals)
     */
    function strategyNAVInETH(address _strategy) external view returns (uint256);

    /**
     * @notice Get the NAV for a specific strategy in USD terms (18 decimals)
     * @param _strategy The strategy address
     * @return uint256 NAV for the strategy in USD (18 decimals)
     */
    function strategyNAVInUSD(address _strategy) external view returns (uint256);

    /**
     * @notice Check if a strategy is registered
     * @param _strategy The strategy address
     * @return bool True if strategy is registered
     */
    function isStrategyRegistered(address _strategy) external view returns (bool);

    /**
     * @notice Get all registered strategies
     * @return address[] Array of strategy addresses
     */
    function strategies() external view returns (address[] memory);

    /**
     * @notice Get a strategy at a specific index
     * @param _index The index of the strategy
     * @return address The strategy address
     */
    function strategyAt(uint256 _index) external view returns (address);

    /**
     * @notice Get the number of registered strategies
     * @return uint256 Number of strategies
     */
    function strategyCount() external view returns (uint256);

    /**
     * @notice Proportional deposit weight for a strategy (0 = no share of batch deposits)
     * @param _strategy The strategy address
     * @return uint8 Deposit weight (0–MAX_DEPOSIT_WEIGHT)
     */
    function depositWeight(address _strategy) external view returns (uint8);

    /**
     * @notice Proportional withdrawal weight for a strategy (0 = no share of batch withdrawals)
     * @param _strategy The strategy address
     * @return uint8 Withdrawal weight (0–MAX_WITHDRAWAL_WEIGHT)
     */
    function withdrawalWeight(address _strategy) external view returns (uint8);

    /**
     * @notice Performance fee rate in basis points (0 disables fee harvesting;
     * capped at `MAX_PERFORMANCE_FEE_BPS`)
     */
    function performanceFeeBps() external view returns (uint256);

    /**
     * @notice Harvest performance fees for a single strategy.
     * @dev Settles the strategy-reported fee base via `IStrategy.settlePerformanceFee()`,
     *      mints EVE to the DAO treasury via the bonding curve. Callable only by the registered
     *      Controller. Reverts with `StrategyManagerStrategyNotRegistered` when `_strategy` is
     *      not registered. Strict: reverts if `settlePerformanceFee()` fails.
     * @param _strategy The strategy address to harvest fees for
     * @return eveAmount EVE minted to the DAO treasury
     * @return feeETHEquivalent Performance fee settled, in wei of ETH (18 decimals). Drives the
     *         bonding-curve mint — no ETH is withdrawn from the strategy.
     */
    function harvestPerformanceFeeFromStrategy(address _strategy)
        external
        returns (uint256 eveAmount, uint256 feeETHEquivalent);

    /**
     * @notice Harvest performance fees for all registered strategies.
     * @dev Accrues each strategy's fee, sums ETH fees, and mints EVE once at the pre-batch
     *      supply/NAV snapshot. Emits per-strategy `PerformanceFeePaid` with pro-rata EVE.
     *      Batch path: wraps each `settlePerformanceFee()` in `try/catch` — emits
     *      `StrategyHarvestFailed(strategy, reason)` (`reason` is the revert data) and continues
     *      on failure (failed strategies are omitted from the mint sum). Callable only by the
     *      registered Controller.
     * @return eveAmount Total EVE minted to the DAO treasury
     * @return feeETHEquivalent Sum of per-strategy fees settled in this batch, in wei of ETH
     *         (18 decimals); drives the single bonding-curve mint for the batch.
     */
    function harvestPerformanceFeeFromStrategies() external returns (uint256 eveAmount, uint256 feeETHEquivalent);

    /**
     * @notice Harvest performance fees for a range of registered strategies.
     * @dev Accrues each strategy's fee in `[startIndex, endIndex)`, sums ETH fees, and mints
     *      EVE once at the pre-batch supply/NAV snapshot. Emits per-strategy `PerformanceFeePaid`
     *      with pro-rata EVE. Batch path: wraps each `settlePerformanceFee()` in `try/catch` —
     *      emits `StrategyHarvestFailed(strategy, reason)` (`reason` is the revert data) and
     *      continues on failure (failed strategies are omitted from the mint sum). Callable only
     *      by the registered Controller.
     * @param _startIndex The start index (inclusive) of the strategies to harvest
     * @param _endIndex The end index (exclusive) of the strategies to harvest
     * @return eveAmount Total EVE minted to the DAO treasury
     * @return feeETHEquivalent Sum of per-strategy fees settled in `[startIndex, endIndex)`, in wei
     *         of ETH (18 decimals); drives the single bonding-curve mint for the batch.
     */
    function harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        returns (uint256 eveAmount, uint256 feeETHEquivalent);

    /**
     * @notice Returns the pending performance fee in ETH for a strategy.
     * @dev Delegates to `IStrategy.pendingPerformanceFeeInETH(performanceFeeBps)`. Returns 0
     *      when the global fee rate is 0, the strategy is paused, or nothing is pending. Reverts with
     *      `StrategyManagerStrategyNotRegistered` when `_strategy` is not registered.
     * @param _strategy The strategy address
     * @return feeETH Pending fee in wei of ETH (18 decimals)
     */
    function pendingPerformanceFeeInETH(address _strategy) external view returns (uint256 feeETH);

    /**
     * @notice Set the performance fee rate in basis points.
     * @param _feeBps New performance fee rate (0 to MAX_PERFORMANCE_FEE_BPS)
     */
    function setPerformanceFeeBps(uint256 _feeBps) external;

    /**
     * @notice Set the DAO treasury address that receives performance fees.
     * @param _treasury New DAO treasury address
     */
    function setDaoTreasury(address _treasury) external;

    /**
     * @notice Cooldown in seconds between a withdrawal from a strategy and the next deposit
     *         into the same strategy.
     * @dev Mitigates keeper strategy-swap cycling (NAV bleed through DEX fees and slippage on
     *      every deposit/withdraw round trip) by bounding cycling to at most one round trip per
     *      strategy per cooldown window. Only deposits are gated — withdrawals are always exempt
     *      so exit-liquidity provisioning for user redemptions can never be blocked.
     * @return uint256 Cooldown duration in seconds (0 = disabled)
     */
    function strategyDepositCooldown() external view returns (uint256);

    /**
     * @notice Timestamp of the last withdrawal from a strategy.
     * @dev Recorded by `withdrawFromStrategy` and `withdrawFromStrategies` whenever capital
     *      leaves the strategy; 0 when the strategy has never been withdrawn from. Survives
     *      `removeStrategy` / `forceRemoveStrategy` so a remove → re-add while still inside
     *      `strategyDepositCooldown` keeps deposits blocked (cooldown is wall-clock on the address,
     *      not a per-registration epoch).
     * @param _strategy The strategy address
     * @return uint256 Timestamp of the last withdrawal (0 if none)
     */
    function lastStrategyWithdrawal(address _strategy) external view returns (uint256);

    /**
     * @notice Check whether deposits into a strategy are currently blocked by the cooldown.
     * @dev True when `strategyDepositCooldown() > 0`, the strategy has been withdrawn from, and less
     *      than `strategyDepositCooldown()` seconds have elapsed since that withdrawal.
     * @param _strategy The strategy address
     * @return bool True when the strategy is cooling down
     */
    function isStrategyInDepositCooldown(address _strategy) external view returns (bool);

    /**
     * @notice Set the per-strategy deposit cooldown.
     * @dev Callable by `ADMIN_ROLE`. Reverts with `StrategyManagerInvalidStrategyDepositCooldown`
     *      when `_cooldown` exceeds `MAX_STRATEGY_DEPOSIT_COOLDOWN`. Setting 0 disables the cooldown
     *      (default). Emits `StrategyDepositCooldownUpdated`.
     * @param _cooldown New cooldown duration in seconds
     */
    function setStrategyDepositCooldown(uint256 _cooldown) external;
}
