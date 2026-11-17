// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../src/contracts/Controller.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {StrategyManager} from "../../src/contracts/StrategyManager.sol";
import {QueueKeeperExecutor} from "../../src/contracts/automation/QueueKeeperExecutor.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {IQueueKeeperExecutor} from "../../src/interfaces/automation/IQueueKeeperExecutor.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/// @notice Admin configuration, cursor management and the less-travelled `perform` /
///         `queueUpkeepStatus` branches of QueueKeeperExecutor.
contract QueueKeeperExecutorConfigTest is ProtocolTestBase {
    uint256 public constant ETH_PRICE = 4000e8;
    uint256 public constant STALENESS_INTERVAL = 3600;
    uint256 public constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 public constant EXIT_ETH = 1 ether;
    uint256 public constant PRICE_TOLERANCE = 1e17;
    uint256 public constant MIN_TOKENS_TO_MINT = 1;

    /// @dev Action ordinals. `CLOSE_BATCH_ACTION` is the action that closes the current
    ///      batch and opens it for processing; it is addressed by ordinal so these tests do
    ///      not depend on that enum member's name.
    uint8 internal constant NONE_ACTION = 0;
    uint8 internal constant CLOSE_BATCH_ACTION = 1;
    uint8 internal constant PROCESS_REQUESTS_ACTION = uint8(IQueueKeeperExecutor.QueueAction.ProcessRequests);
    uint8 internal constant ADVANCE_CURSOR_ACTION = uint8(IQueueKeeperExecutor.QueueAction.AdvanceCursor);

    Registry public registry;
    ExitQueue public exitQueue;
    AMM public amm;
    Controller public controller;
    Oracle public oracle;
    EVE public token;
    StrategyManager public strategyManager;
    QueueKeeperExecutor public executor;

    address public admin;
    address public automationAccount;
    address public user;
    address public user2;
    address public stranger;

    function setUp() public {
        admin = address(this);
        automationAccount = makeAddr("mimicSmartAccount");
        user = makeAddr("user");
        user2 = makeAddr("user2");
        stranger = makeAddr("stranger");

        ProtocolContracts memory contracts = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        oracle = contracts.oracle;
        amm = contracts.amm;
        strategyManager = contracts.strategyManager;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        executor = new QueueKeeperExecutor(address(registry));
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));
        executor.allowExecutorCaller(automationAccount);

        vm.deal(user, BOOTSTRAP_DEPOSIT);
        vm.prank(user);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(MIN_TOKENS_TO_MINT);
    }

    // ============ Helpers ============

    function _queueExit(address _user, uint256 _requestedETH) internal returns (uint256 batchId) {
        vm.startPrank(_user);
        token.approve(address(amm), type(uint256).max);
        batchId = amm.exit(_requestedETH, token.balanceOf(_user), PRICE_TOLERANCE);
        vm.stopPrank();
    }

    function _perform(uint8 action, bytes memory params) internal {
        vm.prank(automationAccount);
        executor.perform(action, params);
    }

    function _expectPerformRevert(uint8 action, bytes memory params, bytes4 selector) internal {
        vm.prank(automationAccount);
        vm.expectRevert(selector);
        executor.perform(action, params);
    }

    /// @dev Queues an exit into the current batch, matures it and closes it. Returns the closed batch id.
    function _queueAndCloseBatch() internal returns (uint256 batchId) {
        batchId = _queueExit(user, EXIT_ETH);
        vm.warp(block.timestamp + executor.minBatchAge());
        _perform(CLOSE_BATCH_ACTION, abi.encode(batchId));
    }

    function _expectMissingAdminRole() internal {
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
    }

    // ============ Constructor / version ============

    function test_Constructor_Defaults() public view {
        assertEq(executor.minBatchAge(), 1 days);
        assertEq(executor.maxUsersPerUpkeep(), 20);
        assertEq(executor.nextBatchIdToProcess(), 1);
        assertEq(executor.version(), "2.1.0-mimic");
    }

    // ============ setMinBatchAge ============

    function test_SetMinBatchAge_UpdatesAndEmits() public {
        uint256 newAge = 2 days;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IQueueKeeperExecutor.MinBatchAgeChanged(1 days, newAge);
        executor.setMinBatchAge(newAge);
        assertEq(executor.minBatchAge(), newAge);
    }

    function test_SetMinBatchAge_AcceptsBounds() public {
        executor.setMinBatchAge(executor.MIN_BATCH_AGE_LOWER_BOUND());
        assertEq(executor.minBatchAge(), executor.MIN_BATCH_AGE_LOWER_BOUND());
        executor.setMinBatchAge(executor.MIN_BATCH_AGE_UPPER_BOUND());
        assertEq(executor.minBatchAge(), executor.MIN_BATCH_AGE_UPPER_BOUND());
    }

    function test_SetMinBatchAge_RevertsOutOfBounds() public {
        uint256 lower = executor.MIN_BATCH_AGE_LOWER_BOUND();
        uint256 upper = executor.MIN_BATCH_AGE_UPPER_BOUND();

        vm.expectRevert(IQueueKeeperExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMinBatchAge(lower - 1);

        vm.expectRevert(IQueueKeeperExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMinBatchAge(upper + 1);
    }

    function test_SetMinBatchAge_OnlyAdmin() public {
        _expectMissingAdminRole();
        vm.prank(stranger);
        executor.setMinBatchAge(2 days);
    }

    function test_SetMinBatchAge_GatesClosingTheBatch() public {
        executor.setMinBatchAge(3 days);
        uint256 batchId = _queueExit(user, EXIT_ETH);

        vm.warp(block.timestamp + 1 days);
        (IQueueKeeperExecutor.QueueAction action,,) = executor.queueUpkeepStatus();
        assertEq(uint8(action), NONE_ACTION);
        _expectPerformRevert(
            CLOSE_BATCH_ACTION, abi.encode(batchId), IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );

        vm.warp(block.timestamp + 2 days);
        (action,,) = executor.queueUpkeepStatus();
        assertEq(uint8(action), CLOSE_BATCH_ACTION);
    }

    // ============ setMaxUsersPerUpkeep ============

    function test_SetMaxUsersPerUpkeep_UpdatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(executor));
        emit IQueueKeeperExecutor.MaxUsersPerUpkeepChanged(20, 5);
        executor.setMaxUsersPerUpkeep(5);
        assertEq(executor.maxUsersPerUpkeep(), 5);

        executor.setMaxUsersPerUpkeep(executor.MAX_USERS_PER_UPKEEP_UPPER_BOUND());
        assertEq(executor.maxUsersPerUpkeep(), executor.MAX_USERS_PER_UPKEEP_UPPER_BOUND());
    }

    function test_SetMaxUsersPerUpkeep_RevertsOutOfBounds() public {
        uint256 upper = executor.MAX_USERS_PER_UPKEEP_UPPER_BOUND();

        vm.expectRevert(IQueueKeeperExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMaxUsersPerUpkeep(0);

        vm.expectRevert(IQueueKeeperExecutor.KeeperExecutorInvalidConfig.selector);
        executor.setMaxUsersPerUpkeep(upper + 1);
    }

    function test_SetMaxUsersPerUpkeep_OnlyAdmin() public {
        _expectMissingAdminRole();
        vm.prank(stranger);
        executor.setMaxUsersPerUpkeep(5);
    }

    function test_SetMaxUsersPerUpkeep_CapsAffordableRequests() public {
        vm.deal(user2, BOOTSTRAP_DEPOSIT);
        vm.prank(user2);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(MIN_TOKENS_TO_MINT);

        uint256 batchId = _queueExit(user, EXIT_ETH);
        _queueExit(user2, EXIT_ETH);
        vm.warp(block.timestamp + executor.minBatchAge());
        _perform(CLOSE_BATCH_ACTION, abi.encode(batchId));

        assertEq(executor.affordableRequests(batchId), 2);
        executor.setMaxUsersPerUpkeep(1);
        assertEq(executor.affordableRequests(batchId), 1);
    }

    // ============ advanceBatchCursor ============

    function test_AdvanceBatchCursor_MovesCursorAndEmits() public {
        uint256 closedBatchId = _queueAndCloseBatch();
        uint256 currentBatchId = exitQueue.currentBatchId();
        assertGt(currentBatchId, closedBatchId);
        // The closed batch still has an unprocessed request, so the cursor stays on it.
        assertEq(executor.nextBatchIdToProcess(), closedBatchId);

        vm.expectEmit(false, false, false, true, address(executor));
        emit IQueueKeeperExecutor.BatchCursorAdvanced(closedBatchId, currentBatchId);
        executor.advanceBatchCursor(currentBatchId);
        assertEq(executor.nextBatchIdToProcess(), currentBatchId);
    }

    function test_AdvanceBatchCursor_RevertsWhenNotAheadOfCursor() public {
        _queueAndCloseBatch();
        uint256 cursor = executor.nextBatchIdToProcess();

        vm.expectRevert(IQueueKeeperExecutor.QueueKeeperExecutorBatchCursorPrecedesCurrent.selector);
        executor.advanceBatchCursor(cursor);

        vm.expectRevert(IQueueKeeperExecutor.QueueKeeperExecutorBatchCursorPrecedesCurrent.selector);
        executor.advanceBatchCursor(cursor - 1);
    }

    function test_AdvanceBatchCursor_RevertsPastCurrentBatch() public {
        _queueAndCloseBatch();
        uint256 currentBatchId = exitQueue.currentBatchId();

        vm.expectRevert(IQueueKeeperExecutor.QueueKeeperExecutorBatchCursorPastCurrent.selector);
        executor.advanceBatchCursor(currentBatchId + 1);
    }

    function test_AdvanceBatchCursor_OnlyAdmin() public {
        _queueAndCloseBatch();
        uint256 currentBatchId = exitQueue.currentBatchId();

        _expectMissingAdminRole();
        vm.prank(stranger);
        executor.advanceBatchCursor(currentBatchId);
    }

    // ============ perform: AdvanceCursor ============

    function test_Perform_AdvanceCursor_MovesPastExpiredBatch() public {
        uint256 closedBatchId = _queueAndCloseBatch();
        vm.warp(block.timestamp + exitQueue.MAX_BATCH_PROCESSING_TIME() + 1);

        // The stored cursor lags the live one; with no other work, status asks to advance it.
        assertEq(executor.nextBatchIdToProcess(), closedBatchId);
        uint256 liveCursor = executor.nextLiveBatchIdToProcess();
        assertGt(liveCursor, closedBatchId);

        (IQueueKeeperExecutor.QueueAction action, uint256 batchId, uint256 count) = executor.queueUpkeepStatus();
        assertEq(uint8(action), ADVANCE_CURSOR_ACTION);
        assertEq(batchId, liveCursor);
        assertEq(count, 0);

        // The checker payload is the exact perform calldata.
        (bool canExec, bytes memory execPayload) = executor.checker();
        assertTrue(canExec);
        assertEq(
            execPayload, abi.encodeCall(QueueKeeperExecutor.perform, (ADVANCE_CURSOR_ACTION, abi.encode(liveCursor)))
        );

        vm.expectEmit(true, true, false, true, address(executor));
        emit IQueueKeeperExecutor.QueueUpkeepPerformed(IQueueKeeperExecutor.QueueAction.AdvanceCursor, liveCursor, 0);
        vm.prank(automationAccount);
        (bool ok,) = address(executor).call(execPayload);
        assertTrue(ok);
        assertEq(executor.nextBatchIdToProcess(), liveCursor);

        // Nothing left to advance.
        _expectPerformRevert(
            ADVANCE_CURSOR_ACTION, abi.encode(liveCursor), IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
    }

    function test_Perform_AdvanceCursor_RevertsWhenClaimedTargetIsAhead() public {
        _queueAndCloseBatch();
        vm.warp(block.timestamp + exitQueue.MAX_BATCH_PROCESSING_TIME() + 1);
        uint256 liveCursor = executor.nextLiveBatchIdToProcess();

        _expectPerformRevert(
            ADVANCE_CURSOR_ACTION,
            abi.encode(liveCursor + 1),
            IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
    }

    function test_Perform_AdvanceCursor_RevertsWhenNothingSkippable() public {
        _expectPerformRevert(
            ADVANCE_CURSOR_ACTION, abi.encode(uint256(1)), IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
    }

    // ============ perform: other branches ============

    function test_Perform_NoneActionReverts() public {
        _expectPerformRevert(NONE_ACTION, "", IQueueKeeperExecutor.KeeperExecutorUnknownAction.selector);
    }

    function test_Perform_ProcessRequests_RevertsOnEmptyRange() public {
        uint256 batchId = _queueAndCloseBatch();

        _expectPerformRevert(
            PROCESS_REQUESTS_ACTION,
            abi.encode(batchId, uint256(0), uint256(0)),
            IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
        _expectPerformRevert(
            PROCESS_REQUESTS_ACTION,
            abi.encode(batchId, uint256(1), uint256(0)),
            IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
    }

    function test_Perform_ProcessRequests_RevertsOnNonZeroStart() public {
        uint256 batchId = _queueAndCloseBatch();

        _expectPerformRevert(
            PROCESS_REQUESTS_ACTION,
            abi.encode(batchId, uint256(1), uint256(2)),
            IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
    }

    function test_Perform_CloseBatch_RevertsForNonCurrentBatch() public {
        uint256 closedBatchId = _queueAndCloseBatch();

        _expectPerformRevert(
            CLOSE_BATCH_ACTION, abi.encode(closedBatchId), IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
    }

    // ============ checker / queueUpkeepStatus ============

    function test_Checker_ProcessRequests_CalldataTargetsPerform() public {
        uint256 batchId = _queueAndCloseBatch();

        (bool canExec, bytes memory execPayload) = executor.checker();
        assertTrue(canExec);
        assertEq(
            execPayload,
            abi.encodeCall(
                QueueKeeperExecutor.perform, (PROCESS_REQUESTS_ACTION, abi.encode(batchId, uint256(0), uint256(1)))
            )
        );

        vm.prank(automationAccount);
        (bool ok,) = address(executor).call(execPayload);
        assertTrue(ok);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_QueueUpkeepStatus_NoneWhenExecutorPaused() public {
        _queueExit(user, EXIT_ETH);
        vm.warp(block.timestamp + executor.minBatchAge());
        executor.pause();

        (IQueueKeeperExecutor.QueueAction action,,) = executor.queueUpkeepStatus();
        assertEq(uint8(action), NONE_ACTION);
    }

    function test_QueueUpkeepStatus_NoneWhenControllerPaused() public {
        _queueExit(user, EXIT_ETH);
        vm.warp(block.timestamp + executor.minBatchAge());
        controller.pause();

        (IQueueKeeperExecutor.QueueAction action,,) = executor.queueUpkeepStatus();
        assertEq(uint8(action), NONE_ACTION);
    }

    function test_QueueUpkeepStatus_NoneWhenExitQueuePaused() public {
        _queueExit(user, EXIT_ETH);
        vm.warp(block.timestamp + executor.minBatchAge());
        exitQueue.pause();

        (IQueueKeeperExecutor.QueueAction action,,) = executor.queueUpkeepStatus();
        assertEq(uint8(action), NONE_ACTION);
    }

    function test_QueueUpkeepStatus_NoneWhenAMMPaused() public {
        _queueExit(user, EXIT_ETH);
        vm.warp(block.timestamp + executor.minBatchAge());
        amm.pause();

        (IQueueKeeperExecutor.QueueAction action,,) = executor.queueUpkeepStatus();
        assertEq(uint8(action), NONE_ACTION);
    }

    // ============ affordableRequests ============

    function test_AffordableRequests_ZeroForOpenBatch() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        assertEq(executor.affordableRequests(batchId), 0);
    }

    function test_AffordableRequests_ZeroForSettledBatch() public {
        uint256 batchId = _queueAndCloseBatch();
        _perform(PROCESS_REQUESTS_ACTION, abi.encode(batchId, uint256(0), uint256(1)));

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        assertEq(executor.affordableRequests(batchId), 0);
    }

    /// @dev Moves most of the Controller's ETH into a strategy (NAV unchanged, so the EVE
    ///      price is unchanged) so the Controller can pay only the first of two requests.
    function test_AffordableRequests_StopsAtControllerBudget() public {
        vm.deal(user2, BOOTSTRAP_DEPOSIT);
        vm.prank(user2);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(MIN_TOKENS_TO_MINT);

        uint256 batchId = _queueExit(user, EXIT_ETH);
        _queueExit(user2, EXIT_ETH);
        vm.warp(block.timestamp + executor.minBatchAge());
        _perform(CLOSE_BATCH_ACTION, abi.encode(batchId));
        assertEq(executor.affordableRequests(batchId), 2);

        MockStrategy strategy = new MockStrategy("Parked", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy), 80, 70);
        uint256 budget = EXIT_ETH * 3 / 2;
        uint256 parked = address(controller).balance - budget;
        strategy.setNavInETH(parked);
        vm.deal(address(controller), budget);

        assertEq(executor.affordableRequests(batchId), 1);
        (IQueueKeeperExecutor.QueueAction action, uint256 statusBatchId, uint256 count) = executor.queueUpkeepStatus();
        assertEq(uint8(action), PROCESS_REQUESTS_ACTION);
        assertEq(statusBatchId, batchId);
        assertEq(count, 1);

        _expectPerformRevert(
            PROCESS_REQUESTS_ACTION,
            abi.encode(batchId, uint256(0), uint256(2)),
            IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector
        );
    }
}
