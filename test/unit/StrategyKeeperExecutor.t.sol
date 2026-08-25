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
import {QueueKeeperExecutor} from "../../src/contracts/automation/QueueKeeperExecutor.sol";
import {StrategyKeeperExecutor} from "../../src/contracts/automation/StrategyKeeperExecutor.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IKeeperExecutorBase} from "../../src/interfaces/automation/IKeeperExecutorBase.sol";
import {IStrategyKeeperExecutor} from "../../src/interfaces/automation/IStrategyKeeperExecutor.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title StrategyKeeperExecutorTest
 * @notice Unit tests for the Gelato strategy keeper executor (on-chain checker + perform).
 */
contract StrategyKeeperExecutorTest is ProtocolTestBase {
    uint256 public constant ETH_PRICE = 4000e8;
    uint256 public constant STALENESS_INTERVAL = 3600;
    uint256 public constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 public constant SETUP_WARP = 10 days;
    uint256 public constant MIN_TOKENS_TO_MINT = 1;
    uint256 public constant PRICE_TOLERANCE = 1e17;

    uint256 public constant DEPOSIT_TO_STRATEGY = 9.5 ether;
    uint256 public constant EXIT_ETH = 1 ether;
    uint256 public constant EXIT_LIQUIDITY_TARGET = 2 ether;

    uint8 public constant DEPOSIT_WEIGHT = 100;
    uint8 public constant WITHDRAWAL_WEIGHT = 100;
    uint8 public constant ZERO_DEPOSIT_WEIGHT = 0;
    uint256 public constant CAPPED_MAX_DEPOSIT = 1 ether;

    uint256 public constant PERFORMANCE_FEE_BPS = 1_000; // 10%
    uint256 public constant UNCHARGED_LP_FEES = 1 ether; // → 0.1 ETH pending fee

    uint256 public constant DEFAULT_MIN_DEPOSIT_ETH = 0.1 ether;
    uint256 public constant DEFAULT_MIN_WITHDRAW_ETH = 0.01 ether;
    uint256 public constant DEFAULT_MIN_HARVEST_ETH = 0.01 ether;
    uint256 public constant DEFAULT_SYNC_INTERVAL = 1 days;
    uint256 public constant DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH = 0.01 ether;

    Registry public registry;
    ExitQueue public exitQueue;
    AMM public amm;
    Controller public controller;
    StrategyManager public strategyManager;
    Oracle public oracle;
    EVE public token;
    MockPriceFeed public ethPriceFeed;
    QueueKeeperExecutor public queueExecutor;
    StrategyKeeperExecutor public executor;
    MockStrategy public strategy;

    address public admin;
    address public gelatoProxy;
    address public user;
    address public outsider;

    function setUp() public {
        admin = address(this);
        gelatoProxy = makeAddr("gelatoDedicatedMsgSender");
        user = makeAddr("user");
        outsider = makeAddr("outsider");

        ProtocolContracts memory contracts = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        strategyManager = contracts.strategyManager;
        oracle = contracts.oracle;
        amm = contracts.amm;

        ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        queueExecutor = new QueueKeeperExecutor(address(registry));
        executor = new StrategyKeeperExecutor(address(registry));

        bytes32[] memory keys = new bytes32[](2);
        address[] memory addresses = new address[](2);
        keys[0] = Auth.QUEUE_KEEPER_EXECUTOR;
        addresses[0] = address(queueExecutor);
        keys[1] = Auth.STRATEGY_KEEPER_EXECUTOR;
        addresses[1] = address(executor);
        registry.registerContracts(keys, addresses);

        registry.grantRole(Auth.KEEPER_ROLE, address(queueExecutor));
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));

        // Executors start inert; the Gelato task's dedicated msg.sender is bound
        // after task creation (the address only exists then).
        executor.allowExecutorCaller(gelatoProxy);

        strategy = new MockStrategy("Mock Strategy", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy), DEPOSIT_WEIGHT, WITHDRAWAL_WEIGHT);

        // Bootstrap: all of `msg.value` is forwarded to the Controller, so the AMM free
        // balance starts at ~0 and exits queue rather than settling immediately.
        vm.deal(user, BOOTSTRAP_DEPOSIT);
        vm.prank(user);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(MIN_TOKENS_TO_MINT);
    }

    // ============ Helpers ============

    function _perform(IStrategyKeeperExecutor.StrategyAction action) internal {
        vm.prank(gelatoProxy);
        executor.perform(uint8(action));
    }

    function _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction action) internal {
        vm.prank(gelatoProxy);
        vm.expectRevert(IStrategyKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector);
        executor.perform(uint8(action));
    }

    /// @dev Moves `DEPOSIT_TO_STRATEGY` out of the Controller and into the strategy so pending
    ///      redemption needs can exceed the Controller balance. The mock does not derive NAV
    ///      from its balance, so report it explicitly — otherwise total NAV drops by the
    ///      deployed amount and AMM pricing (which the exit path uses) is wrong.
    function _deployCapitalToStrategy() internal {
        controller.depositToStrategies(DEPOSIT_TO_STRATEGY);
        strategy.setNavInETH(DEPOSIT_TO_STRATEGY);
    }

    function _queueExit(address _user, uint256 _requestedETH) internal returns (uint256 batchId) {
        vm.startPrank(_user);
        token.approve(address(amm), type(uint256).max);
        batchId = amm.exit(_requestedETH, token.balanceOf(_user), PRICE_TOLERANCE);
        vm.stopPrank();
    }

    /// @dev `priceBatch` is Controller/KEEPER-gated; the strategy executor already holds the role.
    function _priceQueuedBatch() internal {
        vm.prank(address(executor));
        controller.priceBatch();
    }

    function _enablePerformanceFees() internal {
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);
        strategy.setUnchargedLpFeeBaseInETH(UNCHARGED_LP_FEES);
    }

    // ============ Caller allowlist auth ============

    // ============ Construction ============

    function test_Constructor_Defaults() public view {
        assertEq(executor.minDepositETH(), DEFAULT_MIN_DEPOSIT_ETH);
        assertEq(executor.minWithdrawETH(), DEFAULT_MIN_WITHDRAW_ETH);
        assertEq(executor.minHarvestETH(), DEFAULT_MIN_HARVEST_ETH);
        assertEq(executor.syncInterval(), DEFAULT_SYNC_INTERVAL);
        assertEq(executor.minExitLiquidityTopUpETH(), DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH);
        assertEq(executor.lastSyncAt(), block.timestamp);
        // Explicit deploy-time policy knobs — never defaulted to a non-zero value.
        assertEq(executor.controllerReserveETH(), 0);
        assertEq(executor.exitLiquidityTargetETH(), 0);
        assertEq(executor.version(), "2.0.0-gelato");
    }

    function test_Perform_InertUntilCallerAllowed() public {
        StrategyKeeperExecutor fresh = new StrategyKeeperExecutor(address(registry));
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoAllowedCallers.selector);
        vm.prank(gelatoProxy);
        fresh.perform(uint8(IStrategyKeeperExecutor.StrategyAction.Sync));
    }

    function test_Perform_OnlyAllowlistedCaller() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IKeeperExecutorBase.KeeperExecutorUnauthorizedCaller.selector, outsider));
        executor.perform(uint8(IStrategyKeeperExecutor.StrategyAction.Sync));

        // The allowlisted proxy still goes through.
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);
        _perform(IStrategyKeeperExecutor.StrategyAction.Sync);
        assertEq(executor.lastSyncAt(), block.timestamp);
    }

    function test_AllowExecutorCaller_OnlyAdmin() public {
        vm.prank(outsider);
        vm.expectRevert(); // RegistryClientMissingRole
        executor.allowExecutorCaller(makeAddr("other"));
    }

    function test_RemoveExecutorCaller_RestoresInert() public {
        executor.removeExecutorCaller(gelatoProxy);
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);

        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoAllowedCallers.selector);
        vm.prank(gelatoProxy);
        executor.perform(uint8(IStrategyKeeperExecutor.StrategyAction.Sync));
    }

    function test_AllowExecutorCaller_RejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IKeeperExecutorBase.KeeperExecutorUnauthorizedCaller.selector, address(0)));
        executor.allowExecutorCaller(address(0));
    }

    // ============ Pause ============

    function test_WhenPaused_PerformReverts() public {
        executor.pause();
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(gelatoProxy);
        executor.perform(uint8(IStrategyKeeperExecutor.StrategyAction.Sync));
    }

    // ============ Checker ============

    function test_Checker_NoWork_CannotExec() public {
        // Drain idle Controller ETH so no funding action outranks "nothing to do".
        _perform(IStrategyKeeperExecutor.StrategyAction.DepositExcess);

        (IStrategyKeeperExecutor.StrategyAction statusAction,) = executor.strategyUpkeepStatus();
        assertEq(uint8(statusAction), uint8(IStrategyKeeperExecutor.StrategyAction.None));

        (bool canExec, bytes memory execPayload) = executor.checker();
        assertTrue(!canExec);
        // Not empty: Gelato expects a human-readable reason string when canExec=false.
        assertTrue(execPayload.length > 0);
    }

    function test_Checker_SyncDue_ExecPayloadTargetsPerform() public {
        // Drain idle Controller ETH: DepositExcess outranks Sync, so Sync only surfaces
        // once the controller has nothing better to do.
        _perform(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);

        (IStrategyKeeperExecutor.StrategyAction statusAction,) = executor.strategyUpkeepStatus();
        (bool canExec, bytes memory execPayload) = executor.checker();
        assertEq(uint8(statusAction), uint8(IStrategyKeeperExecutor.StrategyAction.Sync));
        assertTrue(canExec);
        assertTrue(execPayload.length > 4);

        // execPayload is the exact calldata for perform: submitting it as the
        // allowlisted proxy must run the sync.
        vm.prank(gelatoProxy);
        (bool ok,) = address(executor).call(execPayload);
        assertTrue(ok);
        assertEq(executor.lastSyncAt(), block.timestamp);
    }

    function test_Checker_MirrorsStrategyUpkeepStatus() public {
        strategy.setIsHealthy(false);

        (IStrategyKeeperExecutor.StrategyAction statusAction,) = executor.strategyUpkeepStatus();
        (bool canExec, bytes memory execPayload) = executor.checker();
        assertEq(uint8(statusAction), uint8(IStrategyKeeperExecutor.StrategyAction.Rebalance));
        assertTrue(canExec);

        vm.prank(gelatoProxy);
        (bool ok,) = address(executor).call(execPayload);
        assertTrue(ok);
        assertTrue(strategy.isHealthy());
    }

    // ============ Unknown action ============

    function test_Perform_UnknownAction() public {
        vm.prank(gelatoProxy);
        vm.expectRevert(IStrategyKeeperExecutor.KeeperExecutorUnknownAction.selector);
        executor.perform(uint8(IStrategyKeeperExecutor.StrategyAction.None));
    }

    function test_MaxBatchScan_MatchesExitQueueLiveCap() public view {
        assertEq(executor.MAX_BATCH_SCAN(), exitQueue.MAX_LIVE_PRICED_BATCHES());
        assertEq(queueExecutor.MAX_BATCH_SCAN(), exitQueue.MAX_LIVE_PRICED_BATCHES());
    }

    // ============ Rebalance ============

    function test_Rebalance_NoUpkeepWhenAllHealthy() public {
        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != IStrategyKeeperExecutor.StrategyAction.Rebalance);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.Rebalance);
    }

    function test_Rebalance_WhenStrategyUnhealthy() public {
        strategy.setIsHealthy(false);

        (IStrategyKeeperExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.Rebalance));
        assertEq(amount, 0);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(IStrategyKeeperExecutor.StrategyAction.Rebalance, 0);
        _perform(IStrategyKeeperExecutor.StrategyAction.Rebalance);

        assertTrue(strategy.isHealthy());
    }

    function test_Rebalance_SkipsPausedStrategy() public {
        strategy.setIsHealthy(false);
        strategy.setPaused(true);

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != IStrategyKeeperExecutor.StrategyAction.Rebalance);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.Rebalance);
    }

    // ============ DepositExcess ============

    function test_DepositExcess_DeploysIdleControllerETH() public {
        uint256 controllerBalance = address(controller).balance;
        assertGt(controllerBalance, DEFAULT_MIN_DEPOSIT_ETH);

        (IStrategyKeeperExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
        assertEq(amount, controllerBalance);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.DepositExcess, controllerBalance
        );
        _perform(IStrategyKeeperExecutor.StrategyAction.DepositExcess);

        assertEq(address(strategy).balance, controllerBalance);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositExcess_RespectsControllerReserve() public {
        // Reserve everything: nothing is excess, so the action must be rejected.
        executor.setControllerReserveETH(address(controller).balance);

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
    }

    function test_DepositExcess_NoUpkeepWithoutCapacity() public {
        strategy.setMaxDeposit(0);

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
    }

    function test_DepositExcess_NoUpkeepWhenDepositWeightZero() public {
        strategyManager.setDepositWeight(address(strategy), ZERO_DEPOSIT_WEIGHT);

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
    }

    function test_DepositExcess_EmitsActualWhenCappedByMaxDeposit() public {
        strategy.setMaxDeposit(CAPPED_MAX_DEPOSIT);

        uint256 controllerBalance = address(controller).balance;
        assertGt(controllerBalance, CAPPED_MAX_DEPOSIT);

        (IStrategyKeeperExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
        assertEq(amount, controllerBalance);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.DepositExcess, CAPPED_MAX_DEPOSIT
        );
        _perform(IStrategyKeeperExecutor.StrategyAction.DepositExcess);

        assertEq(address(strategy).balance, CAPPED_MAX_DEPOSIT);
        assertEq(address(controller).balance, controllerBalance - CAPPED_MAX_DEPOSIT);
    }

    // ============ WithdrawShortfall ============

    function test_WithdrawShortfall_PullsFromStrategies() public {
        _deployCapitalToStrategy();
        _queueExit(user, EXIT_ETH);
        _priceQueuedBatch();

        uint256 needsETH = executor.pendingRedemptionNeedsETH();
        uint256 controllerBalance = address(controller).balance;
        assertGt(needsETH, controllerBalance);
        uint256 shortfall = needsETH - controllerBalance;

        (IStrategyKeeperExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall));
        assertEq(amount, shortfall);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall, shortfall
        );
        _perform(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);

        assertEq(address(controller).balance, controllerBalance + shortfall);
    }

    function test_WithdrawShortfall_NoUpkeepWhenUnpriced() public {
        _deployCapitalToStrategy();
        _queueExit(user, EXIT_ETH);
        assertEq(executor.pendingRedemptionNeedsETH(), 0);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
    }

    function test_WithdrawShortfall_NoUpkeepWhenCovered() public {
        // Controller still holds the full bootstrap deposit — nothing to pull.
        _queueExit(user, EXIT_ETH);
        _priceQueuedBatch();
        assertLe(executor.pendingRedemptionNeedsETH(), address(controller).balance);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
    }

    // ============ ProvideExitLiquidity ============

    function test_ProvideExitLiquidity_DisabledWhenTargetZero() public {
        assertEq(executor.exitLiquidityTargetETH(), 0);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity);
    }

    function test_ProvideExitLiquidity_TopsUpAmmFloat() public {
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);
        uint256 floatBefore = amm.freeBalance();
        assertLt(floatBefore, EXIT_LIQUIDITY_TARGET);
        uint256 topUp = EXIT_LIQUIDITY_TARGET - floatBefore;

        (IStrategyKeeperExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));
        assertEq(amount, topUp);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity, topUp
        );
        _perform(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity);

        assertEq(amm.freeBalance(), EXIT_LIQUIDITY_TARGET);
    }

    function test_ProvideExitLiquidity_NoUpkeepWhenTargetMet() public {
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);
        _perform(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity);

        // Float now sits at the target: a second top-up is not needed.
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity);
    }

    // ============ HarvestPerformanceFees ============

    function test_Harvest_NoUpkeepWhenFeesDisabled() public {
        assertEq(strategyManager.performanceFeeBps(), 0);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees);
    }

    function test_Harvest_MintsFeeToTreasury() public {
        _enablePerformanceFees();

        uint256 feeETH = strategyManager.pendingPerformanceFeeInETH(address(strategy));
        assertGe(feeETH, DEFAULT_MIN_HARVEST_ETH);
        uint256 treasuryBefore = token.balanceOf(TEST_DAO_TREASURY);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(
            IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees, feeETH
        );
        _perform(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees);

        assertGt(token.balanceOf(TEST_DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(address(strategy)), 0);
    }

    function test_Harvest_NoUpkeepBelowMinHarvest() public {
        _enablePerformanceFees();
        executor.setMinHarvestETH(type(uint256).max);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.HarvestPerformanceFees);
    }

    // ============ Sync ============

    function test_Sync_RateLimited() public {
        assertEq(executor.lastSyncAt(), block.timestamp);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.Sync);
    }

    function test_Sync_AfterInterval() public {
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);

        vm.expectEmit(true, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.StrategyUpkeepPerformed(IStrategyKeeperExecutor.StrategyAction.Sync, 0);
        _perform(IStrategyKeeperExecutor.StrategyAction.Sync);

        assertEq(executor.lastSyncAt(), block.timestamp);
        // Consecutive syncs are rate limited again.
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.Sync);
    }

    function test_Sync_DisabledWhenIntervalZero() public {
        executor.setSyncInterval(0);
        vm.warp(block.timestamp + SETUP_WARP);
        _expectNoUpkeep(IStrategyKeeperExecutor.StrategyAction.Sync);
    }

    // ============ strategyUpkeepStatus ============

    function test_StrategyUpkeepStatus_NoneWhenExecutorPaused() public {
        strategy.setIsHealthy(false);
        executor.pause();

        (IStrategyKeeperExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.None));
        assertEq(amount, 0);
    }

    function test_StrategyUpkeepStatus_NoneWhenControllerPaused() public {
        strategy.setIsHealthy(false);
        controller.pause();

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.None));
    }

    function test_StrategyUpkeepStatus_NoneWhenStrategyManagerPaused() public {
        strategy.setIsHealthy(false);
        strategyManager.pause();

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.None));
    }

    /// @dev Rebalance outranks every funding action — it is the only one that repairs the
    ///      NAV source the rest of the protocol prices against.
    function test_StrategyUpkeepStatus_RebalanceOutranksDeposit() public {
        strategy.setIsHealthy(false);
        assertGt(address(controller).balance, DEFAULT_MIN_DEPOSIT_ETH);

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.Rebalance));
    }

    function test_StrategyUpkeepStatus_ExitLiquidityOutranksDeposit() public {
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);

        (IStrategyKeeperExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.ProvideExitLiquidity));
    }

    function test_StrategyUpkeepStatus_NoneWhenNothingToDo() public {
        // Deploy all idle ETH, keep the strategy healthy, leave fees and exit target off.
        _perform(IStrategyKeeperExecutor.StrategyAction.DepositExcess);

        (IStrategyKeeperExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(IStrategyKeeperExecutor.StrategyAction.None));
        assertEq(amount, 0);
    }

    // ============ pendingRedemptionNeedsETH ============

    function test_PendingRedemptionNeedsETH_ZeroWithoutQueuedExits() public view {
        assertEq(executor.pendingRedemptionNeedsETH(), 0);
    }

    function test_PendingRedemptionNeedsETH_DoesNotCountUnpricedCurrentBatch() public {
        _queueExit(user, EXIT_ETH);
        assertEq(executor.pendingRedemptionNeedsETH(), 0);
    }

    function test_PendingRedemptionNeedsETH_CountsPricedInWindowBatch() public {
        _queueExit(user, EXIT_ETH);
        _priceQueuedBatch();
        assertApproxEqAbs(executor.pendingRedemptionNeedsETH(), EXIT_ETH, 1);
    }

    /// @dev The strategy executor reads the cursor from the registered queue executor — the
    ///      two executors must agree on which batch is next, or reserved ETH drifts.
    function test_PendingRedemptionNeedsETH_AnchoredAtQueueCursor() public {
        _queueExit(user, EXIT_ETH);
        assertEq(queueExecutor.nextLiveBatchIdToProcess(), exitQueue.currentBatchId());
        assertEq(executor.pendingRedemptionNeedsETH(), 0);

        uint256 pricedBatchId = exitQueue.currentBatchId();
        _priceQueuedBatch();
        assertEq(queueExecutor.nextLiveBatchIdToProcess(), pricedBatchId);
        assertGt(executor.pendingRedemptionNeedsETH(), 0);
    }

    // ============ Admin setters ============

    function test_Setters_AccessControl() public {
        vm.startPrank(outsider);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setControllerReserveETH(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinDepositETH(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinWithdrawETH(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinHarvestETH(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setSyncInterval(1 days);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setExitLiquidityTargetETH(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinExitLiquidityTopUpETH(1 ether);

        vm.stopPrank();
    }

    /// @dev Dust floors must stay non-zero: zeroing them would let the keeper burn gas on
    ///      economically pointless upkeeps.
    function test_Setters_RejectZeroDustFloors() public {
        vm.expectRevert(IStrategyKeeperExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMinDepositETH(0);

        vm.expectRevert(IStrategyKeeperExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMinHarvestETH(0);

        vm.expectRevert(IStrategyKeeperExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMinExitLiquidityTopUpETH(0);
    }

    /// @dev Zero IS a meaningful explicit choice for these: no reserve, action disabled,
    ///      sync disabled, no withdraw floor.
    function test_Setters_AcceptZeroWhereMeaningful() public {
        executor.setControllerReserveETH(0);
        executor.setExitLiquidityTargetETH(0);
        executor.setSyncInterval(0);
        executor.setMinWithdrawETH(0);

        assertEq(executor.controllerReserveETH(), 0);
        assertEq(executor.exitLiquidityTargetETH(), 0);
        assertEq(executor.syncInterval(), 0);
        assertEq(executor.minWithdrawETH(), 0);
    }

    function test_Setters_EmitEvents() public {
        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.ControllerReserveETHChanged(0, 1 ether);
        executor.setControllerReserveETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinDepositETHChanged(DEFAULT_MIN_DEPOSIT_ETH, 1 ether);
        executor.setMinDepositETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinWithdrawETHChanged(DEFAULT_MIN_WITHDRAW_ETH, 1 ether);
        executor.setMinWithdrawETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinHarvestETHChanged(DEFAULT_MIN_HARVEST_ETH, 1 ether);
        executor.setMinHarvestETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.SyncIntervalChanged(DEFAULT_SYNC_INTERVAL, 2 days);
        executor.setSyncInterval(2 days);

        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.ExitLiquidityTargetETHChanged(0, EXIT_LIQUIDITY_TARGET);
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);

        vm.expectEmit(false, false, false, true, address(executor));
        emit IStrategyKeeperExecutor.MinExitLiquidityTopUpETHChanged(DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH, 1 ether);
        executor.setMinExitLiquidityTopUpETH(1 ether);
    }

    function test_Pause_AccessControl() public {
        vm.prank(outsider);
        vm.expectRevert();
        executor.pause();

        executor.pause();
        assertTrue(executor.paused());

        executor.unpause();
        assertFalse(executor.paused());
    }
}
