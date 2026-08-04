// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IStrategyManager} from "interfaces/IStrategyManager.sol";
import {IStrategy} from "interfaces/IStrategy.sol";
import {IAMM} from "interfaces/IAMM.sol";
import {IConverter} from "interfaces/IConverter.sol";
import {IRegistry} from "interfaces/IRegistry.sol";
import {IEVE} from "interfaces/IEVE.sol";

import {Oracle} from "contracts/Oracle.sol";
import {RegistryClientUpgradeable} from "registry/client/RegistryClientUpgradeable.sol";

import {Auth} from "libraries/Auth.sol";
import {Math} from "libraries/Math.sol";

/**
 * @title StrategyManager
 * @notice Upgradable manager contract for handling strategies and NAV calculations
 * @dev This manager can be upgraded independently while keeping AMM math stable
 */
contract StrategyManager is
    IStrategyManager,
    Initializable,
    UUPSUpgradeable,
    RegistryClientUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address payable;

    using Auth for IRegistry;
    using Math for uint256;

    // ============ Constants ============

    /// @notice The maximum allowed deposit weight for a strategy
    uint8 public constant MAX_DEPOSIT_WEIGHT = 100;

    /// @notice The maximum allowed withdrawal weight for a strategy
    uint8 public constant MAX_WITHDRAWAL_WEIGHT = 100;

    /// @notice Maximum NAV dust allowed to remain in a strategy when removing it
    uint256 public constant MAX_NAV_RESIDUE = 10 wei;

    /// @notice Basis points value
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Maximum allowed performance fee rate
    uint256 public constant MAX_PERFORMANCE_FEE_BPS = 2_000;

    /// @notice Maximum allowed per-strategy deposit cooldown
    uint256 public constant MAX_STRATEGY_DEPOSIT_COOLDOWN = 1 days;

    // ============ State Variables ============

    /// @notice Set of registered strategies
    EnumerableSet.AddressSet private _strategies;

    /// @notice Performance fee rate in basis points
    uint256 public performanceFeeBps;

    /// @notice DAO Treasury which receive performance fees
    address public daoTreasury;

    /// @notice Cumulative EVE tokens minted as performance fees
    uint256 public totalPerformanceFeesPaidEVE;

    /// @inheritdoc IStrategyManager
    uint256 public strategyDepositCooldown;

    /// @inheritdoc IStrategyManager
    mapping(address strategy => uint256) public lastStrategyWithdrawal;

    /// @notice Admin-whitelisted ERC-20 tokens the StrategyManager may hold, priced into NAV
    EnumerableSet.AddressSet private _supportedERC20s;

    /// @notice Proportional deposit weight per strategy (owned here — strategies cannot self-report)
    mapping(address strategy => uint8) public depositWeight;

    /// @notice Proportional withdrawal weight per strategy (owned here — strategies cannot self-report)
    mapping(address strategy => uint8) public withdrawalWeight;

    // ============ Receive Function ============

    /**
     * @notice Allows Controller top-ups and unsolicited native ETH transfers
     * @dev ETH held directly by StrategyManager is included in total NAV and can remain
     *      on the contract between distributions, especially when balance exceeds a
     *      requested distribution amount.
     */
    receive() external payable {}

    // ============ Initialization ============
    /**
     * @notice Constructor that disables initialization of the implementation contract
     * @dev This prevents the implementation contract from being initialized
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Strategy Manager
     * @param _registry Address of the protocol Registry (role authority and contract addresses)
     * @param _feeConfig Performance fee configuration (non-zero treasury; fees disabled when `performanceFeeBps` is 0)
     */
    function initialize(address _registry, FeeConfig calldata _feeConfig) public initializer {
        __UUPSUpgradeable_init();
        __RegistryClient_init(_registry);
        __Pausable_init();
        __ReentrancyGuard_init();

        _applyFeeConfig(_feeConfig);
    }

    // ============ Metadata ============
    /**
     * @inheritdoc IStrategyManager
     */
    function version() public pure returns (string memory) {
        return "1.1.0";
    }

    // ============ Strategy Management ============

    /**
     * @inheritdoc IStrategyManager
     *
     * @dev NOTE: `grantCallerRole` is NOT wrapped in try/catch. If the call chain reverts,
     *      `addStrategy` reverts loudly. `Converter.grantCallerRole` itself has no pause
     *      gate — the actual revert sources are the underlying `Registry.grantRole` being
     *      `whenNotPaused` (paused Registry) or the Converter missing CONVERTER_CALLER_MANAGER_ROLE.
     *      This is the correct behaviour for add: we must never silently register a strategy
     *      that lacks CONVERTER_CALLER_ROLE — it would be permanently unable to wrap, unwrap, or swap.
     *      Contrast with {removeStrategy}, which wraps `revokeCallerRole` in try/catch so
     *      removal can proceed even when revocation fails.
     */
    function addStrategy(address _strategy, uint8 _depositWeight, uint8 _withdrawalWeight)
        external
        onlyAuthRole(Auth.ADMIN_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (_strategy == address(0)) {
            revert StrategyManagerZeroAddress();
        }
        if (_strategy.code.length == 0) revert StrategyManagerNoCode();

        if (_isStrategyRegistered(_strategy)) revert StrategyManagerStrategyAlreadyRegistered();
        _strategies.add(_strategy);

        _setDepositWeight(_strategy, _depositWeight);
        _setWithdrawalWeight(_strategy, _withdrawalWeight);

        // Grant CONVERTER_CALLER_ROLE on the Converter so the strategy can wrap/unwrap/swap.
        IConverter(registry().converter()).grantCallerRole(_strategy);

        emit StrategyAdded(_strategy);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function setStrategyWeights(
        address[] calldata _strategies_,
        uint8[] calldata _depositWeights,
        uint8[] calldata _withdrawalWeights
    ) external onlyAuthRole(Auth.ADMIN_ROLE) {
        uint256 length = _strategies_.length;
        if (length != _depositWeights.length || length != _withdrawalWeights.length) {
            revert StrategyManagerInvalidLength();
        }

        for (uint256 i; i < length; ++i) {
            _validateStrategyIsRegistered(_strategies_[i]);
            _setDepositWeight(_strategies_[i], _depositWeights[i]);
            _setWithdrawalWeight(_strategies_[i], _withdrawalWeights[i]);
        }
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function setDepositWeight(address _strategy, uint8 _depositWeight) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _validateStrategyIsRegistered(_strategy);
        _setDepositWeight(_strategy, _depositWeight);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function setWithdrawalWeight(address _strategy, uint8 _withdrawalWeight) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _validateStrategyIsRegistered(_strategy);
        _setWithdrawalWeight(_strategy, _withdrawalWeight);
    }

    /**
     * @inheritdoc IStrategyManager
     *
     * @dev NOTE: `revokeCallerRole` is wrapped in try/catch so removal can succeed even when
     *      revocation fails. `Converter.revokeCallerRole` itself has no pause gate — the
     *      realistic revert sources are the underlying `Registry.revokeRole` being
     *      `whenNotPaused` (paused Registry) or the Converter missing CONVERTER_CALLER_MANAGER_ROLE.
     *      (Revoking a role the strategy never held is an AccessControl no-op, not a revert.)
     *      A best-effort revocation is safe: a removed strategy holds at most MAX_NAV_RESIDUE
     *      of protocol funds, so a leftover CONVERTER_CALLER_ROLE only lets it wrap/unwrap/swap its own
     *      balances. Cleanup: `converter.revokeCallerRole` is callable only by this contract,
     *      so the retry path is re-`addStrategy` + `removeStrategy` once the Registry is
     *      unpaused (or pause the Converter to neutralise the orphaned role). Contrast with
     *      {addStrategy}, which does NOT wrap `grantCallerRole` in try/catch — failing to
     *      grant on add would silently orphan a registered strategy.
     *      A reverting `navInETH()` bubbles up — use {forceRemoveStrategy} for that case.
     */
    function removeStrategy(address _strategy) external override onlyAuthRole(Auth.ADMIN_ROLE) nonReentrant {
        _validateStrategyIsRegistered(_strategy);

        if (IStrategy(_strategy).navInETH() > MAX_NAV_RESIDUE) {
            revert StrategyManagerStrategyNAVResidueTooHigh(_strategy);
        }

        _deregisterStrategy(_strategy);

        emit StrategyRemoved(_strategy);
    }

    /**
     * @inheritdoc IStrategyManager
     *
     * @dev NOTE: intentionally does NOT require the strategy to be paused. A broken or
     *      malicious strategy may misreport `paused()` (or revert in it), so gating force
     *      removal on strategy state could re-create the very deadlock this function exists
     *      to break. The `ADMIN_ROLE` gate (48h timelock in production) is the safeguard
     *      against accidental removal of a strategy still holding real funds.
     *      `revokeCallerRole` is best-effort here for the same reasons as in {removeStrategy}.
     */
    function forceRemoveStrategy(address _strategy) external override onlyAuthRole(Auth.ADMIN_ROLE) nonReentrant {
        _validateStrategyIsRegistered(_strategy);

        // NAV is read for observability only — over-reporting, reverting, or dust NAV all
        // proceed to removal. Anyone reviewing the timelocked call or the emitted event can
        // see exactly how much reported NAV was dropped from totalNAVInETH().
        uint256 reportedNAV;
        bool navReverted;
        try IStrategy(_strategy).navInETH() returns (uint256 nav) {
            reportedNAV = nav;
        } catch {
            navReverted = true;
        }

        _deregisterStrategy(_strategy);

        emit StrategyForceRemoved(_strategy, reportedNAV, navReverted);
    }

    /**
     * @notice Shared removal tail for {removeStrategy} and {forceRemoveStrategy}.
     * @dev Drops the strategy from the registry set and best-effort revokes
     *      CONVERTER_CALLER_ROLE via the Converter. Removal proceeds even if revocation
     *      fails (e.g. the Registry is paused — the Converter's own pause does not gate
     *      revokeCallerRole). Intentionally does NOT clear `lastStrategyWithdrawal`: the
     *      cooldown is wall-clock since the last withdrawal of this strategy address, so a
     *      remove → re-add while still inside the window keeps deposits blocked. Clearing
     *      would couple correctness to admin-timelock delay vs `MAX_STRATEGY_DEPOSIT_COOLDOWN`, which
     *      are independently configurable. Note: registry().converter() is resolved OUTSIDE
     *      the try — an unregistered Converter reverts the whole call. Strategy-local LP-fee
     *      accounting lives on the strategy itself, so there is no SM-side counter to clear.
     * @param _strategy The strategy address being removed
     */
    function _deregisterStrategy(address _strategy) private {
        _strategies.remove(_strategy);
        delete depositWeight[_strategy];
        delete withdrawalWeight[_strategy];

        try IConverter(registry().converter()).revokeCallerRole(_strategy) {
            // revocation succeeded
        } catch {
            emit CallerRoleRevokeFailed(_strategy);
        }
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 totalDeposited)
    {
        _requireStrategiesRegistered();
        _validateRange(_startIndex, _endIndex);
        totalDeposited = _depositToStrategies(_startIndex, _endIndex, _amount);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function depositToStrategies(uint256 _amount)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 totalDeposited)
    {
        _requireStrategiesRegistered();
        totalDeposited = _depositToStrategies(0, _strategies.length(), _amount);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function depositToStrategy(address _strategy, uint256 _amount)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 depositAmount)
    {
        _validateStrategyIsRegistered(_strategy);
        _validateStrategyNotInDepositCooldown(_strategy);
        depositAmount = _depositToStrategy(_strategy, _amount);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 totalWithdrawn)
    {
        _requireStrategiesRegistered();
        _validateRange(_startIndex, _endIndex);
        totalWithdrawn = _withdrawFromStrategies(_startIndex, _endIndex, _amount);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function withdrawFromStrategies(uint256 _amount)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 totalWithdrawn)
    {
        _requireStrategiesRegistered();
        totalWithdrawn = _withdrawFromStrategies(0, _strategies.length(), _amount);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function withdrawFromStrategy(address _strategy, uint256 _amount)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 withdrawalAmount)
    {
        _validateStrategyIsRegistered(_strategy);
        withdrawalAmount = _withdrawFromStrategy(_strategy, _amount);
    }

    /**
     * @inheritdoc IStrategyManager
     * @param _startIndex The start index (inclusive) of the strategies to check and rebalance
     * @param _endIndex The end index (exclusive) of the strategies to check and rebalance
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
     */
    function checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
    {
        _validateRange(_startIndex, _endIndex);
        _checkAndRebalanceStrategies(_startIndex, _endIndex);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function checkAndRebalanceStrategies() external onlyAuthContract(Auth.CONTROLLER) whenNotPaused nonReentrant {
        _checkAndRebalanceStrategies(0, _strategies.length());
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function checkAndRebalanceStrategy(address _strategy)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
    {
        _validateStrategyIsRegistered(_strategy);
        _checkAndRebalanceStrategy(_strategy);
    }

    /**
     * @inheritdoc IStrategyManager
     * @param _startIndex The start index (inclusive) of the strategies to sync
     * @param _endIndex The end index (exclusive) of the strategies to sync
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
     */
    function syncStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
    {
        _validateRange(_startIndex, _endIndex);
        _syncStrategies(_startIndex, _endIndex);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function syncStrategies() external onlyAuthContract(Auth.CONTROLLER) whenNotPaused nonReentrant {
        _syncStrategies(0, _strategies.length());
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function syncStrategy(address _strategy) external onlyAuthContract(Auth.CONTROLLER) whenNotPaused nonReentrant {
        _validateStrategyIsRegistered(_strategy);
        _syncStrategy(_strategy);
    }

    // ============ Emergency Functions ============
    /**
     * @inheritdoc IStrategyManager
     */
    function emergencyWithdrawToController()
        external
        onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE)
        nonReentrant
    {
        uint256 amount = address(this).balance;
        if (amount == 0) revert StrategyManagerNoBalanceToRecover();

        payable(registry().controller()).sendValue(amount);
        emit EmergencyWithdrawnToController(amount);
    }

    // ============ Supported ERC-20 Management ============
    // ERC-20 accounting only in this release: whitelist + Oracle-priced NAV via
    // `_supportedERC20sNAVInETH()`. On-chain swap recovery of stranded supported ERC-20s back to native
    // ETH via the shared Converter is deferred to a follow-up PR.

    /**
     * @inheritdoc IStrategyManager
     *
     * @dev NOTE: intentionally not `whenNotPaused` — supported ERC-20s matter precisely during
     *      emergencies (paired tokens arrive via `IStrategy.emergencyExit()` while everything
     *      is paused), so a missed whitelisting must be fixable without unpausing.
     */
    function addSupportedERC20(address _token) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_token == address(0)) revert StrategyManagerZeroAddress();
        if (_token.code.length == 0) revert StrategyManagerNoCode();
        if (!Oracle(registry().oracle()).isTokenSupported(_token)) {
            revert StrategyManagerERC20NotPriceable(_token);
        }
        if (!_supportedERC20s.add(_token)) revert StrategyManagerERC20AlreadySupported(_token);

        emit SupportedERC20Added(_token);
    }

    /**
     * @inheritdoc IStrategyManager
     *
     * @dev NOTE: performs no external calls (not even `balanceOf`) so a bricked token
     *      contract can never block its own removal — this is the escape hatch when a supported
     *      ERC-20's feed goes permanently stale and freezes NAV (including 1-wei dust griefing).
     *      `SECURITY_ROLE` can remove instantly (circuit breaker); `ADMIN_ROLE` retains remove for
     *      the 48h path. `addSupportedERC20` stays ADMIN-only. Removing a token with a non-zero
     *      balance drops that value out of NAV immediately.
     */
    function removeSupportedERC20(address _token) external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        if (!_supportedERC20s.remove(_token)) revert StrategyManagerERC20NotSupported(_token);

        emit SupportedERC20Removed(_token);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }

    // ============ View Functions ============
    /**
     * @inheritdoc IStrategyManager
     */
    function totalNAVInETH() external view returns (uint256) {
        return _totalNAVInETH();
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function totalNAVInUSD() external view returns (uint256) {
        return _totalNAVInUSD();
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function strategyNAVInETH(address _strategy) external view returns (uint256) {
        _validateStrategyIsRegistered(_strategy);

        return IStrategy(_strategy).navInETH();
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function strategyNAVInUSD(address _strategy) external view returns (uint256) {
        _validateStrategyIsRegistered(_strategy);

        return Oracle(registry().oracle()).convertTokenToUSD(
            address(0), IStrategy(_strategy).navInETH(), Math.DECIMALS_NORMALIZED
        );
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function isStrategyRegistered(address strategy) external view override returns (bool) {
        return _isStrategyRegistered(strategy);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function strategies() external view returns (address[] memory) {
        return _strategies.values();
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function strategyAt(uint256 _index) external view returns (address) {
        return _strategies.at(_index);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function strategyCount() external view returns (uint256) {
        return _strategies.length();
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function isStrategyInDepositCooldown(address _strategy) external view returns (bool) {
        return _isStrategyInDepositCooldown(_strategy);
    }

    // ============ Deposit Cooldown Functions ============

    /**
     * @inheritdoc IStrategyManager
     */
    function setStrategyDepositCooldown(uint256 _cooldown) external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_cooldown > MAX_STRATEGY_DEPOSIT_COOLDOWN) revert StrategyManagerInvalidStrategyDepositCooldown();

        emit StrategyDepositCooldownUpdated(strategyDepositCooldown, _cooldown);
        strategyDepositCooldown = _cooldown;
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function supportedERC20() external view returns (address[] memory) {
        return _supportedERC20s.values();
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function isSupportedERC20(address _token) external view returns (bool) {
        return _supportedERC20s.contains(_token);
    }

    // ============ Fee Functions ============

    /**
     * @inheritdoc IStrategyManager
     */
    function harvestPerformanceFeeFromStrategy(address _strategy)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 eveAmount, uint256 feeETHEquivalent)
    {
        _validateStrategyIsRegistered(_strategy);
        return _harvestPerformanceFeeFromStrategy(_strategy);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function harvestPerformanceFeeFromStrategies()
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 eveAmount, uint256 feeETHEquivalent)
    {
        _requireStrategiesRegistered();
        return _harvestPerformanceFeeFromStrategies(0, _strategies.length());
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        onlyAuthContract(Auth.CONTROLLER)
        whenNotPaused
        nonReentrant
        returns (uint256 eveAmount, uint256 feeETHEquivalent)
    {
        _requireStrategiesRegistered();
        _validateRange(_startIndex, _endIndex);
        return _harvestPerformanceFeeFromStrategies(_startIndex, _endIndex);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function pendingPerformanceFeeInETH(address _strategy) external view returns (uint256 feeETH) {
        _validateStrategyIsRegistered(_strategy);

        if (performanceFeeBps == 0) return 0;

        return IStrategy(_strategy).pendingPerformanceFeeInETH(performanceFeeBps);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function setPerformanceFeeBps(uint256 _feeBps) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setPerformanceFeeBps(_feeBps);
    }

    /**
     * @inheritdoc IStrategyManager
     */
    function setDaoTreasury(address _treasury) external onlyAuthRole(Auth.ADMIN_ROLE) {
        _setDaoTreasury(_treasury);
    }

    /**
     * @notice Harvest performance fees for a single strategy.
     * @dev Accrues the strategy fee, mints EVE once, and emits `PerformanceFeePaid`.
     */
    function _harvestPerformanceFeeFromStrategy(address _strategy)
        internal
        returns (uint256 eveAmount, uint256 feeETHEquivalent)
    {
        feeETHEquivalent = _accruePerformanceFeeForStrategy(_strategy);
        if (feeETHEquivalent == 0) return (0, 0);

        eveAmount = _mintPerformanceFeeEVE(feeETHEquivalent);
        emit PerformanceFeePaid(_strategy, daoTreasury, eveAmount, feeETHEquivalent);
    }

    /**
     * @notice Harvest performance fees for a range of registered strategies with one EVE mint.
     */
    function _harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex)
        internal
        returns (uint256 eveAmount, uint256 feeETHEquivalent)
    {
        uint256 strategiesAmount = _endIndex - _startIndex;
        address[] memory strategiesToHarvest = new address[](strategiesAmount);
        for (uint256 i; i < strategiesAmount; ++i) {
            strategiesToHarvest[i] = _strategies.at(_startIndex + i);
        }
        return _harvestPerformanceFeesFor(strategiesToHarvest, strategiesAmount);
    }

    /**
     * @notice Harvest performance fees for a list of strategies with one EVE mint.
     * @dev Settles each strategy via `IStrategy.settlePerformanceFee()`, sums ETH fees, mints once at the pre-batch
     *      supply/NAV snapshot, then emits per-strategy `PerformanceFeePaid` with pro-rata EVE.
     *      Each settle is wrapped in `try/catch` — emits `StrategyHarvestFailed(strategy, reason)`
     *      and continues on failure so one bad strategy cannot brick the batch (or the pre-withdraw
     *      harvest that shares this helper).
     * @param _strategiesToHarvest Strategy addresses to attempt harvest for (may be longer than
     *        `_count`; only indices `[0, _count)` are read)
     * @param _count How many entries at the start of `_strategiesToHarvest` to process. Typically
     *        equals `_strategiesToHarvest.length` but allows reusing a pre-sized buffer.
     * @return totalEves Total EVE minted to the DAO treasury in this batch
     * @return totalFeeETH Sum of per-strategy `feeETHEquivalent` amounts (wei of ETH) that drove
     *         the single `_mintPerformanceFeeEVE` call. Strategies with zero accrued fee or a
     *         failed settle are skipped and not included in this sum.
     */
    function _harvestPerformanceFeesFor(address[] memory _strategiesToHarvest, uint256 _count)
        internal
        returns (uint256 totalEves, uint256 totalFeeETH)
    {
        if (performanceFeeBps == 0 || _count == 0) return (0, 0);

        address[] memory harvestedStrategies = new address[](_count);
        uint256[] memory feeETHs = new uint256[](_count);
        uint256 feeCount;

        for (uint256 i; i < _count; ++i) {
            address strategy = _strategiesToHarvest[i];
            try IStrategy(strategy).settlePerformanceFee(performanceFeeBps) returns (uint256 feeETH) {
                if (feeETH > 0) {
                    harvestedStrategies[feeCount] = strategy;
                    feeETHs[feeCount] = feeETH;
                    totalFeeETH += feeETH;
                    unchecked {
                        ++feeCount;
                    }
                }
            } catch (bytes memory reason) {
                emit StrategyHarvestFailed(strategy, reason);
            }
        }

        if (totalFeeETH == 0) return (0, 0);

        totalEves = _mintPerformanceFeeEVE(totalFeeETH);

        uint256 evesRemaining = totalEves;
        for (uint256 i; i < feeCount; ++i) {
            uint256 eveAmount = i == feeCount - 1 ? evesRemaining : (totalEves * feeETHs[i]) / totalFeeETH;
            if (i != feeCount - 1) evesRemaining -= eveAmount;
            emit PerformanceFeePaid(harvestedStrategies[i], daoTreasury, eveAmount, feeETHs[i]);
        }
    }

    /**
     * @notice Accrue performance fees for a single strategy via strategy-local settlement.
     * @dev Returns the ETH-equivalent fee owed; does not mint EVE.
     * @param _strategy The strategy address
     * @return feeETH Accrued performance fee in wei of ETH (18 decimals), reported by the strategy
     */
    function _accruePerformanceFeeForStrategy(address _strategy) internal returns (uint256 feeETH) {
        if (performanceFeeBps == 0) return 0;

        return IStrategy(_strategy).settlePerformanceFee(performanceFeeBps);
    }

    /**
     * @notice Mint EVE to the DAO treasury for a settled performance-fee ETH amount.
     * @dev Bonding-curve dilution: dS = (feeETH * supply) / (NAV - feeETH).
     * @param _totalFeeETH Total performance fee in ETH terms
     * @return evesToMint EVE minted to the treasury
     */
    function _mintPerformanceFeeEVE(uint256 _totalFeeETH) internal returns (uint256 evesToMint) {
        uint256 supply = IERC20(registry().eve()).totalSupply();
        uint256 totalNAV = _totalNAVInETH();
        if (totalNAV <= _totalFeeETH) revert StrategyManagerFeeMintOverflow();
        evesToMint = (_totalFeeETH * supply) / (totalNAV - _totalFeeETH);

        IEVE(registry().eve()).mint(daoTreasury, evesToMint);
        totalPerformanceFeesPaidEVE += evesToMint;
    }

    // ============ Internal Functions ============

    /**
     * @notice Apply performance fee configuration from initialization.
     * @dev Routes through the internal setters so the change events are emitted at
     *      initialization too (`initial` values are zero), mirroring how the AMM emits
     *      `ConnectorWeightChanged(0, current)` on deploy.
     * @param _feeConfig Fee configuration (non-zero treasury; fees disabled when `performanceFeeBps` is 0).
     */
    function _applyFeeConfig(FeeConfig calldata _feeConfig) internal {
        _setDaoTreasury(_feeConfig.daoTreasury);
        _setPerformanceFeeBps(_feeConfig.performanceFeeBps);
    }

    /**
     * @notice Set the DAO treasury address that receives performance fees.
     * @param _treasury New DAO treasury address (non-zero).
     */
    function _setDaoTreasury(address _treasury) internal {
        if (_treasury == address(0)) revert StrategyManagerZeroDaoTreasury();

        emit DaoTreasuryChanged(daoTreasury, _treasury);
        daoTreasury = _treasury;
    }

    /**
     * @notice Set the performance fee rate in basis points.
     * @param _feeBps New performance fee rate (0 to MAX_PERFORMANCE_FEE_BPS; 0 disables harvesting).
     */
    function _setPerformanceFeeBps(uint256 _feeBps) internal {
        if (_feeBps > MAX_PERFORMANCE_FEE_BPS) revert StrategyManagerInvalidPerformanceFeeBps();

        emit PerformanceFeeBpsChanged(performanceFeeBps, _feeBps);
        performanceFeeBps = _feeBps;
    }

    /**
     * @notice Validate and store a deposit weight
     * @dev Zero is allowed (strategy registered but excluded from batch deposit allocation).
     * @param _strategy The strategy address
     * @param _depositWeight The deposit weight to set
     */
    function _setDepositWeight(address _strategy, uint8 _depositWeight) internal {
        if (_depositWeight > MAX_DEPOSIT_WEIGHT) {
            revert StrategyManagerInvalidDepositWeight(_strategy);
        }
        uint8 oldWeight = depositWeight[_strategy];
        depositWeight[_strategy] = _depositWeight;
        emit DepositWeightUpdated(_strategy, oldWeight, _depositWeight);
    }

    /**
     * @notice Validate and store a withdrawal weight
     * @dev Zero is allowed (strategy registered but excluded from batch withdrawal allocation).
     * @param _strategy The strategy address
     * @param _withdrawalWeight The withdrawal weight to set
     */
    function _setWithdrawalWeight(address _strategy, uint8 _withdrawalWeight) internal {
        if (_withdrawalWeight > MAX_WITHDRAWAL_WEIGHT) {
            revert StrategyManagerInvalidWithdrawalWeight(_strategy);
        }
        uint8 oldWeight = withdrawalWeight[_strategy];
        withdrawalWeight[_strategy] = _withdrawalWeight;
        emit WithdrawalWeightUpdated(_strategy, oldWeight, _withdrawalWeight);
    }

    /**
     * @notice Validate a range of strategies
     * @param _startIndex The start index (inclusive) of the strategies
     * @param _endIndex The end index (exclusive) of the strategies
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
     *      Validates that endIndex <= strategies.length() and startIndex < endIndex
     */
    function _validateRange(uint256 _startIndex, uint256 _endIndex) internal view {
        if (_endIndex > _strategies.length() || _startIndex >= _endIndex) revert StrategyManagerInvalidRange();
    }

    /**
     * @notice Check if a strategy is registered
     * @param _strategy The strategy address
     */
    function _validateStrategyIsRegistered(address _strategy) internal view {
        if (!_isStrategyRegistered(_strategy)) revert StrategyManagerStrategyNotRegistered();
    }

    /**
     * @notice Revert when deposits into a strategy are blocked by the cooldown
     * @param _strategy The strategy address
     */
    function _validateStrategyNotInDepositCooldown(address _strategy) internal view {
        if (_isStrategyInDepositCooldown(_strategy)) revert StrategyManagerStrategyInDepositCooldown(_strategy);
    }

    /**
     * @notice Check whether deposits into a strategy are currently blocked by the cooldown
     * @dev Only deposits are gated. Withdrawals — including exit-liquidity provisioning for
     *      user redemptions — and the emergency path (`emergencyWithdrawToController`)
     *      are never subject to the cooldown.
     * @param _strategy The strategy address
     * @return bool True when `strategyDepositCooldown > 0`, the strategy has been withdrawn from,
     *         and less than `strategyDepositCooldown` seconds have elapsed since that withdrawal
     */
    function _isStrategyInDepositCooldown(address _strategy) internal view returns (bool) {
        uint256 cooldown = strategyDepositCooldown;
        if (cooldown == 0) return false;

        uint256 lastWithdrawal = lastStrategyWithdrawal[_strategy];
        return lastWithdrawal != 0 && block.timestamp < lastWithdrawal + cooldown;
    }

    /**
     * @notice Require at least one strategy is registered
     * @dev Reverts with StrategyManagerNoStrategiesRegistered when the registry is empty
     */
    function _requireStrategiesRegistered() internal view {
        if (_strategies.length() == 0) revert StrategyManagerNoStrategiesRegistered();
    }

    /**
     * @notice Check if a strategy is registered
     * @param _strategy The strategy address
     * @return bool True if strategy is registered
     */
    function _isStrategyRegistered(address _strategy) internal view returns (bool) {
        return _strategies.contains(_strategy);
    }

    /**
     * @notice Calculate the total NAV in ETH
     * @dev NAV = sum of all strategy NAVs
     *           + StrategyManager balance (funds in-flight during strategy allocation)
     *           + Controller balance (undistributed funds awaiting strategy allocation)
     *           + AMM free balance (ETH available on AMM; excludes lockedForClaims)
     *           + ETH value of each whitelisted supported-ERC-20 balance (via the protocol Oracle)
     *      If any strategy's `navInETH()` reverts, this function reverts and enter/exit/pricing
     *      are frozen until the strategy is fixed or force-removed via `forceRemoveStrategy()`.
     *      Supported-ERC-20 pricing is equally fail-closed: a stale or invalid Oracle feed for a
     *      supported ERC-20 with a non-zero balance reverts and freezes NAV — users must never
     *      enter or exit at prices that mis-count recoverable value. Zero balances skip the
     *      Oracle entirely, so an empty whitelist entry costs ~nothing and cannot freeze NAV.
     *      Escape hatch: `removeSupportedERC20()` (ADMIN or SECURITY; drops the balance out of
     *      NAV, no external calls).
     * @return _currentTotalNAV The total NAV in ETH
     */
    function _totalNAVInETH() internal view returns (uint256 _currentTotalNAV) {
        for (uint256 i; i < _strategies.length(); ++i) {
            _currentTotalNAV += IStrategy(_strategies.at(i)).navInETH();
        }

        IRegistry registry_ = registry();

        // Account for in-flight funds not yet reflected in strategy NAVs.
        _currentTotalNAV += address(this).balance + registry_.controller().balance + IAMM(registry_.amm()).freeBalance();

        _currentTotalNAV += _supportedERC20sNAVInETH(Oracle(registry_.oracle()));
    }

    /**
     * @notice Sum the ETH value of each whitelisted supported-ERC-20 balance via the Oracle
     * @dev Zero balances skip the Oracle entirely. A non-zero balance with a stale or invalid
     *      feed reverts and freezes NAV — the same fail-closed semantics as a reverting
     *      strategy `navInETH()`.
     * @param _oracle The protocol Oracle used to price supported ERC-20s
     * @return _supportedERC20sNAV The ETH-denominated NAV contribution of supported-ERC-20 balances
     */
    function _supportedERC20sNAVInETH(Oracle _oracle) internal view returns (uint256 _supportedERC20sNAV) {
        uint256 supportedERC20Count = _supportedERC20s.length();
        for (uint256 i; i < supportedERC20Count; ++i) {
            address token = _supportedERC20s.at(i);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;
            _supportedERC20sNAV +=
                _oracle.convert(token, address(0), balance, IERC20Metadata(token).decimals(), Math.DECIMALS_NORMALIZED);
        }
    }

    /**
     * @notice Calculate the total NAV in USD
     * @return _currentTotalNAV The total NAV in USD
     */
    function _totalNAVInUSD() internal view returns (uint256 _currentTotalNAV) {
        Oracle oracle = Oracle(registry().oracle());
        _currentTotalNAV = oracle.convertTokenToUSD(address(0), _totalNAVInETH(), Math.DECIMALS_NORMALIZED);
    }

    /**
     * @notice Deposit funds to the strategies
     * @param _startIndex The start index (inclusive) of the strategies to deposit to
     * @param _endIndex The end index (exclusive) of the strategies to deposit to
     * @param _amount The amount of ETH to deposit to the strategies
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
     * @return totalDeposited The total amount of funds deposited
     */
    function _depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        internal
        returns (uint256 totalDeposited)
    {
        uint256 strategiesAmount = _endIndex - _startIndex;

        uint256 cumulativeDepositWeight;
        uint8[] memory depositWeights = new uint8[](strategiesAmount);

        uint256[] memory maxDeposits = new uint256[](strategiesAmount);

        for (uint256 i; i < strategiesAmount; ++i) {
            IStrategy strategy = IStrategy(_strategies.at(i + _startIndex));

            uint256 maxDeposit = strategy.maxDeposit();

            // Strategies still cooling down after a withdrawal are skipped like unhealthy ones,
            // consistent with the batch path's partial-success design. Zero depositWeight means
            // registered-but-unfunded — skipped for allocation without reverting.
            if (!_isStrategyInDepositCooldown(address(strategy)) && strategy.isHealthy() && maxDeposit > 0) {
                maxDeposits[i] = maxDeposit;

                depositWeights[i] = depositWeight[address(strategy)];
                cumulativeDepositWeight += depositWeights[i];
            }
        }

        if (cumulativeDepositWeight == 0) {
            if (_amount > 0) payable(registry().controller()).sendValue(_amount);
            return 0;
        }

        for (uint256 i; i < strategiesAmount; ++i) {
            uint256 depositAmount = OZMath.min(_amount * depositWeights[i] / cumulativeDepositWeight, maxDeposits[i]);

            if (depositAmount > 0) {
                address strategy = _strategies.at(i + _startIndex);

                try IStrategy(strategy).deposit{value: depositAmount}() {
                    totalDeposited += depositAmount;
                    emit FundsDepositedToStrategy(strategy, depositAmount);
                } catch (bytes memory reason) {
                    emit StrategyDepositFailed(strategy, reason);
                }
            }
        }

        uint256 remaining = _amount - totalDeposited;
        if (remaining > 0) {
            payable(registry().controller()).sendValue(remaining);
        }
    }

    /**
     * @notice Deposit funds to a strategy
     * @param _strategy The strategy address
     * @param _amount The amount of funds to deposit
     * @return depositAmount The amount of funds deposited; 0 when the strategy is unhealthy or
     *         `maxDeposit() == 0`, with unused ETH returned to the controller
     */
    function _depositToStrategy(address _strategy, uint256 _amount) internal returns (uint256 depositAmount) {
        IStrategy strategy = IStrategy(_strategy);

        uint256 maxDeposit = strategy.maxDeposit();

        if (strategy.isHealthy() && maxDeposit > 0) {
            depositAmount = OZMath.min(_amount, maxDeposit);
        }

        if (depositAmount == 0) {
            if (_amount > 0) payable(registry().controller()).sendValue(_amount);
            return 0;
        }

        strategy.deposit{value: depositAmount}();
        emit FundsDepositedToStrategy(_strategy, depositAmount);

        uint256 remaining = _amount - depositAmount;
        if (remaining > 0) {
            payable(registry().controller()).sendValue(remaining);
        }
    }

    /**
     * @notice Withdraw from the strategies
     * @param _startIndex The start index (inclusive) of the strategies to withdraw from
     * @param _endIndex The end index (exclusive) of the strategies to withdraw from
     * @param _amount The amount of funds to withdraw from the strategies
     * @dev Range is [startIndex, endIndex), meaning strategies from startIndex up to but not including endIndex
     * @return totalWithdrawn The total ETH actually received by the controller (net of strategy fees)
     */
    function _withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        internal
        returns (uint256 totalWithdrawn)
    {
        uint256 strategiesAmount = _endIndex - _startIndex;

        uint256 cumulativeWithdrawalWeight;
        uint8[] memory withdrawalWeights = new uint8[](strategiesAmount);
        uint256[] memory maxWithdrawals = new uint256[](strategiesAmount);

        for (uint256 i; i < strategiesAmount; ++i) {
            IStrategy strategy = IStrategy(_strategies.at(i + _startIndex));

            uint256 maxWithdrawal = strategy.maxWithdrawal();

            if (maxWithdrawal > 0) {
                maxWithdrawals[i] = maxWithdrawal;

                withdrawalWeights[i] = withdrawalWeight[address(strategy)];
                cumulativeWithdrawalWeight += withdrawalWeights[i];
            }
        }

        if (cumulativeWithdrawalWeight == 0) return 0;

        uint256[] memory amountsToWithdraw = new uint256[](strategiesAmount);
        address[] memory withdrawingStrategies = new address[](strategiesAmount);
        uint256 withdrawingCount;

        for (uint256 i; i < strategiesAmount; ++i) {
            uint256 amountToWithdraw =
                OZMath.min(_amount * withdrawalWeights[i] / cumulativeWithdrawalWeight, maxWithdrawals[i]);
            amountsToWithdraw[i] = amountToWithdraw;
            if (amountToWithdraw > 0) {
                withdrawingStrategies[withdrawingCount] = _strategies.at(i + _startIndex);
                unchecked {
                    ++withdrawingCount;
                }
            }
        }

        _harvestPerformanceFeesFor(withdrawingStrategies, withdrawingCount);

        address controller = registry().controller();
        for (uint256 i; i < strategiesAmount; ++i) {
            uint256 amountToWithdraw = amountsToWithdraw[i];
            if (amountToWithdraw == 0) continue;

            address strategy = _strategies.at(i + _startIndex);

            uint256 balanceBefore = controller.balance;
            try IStrategy(strategy).withdraw(controller, amountToWithdraw) {
                uint256 withdrawn = controller.balance - balanceBefore;
                totalWithdrawn += withdrawn;

                // Start the deposit cooldown window for this strategy (see strategyDepositCooldown)
                lastStrategyWithdrawal[strategy] = block.timestamp;

                emit FundsWithdrawnFromStrategy(strategy, withdrawn);
            } catch (bytes memory reason) {
                emit StrategyWithdrawFailed(strategy, reason);
            }
        }
    }

    /**
     * @notice Withdraw funds from a strategy
     * @param _strategy The strategy address
     * @param _amount The amount of funds to withdraw
     * @return withdrawalAmount The ETH actually received by the controller (net of strategy fees)
     */
    function _withdrawFromStrategy(address _strategy, uint256 _amount) internal returns (uint256 withdrawalAmount) {
        IStrategy strategy = IStrategy(_strategy);
        uint256 amountToWithdraw = OZMath.min(_amount, strategy.maxWithdrawal());
        if (amountToWithdraw == 0) return 0;

        // Harvest any accrued performance fees before withdrawal
        _harvestPerformanceFeeFromStrategy(_strategy);

        // Account for the ETH actually delivered to the Controller via a balance delta,
        // net of any strategy-retained fees, mirroring the Converter's adapter accounting.
        address controller = registry().controller();
        uint256 balanceBefore = controller.balance;
        strategy.withdraw(controller, amountToWithdraw);
        withdrawalAmount = controller.balance - balanceBefore;

        // Start the deposit cooldown window for this strategy (see strategyDepositCooldown)
        lastStrategyWithdrawal[_strategy] = block.timestamp;

        emit FundsWithdrawnFromStrategy(_strategy, withdrawalAmount);
    }

    /**
     * @notice Check and rebalance strategies in a range
     * @param _startIndex The start index of the strategies to check and rebalance
     * @param _endIndex The end index of the strategies to check and rebalance
     */
    function _checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex) internal {
        for (uint256 i = _startIndex; i < _endIndex; ++i) {
            IStrategy strategy = IStrategy(_strategies.at(i));
            if (!strategy.paused() && !strategy.isHealthy()) {
                try strategy.rebalance() {
                    emit StrategyRebalanced(address(strategy));
                } catch (bytes memory reason) {
                    emit StrategyRebalanceFailed(address(strategy), reason);
                }
            }
        }
    }

    /**
     * @notice Check and rebalance strategy if it's not healthy
     * @param _strategy The strategy address
     * @dev No-op when the strategy is paused.
     */
    function _checkAndRebalanceStrategy(address _strategy) internal {
        IStrategy strategy = IStrategy(_strategy);
        if (!strategy.paused() && !strategy.isHealthy()) {
            strategy.rebalance();
            emit StrategyRebalanced(address(strategy));
        }
    }

    /**
     * @notice Sync strategies in a range
     * @param _startIndex The start index of the strategies to sync
     * @param _endIndex The end index of the strategies to sync
     * @dev Range is [startIndex, endIndex). Delegates to each strategy's `sync()`.
     *      Batch path: wraps each `sync()` in `try/catch` — emits `StrategySyncFailed` and
     *      continues on failure. Skips paused strategies.
     */
    function _syncStrategies(uint256 _startIndex, uint256 _endIndex) internal {
        for (uint256 i = _startIndex; i < _endIndex; ++i) {
            address strategy = _strategies.at(i);
            if (IStrategy(strategy).paused()) continue;

            try IStrategy(strategy).sync() {
                emit StrategySynced(strategy);
            } catch (bytes memory reason) {
                emit StrategySyncFailed(strategy, reason);
            }
        }
    }

    /**
     * @notice Sync a strategy
     * @param _strategy The strategy address
     * @dev Delegates to `IStrategy.sync()`. No-op when the strategy is paused.
     *      Strict: reverts if `sync()` fails.
     */
    function _syncStrategy(address _strategy) internal {
        if (IStrategy(_strategy).paused()) return;

        IStrategy(_strategy).sync();
        emit StrategySynced(_strategy);
    }

    /**
     * @notice Authorize an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyAuthRole(Auth.ADMIN_ROLE) {}

    // ============ Storage Gap ============
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[40] private __gap;
}
