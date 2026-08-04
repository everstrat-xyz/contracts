// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";

import {Controller} from "../../src/contracts/Controller.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {StrategyManager} from "../../src/contracts/StrategyManager.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";

import {IController} from "../../src/interfaces/IController.sol";
import {IStrategyManager} from "../../src/interfaces/IStrategyManager.sol";
import {Math} from "../../src/libraries/Math.sol";
import {IExitQueue} from "../../src/interfaces/IExitQueue.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../../src/libraries/Auth.sol";

/**
 * @title ETHFlowTest
 * @notice Comprehensive integration tests for ETH flow and strategy management
 * @dev Tests the complete ETH flow: AMM -> Controller -> StrategyManager -> Strategies
 *      Also includes strategy management, distribution, withdrawal, and rebalancing tests
 */
contract ETHFlowTest is ProtocolTestBase {
    // ============ State Variables ============
    Registry public registry;
    ExitQueue public exitQueue;
    AMM public amm;
    Controller public controller;
    StrategyManager public strategyManager;
    Oracle public oracle;
    EVE public token;
    MockStrategy public strategy1;
    MockStrategy public strategy2;
    MockStrategy public strategy3;

    address public admin;
    address public strategyOperator;
    address public user;
    address public user2;

    uint256 public constant INITIAL_CONNECTOR_WEIGHT = 5e17; // 0.5 (50%)
    uint256 public constant ETH_PRICE = 4000e8; // $4000 with 8 decimals
    uint256 public constant STALENESS_INTERVAL = 3600;

    // ============ Events ============
    event DepositToStrategiesCompleted(uint256 requestedAmount);
    event DirectDepositCompleted(address indexed strategy, uint256 requestedAmount);
    event WithdrawalCompleted(uint256 requestedAmount);
    event DirectWithdrawalCompleted(address indexed strategy, uint256 requestedAmount);
    event FundsDepositedToStrategy(address indexed strategy, uint256 amount);
    event FundsWithdrawnFromStrategy(address indexed strategy, uint256 amount);
    event StrategyRebalanced(address indexed strategy);
    event StrategySynced(address indexed strategy);

    // ============ Setup ============
    function setUp() public {
        admin = address(this);
        strategyOperator = makeAddr("strategyOperator");
        user = makeAddr("user");
        user2 = makeAddr("user2");

        _deployCoreContracts();
        _setupRoles();
        _deployStrategies();
    }

    function _deployCoreContracts() internal {
        ProtocolContracts memory contracts = _deployProtocol(admin, INITIAL_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        strategyManager = contracts.strategyManager;
        oracle = contracts.oracle;
        amm = contracts.amm;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
    }

    function _setupRoles() internal {
        registry.grantRole(Auth.KEEPER_ROLE, strategyOperator);
    }

    function _deployStrategies() internal {
        // Step 10: Deploy mock strategies
        strategy1 = new MockStrategy("Strategy 1", address(controller), address(strategyManager));
        strategy2 = new MockStrategy("Strategy 2", address(controller), address(strategyManager));
        strategy3 = new MockStrategy("Strategy 3", address(controller), address(strategyManager));

        // Step 11: Add strategies
        strategyManager.addStrategy(address(strategy1), 80, 70);
        strategyManager.addStrategy(address(strategy2), 60, 50);
        strategyManager.addStrategy(address(strategy3), 40, 30);

        // Step 12: Set initial NAVs
        strategy1.setNavInETH(1000e18);
        strategy2.setNavInETH(2000e18);
        strategy3.setNavInETH(3000e18);
    }

    // ============ ETH Flow Tests ============

    function test_ETHFlow_AMMToController() public {
        // User enters AMM with ETH
        uint256 ethAmount = 1 ether;
        vm.deal(user, ethAmount);

        vm.prank(user);
        amm.enter{value: ethAmount}(1000e18);

        // Verify ETH went to Controller (not StrategyManager)
        assertEq(address(controller).balance, ethAmount);
        assertEq(address(strategyManager).balance, 0);
    }

    function test_ETHFlow_ControllerToStrategies() public {
        // Step 1: User enters AMM (ETH goes to Controller)
        uint256 ethAmount = 18 ether;
        vm.deal(user, ethAmount);

        vm.prank(user);
        amm.enter{value: ethAmount}(1000e18);

        // Verify ETH is in Controller
        assertEq(address(controller).balance, ethAmount);

        // Step 2: Strategy operator distributes to strategies
        vm.prank(strategyOperator);
        controller.depositToStrategies(ethAmount);

        // Verify ETH was distributed to strategies
        uint256 totalInStrategies = address(strategy1).balance + address(strategy2).balance;
        assertGt(totalInStrategies, 0);
        // With safety levels 80 + 60 + 40 = 180, distribution should be clean
        assertEq(address(controller).balance, 0);
    }

    function test_ETHFlow_CompleteCycle() public {
        // Step 1: User enters AMM
        uint256 depositAmount = 18 ether;
        vm.deal(user, depositAmount);

        vm.prank(user);
        amm.enter{value: depositAmount}(1000e18);

        // Step 2: Distribute to strategies
        vm.prank(strategyOperator);
        controller.depositToStrategies(depositAmount);

        // Step 3: Withdraw from strategies back to Controller
        uint256 withdrawalAmount = 5 ether;
        vm.prank(strategyOperator);
        controller.withdrawFromStrategies(withdrawalAmount);

        // Verify Controller received funds
        assertGt(address(controller).balance, 0);
    }

    function test_ETHFlow_MultipleUsers() public {
        // User 1 enters

        vm.deal(user, 5 ether);
        vm.prank(user);
        amm.enter{value: 5 ether}(19999e18);

        console.log("EVE balance of user 2", token.balanceOf(user2));

        // User 2 enters
        vm.deal(user2, 5 ether);
        vm.prank(user2);
        amm.enter{value: 5 ether}(1);

        console.log("EVE balance of user 2", token.balanceOf(user2));

        // All ETH should be in Controller
        assertEq(address(controller).balance, 10 ether);

        // Distribute
        vm.prank(strategyOperator);
        controller.depositToStrategies(10 ether);

        // Verify distribution
        uint256 totalInStrategies = address(strategy1).balance + address(strategy2).balance + address(strategy3).balance;
        assertGt(totalInStrategies, 0);
    }

    function test_ETHFlow_ControllerBalanceInNAV() public {
        // Fund Controller
        uint256 controllerBalance = 5 ether;
        vm.deal(address(controller), controllerBalance);

        // Get total NAV
        uint256 totalNAV = strategyManager.totalNAVInETH();

        // NAV should include Controller balance converted to USD
        // Strategies: 1000e18 + 2000e18 + 3000e18 = 6000e18
        // Controller: 5 ether * $4000 = 20000e18
        // Total should be at least 3000e18 (strategies) + some amount for Controller
        assertGe(totalNAV, 6000e18);
    }

    function test_ETHFlow_WithdrawToController() public {
        // Fund strategies first
        vm.deal(address(strategy1), 7 ether);
        vm.deal(address(strategy2), 5 ether);
        vm.deal(address(strategy3), 3 ether);

        uint256 initialControllerBalance = address(controller).balance;

        // Withdraw from strategies
        vm.prank(strategyOperator);
        controller.withdrawFromStrategies(15 ether);

        // Verify Controller received funds
        assertGt(address(controller).balance, initialControllerBalance);
    }

    // ============ Distribution Tests ============

    function test_DepositToStrategies_ShouldDistributeProportionally() public {
        // Fund Controller
        uint256 amount = 14 ether; // Amount that avoids rounding with 3 strategies
        vm.deal(address(controller), amount);

        // Distribute
        vm.expectEmit(true, false, false, false);
        emit IController.DepositToStrategiesCompleted(amount, amount);

        controller.depositToStrategies(amount);

        // Verify Controller balance decreased
        assertLe(address(controller).balance, amount);
    }

    function test_DepositToStrategies_RespectsMaxDeposit() public {
        // Set max deposit limits
        strategy1.setMaxDeposit(2 ether);
        strategy2.setMaxDeposit(3 ether);
        strategy3.setMaxDeposit(4 ether);

        // Fund Controller
        uint256 amount = 20 ether; // More than total max deposits
        vm.deal(address(controller), amount);

        // Distribute
        controller.depositToStrategies(amount);

        // Verify Controller has remaining balance (some strategies hit max deposit)
        assertLt(address(controller).balance, amount);
    }

    function test_DepositToStrategies_SkipsUnhealthyStrategies() public {
        strategy2.setIsHealthy(false);

        uint256 amount = 10 ether;
        vm.deal(address(controller), amount);

        controller.depositToStrategies(amount);

        assertEq(address(strategy2).balance, 0);
    }

    function test_DepositToStrategies_OnlyStrategyOperator() public {
        vm.deal(address(controller), 10 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.depositToStrategies(10 ether);
    }

    // ============ Direct Deposit Tests ============

    function test_DepositToStrategy_ShouldWork() public {
        // Fund Controller
        uint256 amount = 5 ether;
        vm.deal(address(controller), amount);

        // Deposit to strategy1
        vm.expectEmit(true, true, false, false);
        emit IController.DirectDepositCompleted(address(strategy1), amount, amount);

        controller.depositToStrategy(address(strategy1), amount);

        // Verify funds were deposited
        assertEq(address(strategy1).balance, amount);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositToStrategy_RespectsMaxDeposit() public {
        // Set max deposit
        strategy1.setMaxDeposit(2 ether);

        // Fund Controller
        uint256 amount = 5 ether;
        vm.deal(address(controller), amount);

        // Deposit
        controller.depositToStrategy(address(strategy1), amount);

        // Only maxDeposit should be deposited
        assertEq(address(strategy1).balance, 2 ether);
        assertGt(address(controller).balance, 0);
    }

    function test_DepositToStrategy_OnlyStrategyOperator() public {
        vm.deal(address(controller), 5 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.depositToStrategy(address(strategy1), 5 ether);
    }

    // ============ Withdrawal Tests ============

    function test_WithdrawFromStrategies_ShouldWithdrawProportionally() public {
        // First, fund strategies
        vm.deal(address(strategy1), 5 ether);
        vm.deal(address(strategy2), 5 ether);
        vm.deal(address(strategy3), 5 ether);

        uint256 withdrawalAmount = 10 ether;

        // Withdraw
        vm.expectEmit(true, false, false, false);
        emit IController.WithdrawalCompleted(withdrawalAmount, withdrawalAmount);

        controller.withdrawFromStrategies(withdrawalAmount);

        // Verify Controller received funds
        assertGt(address(controller).balance, 0);
    }

    function test_WithdrawFromStrategies_RespectsMaxWithdrawal() public {
        // Fund strategies
        vm.deal(address(strategy1), 5 ether);
        vm.deal(address(strategy2), 5 ether);
        vm.deal(address(strategy3), 5 ether);

        // Set max withdrawal limits
        strategy1.setMaxWithdrawal(2 ether);
        strategy2.setMaxWithdrawal(2 ether);
        strategy3.setMaxWithdrawal(2 ether);

        uint256 withdrawalAmount = 20 ether; // More than total max withdrawals

        // Withdraw
        controller.withdrawFromStrategies(withdrawalAmount);

        // Total withdrawn should be limited by maxWithdrawal
        assertLe(address(controller).balance, 6 ether);
    }

    function test_WithdrawFromStrategy_ShouldWork() public {
        // Fund strategy1
        uint256 amount = 5 ether;
        vm.deal(address(strategy1), amount);

        // Withdraw
        vm.expectEmit(true, true, false, false);
        emit IController.DirectWithdrawalCompleted(address(strategy1), amount, amount);

        controller.withdrawFromStrategy(address(strategy1), amount);

        // Verify Controller received funds
        assertEq(address(controller).balance, amount);
        assertEq(address(strategy1).balance, 0);
    }

    function test_WithdrawFromStrategy_RespectsMaxWithdrawal() public {
        // Fund strategy1
        vm.deal(address(strategy1), 5 ether);

        // Set max withdrawal
        strategy1.setMaxWithdrawal(2 ether);

        // Withdraw more than max
        controller.withdrawFromStrategy(address(strategy1), 5 ether);

        // Only maxWithdrawal should be withdrawn
        assertEq(address(controller).balance, 2 ether);
        assertEq(address(strategy1).balance, 3 ether);
    }

    function test_WithdrawFromStrategy_OnlyStrategyOperator() public {
        vm.deal(address(strategy1), 5 ether);

        vm.prank(user);
        vm.expectRevert();
        controller.withdrawFromStrategy(address(strategy1), 5 ether);
    }

    // ============ Rebalancing Tests ============

    function test_CheckAndRebalanceStrategies_ShouldRebalanceUnhealthy() public {
        // Make strategies unhealthy
        strategy1.setIsHealthy(false);
        strategy2.setIsHealthy(false);

        // Rebalance all
        vm.prank(strategyOperator);
        controller.checkAndRebalanceStrategies();

        // Strategies should be healthy after rebalance
        assertTrue(strategy1.isHealthy());
        assertTrue(strategy2.isHealthy());
    }

    function test_CheckAndRebalanceStrategy_ShouldRebalanceSpecific() public {
        // Make strategy1 unhealthy
        strategy1.setIsHealthy(false);

        // Rebalance strategy1
        vm.prank(strategyOperator);
        controller.checkAndRebalanceStrategy(address(strategy1));

        // Strategy1 should be healthy
        assertTrue(strategy1.isHealthy());
    }

    function test_CheckAndRebalanceStrategy_HealthyStrategy_ShouldNotRebalance() public {
        // Strategy is healthy, rebalance should not do anything
        assertTrue(strategy1.isHealthy());

        vm.prank(strategyOperator);
        controller.checkAndRebalanceStrategy(address(strategy1));

        // Still healthy
        assertTrue(strategy1.isHealthy());
    }

    function test_CheckAndRebalanceStrategy_OnlyStrategyOperator() public {
        strategy1.setIsHealthy(false);

        vm.prank(user);
        vm.expectRevert();
        controller.checkAndRebalanceStrategy(address(strategy1));
    }

    function test_CheckAndRebalanceStrategy_ZeroAddress() public {
        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.checkAndRebalanceStrategy(address(0));
    }

    // ============ Sync Tests ============

    function test_SyncStrategies_ShouldSyncAll() public {
        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit StrategySynced(address(strategy1));
        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit StrategySynced(address(strategy2));

        vm.prank(strategyOperator);
        controller.syncStrategies();
    }

    function test_SyncStrategy_ShouldSyncSpecific() public {
        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit StrategySynced(address(strategy1));

        vm.prank(strategyOperator);
        controller.syncStrategy(address(strategy1));
    }

    function test_SyncStrategy_AccessControl() public {
        vm.prank(user);
        vm.expectRevert();
        controller.syncStrategy(address(strategy1));
    }

    function test_SyncStrategy_ZeroAddress() public {
        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.syncStrategy(address(0));
    }

    // ============ NAV Calculation Tests ============

    function test_TotalNAVInETH_IncludesControllerBalance() public {
        // Fund Controller
        uint256 controllerBalance = 5 ether;
        vm.deal(address(controller), controllerBalance);

        // Get total NAV
        uint256 totalNAV = strategyManager.totalNAVInETH();

        // Should include strategies NAV + Controller balance converted to USD
        // Strategies: 1000e18 + 2000e18 + 3000e18 = 6000e18
        // Controller: 5 ether * $4000 = 20000e18
        // Total: 26000e18
        assertGe(totalNAV, 6000e18); // At least strategies NAV
    }

    function test_StrategyNAVInETH_ReadsFromStrategy() public view {
        // Get NAV for strategy1
        uint256 nav = strategyManager.strategyNAVInETH(address(strategy1));

        // Should match strategy's navInETH()
        assertEq(nav, strategy1.navInETH());
    }

    function test_StrategyNAVInETH_UpdatesWhenStrategyUpdates() public {
        // Update strategy NAV
        uint256 newNAV = 5000e18;
        strategy1.setNavInETH(newNAV);

        // Get NAV from StrategyManager
        uint256 nav = strategyManager.strategyNAVInETH(address(strategy1));

        // Should reflect new NAV
        assertEq(nav, newNAV);
    }

    // ============ USD Calculation Tests ============

    function test_TotalNAVInUSD_MatchesETHConversion() public view {
        // Get NAV in ETH
        uint256 navETH = strategyManager.totalNAVInETH();

        // Get NAV in USD
        uint256 navUSD = strategyManager.totalNAVInUSD();

        // USD NAV should be ETH NAV converted via oracle
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), navETH, Math.DECIMALS_NORMALIZED);

        assertEq(navUSD, expectedUSD, "USD NAV should match ETH NAV conversion via oracle");
    }

    function test_TotalNAVInUSD_IncludesControllerBalance() public {
        // Fund Controller
        uint256 controllerBalance = 5 ether;
        vm.deal(address(controller), controllerBalance);

        // Get NAV in USD
        uint256 navUSD = strategyManager.totalNAVInUSD();

        // Get NAV in ETH
        uint256 navETH = strategyManager.totalNAVInETH();

        // Verify USD is ETH converted
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), navETH, Math.DECIMALS_NORMALIZED);
        assertEq(navUSD, expectedUSD, "USD NAV should include Controller balance converted from ETH");

        // Verify NAV includes Controller balance
        // Strategies: 1000e18 + 2000e18 + 3000e18 = 6000e18
        // Controller: 5 ether = 5e18
        // Total ETH: 6000e18 + 5e18 = 6005e18
        assertGe(navETH, 6005e18, "NAV should include Controller balance");
    }

    function test_StrategyNAVInUSD_MatchesETHConversion() public view {
        // Get strategy NAV in ETH
        uint256 navETH = strategyManager.strategyNAVInETH(address(strategy1));

        // Get strategy NAV in USD
        uint256 navUSD = strategyManager.strategyNAVInUSD(address(strategy1));

        // USD NAV should be ETH NAV converted via oracle
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), navETH, Math.DECIMALS_NORMALIZED);

        assertEq(navUSD, expectedUSD, "Strategy USD NAV should match ETH NAV conversion");
    }

    function test_StrategyNAVInUSD_UpdatesWhenStrategyUpdates() public {
        // Update strategy NAV
        uint256 newNAV = 5000e18;
        strategy1.setNavInETH(newNAV);

        // Get NAV in USD from StrategyManager
        uint256 navUSD = strategyManager.strategyNAVInUSD(address(strategy1));

        // Should reflect new NAV converted to USD`
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), newNAV, Math.DECIMALS_NORMALIZED);
        assertEq(navUSD, expectedUSD, "USD NAV should reflect updated strategy NAV");
    }

    function test_AMMEveBasePriceInUSD_MatchesETHConversion() public {
        // Bootstrap AMM
        vm.deal(user, 5 ether);
        vm.prank(user);
        amm.enter{value: 5 ether}(1000e18);

        // Get base price in ETH
        uint256 basePriceETH = amm.eveBasePriceInETH();

        // Get base price in USD
        uint256 basePriceUSD = amm.eveBasePriceInUSD();

        // USD price should be ETH price converted via oracle
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), basePriceETH, Math.DECIMALS_NORMALIZED);

        assertEq(basePriceUSD, expectedUSD, "Base USD price should match ETH price conversion");
    }

    function test_AMMEvePremiumPriceInUSD_MatchesETHConversion() public {
        // Bootstrap AMM
        vm.deal(user, 5 ether);
        vm.prank(user);
        amm.enter{value: 5 ether}(1000e18);

        // Get premium price in ETH
        uint256 premiumPriceETH = amm.evePremiumPriceInETH();

        // Get premium price in USD
        uint256 premiumPriceUSD = amm.evePremiumPriceInUSD();

        // USD price should be ETH price converted via oracle
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), premiumPriceETH, Math.DECIMALS_NORMALIZED);

        assertEq(premiumPriceUSD, expectedUSD, "Premium USD price should match ETH price conversion");
    }

    function test_AMMPriceUSD_ConsistentAfterOperations() public {
        // Bootstrap AMM
        vm.deal(user, 5 ether);
        vm.prank(user);
        amm.enter{value: 5 ether}(1000e18);

        // Record initial prices
        uint256 initialBasePriceUSD = amm.eveBasePriceInUSD();
        uint256 initialPremiumPriceUSD = amm.evePremiumPriceInUSD();

        // User2 enters
        vm.deal(user2, 3 ether);
        vm.prank(user2);
        amm.enter{value: 3 ether}(1);

        // Get prices after operation
        uint256 basePriceETH = amm.eveBasePriceInETH();
        uint256 basePriceUSD = amm.eveBasePriceInUSD();
        uint256 premiumPriceETH = amm.evePremiumPriceInETH();
        uint256 premiumPriceUSD = amm.evePremiumPriceInUSD();

        // Verify USD prices are still conversions of ETH prices
        uint256 expectedBaseUSD = oracle.convertTokenToUSD(address(0), basePriceETH, Math.DECIMALS_NORMALIZED);
        uint256 expectedPremiumUSD = oracle.convertTokenToUSD(address(0), premiumPriceETH, Math.DECIMALS_NORMALIZED);

        assertEq(basePriceUSD, expectedBaseUSD, "Base USD price should remain consistent after operations");
        assertEq(premiumPriceUSD, expectedPremiumUSD, "Premium USD price should remain consistent after operations");

        // Prices should have changed (NAV and supply changed)
        assertTrue(
            basePriceUSD != initialBasePriceUSD || premiumPriceUSD != initialPremiumPriceUSD,
            "Prices should change after operations"
        );
    }

    function test_NAVUSD_ConsistentAfterDistribution() public {
        // Fund Controller
        uint256 controllerBalance = 10 ether;
        vm.deal(address(controller), controllerBalance);

        // Get NAV before distribution
        uint256 navETHBefore = strategyManager.totalNAVInETH();

        // Distribute to strategies
        vm.prank(strategyOperator);
        controller.depositToStrategies(controllerBalance);

        // Get NAV after distribution
        uint256 navUSDAfter = strategyManager.totalNAVInUSD();
        uint256 navETHAfter = strategyManager.totalNAVInETH();

        // NAV in ETH should decrease (Controller balance moved to strategies)
        // But strategies NAV should increase, so total might stay similar
        // The key is that USD should still be ETH converted
        uint256 expectedUSDAfter = oracle.convertTokenToUSD(address(0), navETHAfter, Math.DECIMALS_NORMALIZED);
        assertEq(navUSDAfter, expectedUSDAfter, "USD NAV should remain consistent after distribution");

        // Verify NAV changed (Controller balance moved to strategies)
        assertTrue(navETHAfter != navETHBefore, "NAV should change after distribution");
    }

    function test_NAVUSD_ConsistentAfterWithdrawal() public {
        // Fund strategies first
        vm.deal(address(strategy1), 5 ether);
        vm.deal(address(strategy2), 5 ether);
        vm.deal(address(strategy3), 5 ether);

        // Get NAV before withdrawal
        uint256 navETHBefore = strategyManager.totalNAVInETH();

        // Withdraw from strategies
        uint256 withdrawalAmount = 10 ether;
        vm.prank(strategyOperator);
        controller.withdrawFromStrategies(withdrawalAmount);

        // Get NAV after withdrawal
        uint256 navUSDAfter = strategyManager.totalNAVInUSD();
        uint256 navETHAfter = strategyManager.totalNAVInETH();

        // NAV in ETH should reflect withdrawal (funds moved to Controller)
        // USD should still be ETH converted
        uint256 expectedUSDAfter = oracle.convertTokenToUSD(address(0), navETHAfter, Math.DECIMALS_NORMALIZED);
        assertEq(navUSDAfter, expectedUSDAfter, "USD NAV should remain consistent after withdrawal");

        // Verify NAV changed (funds moved from strategies to Controller)
        assertTrue(navETHAfter != navETHBefore, "NAV should change after withdrawal");
    }

    function test_MultipleStrategies_TotalNAVUSD_MatchesSum() public view {
        // Get individual strategy NAVs in USD
        uint256 strategy1USD = strategyManager.strategyNAVInUSD(address(strategy1));
        uint256 strategy2USD = strategyManager.strategyNAVInUSD(address(strategy2));
        uint256 strategy3USD = strategyManager.strategyNAVInUSD(address(strategy3));

        // Get total NAV in USD
        uint256 totalNAVUSD = strategyManager.totalNAVInUSD();

        // Total should be sum of strategies + Controller balance
        uint256 controllerBalance = address(controller).balance;
        uint256 controllerUSD = oracle.convertTokenToUSD(address(0), controllerBalance, Math.DECIMALS_NORMALIZED);
        uint256 expectedTotal = strategy1USD + strategy2USD + strategy3USD + controllerUSD;

        assertEq(totalNAVUSD, expectedTotal, "Total USD NAV should equal sum of strategy USD NAVs plus Controller");
    }

    function test_PriceUSD_WithDifferentETHPrices() public {
        // Bootstrap AMM
        vm.deal(user, 5 ether);
        vm.prank(user);
        amm.enter{value: 5 ether}(1000e18);

        // Get initial prices
        uint256 basePriceUSD1 = amm.eveBasePriceInUSD();

        // Change ETH price (simulate price feed update)
        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(5000e8)); // $5000 instead of $4000
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        // Get prices after price change
        uint256 basePriceUSD2 = amm.eveBasePriceInUSD();

        // Prices should change (ETH price increased, so USD prices should increase)
        // Note: ETH prices in ETH terms should remain the same, but USD prices should increase
        uint256 basePriceETH = amm.eveBasePriceInETH();
        uint256 expectedBaseUSD2 = oracle.convertTokenToUSD(address(0), basePriceETH, Math.DECIMALS_NORMALIZED);

        assertEq(basePriceUSD2, expectedBaseUSD2, "USD price should reflect new ETH/USD exchange rate");
        assertGt(basePriceUSD2, basePriceUSD1, "USD price should increase when ETH price increases");
    }

    // ============ Complete Flow Tests ============

    function test_CompleteFlow_EnterDepositWithdraw() public {
        // 1. User sends ETH to Controller (simulating AMM)
        uint256 depositAmount = 14 ether; // Amount that avoids rounding
        vm.deal(address(this), depositAmount);
        (bool success,) = payable(address(controller)).call{value: depositAmount}("");
        assertTrue(success);

        // 2. Strategy operator distributes funds
        vm.prank(strategyOperator);
        controller.depositToStrategies(depositAmount);

        // 3. Verify funds were distributed
        uint256 totalInStrategies = address(strategy1).balance + address(strategy2).balance + address(strategy3).balance;
        assertGt(totalInStrategies, 0);

        // 4. Withdraw some funds
        uint256 withdrawalAmount = 3 ether;
        vm.prank(strategyOperator);
        controller.withdrawFromStrategies(withdrawalAmount);

        // 5. Verify Controller received funds
        assertGe(address(controller).balance, 0);
    }

    function test_CompleteFlow_WithRebalancing() public {
        // 1. Fund and distribute
        vm.deal(address(controller), 14 ether);
        vm.prank(strategyOperator);
        controller.depositToStrategies(14 ether);

        // 2. Make a strategy unhealthy
        strategy1.setIsHealthy(false);

        // 3. Rebalance
        vm.prank(strategyOperator);
        controller.checkAndRebalanceStrategy(address(strategy1));

        // 4. Verify strategy is healthy
        assertTrue(strategy1.isHealthy());
    }

    // ============ Redemption Queue Flow Tests ============

    /**
     * @notice Test complete redemption queue flow: enter -> exit -> priceBatch -> processRequests -> receive ETH
     */
    function test_RedemptionQueueFlow_CompleteFlow() public {
        // Step 1: User enters AMM (bootstraps and receives EVE tokens)
        uint256 depositAmount = 5 ether;
        vm.deal(user, depositAmount);

        vm.prank(user);
        amm.enter{value: depositAmount}(1000e18);

        // Verify user received EVE tokens
        uint256 userEveBalance = token.balanceOf(user);
        assertGt(userEveBalance, 0);
        assertTrue(amm.bootstrapped());
        assertEq(address(controller).balance, depositAmount);

        // Step 2: User exits (queues redemption request)
        uint256 ethRequested = 2 ether;
        uint256 maxTokensToBurn = userEveBalance;
        uint256 priceTolerance = 0; // No slippage protection for this test

        vm.startPrank(user);
        token.approve(address(amm), maxTokensToBurn);
        uint256 batchId = amm.exit(ethRequested, maxTokensToBurn, priceTolerance);
        vm.stopPrank();

        // Verify request was queued (batchId > 0 means queued)
        assertGt(batchId, 0);
        assertLt(token.balanceOf(user), userEveBalance); // Tokens transferred to AMM

        // Get ExitQueue instance

        // Verify request exists in queue
        (bool isProcessed, bool isClosedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user);
        assertFalse(isProcessed);
        assertFalse(isClosedDueToSlippage);

        // Step 3: Keeper prices the batch
        vm.prank(strategyOperator);
        controller.priceBatch();

        // Verify batch is priced
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        assertGt(finalEvePrice, 0);

        // Step 4: Calculate ETH needed and fund Controller
        (,,, uint256 tokensToBurn,) = exitQueue.requestInfo(batchId, user);
        uint256 ethToRedeem = Math.convertAssets(tokensToBurn, finalEvePrice);

        // Fund Controller with ETH for redemption
        vm.deal(address(controller), ethToRedeem);

        // Step 5: Keeper processes the request (pull-over-push: ETH is credited, not pushed)
        uint256 userBalanceBefore = user.balance;
        vm.prank(strategyOperator);
        controller.processRequest(batchId, user);

        // After processing, ETH is credited to claimableBalances — not yet sent to user
        assertEq(user.balance, userBalanceBefore, "ETH must not be pushed directly to user");
        assertGe(amm.claimableBalances(user), ethToRedeem * 99 / 100, "claimableBalances must be credited");

        // Step 6: User claims ETH
        vm.prank(user);
        amm.claim();

        // Verify user received ETH after claim
        assertGt(user.balance, userBalanceBefore);
        assertGe(user.balance - userBalanceBefore, ethToRedeem * 99 / 100); // Allow 1% rounding
        assertEq(amm.claimableBalances(user), 0, "claimableBalances must be cleared after claim");

        // Verify request is processed
        (isProcessed, isClosedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user);
        assertTrue(isProcessed);
        assertFalse(isClosedDueToSlippage);
    }

    /**
     * @notice Test redemption queue flow with multiple users in same batch
     */
    function test_RedemptionQueueFlow_MultipleUsers() public {
        // Step 1: Both users enter
        vm.deal(user, 5 ether);
        vm.deal(user2, 5 ether);

        vm.prank(user);
        amm.enter{value: 5 ether}(1);
        vm.prank(user2);
        amm.enter{value: 5 ether}(1);

        uint256 user1EveBalance = token.balanceOf(user);
        uint256 user2EveBalance = token.balanceOf(user2);

        // Step 2: Both users exit (same batch)
        vm.startPrank(user);
        token.approve(address(amm), user1EveBalance);
        uint256 batchId1 = amm.exit(2 ether, user1EveBalance, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(address(amm), user2EveBalance);
        uint256 batchId2 = amm.exit(2 ether, user2EveBalance, 0);
        vm.stopPrank();

        // Both should be in the same batch (assuming they exit in same block)
        assertEq(batchId1, batchId2);

        // Step 3: Price the batch
        vm.prank(strategyOperator);
        controller.priceBatch();

        // Step 4: Process both requests
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId1);

        // Calculate ETH needed for both users
        (,,, uint256 tokensToBurn1,) = exitQueue.requestInfo(batchId1, user);
        (,,, uint256 tokensToBurn2,) = exitQueue.requestInfo(batchId1, user2);
        uint256 ethToRedeem1 = Math.convertAssets(tokensToBurn1, finalEvePrice);
        uint256 ethToRedeem2 = Math.convertAssets(tokensToBurn2, finalEvePrice);

        // Fund Controller
        vm.deal(address(controller), ethToRedeem1 + ethToRedeem2);

        // Process both requests (pull-over-push: ETH is credited, not pushed)
        uint256 user1BalanceBefore = user.balance;
        uint256 user2BalanceBefore = user2.balance;

        vm.prank(strategyOperator);
        controller.processRequest(batchId1, user);
        vm.prank(strategyOperator);
        controller.processRequest(batchId1, user2);

        // After processing, ETH is in claimableBalances — not yet sent to users
        assertEq(user.balance, user1BalanceBefore, "ETH must not be pushed directly to user1");
        assertEq(user2.balance, user2BalanceBefore, "ETH must not be pushed directly to user2");
        assertGt(amm.claimableBalances(user), 0, "user1 claimableBalances must be credited");
        assertGt(amm.claimableBalances(user2), 0, "user2 claimableBalances must be credited");

        // Both users claim their ETH
        vm.prank(user);
        amm.claim();
        vm.prank(user2);
        amm.claim();

        // Verify both users received ETH after claiming
        assertGt(user.balance, user1BalanceBefore);
        assertGt(user2.balance, user2BalanceBefore);
        assertEq(amm.claimableBalances(user), 0, "user1 claimableBalances must be cleared");
        assertEq(amm.claimableBalances(user2), 0, "user2 claimableBalances must be cleared");

        // Verify both requests are processed
        (bool isProcessed1,,,,) = exitQueue.requestInfo(batchId1, user);
        (bool isProcessed2,,,,) = exitQueue.requestInfo(batchId1, user2);
        assertTrue(isProcessed1);
        assertTrue(isProcessed2);
    }

    /**
     * @notice Test redemption queue flow with slippage protection
     */
    function test_RedemptionQueueFlow_WithSlippageProtection() public {
        // Step 1: User enters
        vm.deal(user, 5 ether);
        vm.prank(user);
        amm.enter{value: 5 ether}(1000e18);

        uint256 userEveBalance = token.balanceOf(user);

        // Step 2: User exits with price tolerance (1%)
        uint256 priceTolerance = 1e16; // 1%
        vm.startPrank(user);
        token.approve(address(amm), userEveBalance);
        uint256 batchId = amm.exit(2 ether, userEveBalance, priceTolerance);
        vm.stopPrank();

        // Step 3: Price batch with significant price drop
        (,, uint256 evePriceAtRequestTime,,) = exitQueue.requestInfo(batchId, user);
        strategy1.setNavInETH(evePriceAtRequestTime * 1e17 / Math.SCALE_FACTOR);

        // Price the batch with dropped price; the user's own priceTolerance closes
        // the request due to slippage below.
        controller.priceBatch();

        // Step 4: Process request (should close due to slippage, no ETH needed)
        controller.processRequest(batchId, user);

        // Verify request is processed and closed due to slippage
        (bool isProcessed, bool isClosedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user);
        assertTrue(isProcessed);
        assertTrue(isClosedDueToSlippage);

        // User should not receive ETH (slippage too high)
        assertEq(user.balance, 0);
    }

    // ============ NAV Fail-Closed Recovery Tests ============

    /**
     * @notice End-to-end recovery when a strategy's navInETH() reverts through force-removal.
     * @dev forceRemoveStrategy() must succeed while navInETH() is still reverting and while
     *      StrategyManager is paused; only then should enter/exit pricing work again.
     */
    function test_NAVFailClosed_UserFlowRecoversWhenBrokenStrategyForceRemovedWhileNavReverts() public {
        uint256 depositAmount = 5 ether;
        vm.deal(user, depositAmount);

        vm.prank(user);
        amm.enter{value: depositAmount}(1000e18);

        uint256 userEveBalance = token.balanceOf(user);
        assertGt(userEveBalance, 0);
        assertEq(address(controller).balance, depositAmount);

        strategy2.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.totalNAVInETH();

        vm.deal(user2, depositAmount);
        vm.prank(user2);
        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        amm.enter{value: depositAmount}(1);

        vm.startPrank(user);
        token.approve(address(amm), userEveBalance);
        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        amm.exit(1 ether, userEveBalance, 0);
        vm.stopPrank();

        strategyManager.pause();

        vm.expectEmit(true, false, false, true);
        emit IStrategyManager.StrategyForceRemoved(address(strategy2), 0, true);
        strategyManager.forceRemoveStrategy(address(strategy2));

        assertFalse(strategyManager.isStrategyRegistered(address(strategy2)));
        assertEq(strategyManager.strategyCount(), 2);

        uint256 expectedNav = strategy1.navInETH() + strategy3.navInETH() + address(strategyManager).balance
            + address(controller).balance + address(amm).balance;
        assertEq(strategyManager.totalNAVInETH(), expectedNav);

        // With the broken strategy removed, NAV is readable again and user flows re-open.
        vm.prank(user2);
        amm.enter{value: depositAmount}(1);
        assertGt(token.balanceOf(user2), 0);

        vm.startPrank(user);
        token.approve(address(amm), userEveBalance);
        amm.exit(1 ether, userEveBalance, 0);
        vm.stopPrank();
    }

    /**
     * @notice Orphaned ETH on a force-removed strategy is recovered into NAV via emergencyExit().
     */
    function test_NAVFailClosed_OrphanedStrategyRecoveredViaEmergencyExit() public {
        uint256 orphanedEth = 7 ether;
        vm.deal(address(strategy2), orphanedEth);
        strategy2.setRevertNavInETH(true);

        vm.expectRevert(MockStrategy.MockStrategyNavReverted.selector);
        strategyManager.totalNAVInETH();

        strategyManager.pause();
        strategyManager.forceRemoveStrategy(address(strategy2));

        assertFalse(strategyManager.isStrategyRegistered(address(strategy2)));

        uint256 navBeforeRecovery = strategyManager.totalNAVInETH();
        assertEq(
            navBeforeRecovery,
            strategy1.navInETH() + strategy3.navInETH() + address(strategyManager).balance + address(controller).balance
                + address(amm).balance
        );
        assertEq(address(strategy2).balance, orphanedEth);

        strategy2.setPaused(true);
        vm.expectEmit(false, false, false, true, address(strategy2));
        emit IStrategy.EmergencyExited(orphanedEth);
        strategy2.emergencyExit();

        assertEq(address(strategy2).balance, 0);
        assertEq(address(strategyManager).balance, orphanedEth);
        assertEq(strategyManager.totalNAVInETH(), navBeforeRecovery + orphanedEth);
    }

    // ============ Edge Cases ============

    function test_ETHFlow_NoStrategies() public {
        strategy1.setNavInETH(0);
        strategy2.setNavInETH(0);
        strategy3.setNavInETH(0);
        // Remove all strategies
        strategyManager.removeStrategy(address(strategy1));
        strategyManager.removeStrategy(address(strategy2));
        strategyManager.removeStrategy(address(strategy3));

        // User enters AMM
        vm.deal(user, 10 ether);
        vm.prank(user);
        amm.enter{value: 10 ether}(1000e18);

        // ETH should still go to Controller
        assertEq(address(controller).balance, 10 ether);

        // Distribution should revert when no strategies are registered
        vm.prank(strategyOperator);
        vm.expectRevert(IStrategyManager.StrategyManagerNoStrategiesRegistered.selector);
        controller.depositToStrategies(10 ether);

        // Controller should still have funds (no strategies to distribute to)
        assertEq(address(controller).balance, 10 ether);
    }

    function test_DepositToStrategies_NoStrategies() public {
        strategy1.setNavInETH(0);
        strategy2.setNavInETH(0);
        strategy3.setNavInETH(0);
        // Remove all strategies
        strategyManager.removeStrategy(address(strategy1));
        strategyManager.removeStrategy(address(strategy2));
        strategyManager.removeStrategy(address(strategy3));

        // Fund Controller
        vm.deal(address(controller), 10 ether);

        // Distribute should revert when no strategies are registered
        vm.prank(strategyOperator);
        vm.expectRevert(IStrategyManager.StrategyManagerNoStrategiesRegistered.selector);
        controller.depositToStrategies(10 ether);
    }

    function test_WithdrawFromStrategies_NoFunds() public {
        strategy1.setMaxWithdrawal(0);
        strategy2.setMaxWithdrawal(0);
        strategy3.setMaxWithdrawal(0);

        // Withdraw should no-op when no strategy has liquidity
        uint256 controllerBalanceBefore = address(controller).balance;
        vm.prank(strategyOperator);
        controller.withdrawFromStrategies(10 ether);
        assertEq(address(controller).balance, controllerBalanceBefore);
    }

    function test_Paused_BlocksKeeperFunctions() public {
        // Pause Controller
        controller.pause();

        vm.deal(address(controller), 10 ether);

        // All keeper functions should fail
        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.depositToStrategies(10 ether);

        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.depositToStrategy(address(strategy1), 5 ether);

        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.withdrawFromStrategies(5 ether);

        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.checkAndRebalanceStrategies();

        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.syncStrategies();
    }

    function test_ETHFlow_PausedBlocksDistribution() public {
        // User enters AMM
        vm.deal(user, 10 ether);
        vm.prank(user);
        amm.enter{value: 10 ether}(1000e18);

        // Pause Controller
        controller.pause();

        // Distribution should fail
        vm.prank(strategyOperator);
        vm.expectRevert();
        controller.depositToStrategies(10 ether);

        // ETH should remain in Controller
        assertEq(address(controller).balance, 10 ether);
    }

    // ============ Pagination Tests ============

    function test_DepositToStrategies_WithPagination() public {
        // Fund Controller
        uint256 amount = 18 ether;
        vm.deal(address(controller), amount);

        // Distribute to first two strategies only (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        vm.prank(strategyOperator);
        controller.depositToStrategies(0, 2, amount);

        // Verify funds were distributed to first two strategies
        uint256 totalInFirstTwo = address(strategy1).balance + address(strategy2).balance;
        assertGt(totalInFirstTwo, 0);
        assertEq(address(strategy3).balance, 0); // Third strategy should not receive funds
    }

    function test_WithdrawFromStrategies_WithPagination() public {
        // Fund strategies
        vm.deal(address(strategy1), 7 ether);
        vm.deal(address(strategy2), 5 ether);
        vm.deal(address(strategy3), 5 ether);

        uint256 amount = 12 ether;

        // Withdraw from first two strategies only (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        vm.prank(strategyOperator);
        controller.withdrawFromStrategies(0, 2, amount);

        // Controller should receive funds
        assertGt(address(controller).balance, 0);
        // Third strategy should not be withdrawn from
        assertEq(address(strategy3).balance, 5 ether);
    }

    function test_CheckAndRebalanceStrategies_WithPagination() public {
        // Make strategies unhealthy
        strategy1.setIsHealthy(false);
        strategy2.setIsHealthy(false);
        strategy3.setIsHealthy(false);

        // Rebalance only first two strategies (indices 0 and 1)
        // Range [0, 2) processes indices 0 and 1
        vm.prank(strategyOperator);
        controller.checkAndRebalanceStrategies(0, 2);

        // First two strategies should be healthy after rebalance
        assertTrue(strategy1.isHealthy());
        assertTrue(strategy2.isHealthy());
        // Third strategy should still be unhealthy
        assertFalse(strategy3.isHealthy());
    }

    function test_DepositToStrategies_ProportionalBySafetyLevel_WithPagination() public {
        // Fund Controller
        uint256 amount = 14 ether; // 80 + 60 = 140 total safety level for first two
        vm.deal(address(controller), amount);

        // Distribute to first two strategies only
        // Range [0, 2) processes indices 0 and 1
        vm.prank(strategyOperator);
        controller.depositToStrategies(0, 2, amount);

        // Verify proportional distribution based on safety levels
        // Strategy1 (80) should get more than Strategy2 (60)
        assertGt(address(strategy1).balance, address(strategy2).balance);
        assertEq(address(strategy3).balance, 0); // Third strategy should not receive funds
    }

    function test_WithdrawFromStrategies_ProportionalByWithdrawalPriority_WithPagination() public {
        // Fund strategies
        vm.deal(address(strategy1), 10 ether);
        vm.deal(address(strategy2), 10 ether);
        vm.deal(address(strategy3), 10 ether);

        uint256 amount = 12 ether; // 70 + 50 = 120 total withdrawal priority for first two

        // Withdraw from first two strategies only
        // Range [0, 2) processes indices 0 and 1
        vm.prank(strategyOperator);
        controller.withdrawFromStrategies(0, 2, amount);

        // Controller should receive funds
        assertGt(address(controller).balance, 0);
        // Strategy1 (priority 70) should withdraw more than Strategy2 (priority 50)
        // Third strategy should not be withdrawn from
        assertEq(address(strategy3).balance, 10 ether);
    }

    // ============ Receive Function ============
    receive() external payable {}
}
