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
import {CREQueueExecutor} from "../../src/contracts/automation/CREQueueExecutor.sol";
import {CREStrategyExecutor} from "../../src/contracts/automation/CREStrategyExecutor.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {ICREReceiverBase} from "../../src/interfaces/automation/ICREReceiverBase.sol";
import {ICREStrategyExecutor} from "../../src/interfaces/automation/ICREStrategyExecutor.sol";
import {IReceiver} from "../../src/interfaces/automation/IReceiver.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {CRETestUtils} from "../helpers/CRETestUtils.sol";

/**
 * @title CREStrategyExecutorTest
 * @notice Unit tests for the CRE strategy keeper receiver.
 * @dev Tree: `test/trees/CREStrategyExecutor.tree` (shared entrypoint branches live in
 *      `test/trees/CREReceiverBase.tree` and are exercised here and in CREQueueExecutor.t.sol).
 */
contract CREStrategyExecutorTest is ProtocolTestBase, CRETestUtils {
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
    CREQueueExecutor public queueExecutor;
    CREStrategyExecutor public executor;
    MockStrategy public strategy;

    address public admin;
    address public forwarder;
    address public workflowOwner;
    address public user;
    address public outsider;
    bytes32 public workflowId;
    bytes10 public workflowName;

    uint64 internal _seq;

    function setUp() public {
        admin = address(this);
        forwarder = makeAddr("keystoneForwarder");
        workflowOwner = makeAddr("workflowOwner");
        user = makeAddr("user");
        outsider = makeAddr("outsider");
        workflowId = keccak256("strategy-keeper-v1");
        workflowName = bytes10("strat-keep");

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

        // Move off timestamp 0 so `observedAt` can be pushed a full MAX_REPORT_AGE into the
        // past without underflowing, then refresh the feed so it is not stale after the warp.
        vm.warp(block.timestamp + SETUP_WARP);
        ethPriceFeed.setPrice(int256(ETH_PRICE));

        queueExecutor = new CREQueueExecutor(address(registry), forwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        executor = new CREStrategyExecutor(address(registry), forwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);

        bytes32[] memory keys = new bytes32[](2);
        address[] memory addresses = new address[](2);
        keys[0] = Auth.QUEUE_KEEPER_EXECUTOR;
        addresses[0] = address(queueExecutor);
        keys[1] = Auth.STRATEGY_KEEPER_EXECUTOR;
        addresses[1] = address(executor);
        registry.registerContracts(keys, addresses);

        registry.grantRole(Auth.KEEPER_ROLE, address(queueExecutor));
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));

        executor.setExpectedAuthor(workflowOwner);
        executor.setExpectedWorkflowName(workflowName);
        executor.setExpectedWorkflowId(workflowId);

        strategy = new MockStrategy("Mock Strategy", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy), DEPOSIT_WEIGHT, WITHDRAWAL_WEIGHT);

        // Bootstrap: all of `msg.value` is forwarded to the Controller, so the AMM free
        // balance starts at ~0 and exits queue rather than settling immediately.
        vm.deal(user, BOOTSTRAP_DEPOSIT);
        vm.prank(user);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(MIN_TOKENS_TO_MINT);
    }

    // ============ Helpers ============

    function _metadata() internal view returns (bytes memory) {
        return _encodeMetadata(workflowId, workflowName, workflowOwner);
    }

    function _report(uint8 action, bytes memory params) internal returns (bytes memory) {
        _seq += 1;
        return _encodeReport(TEST_CHAIN_SELECTOR, _seq, uint64(block.timestamp), action, params);
    }

    function _onReport(ICREStrategyExecutor.StrategyAction action) internal {
        vm.prank(forwarder);
        executor.onReport(_metadata(), _report(uint8(action), ""));
    }

    function _expectNoUpkeep(ICREStrategyExecutor.StrategyAction action) internal {
        bytes memory report = _report(uint8(action), "");
        vm.prank(forwarder);
        vm.expectRevert(ICREStrategyExecutor.KeeperExecutorNoUpkeepNeeded.selector);
        executor.onReport(_metadata(), report);
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

    function _enablePerformanceFees() internal {
        strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);
        strategy.setUnchargedLpFeeBaseInETH(UNCHARGED_LP_FEES);
    }

    // ============ Construction ============

    function test_Constructor_Defaults() public view {
        assertEq(executor.FORWARDER(), forwarder);
        assertEq(executor.CHAIN_SELECTOR(), TEST_CHAIN_SELECTOR);
        assertEq(executor.MAX_REPORT_AGE(), TEST_MAX_REPORT_AGE);
        assertEq(executor.minDepositETH(), DEFAULT_MIN_DEPOSIT_ETH);
        assertEq(executor.minWithdrawETH(), DEFAULT_MIN_WITHDRAW_ETH);
        assertEq(executor.minHarvestETH(), DEFAULT_MIN_HARVEST_ETH);
        assertEq(executor.syncInterval(), DEFAULT_SYNC_INTERVAL);
        assertEq(executor.minExitLiquidityTopUpETH(), DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH);
        assertEq(executor.lastSyncAt(), block.timestamp);
        // Explicit deploy-time policy knobs — never defaulted to a non-zero value.
        assertEq(executor.controllerReserveETH(), 0);
        assertEq(executor.exitLiquidityTargetETH(), 0);
        assertEq(executor.version(), "1.0.0-cre");
    }

    function test_Constructor_InvalidConfig() public {
        vm.expectRevert(ICREReceiverBase.CREReceiverZeroAddress.selector);
        new CREStrategyExecutor(address(registry), address(0), TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);

        vm.expectRevert(ICREReceiverBase.CREReceiverInvalidConfig.selector);
        new CREStrategyExecutor(address(registry), forwarder, TEST_CHAIN_SELECTOR, 0);
    }

    // ============ Auth / replay / timestamp guards ============

    function test_OnReport_OnlyForwarder() public {
        bytes memory report = _report(uint8(ICREStrategyExecutor.StrategyAction.Sync), "");
        vm.expectRevert(abi.encodeWithSelector(ICREReceiverBase.InvalidSender.selector, address(this), forwarder));
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_UnboundRejected() public {
        CREStrategyExecutor unbound =
            new CREStrategyExecutor(address(registry), forwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        bytes memory report = _report(uint8(ICREStrategyExecutor.StrategyAction.Sync), "");
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverWorkflowUnbound.selector);
        unbound.onReport(_metadata(), report);
    }

    function test_OnReport_WrongChain() public {
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR + 1, 1, uint64(block.timestamp), uint8(ICREStrategyExecutor.StrategyAction.Sync), ""
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverWrongChain.selector);
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_ReplaySequence() public {
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);
        _onReport(ICREStrategyExecutor.StrategyAction.Sync);

        // Re-deliver at the same sequence: strictly-increasing guard rejects it.
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR, _seq, uint64(block.timestamp), uint8(ICREStrategyExecutor.StrategyAction.Sync), ""
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverReplayedSequence.selector);
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_StaleReport() public {
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            1,
            uint64(block.timestamp - TEST_MAX_REPORT_AGE - 1),
            uint8(ICREStrategyExecutor.StrategyAction.Sync),
            ""
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverStaleReport.selector);
        executor.onReport(_metadata(), report);
    }

    /// @dev A future `observedAt` is a malformed / clock-skewed report, not staleness — it
    ///      carries its own error so monitoring can distinguish the two failure modes.
    function test_OnReport_FutureTimestamp() public {
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR, 1, uint64(block.timestamp + 1), uint8(ICREStrategyExecutor.StrategyAction.Sync), ""
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverFutureTimestamp.selector);
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_MaxReportAgeBoundaryAccepted() public {
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            1,
            uint64(block.timestamp - TEST_MAX_REPORT_AGE),
            uint8(ICREStrategyExecutor.StrategyAction.Sync),
            ""
        );
        vm.prank(forwarder);
        executor.onReport(_metadata(), report);
        assertEq(executor.lastSequence(), 1);
    }

    function test_OnReport_UnknownAction() public {
        bytes memory report = _report(uint8(ICREStrategyExecutor.StrategyAction.None), "");
        vm.prank(forwarder);
        vm.expectRevert(ICREStrategyExecutor.KeeperExecutorUnknownAction.selector);
        executor.onReport(_metadata(), report);
    }

    function test_WhenPaused_OnReportReverts() public {
        executor.pause();
        bytes memory report = _report(uint8(ICREStrategyExecutor.StrategyAction.Sync), "");
        vm.prank(forwarder);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.onReport(_metadata(), report);
    }

    function test_SupportsIReceiverInterface() public view {
        assertTrue(executor.supportsInterface(type(IReceiver).interfaceId));
    }

    // ============ Rebalance ============

    function test_Rebalance_NoUpkeepWhenAllHealthy() public {
        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != ICREStrategyExecutor.StrategyAction.Rebalance);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.Rebalance);
    }

    function test_Rebalance_WhenStrategyUnhealthy() public {
        strategy.setIsHealthy(false);

        (ICREStrategyExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.Rebalance));
        assertEq(amount, 0);

        vm.expectEmit(true, false, false, true, address(executor));
        emit ICREStrategyExecutor.StrategyUpkeepPerformed(ICREStrategyExecutor.StrategyAction.Rebalance, 0);
        _onReport(ICREStrategyExecutor.StrategyAction.Rebalance);

        assertTrue(strategy.isHealthy());
    }

    function test_Rebalance_SkipsPausedStrategy() public {
        strategy.setIsHealthy(false);
        strategy.setPaused(true);

        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != ICREStrategyExecutor.StrategyAction.Rebalance);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.Rebalance);
    }

    // ============ DepositExcess ============

    function test_DepositExcess_DeploysIdleControllerETH() public {
        uint256 controllerBalance = address(controller).balance;
        assertGt(controllerBalance, DEFAULT_MIN_DEPOSIT_ETH);

        (ICREStrategyExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.DepositExcess));
        assertEq(amount, controllerBalance);

        vm.expectEmit(true, false, false, true, address(executor));
        emit ICREStrategyExecutor.StrategyUpkeepPerformed(
            ICREStrategyExecutor.StrategyAction.DepositExcess, controllerBalance
        );
        _onReport(ICREStrategyExecutor.StrategyAction.DepositExcess);

        assertEq(address(strategy).balance, controllerBalance);
        assertEq(address(controller).balance, 0);
    }

    function test_DepositExcess_RespectsControllerReserve() public {
        // Reserve everything: nothing is excess, so the action must be rejected.
        executor.setControllerReserveETH(address(controller).balance);

        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != ICREStrategyExecutor.StrategyAction.DepositExcess);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.DepositExcess);
    }

    function test_DepositExcess_NoUpkeepWithoutCapacity() public {
        strategy.setMaxDeposit(0);

        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertTrue(action != ICREStrategyExecutor.StrategyAction.DepositExcess);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.DepositExcess);
    }

    // ============ WithdrawShortfall ============

    function test_WithdrawShortfall_PullsFromStrategies() public {
        _deployCapitalToStrategy();
        _queueExit(user, EXIT_ETH);

        uint256 needsETH = executor.pendingRedemptionNeedsETH();
        uint256 controllerBalance = address(controller).balance;
        assertGt(needsETH, controllerBalance);
        uint256 shortfall = needsETH - controllerBalance;

        (ICREStrategyExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.WithdrawShortfall));
        assertEq(amount, shortfall);

        vm.expectEmit(true, false, false, true, address(executor));
        emit ICREStrategyExecutor.StrategyUpkeepPerformed(
            ICREStrategyExecutor.StrategyAction.WithdrawShortfall, shortfall
        );
        _onReport(ICREStrategyExecutor.StrategyAction.WithdrawShortfall);

        assertEq(address(controller).balance, controllerBalance + shortfall);
    }

    function test_WithdrawShortfall_NoUpkeepWhenCovered() public {
        // Controller still holds the full bootstrap deposit — nothing to pull.
        _queueExit(user, EXIT_ETH);
        assertLe(executor.pendingRedemptionNeedsETH(), address(controller).balance);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.WithdrawShortfall);
    }

    function test_WithdrawShortfall_IgnoresReportParams() public {
        _deployCapitalToStrategy();
        _queueExit(user, EXIT_ETH);

        uint256 shortfall = executor.pendingRedemptionNeedsETH() - address(controller).balance;

        // Params claim an absurd amount; the executor recomputes and uses the live shortfall.
        _seq += 1;
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            _seq,
            uint64(block.timestamp),
            uint8(ICREStrategyExecutor.StrategyAction.WithdrawShortfall),
            abi.encode(type(uint256).max)
        );
        vm.expectEmit(true, false, false, true, address(executor));
        emit ICREStrategyExecutor.StrategyUpkeepPerformed(
            ICREStrategyExecutor.StrategyAction.WithdrawShortfall, shortfall
        );
        vm.prank(forwarder);
        executor.onReport(_metadata(), report);
    }

    // ============ ProvideExitLiquidity ============

    function test_ProvideExitLiquidity_DisabledWhenTargetZero() public {
        assertEq(executor.exitLiquidityTargetETH(), 0);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.ProvideExitLiquidity);
    }

    function test_ProvideExitLiquidity_TopsUpAmmFloat() public {
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);
        uint256 floatBefore = amm.freeBalance();
        assertLt(floatBefore, EXIT_LIQUIDITY_TARGET);
        uint256 topUp = EXIT_LIQUIDITY_TARGET - floatBefore;

        (ICREStrategyExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.ProvideExitLiquidity));
        assertEq(amount, topUp);

        vm.expectEmit(true, false, false, true, address(executor));
        emit ICREStrategyExecutor.StrategyUpkeepPerformed(
            ICREStrategyExecutor.StrategyAction.ProvideExitLiquidity, topUp
        );
        _onReport(ICREStrategyExecutor.StrategyAction.ProvideExitLiquidity);

        assertEq(amm.freeBalance(), EXIT_LIQUIDITY_TARGET);
    }

    function test_ProvideExitLiquidity_NoUpkeepWhenTargetMet() public {
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);
        _onReport(ICREStrategyExecutor.StrategyAction.ProvideExitLiquidity);

        // Float now sits at the target: a second top-up is not needed.
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.ProvideExitLiquidity);
    }

    // ============ HarvestPerformanceFees ============

    function test_Harvest_NoUpkeepWhenFeesDisabled() public {
        assertEq(strategyManager.performanceFeeBps(), 0);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.HarvestPerformanceFees);
    }

    function test_Harvest_MintsFeeToTreasury() public {
        _enablePerformanceFees();

        uint256 feeETH = strategyManager.pendingPerformanceFeeInETH(address(strategy));
        assertGe(feeETH, DEFAULT_MIN_HARVEST_ETH);
        uint256 treasuryBefore = token.balanceOf(TEST_DAO_TREASURY);

        vm.expectEmit(true, false, false, true, address(executor));
        emit ICREStrategyExecutor.StrategyUpkeepPerformed(
            ICREStrategyExecutor.StrategyAction.HarvestPerformanceFees, feeETH
        );
        _onReport(ICREStrategyExecutor.StrategyAction.HarvestPerformanceFees);

        assertGt(token.balanceOf(TEST_DAO_TREASURY), treasuryBefore);
        assertEq(strategyManager.pendingPerformanceFeeInETH(address(strategy)), 0);
    }

    function test_Harvest_NoUpkeepBelowMinHarvest() public {
        _enablePerformanceFees();
        executor.setMinHarvestETH(type(uint256).max);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.HarvestPerformanceFees);
    }

    // ============ Sync ============

    function test_Sync_RateLimited() public {
        assertEq(executor.lastSyncAt(), block.timestamp);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.Sync);
    }

    function test_Sync_AfterInterval() public {
        vm.warp(block.timestamp + DEFAULT_SYNC_INTERVAL);

        vm.expectEmit(true, false, false, true, address(executor));
        emit ICREStrategyExecutor.StrategyUpkeepPerformed(ICREStrategyExecutor.StrategyAction.Sync, 0);
        _onReport(ICREStrategyExecutor.StrategyAction.Sync);

        assertEq(executor.lastSyncAt(), block.timestamp);
        // Consecutive syncs are rate limited again.
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.Sync);
    }

    function test_Sync_DisabledWhenIntervalZero() public {
        executor.setSyncInterval(0);
        vm.warp(block.timestamp + SETUP_WARP);
        _expectNoUpkeep(ICREStrategyExecutor.StrategyAction.Sync);
    }

    // ============ strategyUpkeepStatus ============

    function test_StrategyUpkeepStatus_NoneWhenExecutorPaused() public {
        strategy.setIsHealthy(false);
        executor.pause();

        (ICREStrategyExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.None));
        assertEq(amount, 0);
    }

    function test_StrategyUpkeepStatus_NoneWhenControllerPaused() public {
        strategy.setIsHealthy(false);
        controller.pause();

        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.None));
    }

    function test_StrategyUpkeepStatus_NoneWhenStrategyManagerPaused() public {
        strategy.setIsHealthy(false);
        strategyManager.pause();

        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.None));
    }

    /// @dev Rebalance outranks every funding action — it is the only one that repairs the
    ///      NAV source the rest of the protocol prices against.
    function test_StrategyUpkeepStatus_RebalanceOutranksDeposit() public {
        strategy.setIsHealthy(false);
        assertGt(address(controller).balance, DEFAULT_MIN_DEPOSIT_ETH);

        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.Rebalance));
    }

    function test_StrategyUpkeepStatus_ExitLiquidityOutranksDeposit() public {
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);

        (ICREStrategyExecutor.StrategyAction action,) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.ProvideExitLiquidity));
    }

    function test_StrategyUpkeepStatus_NoneWhenNothingToDo() public {
        // Deploy all idle ETH, keep the strategy healthy, leave fees and exit target off.
        _onReport(ICREStrategyExecutor.StrategyAction.DepositExcess);

        (ICREStrategyExecutor.StrategyAction action, uint256 amount) = executor.strategyUpkeepStatus();
        assertEq(uint8(action), uint8(ICREStrategyExecutor.StrategyAction.None));
        assertEq(amount, 0);
    }

    // ============ pendingRedemptionNeedsETH ============

    function test_PendingRedemptionNeedsETH_ZeroWithoutQueuedExits() public view {
        assertEq(executor.pendingRedemptionNeedsETH(), 0);
    }

    function test_PendingRedemptionNeedsETH_CountsCurrentBatch() public {
        _queueExit(user, EXIT_ETH);
        assertApproxEqAbs(executor.pendingRedemptionNeedsETH(), EXIT_ETH, 1);
    }

    /// @dev The strategy executor reads the cursor from the registered queue executor — the
    ///      two receivers must agree on which batch is next, or reserved ETH drifts.
    function test_PendingRedemptionNeedsETH_AnchoredAtQueueCursor() public {
        _queueExit(user, EXIT_ETH);
        assertEq(queueExecutor.nextLiveBatchIdToProcess(), exitQueue.currentBatchId());
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

    /// @dev Dust floors must stay non-zero: zeroing them would let a workflow burn gas on
    ///      economically pointless upkeeps.
    function test_Setters_RejectZeroDustFloors() public {
        vm.expectRevert(ICREStrategyExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMinDepositETH(0);

        vm.expectRevert(ICREStrategyExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMinHarvestETH(0);

        vm.expectRevert(ICREStrategyExecutor.KeeperExecutorInvalidConfig.selector);
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
        emit ICREStrategyExecutor.ControllerReserveETHChanged(0, 1 ether);
        executor.setControllerReserveETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ICREStrategyExecutor.MinDepositETHChanged(DEFAULT_MIN_DEPOSIT_ETH, 1 ether);
        executor.setMinDepositETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ICREStrategyExecutor.MinWithdrawETHChanged(DEFAULT_MIN_WITHDRAW_ETH, 1 ether);
        executor.setMinWithdrawETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ICREStrategyExecutor.MinHarvestETHChanged(DEFAULT_MIN_HARVEST_ETH, 1 ether);
        executor.setMinHarvestETH(1 ether);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ICREStrategyExecutor.SyncIntervalChanged(DEFAULT_SYNC_INTERVAL, 2 days);
        executor.setSyncInterval(2 days);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ICREStrategyExecutor.ExitLiquidityTargetETHChanged(0, EXIT_LIQUIDITY_TARGET);
        executor.setExitLiquidityTargetETH(EXIT_LIQUIDITY_TARGET);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ICREStrategyExecutor.MinExitLiquidityTopUpETHChanged(DEFAULT_MIN_EXIT_LIQUIDITY_TOP_UP_ETH, 1 ether);
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
