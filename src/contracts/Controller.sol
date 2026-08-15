// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {Math} from "../libraries/Math.sol";

import {RegistryClientUpgradeable} from "registry/client/RegistryClientUpgradeable.sol";

import {Auth} from "../libraries/Auth.sol";

import {IController} from "../interfaces/IController.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";
import {IRegistry} from "interfaces/IRegistry.sol";

import {AMM} from "../contracts/AMM.sol";
import {ExitQueue} from "../contracts/ExitQueue.sol";

/**
 * @title Controller
 * @notice Upgradeable controller contract using UUPS pattern
 * @dev Peer contract addresses are resolved from the Registry at call time.
 */
contract Controller is
    IController,
    Initializable,
    UUPSUpgradeable,
    RegistryClientUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Address for address payable;

    using Math for uint256;
    using Auth for IRegistry;

    // ============ Constructor ============

    /**
     * @notice Constructor that disables initialization of the implementation contract
     * @dev This prevents the implementation contract from being initialized
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Receive Function ============

    /**
     * @notice Receive function to allow the contract to receive native ETH
     */
    receive() external payable {}

    // ============ Initialization ============

    /**
     * @notice Initializes the controller contract
     * @param _registry The protocol Registry (role authority and contract addresses)
     */
    function initialize(address _registry) public initializer {
        __UUPSUpgradeable_init();
        __RegistryClient_init(_registry);
        __Pausable_init();
        __ReentrancyGuard_init();

        emit ControllerInitialized(_registry);
    }

    // ============ Liquidity Provisioning ============

    /**
     * @inheritdoc IController
     */
    function provideExitLiquidity(uint256 _amount)
        external
        override
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (_amount == 0) revert ControllerZeroAmountRequested();
        if (_amount > address(this).balance) revert ControllerInsufficientBalance();
        payable(registry().amm()).sendValue(_amount);
        emit ExitLiquidityProvided(_amount);
    }

    // ============ Emergency Functions ============

    /**
     * @inheritdoc IController
     */
    function emergencyExitToAMM()
        external
        override
        onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE)
        nonReentrant
    {
        uint256 amount = address(this).balance;
        if (amount == 0) revert ControllerZeroAmountRequested();

        payable(registry().amm()).sendValue(amount);
        emit EmergencyExitedToAMM(amount);
    }

    /**
     * @notice Pauses the contract
     */
    function pause() external override onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external override onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Returns the version of the contract
     * @return string The version number
     */
    function version() public pure virtual override returns (string memory) {
        return "1.0.0";
    }

    // ============ Strategy Management ============

    /**
     * @inheritdoc IController
     */
    function depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _validateDeposit(_amount);

        _fundStrategyManagerIfNeeded(_amount);
        uint256 actualDeposited =
            IStrategyManager(payable(registry().strategyManager())).depositToStrategies(_startIndex, _endIndex, _amount);

        emit DepositToStrategiesCompleted(_amount, actualDeposited);
    }

    /**
     * @inheritdoc IController
     */
    function depositToStrategies(uint256 _amount) external onlyAuthRole(Auth.KEEPER_ROLE) whenNotPaused nonReentrant {
        _validateDeposit(_amount);

        _fundStrategyManagerIfNeeded(_amount);
        uint256 actualDeposited = IStrategyManager(payable(registry().strategyManager())).depositToStrategies(_amount);

        emit DepositToStrategiesCompleted(_amount, actualDeposited);
    }

    /**
     * @inheritdoc IController
     */
    function depositToStrategy(address _strategy, uint256 _amount)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _validateDeposit(_amount);

        _fundStrategyManagerIfNeeded(_amount);
        uint256 actualDeposited =
            IStrategyManager(payable(registry().strategyManager())).depositToStrategy(_strategy, _amount);

        emit DirectDepositCompleted(_strategy, _amount, actualDeposited);
    }

    /**
     * @inheritdoc IController
     */
    function withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _validateWithdrawalAmount(_amount);
        uint256 actualWithdrawn = IStrategyManager(payable(registry().strategyManager())).withdrawFromStrategies(
            _startIndex, _endIndex, _amount
        );
        emit WithdrawalCompleted(_amount, actualWithdrawn);
    }

    /**
     * @inheritdoc IController
     */
    function withdrawFromStrategies(uint256 _amount)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _validateWithdrawalAmount(_amount);
        uint256 actualWithdrawn =
            IStrategyManager(payable(registry().strategyManager())).withdrawFromStrategies(_amount);
        emit WithdrawalCompleted(_amount, actualWithdrawn);
    }

    /**
     * @inheritdoc IController
     */
    function withdrawFromStrategy(address _strategy, uint256 _amount)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _validateWithdrawalAmount(_amount);
        uint256 actualWithdrawn =
            IStrategyManager(payable(registry().strategyManager())).withdrawFromStrategy(_strategy, _amount);
        emit DirectWithdrawalCompleted(_strategy, _amount, actualWithdrawn);
    }

    /**
     * @inheritdoc IController
     */
    function checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        IStrategyManager(payable(registry().strategyManager())).checkAndRebalanceStrategies(_startIndex, _endIndex);
    }

    /**
     * @inheritdoc IController
     */
    function checkAndRebalanceStrategies() external onlyAuthRole(Auth.KEEPER_ROLE) whenNotPaused nonReentrant {
        IStrategyManager(payable(registry().strategyManager())).checkAndRebalanceStrategies();
    }

    /**
     * @inheritdoc IController
     */
    function checkAndRebalanceStrategy(address _strategy)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        IStrategyManager(payable(registry().strategyManager())).checkAndRebalanceStrategy(_strategy);
    }

    /**
     * @inheritdoc IController
     */
    function syncStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        IStrategyManager(payable(registry().strategyManager())).syncStrategies(_startIndex, _endIndex);
    }

    /**
     * @inheritdoc IController
     */
    function syncStrategies() external onlyAuthRole(Auth.KEEPER_ROLE) whenNotPaused nonReentrant {
        IStrategyManager(payable(registry().strategyManager())).syncStrategies();
    }

    /**
     * @inheritdoc IController
     */
    function syncStrategy(address _strategy) external onlyAuthRole(Auth.KEEPER_ROLE) whenNotPaused nonReentrant {
        IStrategyManager(payable(registry().strategyManager())).syncStrategy(_strategy);
    }

    /**
     * @inheritdoc IController
     */
    function harvestPerformanceFeeFromStrategy(address _strategy)
        external
        onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        (uint256 eveAmount, uint256 feeETHEquivalent) =
            IStrategyManager(payable(registry().strategyManager())).harvestPerformanceFeeFromStrategy(_strategy);
        emit DirectPerformanceFeeHarvestCompleted(_strategy, eveAmount, feeETHEquivalent);
    }

    /**
     * @inheritdoc IController
     */
    function harvestPerformanceFeeFromStrategies()
        external
        onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        IStrategyManager strategyManager_ = IStrategyManager(payable(registry().strategyManager()));
        uint256 endIndex = strategyManager_.strategyCount();
        (uint256 eveAmount, uint256 feeETHEquivalent) = strategyManager_.harvestPerformanceFeeFromStrategies();
        emit PerformanceFeeHarvestCompleted(0, endIndex, eveAmount, feeETHEquivalent);
    }

    /**
     * @inheritdoc IController
     */
    function harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex)
        external
        onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        (uint256 eveAmount, uint256 feeETHEquivalent) = IStrategyManager(payable(registry().strategyManager()))
            .harvestPerformanceFeeFromStrategies(_startIndex, _endIndex);
        emit PerformanceFeeHarvestCompleted(_startIndex, _endIndex, eveAmount, feeETHEquivalent);
    }

    /**
     * @inheritdoc IController
     */
    function priceBatch() external onlyAuthRole(Auth.KEEPER_ROLE) whenNotPaused nonReentrant {
        IRegistry registry_ = registry();
        // Batches settle at the same price as immediate exit(): the live base price
        // (NAV−L) / (supply−escrow). This batch is still equity at the moment of the
        // read; already-priced in-window batches are already deducted.
        ExitQueue(payable(registry_.exitQueue())).priceBatch(AMM(payable(registry_.amm())).eveBasePriceInETH());
    }

    /**
     * @inheritdoc IController
     */
    function processRequests(uint256 _batchId, uint256 _startIndex, uint256 _endIndex)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _processRequests(_batchId, _startIndex, _endIndex);
    }

    /**
     * @inheritdoc IController
     */
    function processRequests(uint256 _batchId) external onlyAuthRole(Auth.KEEPER_ROLE) whenNotPaused nonReentrant {
        ExitQueue exitQueue = ExitQueue(payable(registry().exitQueue()));
        _processRequests(_batchId, 0, exitQueue.unprocessedUsersCount(_batchId));
    }

    /**
     * @inheritdoc IController
     */
    function processRequest(uint256 _batchId, address _user)
        external
        onlyAuthRole(Auth.KEEPER_ROLE)
        whenNotPaused
        nonReentrant
    {
        (, uint256 finalEvePrice,,,) = ExitQueue(payable(registry().exitQueue())).batchInfo(_batchId);
        _processRequest(finalEvePrice, _batchId, _user);
    }

    // ============ Internal Functions ============

    /**
     * @notice Check if the withdrawal is valid
     * @param _amount The amount of ETH to withdraw
     */
    function _validateWithdrawalAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert ControllerZeroAmountRequested();
    }

    /**
     * @notice Check if the deposit is valid
     * @param _amount The amount of ETH to deposit
     */
    function _validateDeposit(uint256 _amount) internal view {
        if (_amount == 0) revert ControllerZeroAmountRequested();

        uint256 strategyManagerBalance = payable(registry().strategyManager()).balance;
        uint256 toSend = _amount > strategyManagerBalance ? _amount - strategyManagerBalance : 0;
        if (address(this).balance < toSend) revert ControllerInsufficientBalance();
    }

    /**
     * @notice Fund the Strategy Manager if needed
     * @param _targetAmount The target amount of ETH to fund the Strategy Manager with
     */
    function _fundStrategyManagerIfNeeded(uint256 _targetAmount) internal {
        IRegistry registry_ = registry();

        address strategyManager = payable(registry_.strategyManager());
        uint256 strategyManagerBalance = strategyManager.balance;

        uint256 toSend = _targetAmount > strategyManagerBalance ? _targetAmount - strategyManagerBalance : 0;
        if (toSend > 0) {
            payable(registry_.strategyManager()).sendValue(toSend);
        }
    }

    /**
     * @notice Processes redemption requests from a batch in the given range
     * in the exit queue.
     * @param _batchId The ID of the batch
     * @param _startIndex The start index (inclusive) of the users to process
     * @param _endIndex The end index (exclusive) of the users to process
     * @dev Range is [startIndex, endIndex), meaning users from startIndex up to but not including endIndex
     */
    function _processRequests(uint256 _batchId, uint256 _startIndex, uint256 _endIndex) internal {
        ExitQueue exitQueue = ExitQueue(registry().exitQueue());
        address[] memory users = exitQueue.unprocessedUsers(_batchId, _startIndex, _endIndex);

        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(_batchId);

        for (uint256 i = 0; i < users.length; i++) {
            _processRequest(finalEvePrice, _batchId, users[i]);
        }
    }

    /**
     * @notice Processes a redemption request from a batch
     * @param _finalEvePrice The final EVE price in the given batch
     * @param _batchId The ID of the batch
     * @param _user The address of the user
     */
    function _processRequest(uint256 _finalEvePrice, uint256 _batchId, address _user) internal {
        IRegistry registry_ = registry();

        ExitQueue exitQueue = ExitQueue(registry_.exitQueue());
        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(_batchId, _user);

        uint256 ethToRedeem = (_finalEvePrice.isRelativelyLessThan(evePriceAtRequestTime, priceTolerance))
            ? 0
            : Math.convertAssets(tokensToBurn, _finalEvePrice);

        if (address(this).balance < ethToRedeem) revert ControllerInsufficientBalance();

        AMM(payable(registry_.amm())).processRedemption{value: ethToRedeem}(_batchId, _user);
    }

    // ============ Upgrade Functions ============

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only addresses with ADMIN_ROLE (held by the admin timelock in production)
     *      can authorize upgrades
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyAuthRole(Auth.ADMIN_ROLE) {}

    /**
     * @dev Storage gap for future upgrades
     * This allows adding new state variables without shifting down
     * storage in the inheritance chain.
     */
    uint256[50] private __gap;
}
