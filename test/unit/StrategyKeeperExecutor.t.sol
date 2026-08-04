// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../src/contracts/Controller.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {StrategyManager} from "../../src/contracts/StrategyManager.sol";
import {StrategyKeeperExecutor} from "../../src/contracts/automation/StrategyKeeperExecutor.sol";
import {QueueKeeperExecutor} from "../../src/contracts/automation/QueueKeeperExecutor.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IAMM} from "../../src/interfaces/IAMM.sol";
import {IRegistryClient} from "../../src/interfaces/IRegistryClient.sol";
import {IKeeperExecutorBase} from "../../src/interfaces/automation/IKeeperExecutorBase.sol";
import {IQueueKeeperExecutor} from "../../src/interfaces/automation/IQueueKeeperExecutor.sol";
import {IStrategyKeeperExecutor} from "../../src/interfaces/automation/IStrategyKeeperExecutor.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title StrategyKeeperExecutorTest
 * @notice Unit tests for the strategy operations Chainlink Automation executor
 */
contract StrategyKeeperExecutorTest is ProtocolTestBase {
    // ============ Constants ============
    uint256 public constant ETH_PRICE = 4000e8; // $4000 with 8 decimals
    uint256 public constant STALENESS_INTERVAL = 3600;
    uint256 public constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 public constant EXIT_ETH = 1 ether;
    uint256 public constant PRICE_TOLERANCE = 1e17; // 10%
    uint256 public constant MIN_TOKENS_TO_MINT = 1;
    uint8 public constant STRATEGY_DEPOSIT_WEIGHT = 80;
    uint8 public constant STRATEGY_WITHDRAWAL_WEIGHT = 70;
    uint256 public constant HUGE_RESERVE = 1e30;
    uint256 public constant EXIT_LIQUIDITY_TARGET = 1 ether;
    uint256 public constant DEPOSIT_COOLDOWN = 6 hours;

    // ============ State Variables ============
    Registry public registry;
    ExitQueue public exitQueue;
    AMM public amm;
    Controller public controller;
    StrategyManager public strategyManager;
    Oracle public oracle;
    EVE public token;
    StrategyKeeperExecutor public executor;
    QueueKeeperExecutor public queueExecutor;
    MockStrategy public strategy;

    address public admin;
    address public forwarder;
    address public user;

    // ============ Setup ============
    function setUp() public {
        admin = address(this);
        forwarder = makeAddr("forwarder");
        user = makeAddr("user");

        ProtocolContracts memory contracts = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        strategyManager = contracts.strategyManager;
        oracle = contracts.oracle;
        amm = contracts.amm;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        strategy = new MockStrategy("Strategy", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy), STRATEGY_DEPOSIT_WEIGHT, STRATEGY_WITHDRAWAL_WEIGHT);

        executor = new StrategyKeeperExecutor(address(registry));
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));
        executor.setForwarder(forwarder);

        // Deploy and register both keepers so the strategy executor can anchor
        // its pending-redemption scan at the queue cursor
        queueExecutor = new QueueKeeperExecutor(address(registry));
        registry.registerContract(Auth.QUEUE_KEEPER_EXECUTOR, address(queueExecutor));
        registry.registerContract(Auth.STRATEGY_KEEPER_EXECUTOR, address(executor));
        registry.grantRole(Auth.KEEPER_ROLE, address(queueExecutor));
        queueExecutor.setForwarder(forwarder);

        // Bootstrap the AMM; the deposit lands on the Controller as idle ETH
        vm.deal(user, BOOTSTRAP_DEPOSIT);
        vm.prank(user);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(MIN_TOKENS_TO_MINT);
    }

    // ============ Helpers ============

    function _performUpkeep(bytes memory _performData) internal {
        vm.prank(forwarder);
        executor.performUpkeep(_performData);
    }

    /// @dev Enables the ProvideExitLiquidity action at EXIT_LIQUIDITY_TARGET (deploy default is 0)
    function _enableExitLiquidityFloat() internal {
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);
    }

    /// @dev Tops the AMM immediate-exit float up to the executor's target
    function _fundAmmFloatToTarget() internal {
        _enableExitLiquidityFloat();
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));
    }

    function _queuePricedExit() internal returns (uint256 batchId) {
        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        batchId = amm.exit(EXIT_ETH, token.balanceOf(user), PRICE_TOLERANCE);
        vm.stopPrank();

        // Deploy the idle Controller ETH into the strategy (the executor keeps
        // the pending redemption estimate on the Controller), then track the
        // deposited ETH in the mock's NAV so the base price stays in band
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
        strategy.setNavInETH(address(strategy).balance);

        vm.prank(address(executor));
        controller.priceBatch();

        // Drain the Controller so the priced batch faces a liquidity shortfall
        vm.deal(address(controller), 0);
        strategy.setNavInETH(address(strategy).balance + EXIT_ETH); // keep NAV in band for later pricing reads
    }

    // ============ checkUpkeep Tests ============

    function test_CheckUpkeep_IdleControllerETH_ReturnsDepositExcess() public {
        // exitLiquidityTargetETH defaults to 0 (disabled), so idle ETH → DepositExcess
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
    }

    function test_CheckUpkeep_ReserveCoversBalance_NoDeposit() public {
        executor.setControllerReserveETH(HUGE_RESERVE);
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_NoDepositCapacity_NoDeposit() public {
        strategy.setMaxDeposit(0);
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_UnhealthyStrategy_ReturnsRebalance() public {
        strategy.setIsHealthy(false);

        // Rebalance outranks the pending deposit
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.Rebalance));
    }

    function test_CheckUpkeep_UnhealthyButPausedStrategy_NoRebalance() public {
        strategy.setIsHealthy(false);
        strategy.setPaused(true);

        // Paused strategies are never rebalanced, and an unhealthy strategy
        // accepts no deposits — with float funding disabled by default, nothing
        // is actionable
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_RedemptionShortfall_ReturnsWithdraw() public {
        _queuePricedExit();

        // All liquidity sits in the strategy; the priced batch needs ETH on the Controller
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall));
    }

    function test_CheckUpkeep_ShortfallButNothingWithdrawable_ReturnsFalse() public {
        _queuePricedExit();
        strategy.setMaxWithdrawal(0);
        strategy.setMaxDeposit(0);

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_SyncIntervalElapsed_ReturnsSync() public {
        vm.deal(address(controller), 0); // no deposit-worthy idle ETH

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);

        vm.warp(block.timestamp + executor.syncInterval());
        bytes memory performData;
        (upkeepNeeded, performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.Sync));
    }

    function test_CheckUpkeep_SyncDisabled_ReturnsFalse() public {
        vm.deal(address(controller), 0);
        executor.setSyncInterval(0);

        vm.warp(block.timestamp + 365 days);
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_WhenExecutorPaused_ReturnsFalse() public {
        executor.pause();
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_WhenProtocolPaused_ReturnsFalse() public {
        controller.pause();
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
        controller.unpause();

        strategyManager.pause();
        (upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    // ============ performUpkeep Tests ============

    function test_PerformUpkeep_AccessControl() public {
        bytes memory performData = abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess);

        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorOnlyForwarder.selector);
        executor.performUpkeep(performData);

        vm.prank(user);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorOnlyForwarder.selector);
        executor.performUpkeep(performData);
    }

    function test_PerformUpkeep_DepositExcess() public {
        uint256 idleETH = address(controller).balance;
        assertEq(idleETH, BOOTSTRAP_DEPOSIT);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.DepositExcess, idleETH
        );
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));

        assertEq(address(controller).balance, 0);
        assertEq(address(strategy).balance, idleETH);
    }

    function test_PerformUpkeep_DepositExcess_RespectsReserve() public {
        uint256 reserve = 4 ether;
        executor.setControllerReserveETH(reserve);

        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));

        assertEq(address(controller).balance, reserve);
        assertEq(address(strategy).balance, BOOTSTRAP_DEPOSIT - reserve);
    }

    function test_PerformUpkeep_Rebalance() public {
        strategy.setIsHealthy(false);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(IStrategyKeeperExecutor.StrategyAction.Rebalance, 0);
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.Rebalance));

        assertTrue(strategy.isHealthy());
    }

    function test_PerformUpkeep_WithdrawShortfall() public {
        _queuePricedExit();
        uint256 needsETH = executor.pendingRedemptionNeedsETH();
        assertGt(needsETH, 0);

        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall));

        // The Controller now holds enough to settle the priced batch
        assertGe(address(controller).balance, needsETH);
    }

    function test_PerformUpkeep_Sync() public {
        vm.deal(address(controller), 0);
        vm.warp(block.timestamp + executor.syncInterval());

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(IStrategyKeeperExecutor.StrategyAction.Sync, 0);
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.Sync));

        assertEq(executor.lastSyncAt(), block.timestamp);

        // Interval restarts: an immediate second sync is stale
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.Sync));
    }

    function test_PerformUpkeep_StaleData_InvalidConditions() public {
        // Rebalance with all strategies healthy
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.Rebalance));

        // Withdraw without any redemption shortfall
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall));

        // Deposit with no idle excess
        vm.deal(address(controller), 0);
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
    }

    function test_PerformUpkeep_UnknownAction() public {
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorUnknownAction.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.None));
    }

    function test_PerformUpkeep_WhenPaused() public {
        executor.pause();

        vm.prank(forwarder);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
    }

    // ============ Deposit Cooldown Tests (PR #243 review) ============

    /// @dev Enables the post-withdrawal deposit cooldown and deploys the idle
    /// Controller ETH into the registered strategies via the keeper
    function _enableCooldownAndDeposit() internal {
        strategyManager.setStrategyDepositCooldown(DEPOSIT_COOLDOWN);
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
        assertEq(address(controller).balance, 0);
    }

    function test_DepositExcess_AllStrategiesInDepositCooldown() public {
        _enableCooldownAndDeposit();

        // Withdraw through the production path: the cooldown starts while the
        // Controller again holds deposit-worthy excess
        vm.prank(address(executor));
        controller.withdrawFromStrategies(4 ether);

        assertTrue(strategyManager.isStrategyInDepositCooldown(address(strategy)));
        assertGe(address(controller).balance, executor.minDepositETH());

        // A lower-priority action is actionable: accrued performance fees
        _configurePerformanceFees();
        strategy.setUnchargedLpFeeBaseInETH(1 ether);
        strategy.setNavInETH(address(strategy).balance); // mint formula needs NAV backing

        // checkUpkeep must NOT select DepositExcess: the batch deposit would skip
        // the cooled strategy, refund everything, and the upkeep would repeat
        // every cycle — the executor falls through to the lower-priority action
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees));

        // Stale DepositExcess performData is rejected like the other actions
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));

        // The lower-priority action actually executes during the cooldown window
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees));
        assertEq(strategyManager.pendingPerformanceFeeInETH(address(strategy)), 0);

        // After the cooldown expires, DepositExcess is selectable and deposits again
        vm.warp(block.timestamp + DEPOSIT_COOLDOWN);
        assertFalse(strategyManager.isStrategyInDepositCooldown(address(strategy)));

        (upkeepNeeded, performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));

        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
        assertEq(address(controller).balance, 0);
        assertEq(address(strategy).balance, BOOTSTRAP_DEPOSIT);
    }

    function test_DepositExcess_PartialCooldown_DepositsIntoAvailableStrategy() public {
        MockStrategy strategy2 = new MockStrategy("Strategy2", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy2), STRATEGY_DEPOSIT_WEIGHT, STRATEGY_WITHDRAWAL_WEIGHT);

        _enableCooldownAndDeposit(); // equal deposit weights: 5 ETH per strategy

        // Cool only the first strategy; the Controller holds the withdrawn excess
        vm.prank(address(executor));
        controller.withdrawFromStrategy(address(strategy), 2 ether);

        assertTrue(strategyManager.isStrategyInDepositCooldown(address(strategy)));
        assertFalse(strategyManager.isStrategyInDepositCooldown(address(strategy2)));

        // Capacity via the uncooled strategy keeps DepositExcess selectable
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));

        uint256 cooledBefore = address(strategy).balance;
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));

        // The batch deposit skips the cooled strategy; all of the excess lands
        // in the available one
        assertEq(address(strategy).balance, cooledBefore);
        assertEq(address(strategy2).balance, BOOTSTRAP_DEPOSIT - cooledBefore);
        assertEq(address(controller).balance, 0);
    }

    // ============ ProvideExitLiquidity Tests ============

    function test_CheckUpkeep_LowAmmFloat_ReturnsProvideExitLiquidity() public {
        _enableExitLiquidityFloat();

        // Bootstrap left all ETH on the Controller; the AMM float is empty
        assertEq(amm.freeBalance(), 0);
        assertLt(amm.freeBalance(), executor.exitLiquidityTargetETH());

        // Outranks DepositExcess despite the idle Controller ETH
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));
    }

    function test_CheckUpkeep_FloatAtTarget_NoProvideExitLiquidity() public {
        _fundAmmFloatToTarget();
        assertEq(amm.freeBalance(), executor.exitLiquidityTargetETH());

        // Falls through to the next actionable action (idle excess → DepositExcess)
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
    }

    function test_CheckUpkeep_FloatTargetZero_DisablesAction() public {
        // Deploy default: target 0 disables ProvideExitLiquidity (same pattern as reserve)
        assertEq(executor.exitLiquidityTargetETH(), 0);

        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));

        _enableExitLiquidityFloat();
        (upkeepNeeded, performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));

        executor.setExitLiquidityTargetETH(0);
        (upkeepNeeded, performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
    }

    function test_CheckUpkeep_TopUpBelowMin_NoProvideExitLiquidity() public {
        _enableExitLiquidityFloat();
        // Leave less than minExitLiquidityTopUpETH of idle excess above the reserve
        executor.setControllerReserveETH(BOOTSTRAP_DEPOSIT - executor.minExitLiquidityTopUpETH() / 2);

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_PerformUpkeep_ProvideExitLiquidity() public {
        _enableExitLiquidityFloat();
        uint256 target = executor.exitLiquidityTargetETH();
        uint256 controllerBefore = address(controller).balance;

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity, target
        );
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));

        assertEq(amm.freeBalance(), target);
        assertEq(address(controller).balance, controllerBefore - target);
    }

    function test_PerformUpkeep_ProvideExitLiquidity_EnablesImmediateExit() public {
        _enableExitLiquidityFloat();
        uint256 smallExit = amm.minBatchExitETH() / 2; // below the queued-exit floor

        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        uint256 maxBurn = token.balanceOf(user);

        // M-5: with an empty float the sub-minBatchExitETH exit reverts (and any
        // larger exit would queue) — immediate exit is dead code
        vm.expectRevert(IAMM.AMMTooLowBatchExitETH.selector);
        amm.exit(smallExit, maxBurn, PRICE_TOLERANCE);
        vm.stopPrank();

        // The keeper tops up the float through the production wiring
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));

        // The same exit now settles immediately instead of reverting/queuing
        vm.prank(user);
        uint256 ethBefore = user.balance;
        uint256 batchId = amm.exit(smallExit, maxBurn, PRICE_TOLERANCE);

        assertEq(batchId, 0); // not queued
        assertApproxEqAbs(user.balance - ethBefore, smallExit, 1e6);
    }

    function test_PerformUpkeep_ProvideExitLiquidity_PartialTopUp() public {
        _enableExitLiquidityFloat();
        // Reserve all but 0.5 ether of the idle ETH: the top-up is capped at the excess
        uint256 partialTopUp = 0.5 ether;
        executor.setControllerReserveETH(BOOTSTRAP_DEPOSIT - partialTopUp);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity, partialTopUp
        );
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));

        assertEq(amm.freeBalance(), partialTopUp); // below target, capped by the excess
        assertEq(address(controller).balance, BOOTSTRAP_DEPOSIT - partialTopUp);
    }

    function test_PerformUpkeep_ProvideExitLiquidity_RespectsPendingNeeds() public {
        _enableExitLiquidityFloat();
        // Queue an unpriced exit: the estimate counts it as pending needs
        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        amm.exit(EXIT_ETH, token.balanceOf(user), PRICE_TOLERANCE);
        vm.stopPrank();

        uint256 needsETH = executor.pendingRedemptionNeedsETH();
        assertGt(needsETH, 0);

        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));

        // The float is topped to target while the pending redemption needs stay
        // covered on the Controller
        assertEq(amm.freeBalance(), executor.exitLiquidityTargetETH());
        assertGe(address(controller).balance, needsETH);
    }

    function test_PerformUpkeep_ProvideExitLiquidity_StaleData() public {
        // Float already at target
        _fundAmmFloatToTarget();
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));

        // Action disabled
        executor.setExitLiquidityTargetETH(0);
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));
    }

    function test_PerformUpkeep_ProvideExitLiquidity_WhenControllerPaused() public {
        _enableExitLiquidityFloat();
        controller.pause();

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);

        vm.prank(forwarder);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));
    }

    function test_ProvideExitLiquidity_UnauthorizedCaller_Reverts() public {
        // Only KEEPER_ROLE (the executors) can fund the float — not users, not
        // the Chainlink Forwarder
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.KEEPER_ROLE));
        controller.provideExitLiquidity(1 ether);

        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.KEEPER_ROLE));
        controller.provideExitLiquidity(1 ether);

        // And the executor path itself is gated to the Chainlink Forwarder
        vm.prank(user);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorOnlyForwarder.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));
    }

    function test_SetExitLiquidityTargetETH() public {
        uint256 newTarget = 5 ether;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.ExitLiquidityTargetETHChanged(executor.exitLiquidityTargetETH(), newTarget);
        executor.setExitLiquidityTargetETH(newTarget);
        assertEq(executor.exitLiquidityTargetETH(), newTarget);
    }

    function test_SetMinExitLiquidityTopUpETH() public {
        uint256 newMin = 0.1 ether;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinExitLiquidityTopUpETHChanged(executor.minExitLiquidityTopUpETH(), newMin);
        executor.setMinExitLiquidityTopUpETH(newMin);
        assertEq(executor.minExitLiquidityTopUpETH(), newMin);
    }

    function test_SetMinExitLiquidityTopUpETH_InvalidInputs() public {
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorInvalidConfig.selector);
        executor.setMinExitLiquidityTopUpETH(0);
    }

    // ============ View Function Tests ============

    function test_PendingRedemptionNeedsETH() public {
        assertEq(executor.pendingRedemptionNeedsETH(), 0);

        // Unpriced request: estimated at the AMM base price
        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        amm.exit(EXIT_ETH, token.balanceOf(user), PRICE_TOLERANCE);
        vm.stopPrank();

        assertApproxEqAbs(executor.pendingRedemptionNeedsETH(), EXIT_ETH, 1e6);
    }

    // ============ Admin Function Tests ============

    function test_SetControllerReserveETH() public {
        uint256 newReserve = 1 ether;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.ControllerReserveETHChanged(0, newReserve);
        executor.setControllerReserveETH(newReserve);
        assertEq(executor.controllerReserveETH(), newReserve);
    }

    function test_SetMinDepositETH() public {
        uint256 newMin = 1 ether;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinDepositETHChanged(executor.minDepositETH(), newMin);
        executor.setMinDepositETH(newMin);
        assertEq(executor.minDepositETH(), newMin);
    }

    function test_SetMinDepositETH_InvalidInputs() public {
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorInvalidConfig.selector);
        executor.setMinDepositETH(0);
    }

    function test_SetMinWithdrawETH() public {
        uint256 newMin = 1 ether;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinWithdrawETHChanged(executor.minWithdrawETH(), newMin);
        executor.setMinWithdrawETH(newMin);
        assertEq(executor.minWithdrawETH(), newMin);
    }

    function test_SetMinHarvestETH() public {
        uint256 newMin = 1 ether;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinHarvestETHChanged(executor.minHarvestETH(), newMin);
        executor.setMinHarvestETH(newMin);
        assertEq(executor.minHarvestETH(), newMin);
    }

    function test_SetMinHarvestETH_InvalidInputs() public {
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorInvalidConfig.selector);
        executor.setMinHarvestETH(0);
    }

    function test_SetSyncInterval() public {
        uint256 newInterval = 12 hours;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.SyncIntervalChanged(executor.syncInterval(), newInterval);
        executor.setSyncInterval(newInterval);
        assertEq(executor.syncInterval(), newInterval);
    }

    function test_Setters_AccessControl() public {
        vm.startPrank(user);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setControllerReserveETH(1);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinDepositETH(1);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinWithdrawETH(1);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinHarvestETH(1);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setSyncInterval(1);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setExitLiquidityTargetETH(1);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinExitLiquidityTopUpETH(1);

        vm.stopPrank();
    }

    function test_Version() public view {
        assertEq(executor.version(), "1.0.0");
    }

    // ============ HarvestPerformanceFees Tests ============

    function test_CheckUpkeep_AccruedFees_ReturnsHarvest() public {
        // Fees disabled by default: no harvest while bps == 0
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        // Idle Controller ETH would trigger DepositExcess first; drain it so
        // the harvest branch is the only actionable one
        vm.deal(address(controller), 0);

        _configurePerformanceFees();
        // Accrue uncharged LP fees so pending feeETH clears minHarvestETH
        strategy.setUnchargedLpFeeBaseInETH(1 ether);

        bytes memory performData;
        (upkeepNeeded, performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees));
    }

    function test_CheckUpkeep_AccruedFeesBelowMinHarvest_NoHarvest() public {
        _configurePerformanceFees();
        vm.deal(address(controller), 0);
        // 0.05 ether uncharged @ 10% bps → 0.005 ETH fee < default minHarvestETH
        strategy.setUnchargedLpFeeBaseInETH(0.05 ether);

        uint256 feeETH = strategyManager.pendingPerformanceFeeInETH(address(strategy));
        assertGt(feeETH, 0);
        assertLt(feeETH, executor.minHarvestETH());

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_NoAccruedFees_NoHarvest() public {
        _configurePerformanceFees();
        vm.deal(address(controller), 0);
        // No uncharged LP fees → no pending performance fee

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_FeesDisabled_NoHarvest() public {
        // performanceFeeBps stays 0 (default); even with uncharged LP fees, no harvest
        vm.deal(address(controller), 0);
        strategy.setUnchargedLpFeeBaseInETH(1 ether);

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_PerformUpkeep_HarvestPerformanceFees() public {
        _configurePerformanceFees();
        strategy.setUnchargedLpFeeBaseInETH(1 ether);
        // Mint formula needs non-zero strategy NAV backing
        strategy.setNavInETH(10 ether);

        uint256 feeETH = strategyManager.pendingPerformanceFeeInETH(address(strategy));
        assertGt(feeETH, 0);

        uint256 treasuryBefore = token.balanceOf(TEST_DAO_TREASURY);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees, feeETH
        );
        _performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees));

        assertGt(token.balanceOf(TEST_DAO_TREASURY), treasuryBefore);
        // Settlement marks LP fees charged: no further fee pending
        assertEq(strategyManager.pendingPerformanceFeeInETH(address(strategy)), 0);
    }

    function test_PerformUpkeep_HarvestPerformanceFees_StaleData() public {
        // No fee accrued → performUpkeep must reject stale performData
        vm.deal(address(controller), 0);
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees));
    }

    function test_PerformUpkeep_HarvestPerformanceFees_BelowMinHarvest() public {
        _configurePerformanceFees();
        vm.deal(address(controller), 0);
        strategy.setUnchargedLpFeeBaseInETH(0.05 ether);

        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees));
    }

    /// @dev Enables performance fees and sets a non-zero DAO treasury
    function _configurePerformanceFees() internal {
        strategyManager.setPerformanceFeeBps(1_000); // 10%
        strategyManager.setDaoTreasury(TEST_DAO_TREASURY);
    }

    // ============ MAX_BATCH_SCAN Boundary Tests ============

    function test_PendingRedemptionNeedsETH_ScansForwardFromQueueCursor() public {
        // Build a backlog larger than MAX_BATCH_SCAN where the oldest unprocessed
        // batch (at the queue cursor) carries liability. Price via Controller
        // directly (no minBatchAge warps) so batches stay inside
        // MAX_BATCH_PROCESSING_TIME and are not auto-skipped as post-commitment.
        uint256 maxScan = executor.MAX_BATCH_SCAN();
        uint256 backlog = maxScan + 1;

        uint256 smallExit = 0.01 ether;
        uint256 tokensPerUser = 500e18;

        address[] memory users = new address[](backlog);
        for (uint256 i = 0; i < backlog; i++) {
            users[i] = makeAddr(string(abi.encodePacked("u", i)));
            vm.prank(user);
            token.transfer(users[i], tokensPerUser);
        }

        registry.grantRole(Auth.KEEPER_ROLE, address(this));
        for (uint256 i = 0; i < backlog; i++) {
            vm.startPrank(users[i]);
            token.approve(address(amm), type(uint256).max);
            amm.exit(smallExit, token.balanceOf(users[i]), PRICE_TOLERANCE);
            vm.stopPrank();
            controller.priceBatch();
        }

        // The queue cursor is still at batch 1 (nothing processed); the backlog
        // exceeds MAX_BATCH_SCAN
        assertEq(queueExecutor.nextBatchIdToProcess(), 1);
        assertGt(exitQueue.currentBatchId() - queueExecutor.nextBatchIdToProcess(), maxScan);
        assertEq(queueExecutor.nextLiveBatchIdToProcess(), 1);

        // The oldest batch (1) is included in the forward scan from the live cursor
        uint256 needsETH = executor.pendingRedemptionNeedsETH();
        assertGt(needsETH, 0);
        assertGe(needsETH, smallExit);
    }
}
