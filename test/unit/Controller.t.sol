// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IController} from "../../src/interfaces/IController.sol";
import {IExitQueue} from "../../src/interfaces/IExitQueue.sol";

import {Controller} from "../../src/contracts/Controller.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {IRegistry} from "interfaces/IRegistry.sol";
import {StrategyManager} from "../../src/contracts/StrategyManager.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockAMMStub} from "../mocks/MockAMMStub.sol";
import {MockReentrantAMM} from "../mocks/MockReentrantAMM.sol";
import {MockStrategyManagerStub} from "../mocks/MockStrategyManagerStub.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";

/**
 * @title ControllerTest
 * @notice Comprehensive test suite for Controller contract
 */
contract ControllerTest is ProtocolTestBase {
    Controller public implementation;
    Controller public controller;
    ExitQueue public exitQueue;
    Registry public registry;
    EVE public token;
    StrategyManager public strategyManager;
    AMM public amm;
    Oracle public oracle;
    MockStrategy public mockStrategy1;
    MockStrategy public mockStrategy2;
    MockAMMStub public ammStub;

    address public owner;
    address public user;
    address public newOwner;

    // Test amounts
    uint256 public constant MINT_AMOUNT = 100;
    uint256 public constant LIQUIDITY_AMOUNT = 500;
    uint256 public constant LIQUIDITY_AMOUNT_ZERO = 0;

    event Upgraded(address indexed implementation);

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        newOwner = address(0x2);

        ProtocolContracts memory contracts = _deployProtocol(owner, 5e17);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        strategyManager = contracts.strategyManager;
        amm = contracts.amm;
        oracle = contracts.oracle;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(4000e8));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), 3600);

        implementation = new Controller();
        ammStub = new MockAMMStub();

        mockStrategy1 = new MockStrategy("Mock Strategy 1", address(controller), address(strategyManager));
        mockStrategy2 = new MockStrategy("Mock Strategy 2", address(controller), address(strategyManager));
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize() public view {
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, owner));
        assertTrue(registry.hasRole(Auth.KEEPER_ROLE, owner));
        assertEq(address(controller.registry()), address(registry));
        assertEq(controller.version(), "1.0.0");
    }

    function test_Initialize_EmitsControllerInitialized() public {
        Controller impl = new Controller();
        bytes memory initData = abi.encodeWithSelector(Controller.initialize.selector, address(registry));

        vm.expectEmit(true, false, false, true);
        emit IController.ControllerInitialized(address(registry));

        new ERC1967Proxy(address(impl), initData);
    }

    function test_InitializeCannotBeCalledTwice() public {
        vm.expectRevert();
        controller.initialize(address(registry));
    }

    function test_ImplementationIsDisabled() public {
        vm.expectRevert();
        implementation.initialize(address(registry));
    }

    /*//////////////////////////////////////////////////////////////
                         UPGRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AdminCanUpgrade() public {
        // Deploy a new implementation (V2)
        ControllerV2Mock newImplementation = new ControllerV2Mock();

        // Upgrade to new implementation
        controller.upgradeToAndCall(address(newImplementation), "");

        // Verify upgrade by calling new function
        ControllerV2Mock upgradedController = ControllerV2Mock(payable(controller));
        assertEq(upgradedController.version(), "2.0.0");
    }

    function test_NonAdminCannotUpgrade() public {
        ControllerV2Mock newImplementation = new ControllerV2Mock();

        vm.prank(user);
        vm.expectRevert();
        controller.upgradeToAndCall(address(newImplementation), "");
    }

    function test_UpgradePreservesState() public {
        registry.grantRole(Auth.ADMIN_ROLE, newOwner);

        bool hasAdminRoleBefore = registry.hasRole(Auth.ADMIN_ROLE, newOwner);

        // Deploy and upgrade
        ControllerV2Mock newImplementation = new ControllerV2Mock();
        vm.prank(newOwner);
        controller.upgradeToAndCall(address(newImplementation), "");

        // Verify state is preserved
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, newOwner));
        assertEq(hasAdminRoleBefore, true);
    }

    /*//////////////////////////////////////////////////////////////
                         PROXY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProxyPointsToImplementation() public view {
        bytes32 implementationSlot =
            vm.load(address(controller), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1));
        address proxyImplementation = address(uint160(uint256(implementationSlot)));

        assertNotEq(proxyImplementation, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_InitializeWithAnyAdmin(address anyAdmin) public {
        vm.assume(anyAdmin != address(0));

        Registry newRegistry = _deployRegistry(anyAdmin);
        Controller newImplementation = new Controller();
        bytes memory initData = abi.encodeWithSelector(Controller.initialize.selector, address(newRegistry));
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImplementation), initData);
        Controller newController = Controller(payable(newProxy));

        assertTrue(newRegistry.hasRole(Auth.ADMIN_ROLE, anyAdmin));
        assertEq(address(newController.registry()), address(newRegistry));
    }

    function testFuzz_OnlyAdminCanUpgrade(address caller) public {
        vm.assume(caller != owner);
        vm.assume(!registry.hasRole(Auth.ADMIN_ROLE, caller));

        ControllerV2Mock newImplementation = new ControllerV2Mock();

        vm.prank(caller);
        vm.expectRevert();
        controller.upgradeToAndCall(address(newImplementation), "");
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE/UNPAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AdminCanPause() public {
        assertFalse(controller.paused());

        controller.pause();

        assertTrue(controller.paused());
    }

    function test_AdminCanUnpause() public {
        controller.pause();
        assertTrue(controller.paused());

        controller.unpause();

        assertFalse(controller.paused());
    }

    function test_NonAdminCannotPause() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        controller.pause();
    }

    function test_Pause_SecurityCanPauseImmediately() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        controller.pause();

        assertTrue(controller.paused());
    }

    function test_SecurityCannotUnpause() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        controller.pause();

        // Recovery stays with ADMIN_ROLE (timelocked in production)
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        controller.unpause();
    }

    function test_NonAdminCannotUnpause() public {
        controller.pause();

        vm.prank(user);
        vm.expectRevert();
        controller.unpause();
    }

    function test_ProvideExitLiquidityFailsWhenPaused() public {
        controller.pause();

        vm.deal(address(controller), LIQUIDITY_AMOUNT);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.provideExitLiquidity(LIQUIDITY_AMOUNT);
    }

    function test_PriceBatch_WhenPaused_Reverts() public {
        controller.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        controller.priceBatch();
    }

    /*//////////////////////////////////////////////////////////////
                    PROCESS REQUESTS TESTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant QUEUE_ENTER_ETH = 1 ether;
    uint256 internal constant QUEUE_EXIT_ETH = 0.5 ether;
    uint256 internal constant QUEUE_MIN_TOKENS = 1;
    uint256 internal constant QUEUE_PRICE_TOLERANCE = 0;

    function test_ProcessRequests_NoOpWhenBatchEmpty() public {
        uint256 batchId = exitQueue.currentBatchId();
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);

        controller.processRequests(batchId);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_ProcessRequests_NoOpWhenAlreadySettled() public {
        vm.deal(user, QUEUE_ENTER_ETH);
        vm.prank(user);
        amm.enter{value: QUEUE_ENTER_ETH}(QUEUE_MIN_TOKENS);

        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        uint256 batchId = amm.exit(QUEUE_EXIT_ETH, token.balanceOf(user), QUEUE_PRICE_TOLERANCE);
        vm.stopPrank();

        assertGt(batchId, 0);
        controller.priceBatch();
        controller.processRequests(batchId);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);

        // Second call is a keeper race against an already-settled batch — no-op, not InvalidRange.
        controller.processRequests(batchId);
        (bool processed,,,,) = exitQueue.requestInfo(batchId, user);
        assertTrue(processed);
    }

    function test_ProcessRequests_RangedEmptyReverts() public {
        uint256 batchId = exitQueue.currentBatchId();
        vm.expectRevert(IExitQueue.ExitQueueInvalidRange.selector);
        controller.processRequests(batchId, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDITY PROVISIONING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProvideExitLiquidity() public {
        vm.deal(address(controller), LIQUIDITY_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit IController.ExitLiquidityProvided(LIQUIDITY_AMOUNT);
        controller.provideExitLiquidity(LIQUIDITY_AMOUNT);

        assertEq(address(controller).balance, 0);
        assertEq(address(amm).balance, LIQUIDITY_AMOUNT);
    }

    function test_ProvideExitLiquidity_ZeroAmount() public {
        vm.expectRevert(IController.ControllerZeroAmountRequested.selector);
        controller.provideExitLiquidity(LIQUIDITY_AMOUNT_ZERO);
    }

    function test_ProvideExitLiquidity_InsufficientBalance() public {
        vm.deal(address(controller), LIQUIDITY_AMOUNT - 1);

        vm.expectRevert(IController.ControllerInsufficientBalance.selector);
        controller.provideExitLiquidity(LIQUIDITY_AMOUNT);
    }

    function test_ProvideExitLiquidity_AMMNotSet() public {
        Controller freshController = _deployControllerWithoutAMM();
        vm.deal(address(freshController), LIQUIDITY_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        freshController.provideExitLiquidity(LIQUIDITY_AMOUNT);
    }

    function test_NonKeeperCannotProvideExitLiquidity() public {
        vm.deal(address(controller), LIQUIDITY_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.KEEPER_ROLE));
        vm.prank(user);
        controller.provideExitLiquidity(LIQUIDITY_AMOUNT);
    }

    function test_ProvideExitLiquidity_Reentrancy() public {
        MockReentrantAMM reentrantAMM = _wireReentrantAMM();
        reentrantAMM.arm(abi.encodeWithSelector(IController.provideExitLiquidity.selector, 1));

        vm.deal(address(controller), LIQUIDITY_AMOUNT);
        controller.provideExitLiquidity(LIQUIDITY_AMOUNT);

        // The reentrant call was attempted and rejected by the nonReentrant guard,
        // while the outer call still completed successfully.
        assertTrue(reentrantAMM.reentryReverted());
        assertEq(reentrantAMM.lastRevertSelector(), ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        assertEq(address(reentrantAMM).balance, LIQUIDITY_AMOUNT);
    }

    function test_KeeperCanProvideExitLiquidity() public {
        vm.deal(address(controller), LIQUIDITY_AMOUNT);

        registry.grantRole(Auth.KEEPER_ROLE, user);

        vm.prank(user);
        controller.provideExitLiquidity(LIQUIDITY_AMOUNT);

        assertEq(address(amm).balance, LIQUIDITY_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    EMERGENCY EXIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EmergencyExitToAMM() public {
        vm.deal(address(controller), LIQUIDITY_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit IController.EmergencyExitedToAMM(LIQUIDITY_AMOUNT);
        controller.emergencyExitToAMM();

        assertEq(address(controller).balance, 0);
        assertEq(address(amm).balance, LIQUIDITY_AMOUNT);
    }

    function test_EmergencyExitToAMM_ZeroBalance() public {
        vm.expectRevert(IController.ControllerZeroAmountRequested.selector);
        controller.emergencyExitToAMM();
    }

    function test_EmergencyExitToAMM_AMMNotSet() public {
        Controller freshController = _deployControllerWithoutAMM();
        vm.deal(address(freshController), LIQUIDITY_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        freshController.emergencyExitToAMM();
    }

    function test_EmergencyExitToAMM_WhenPaused() public {
        vm.deal(address(controller), LIQUIDITY_AMOUNT);
        controller.pause();

        controller.emergencyExitToAMM();

        assertEq(address(controller).balance, 0);
        assertEq(address(amm).balance, LIQUIDITY_AMOUNT);
    }

    function test_EmergencyExitToAMM_Reentrancy() public {
        MockReentrantAMM reentrantAMM = _wireReentrantAMM();
        reentrantAMM.arm(abi.encodeWithSelector(IController.emergencyExitToAMM.selector));

        vm.deal(address(controller), LIQUIDITY_AMOUNT);
        controller.emergencyExitToAMM();

        // The reentrant call was attempted and rejected by the nonReentrant guard,
        // while the outer call still completed successfully.
        assertTrue(reentrantAMM.reentryReverted());
        assertEq(reentrantAMM.lastRevertSelector(), ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        assertEq(address(reentrantAMM).balance, LIQUIDITY_AMOUNT);
    }

    function test_NonAdminCannotEmergencyExitToAMM() public {
        vm.deal(address(controller), LIQUIDITY_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        vm.prank(user);
        controller.emergencyExitToAMM();
    }

    /*//////////////////////////////////////////////////////////////
                        REGISTRY ROLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AdminCanGrantAndRevokeRoles() public {
        registry.grantRole(Auth.ADMIN_ROLE, user);
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, user));

        registry.revokeRole(Auth.ADMIN_ROLE, user);
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, user));
    }

    function test_NonAdminCannotGrantOrRevokeRoles() public {
        vm.prank(user);
        vm.expectRevert();
        registry.grantRole(Auth.ADMIN_ROLE, user);

        registry.grantRole(Auth.ADMIN_ROLE, user);

        vm.prank(newOwner);
        vm.expectRevert();
        registry.revokeRole(Auth.ADMIN_ROLE, user);
    }

    function test_RegistryResolvesStrategyManager() public view {
        assertEq(registry.getContractByKey(Auth.STRATEGY_MANAGER), address(strategyManager));
    }

    function test_RegistryResolvesAMM() public view {
        assertEq(registry.getContractByKey(Auth.AMM), address(amm));
    }

    /*//////////////////////////////////////////////////////////////
                        KEEPER FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositToStrategies() public {
        // Add strategies
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);

        // Fund Controller
        uint256 amount = 14 ether; // Amount that avoids rounding with 2 strategies (80+60=140)
        vm.deal(address(controller), amount);

        // Expect event
        vm.expectEmit(true, false, false, true);
        emit IController.DepositToStrategiesCompleted(amount, amount);

        // Distribute funds
        controller.depositToStrategies(amount);

        // Verify funds were distributed to strategies
        uint256 totalInStrategies = address(mockStrategy1).balance + address(mockStrategy2).balance;
        assertGt(totalInStrategies, 0);
        // Controller balance should be zero or have remainder due to rounding
        assertLe(address(controller).balance, amount);
    }

    function test_DepositToStrategies_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(controller), 1 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.depositToStrategies(1 ether);
    }

    function test_DepositToStrategies_InvalidInputs() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        // Zero amount
        vm.deal(address(controller), 1 ether);
        vm.expectRevert();
        controller.depositToStrategies(0);

        // Insufficient balance: _validateDeposit checks controller.balance >= deficit.
        // When SM is empty the deficit equals _amount, so 0.5 ETH < 1 ETH reverts.
        vm.deal(address(controller), 0.5 ether);
        vm.expectRevert(IController.ControllerInsufficientBalance.selector);
        controller.depositToStrategies(1 ether);

        // When SM already holds part of _amount, only the deficit matters.
        // Give SM 0.7 ETH so deficit = 0.3 ETH; Controller's 0.5 ETH is sufficient.
        vm.deal(address(strategyManager), 0.7 ether);
        vm.deal(address(controller), 0.3 ether);
        mockStrategy1.setMaxDeposit(1 ether);
        // This should not revert (deficit = 0.3 ETH == controller balance)
        controller.depositToStrategies(1 ether);
    }

    function test_DepositToStrategies_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(controller), 1 ether);
        controller.pause();

        vm.expectRevert();
        controller.depositToStrategies(1 ether);
    }

    function test_DepositToStrategies_TopsUpSMToExactAmount() public {
        // _validateDeposit checks controller.balance >= deficit (not full _amount),
        // so Controller only needs to hold the difference between _amount and any
        // pre-existing SM balance.  _fundStrategyManagerIfNeeded then sends exactly
        // that deficit so SM ends up with exactly _amount before the inner distribute.
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        mockStrategy1.setMaxDeposit(10 ether);

        uint256 preExisting = 3 ether;
        uint256 distributeAmount = 10 ether;
        uint256 deficit = distributeAmount - preExisting; // 7 ether

        vm.deal(address(strategyManager), preExisting);
        vm.deal(address(controller), deficit); // only the deficit is needed

        controller.depositToStrategies(distributeAmount);

        // Strategy got all 10 ETH; Controller and SM are both empty.
        assertEq(address(mockStrategy1).balance, distributeAmount);
        assertEq(address(strategyManager).balance, 0);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositToStrategies_Range_TopsUpSMToExactAmount() public {
        // Same deficit top-up behavior through the paginated keeper overload.
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);
        mockStrategy1.setMaxDeposit(10 ether);
        mockStrategy2.setMaxDeposit(10 ether);

        uint256 preExisting = 3 ether;
        uint256 distributeAmount = 14 ether;
        uint256 deficit = distributeAmount - preExisting;

        vm.deal(address(strategyManager), preExisting);
        vm.deal(address(controller), deficit);

        controller.depositToStrategies(0, 2, distributeAmount);

        assertEq(address(mockStrategy1).balance + address(mockStrategy2).balance, distributeAmount);
        assertEq(address(strategyManager).balance, 0);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositToStrategies_PreExistingSMBalanceCountedInNAV() public {
        // Pre-existing SM balance is included in totalNAVInETH before a distribute
        // call (the fix), then absorbed into the distribution, leaving NAV unchanged.
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        mockStrategy1.setNavInETH(0);
        mockStrategy1.setMaxDeposit(10 ether);

        uint256 preExisting = 2 ether;
        uint256 distributeAmount = 10 ether;
        uint256 deficit = distributeAmount - preExisting;

        vm.deal(address(strategyManager), preExisting);
        vm.deal(address(controller), deficit);

        // NAV before = 0 (strategy) + deficit (controller) + preExisting (SM) = 10 ETH
        uint256 navBefore = strategyManager.totalNAVInETH();

        controller.depositToStrategies(distributeAmount);

        // Real strategy implementations must update navInETH() inside deposit();
        // mock requires manual update here.
        mockStrategy1.setNavInETH(distributeAmount);

        uint256 navAfter = strategyManager.totalNAVInETH();
        assertEq(navAfter, navBefore);
        assertEq(address(strategyManager).balance, 0);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositToStrategy_TopsUpSMToExactAmount() public {
        // Same top-up behaviour for the single-strategy depositToStrategy path.
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        mockStrategy1.setMaxDeposit(5 ether);

        uint256 preExisting = 1 ether;
        uint256 depositAmount = 5 ether;
        uint256 deficit = depositAmount - preExisting;

        vm.deal(address(strategyManager), preExisting);
        vm.deal(address(controller), deficit); // only the deficit is needed

        controller.depositToStrategy(address(mockStrategy1), depositAmount);

        assertEq(address(mockStrategy1).balance, depositAmount);
        assertEq(address(strategyManager).balance, 0);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositToStrategy() public {
        // Add mock strategy
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        // Fund Controller
        uint256 amount = 1 ether;
        vm.deal(address(controller), amount);

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit IController.DirectDepositCompleted(address(mockStrategy1), amount, amount);

        // Deposit to strategy
        controller.depositToStrategy(address(mockStrategy1), amount);

        // Verify funds were deposited to strategy
        assertEq(address(mockStrategy1).balance, amount);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositToStrategy_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.deal(address(controller), 1 ether);
        controller.pause();

        vm.expectRevert();
        controller.depositToStrategy(address(mockStrategy1), 1 ether);
    }

    function test_DepositToStrategy_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.deal(address(controller), 1 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.depositToStrategy(address(mockStrategy1), 1 ether);
    }

    function test_WithdrawFromStrategies() public {
        // Add strategies and fund them
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);
        vm.deal(address(mockStrategy1), 7 ether);
        vm.deal(address(mockStrategy2), 5 ether);

        uint256 amount = 12 ether;
        uint256 initialControllerBalance = address(controller).balance;

        // Expect event
        vm.expectEmit(true, false, false, true);
        emit IController.WithdrawalCompleted(amount, amount);

        // Withdraw from strategies
        controller.withdrawFromStrategies(amount);

        // Controller should receive funds
        assertGt(address(controller).balance, initialControllerBalance);
    }

    function test_WithdrawFromStrategies_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.withdrawFromStrategies(1 ether);
    }

    function test_WithdrawFromStrategies_InvalidInputs() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        // Zero amount
        vm.expectRevert();
        controller.withdrawFromStrategies(0);
    }

    function test_WithdrawFromStrategies_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);
        controller.pause();

        vm.expectRevert();
        controller.withdrawFromStrategies(1 ether);
    }

    function test_WithdrawFromStrategy() public {
        // Add mock strategy and fund it
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);

        uint256 amount = 3 ether;

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit IController.DirectWithdrawalCompleted(address(mockStrategy1), amount, amount);

        uint256 initialControllerBalance = address(controller).balance;

        // Withdraw from strategy
        controller.withdrawFromStrategy(address(mockStrategy1), amount);

        // Controller should receive funds
        assertEq(address(controller).balance, initialControllerBalance + amount);
        assertEq(address(mockStrategy1).balance, 2 ether);
    }

    function test_WithdrawFromStrategy_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.withdrawFromStrategy(address(mockStrategy1), 1 ether);
    }

    function test_WithdrawFromStrategy_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);
        controller.pause();

        vm.expectRevert();
        controller.withdrawFromStrategy(address(mockStrategy1), 1 ether);
    }

    function test_CheckAndRebalanceStrategies() public {
        // Add strategies
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);

        // Make strategies unhealthy
        mockStrategy1.setIsHealthy(false);
        mockStrategy2.setIsHealthy(false);

        // Rebalance all strategies
        controller.checkAndRebalanceStrategies();

        // Strategies should be healthy after rebalance
        assertTrue(mockStrategy1.isHealthy());
        assertTrue(mockStrategy2.isHealthy());
    }

    function test_CheckAndRebalanceStrategies_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.prank(user);
        vm.expectRevert();
        controller.checkAndRebalanceStrategies();
    }

    function test_CheckAndRebalanceStrategies_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        controller.pause();

        vm.expectRevert();
        controller.checkAndRebalanceStrategies();
    }

    function test_CheckAndRebalanceStrategy() public {
        // Add strategy and make it unhealthy
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        mockStrategy1.setIsHealthy(false);

        // Rebalance strategy
        controller.checkAndRebalanceStrategy(address(mockStrategy1));

        // Strategy should be healthy after rebalance
        assertTrue(mockStrategy1.isHealthy());
    }

    function test_CheckAndRebalanceStrategy_InvalidInputs() public {
        // Zero address
        vm.expectRevert();
        controller.checkAndRebalanceStrategy(address(0));
    }

    function test_CheckAndRebalanceStrategy_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.prank(user);
        vm.expectRevert();
        controller.checkAndRebalanceStrategy(address(mockStrategy1));
    }

    function test_CheckAndRebalanceStrategy_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        controller.pause();

        vm.expectRevert();
        controller.checkAndRebalanceStrategy(address(mockStrategy1));
    }

    function test_SyncStrategies() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);

        controller.syncStrategies();
    }

    function test_SyncStrategies_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.prank(user);
        vm.expectRevert();
        controller.syncStrategies();
    }

    function test_SyncStrategies_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        controller.pause();

        vm.expectRevert();
        controller.syncStrategies();
    }

    function test_SyncStrategy() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        controller.syncStrategy(address(mockStrategy1));
    }

    function test_SyncStrategy_InvalidInputs() public {
        vm.expectRevert();
        controller.syncStrategy(address(0));
    }

    function test_SyncStrategy_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.prank(user);
        vm.expectRevert();
        controller.syncStrategy(address(mockStrategy1));
    }

    function test_SyncStrategy_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        controller.pause();

        vm.expectRevert();
        controller.syncStrategy(address(mockStrategy1));
    }

    function test_SyncStrategies_WithPagination() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);
        MockStrategy mockStrategy3 = new MockStrategy("Mock Strategy 3", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(mockStrategy3), 40, 30);

        controller.syncStrategies(0, 2);
    }

    function test_SyncStrategies_WithPagination_InvalidRange() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.expectRevert();
        controller.syncStrategies(0, 2);

        vm.expectRevert();
        controller.syncStrategies(1, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PERFORMANCE FEE HARVEST TESTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PERFORMANCE_FEE_BPS = 2000;
    address internal constant DAO_TREASURY = address(0xdead);
    uint256 internal constant LP_FEE_BASE_1 = 0.5e18;
    uint256 internal constant LP_FEE_BASE_2 = 1e18;

    function _configurePerformanceFees() internal {
        strategyManager.setDaoTreasury(DAO_TREASURY);
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);
        registry.grantRole(Auth.MINTER_ROLE, address(strategyManager));
    }

    function _accrueMockLpFees(MockStrategy _strategy, uint256 _unchargedBase) internal {
        _strategy.setUnchargedLpFeeBaseInETH(_unchargedBase);
    }

    function test_HarvestPerformanceFeeFromStrategy() public {
        amm.enter{value: 1 ether}(1);
        _configurePerformanceFees();
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);

        uint256 feeETH = strategyManager.pendingPerformanceFeeInETH(address(mockStrategy1));
        uint256 supply = token.totalSupply();
        uint256 totalNAV = strategyManager.totalNAVInETH();
        uint256 expectedEves = (feeETH * supply) / (totalNAV - feeETH);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        vm.expectEmit(true, true, false, true);
        emit IController.DirectPerformanceFeeHarvestCompleted(address(mockStrategy1), expectedEves, feeETH);
        controller.harvestPerformanceFeeFromStrategy(address(mockStrategy1));
        assertEq(token.balanceOf(DAO_TREASURY) - treasuryBefore, expectedEves);
        assertEq(strategyManager.pendingPerformanceFeeInETH(address(mockStrategy1)), 0);
    }

    function test_HarvestPerformanceFeeFromStrategies() public {
        amm.enter{value: 1 ether}(1);
        _configurePerformanceFees();
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);
        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);
        _accrueMockLpFees(mockStrategy2, LP_FEE_BASE_2);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        controller.harvestPerformanceFeeFromStrategies();
        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(address(mockStrategy1)), 0);
        assertEq(strategyManager.pendingPerformanceFeeInETH(address(mockStrategy2)), 0);
    }

    function test_HarvestPerformanceFeeFromStrategy_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.prank(user);
        vm.expectRevert();
        controller.harvestPerformanceFeeFromStrategy(address(mockStrategy1));
    }

    function test_HarvestPerformanceFeeFromStrategy_AdminCanHarvest() public {
        amm.enter{value: 1 ether}(1);
        _configurePerformanceFees();
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        _accrueMockLpFees(mockStrategy1, LP_FEE_BASE_1);

        uint256 treasuryBefore = token.balanceOf(DAO_TREASURY);
        controller.harvestPerformanceFeeFromStrategy(address(mockStrategy1));
        assertGt(token.balanceOf(DAO_TREASURY), treasuryBefore);
    }

    function test_HarvestPerformanceFeeFromStrategy_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        controller.pause();

        vm.expectRevert();
        controller.harvestPerformanceFeeFromStrategy(address(mockStrategy1));
    }

    /*//////////////////////////////////////////////////////////////
                        PAGINATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositToStrategies_WithPagination() public {
        // Add multiple strategies
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);
        MockStrategy mockStrategy3 = new MockStrategy("Mock Strategy 3", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(mockStrategy3), 40, 30);

        // Fund Controller
        uint256 amount = 18 ether;
        vm.deal(address(controller), amount);

        // Distribute to first two strategies only (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        controller.depositToStrategies(0, 2, amount);

        // Verify funds were distributed to first two strategies
        uint256 totalInFirstTwo = address(mockStrategy1).balance + address(mockStrategy2).balance;
        assertGt(totalInFirstTwo, 0);
        assertEq(address(mockStrategy3).balance, 0); // Third strategy should not receive funds
    }

    function test_DepositToStrategies_WithPagination_InvalidRange() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(controller), 1 ether);

        // Invalid range: endIndex > strategies.length (with only 1 strategy, endIndex must be <= 1)
        // endIndex = 1 is valid (processes [0, 1) = index 0), but endIndex = 2 is invalid
        vm.expectRevert();
        controller.depositToStrategies(0, 2, 1 ether);

        // Invalid range: startIndex > endIndex
        vm.expectRevert();
        controller.depositToStrategies(1, 0, 1 ether);
    }

    function test_DepositToStrategies_WithPagination_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(controller), 1 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.depositToStrategies(0, 0, 1 ether);
    }

    function test_DepositToStrategies_WithPagination_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(controller), 1 ether);
        controller.pause();

        vm.expectRevert();
        controller.depositToStrategies(0, 0, 1 ether);
    }

    function test_WithdrawFromStrategies_WithPagination() public {
        // Add multiple strategies and fund them
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);
        MockStrategy mockStrategy3 = new MockStrategy("Mock Strategy 3", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(mockStrategy3), 40, 30);

        vm.deal(address(mockStrategy1), 7 ether);
        vm.deal(address(mockStrategy2), 5 ether);
        vm.deal(address(mockStrategy3), 4 ether);

        uint256 amount = 12 ether;
        uint256 initialControllerBalance = address(controller).balance;

        // Withdraw from first two strategies only (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        controller.withdrawFromStrategies(0, 2, amount);

        // Controller should receive funds
        assertGt(address(controller).balance, initialControllerBalance);
        // Third strategy should not be withdrawn from
        assertEq(address(mockStrategy3).balance, 4 ether);
    }

    function test_WithdrawFromStrategies_WithPagination_InvalidRange() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);

        // Invalid range: endIndex > strategies.length (with only 1 strategy, endIndex must be <= 1)
        // endIndex = 1 is valid (processes [0, 1) = index 0), but endIndex = 2 is invalid
        vm.expectRevert();
        controller.withdrawFromStrategies(0, 2, 1 ether);

        // Invalid range: startIndex > endIndex
        vm.expectRevert();
        controller.withdrawFromStrategies(1, 0, 1 ether);
    }

    function test_WithdrawFromStrategies_WithPagination_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.withdrawFromStrategies(0, 0, 1 ether);
    }

    function test_WithdrawFromStrategies_WithPagination_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        vm.deal(address(mockStrategy1), 5 ether);
        controller.pause();

        vm.expectRevert();
        controller.withdrawFromStrategies(0, 0, 1 ether);
    }

    function test_CheckAndRebalanceStrategies_WithPagination() public {
        // Add multiple strategies
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        strategyManager.addStrategy(address(mockStrategy2), 60, 50);
        MockStrategy mockStrategy3 = new MockStrategy("Mock Strategy 3", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(mockStrategy3), 40, 30);

        // Make strategies unhealthy
        mockStrategy1.setIsHealthy(false);
        mockStrategy2.setIsHealthy(false);
        mockStrategy3.setIsHealthy(false);

        // Rebalance only first two strategies (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        controller.checkAndRebalanceStrategies(0, 2);

        // First two strategies should be healthy after rebalance
        assertTrue(mockStrategy1.isHealthy());
        assertTrue(mockStrategy2.isHealthy());
        // Third strategy should still be unhealthy
        assertFalse(mockStrategy3.isHealthy());
    }

    function test_CheckAndRebalanceStrategies_WithPagination_InvalidRange() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        // Invalid range: endIndex > strategies.length (with only 1 strategy, endIndex must be <= 1)
        // endIndex = 1 is valid (processes [0, 1) = index 0), but endIndex = 2 is invalid
        vm.expectRevert();
        controller.checkAndRebalanceStrategies(0, 2);

        // Invalid range: startIndex > endIndex
        vm.expectRevert();
        controller.checkAndRebalanceStrategies(1, 0);
    }

    function test_CheckAndRebalanceStrategies_WithPagination_AccessControl() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);

        vm.prank(user);
        vm.expectRevert();
        controller.checkAndRebalanceStrategies(0, 0);
    }

    function test_CheckAndRebalanceStrategies_WithPagination_WhenPaused() public {
        strategyManager.addStrategy(address(mockStrategy1), 80, 70);
        controller.pause();

        vm.expectRevert();
        controller.checkAndRebalanceStrategies(0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ControllerCanReceiveETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        (bool success,) = payable(address(controller)).call{value: amount}("");
        assertTrue(success);
        assertEq(address(controller).balance, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a fresh Controller proxy without wiring an AMM (amm == address(0)).
    function _deployControllerWithoutAMM() internal returns (Controller) {
        ProtocolContracts memory contracts = _deployProtocolWithoutAmm(owner, 5e17);
        return contracts.controller;
    }

    /// @notice Points Registry AMM at a malicious reentrant stub and grants it keeper/admin on Registry.
    function _wireReentrantAMM() internal returns (MockReentrantAMM) {
        MockReentrantAMM reentrantAMM = new MockReentrantAMM();
        reentrantAMM.setController(address(controller));

        registry.registerContract(Auth.AMM, address(reentrantAMM));
        registry.grantRole(Auth.KEEPER_ROLE, address(reentrantAMM));
        registry.grantRole(Auth.ADMIN_ROLE, address(reentrantAMM));

        return reentrantAMM;
    }
}

/**
 * @title ControllerV2Mock
 * @notice Mock contract for testing upgrades
 */
contract ControllerV2Mock is Controller {
    function version() public pure override returns (string memory) {
        return "2.0.0";
    }

    function newFunctionV2() public pure returns (string memory) {
        return "This is a new function in V2";
    }
}
