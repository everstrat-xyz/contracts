// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../src/contracts/Controller.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {QueueKeeperExecutor} from "../../src/contracts/automation/QueueKeeperExecutor.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IRegistryClient} from "../../src/interfaces/IRegistryClient.sol";
import {IKeeperExecutorBase} from "../../src/interfaces/automation/IKeeperExecutorBase.sol";
import {IQueueKeeperExecutor} from "../../src/interfaces/automation/IQueueKeeperExecutor.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title QueueKeeperExecutorTest
 * @notice Unit tests for the redemption queue Chainlink Automation executor
 */
contract QueueKeeperExecutorTest is ProtocolTestBase {
    // ============ Constants ============
    uint256 public constant ETH_PRICE = 4000e8; // $4000 with 8 decimals
    uint256 public constant STALENESS_INTERVAL = 3600;
    uint256 public constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 public constant USER2_TOKENS = 5000e18; // covers a 1 ETH exit at the genesis base price
    uint256 public constant EXIT_ETH = 1 ether;
    uint256 public constant PRICE_TOLERANCE = 1e17; // 10%
    uint256 public constant MIN_TOKENS_TO_MINT = 1;
    uint256 public constant TEST_MIN_BATCH_AGE = 1 days; // matches MIN_BATCH_AGE_LOWER_BOUND floor
    uint256 public constant FIRST_BATCH_ID = 1;

    // ============ State Variables ============
    Registry public registry;
    ExitQueue public exitQueue;
    AMM public amm;
    Controller public controller;
    Oracle public oracle;
    EVE public token;
    QueueKeeperExecutor public executor;

    address public admin;
    address public forwarder;
    address public user;
    address public user2;

    // ============ Setup ============
    function setUp() public {
        admin = address(this);
        forwarder = makeAddr("forwarder");
        user = makeAddr("user");
        user2 = makeAddr("user2");

        ProtocolContracts memory contracts = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        oracle = contracts.oracle;
        amm = contracts.amm;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        executor = new QueueKeeperExecutor(address(registry));
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));
        executor.setForwarder(forwarder);

        // Bootstrap the AMM; the deposit is forwarded to the Controller, so
        // subsequent exits are queued (AMM free balance is zero)
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

    function _performUpkeep(bytes memory _performData) internal {
        vm.prank(forwarder);
        executor.performUpkeep(_performData);
    }

    /// @dev Warps past the configured minBatchAge so the current batch is priceable
    function _warpPastMinBatchAge() internal {
        vm.warp(block.timestamp + executor.minBatchAge());
    }

    function _fundUser2WithTokens() internal {
        // Transfer EVE instead of entering: keeps the setup focused on the queue
        // without a second enter() moving the price.
        vm.prank(user);
        token.transfer(user2, USER2_TOKENS);
    }

    function _checkAndPerform() internal returns (bool upkeepNeeded) {
        bytes memory performData;
        (upkeepNeeded, performData) = executor.checkUpkeep("");
        if (upkeepNeeded) _performUpkeep(performData);
    }

    // ============ checkUpkeep Tests ============

    function test_CheckUpkeep_NoRequests_ReturnsFalse() public view {
        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(performData.length, 0);
    }

    function test_CheckUpkeep_PendingCurrentBatch_ReturnsPriceBatch() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));
    }

    function test_CheckUpkeep_MinBatchAge_NotReached() public {
        executor.setMinBatchAge(TEST_MIN_BATCH_AGE);
        _queueExit(user, EXIT_ETH);

        // Just under the floor: not priceable yet
        vm.warp(block.timestamp + TEST_MIN_BATCH_AGE - 1);
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);

        vm.warp(block.timestamp + 1);
        (upkeepNeeded,) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
    }

    function test_CheckUpkeep_PricedBatch_ReturnsProcessRequests() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));

        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));
    }

    function test_CheckUpkeep_ProcessingPriorityOverPricing() public {
        // Batch 1 priced with an unprocessed request; batch 2 accumulating
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));

        _fundUser2WithTokens();
        _queueExit(user2, EXIT_ETH);

        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));
    }

    function test_CheckUpkeep_InsufficientControllerBalance_SkipsProcessing() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));

        // Drain the Controller: the settlement is no longer affordable
        vm.deal(address(controller), 0);
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
        assertEq(executor.affordableRequests(batchId), 0);

        // Restore liquidity: processing becomes actionable again
        vm.deal(address(controller), EXIT_ETH * 2);
        (upkeepNeeded,) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(executor.affordableRequests(batchId), 1);
    }

    function test_CheckUpkeep_WhenExecutorPaused_ReturnsFalse() public {
        _queueExit(user, EXIT_ETH);
        executor.pause();

        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeep_WhenProtocolPaused_ReturnsFalse() public {
        _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        controller.pause();
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
        controller.unpause();

        amm.pause();
        (upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
        amm.unpause();

        exitQueue.pause();
        (upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
        exitQueue.unpause();

        (upkeepNeeded,) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
    }

    // ============ performUpkeep Tests ============

    function test_PerformUpkeep_AccessControl() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        bytes memory performData = abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId);

        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorOnlyForwarder.selector);
        executor.performUpkeep(performData);

        vm.prank(user);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorOnlyForwarder.selector);
        executor.performUpkeep(performData);
    }

    function test_PerformUpkeep_PriceBatch() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        vm.expectEmit(true, true, false, true, address(executor));
        emit IQueueKeeperExecutor.QueueUpkeepPerformed(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId, 0);
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));

        (bool canBeProcessed, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        assertTrue(canBeProcessed);
        assertGt(finalEvePrice, 0);
        assertEq(exitQueue.currentBatchId(), batchId + 1);
    }

    function test_PerformUpkeep_ProcessRequests() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));

        vm.expectEmit(true, true, false, true, address(executor));
        emit IQueueKeeperExecutor.QueueUpkeepPerformed(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId, 1);
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        // The batch is fully processed: the cursor advances past it
        assertEq(executor.nextBatchIdToProcess(), batchId + 1);
        // The user's ETH is claimable on the AMM (pull-over-push)
        assertApproxEqAbs(amm.claimableBalances(user), EXIT_ETH, 1);
    }

    function test_PerformUpkeep_ProcessRequests_RespectsMaxUsersPerUpkeep() public {
        _fundUser2WithTokens();

        uint256 batchId = _queueExit(user, EXIT_ETH);
        assertEq(_queueExit(user2, EXIT_ETH), batchId);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));

        executor.setMaxUsersPerUpkeep(1);

        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));
        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);
        assertEq(executor.nextBatchIdToProcess(), batchId);

        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        assertEq(executor.nextBatchIdToProcess(), batchId + 1);
    }

    function test_PerformUpkeep_PriceBatch_InvalidConditions() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        // Stale performData: not the live batch
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId + 1));

        // Too young when a minimum age above the floor is configured
        executor.setMinBatchAge(TEST_MIN_BATCH_AGE + 1 days);
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));
    }

    function test_PerformUpkeep_ProcessRequests_InvalidConditions() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);

        // Batch not priced yet
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));

        // Priced but unaffordable
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));
        vm.deal(address(controller), 0);
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));
    }

    function test_PerformUpkeep_UnknownAction() public {
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorUnknownAction.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.None, FIRST_BATCH_ID));
    }

    function test_PerformUpkeep_WhenPaused() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        executor.pause();

        vm.prank(forwarder);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));
    }

    // ============ End-to-End Test ============

    function test_FullRedemptionFlow_ViaUpkeeps() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        // Upkeep 1: price the batch
        assertTrue(_checkAndPerform());
        // Upkeep 2: process the request
        assertTrue(_checkAndPerform());
        // No further work
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);

        uint256 balanceBefore = user.balance;
        vm.prank(user);
        amm.claim();
        assertApproxEqAbs(user.balance - balanceBefore, EXIT_ETH, 1);
    }

    // ============ Admin Function Tests ============

    function test_SetForwarder() public {
        address newForwarder = makeAddr("newForwarder");

        vm.expectEmit(true, true, false, false, address(executor));
        emit IKeeperExecutorBase.ForwarderChanged(forwarder, newForwarder);
        executor.setForwarder(newForwarder);
        assertEq(executor.forwarder(), newForwarder);
    }

    function test_SetForwarder_InvalidInputs() public {
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorZeroAddress.selector);
        executor.setForwarder(address(0));
    }

    function test_SetForwarder_AccessControl() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setForwarder(user);
    }

    function test_SetMinBatchAge() public {
        uint256 newMin = 2 days;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IQueueKeeperExecutor.MinBatchAgeChanged(executor.MIN_BATCH_AGE_LOWER_BOUND(), newMin);
        executor.setMinBatchAge(newMin);
        assertEq(executor.minBatchAge(), newMin);
    }

    function test_SetMinBatchAge_InvalidInputs() public {
        // Below the floor (1 day - 1 second)
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorInvalidConfig.selector);
        executor.setMinBatchAge(1 days - 1);

        // Above the ceiling
        uint256 aboveUpperBound = executor.MIN_BATCH_AGE_UPPER_BOUND() + 1;
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorInvalidConfig.selector);
        executor.setMinBatchAge(aboveUpperBound);
    }

    function test_SetMinBatchAge_AccessControl() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMinBatchAge(TEST_MIN_BATCH_AGE);
    }

    function test_SetMaxUsersPerUpkeep() public {
        uint256 newCap = 5;
        vm.expectEmit(false, false, false, true, address(executor));
        emit IQueueKeeperExecutor.MaxUsersPerUpkeepChanged(executor.maxUsersPerUpkeep(), newCap);
        executor.setMaxUsersPerUpkeep(newCap);
        assertEq(executor.maxUsersPerUpkeep(), newCap);
    }

    function test_SetMaxUsersPerUpkeep_InvalidInputs() public {
        // Below the floor (zero)
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorInvalidConfig.selector);
        executor.setMaxUsersPerUpkeep(0);

        // Above the ceiling
        uint256 aboveUpperBound = executor.MAX_USERS_PER_UPKEEP_UPPER_BOUND() + 1;
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorInvalidConfig.selector);
        executor.setMaxUsersPerUpkeep(aboveUpperBound);
    }

    function test_SetMaxUsersPerUpkeep_AccessControl() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.setMaxUsersPerUpkeep(1);
    }

    function test_Pause_AccessControl() public {
        vm.prank(user);
        vm.expectRevert();
        executor.pause();

        executor.pause();
        assertTrue(executor.paused());

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.unpause();

        executor.unpause();
        assertFalse(executor.paused());
    }

    function test_Version() public view {
        assertEq(executor.version(), "1.0.0");
    }

    // ============ advanceBatchCursor (escape hatch) Tests ============

    function test_AdvanceBatchCursor_SkipsStuckBatch() public {
        // Build a backlog: batch 1 priced but unaffordable (stuck), batch 2
        // priced and affordable. Without the escape hatch the cursor sits at
        // batch 1 forever since the user will not close their request.
        uint256 stuckBatch = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, stuckBatch));

        _fundUser2WithTokens();
        uint256 liveBatch = _queueExit(user2, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, liveBatch));

        // Drain the Controller so the stuck batch is unaffordable; the cursor
        // is pinned at the stuck batch and checkUpkeep finds no work.
        vm.deal(address(controller), 0);
        assertEq(executor.nextBatchIdToProcess(), stuckBatch);
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);

        // Governance force-advances the cursor past the stuck batch. The
        // skipped request remains in the ExitQueue for the user to close.
        vm.expectEmit(false, false, false, true, address(executor));
        emit IQueueKeeperExecutor.BatchCursorAdvanced(stuckBatch, liveBatch);
        executor.advanceBatchCursor(liveBatch);
        assertEq(executor.nextBatchIdToProcess(), liveBatch);

        // The affordable live batch is now actionable
        vm.deal(address(controller), EXIT_ETH * 2);
        bytes memory livePerformData;
        (upkeepNeeded, livePerformData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(livePerformData, abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, liveBatch));
    }

    function test_AdvanceBatchCursor_InvalidInputs() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        // Target at or below the current cursor (1) is rejected
        vm.expectRevert(IQueueKeeperExecutor.QueueKeeperExecutorBatchCursorPrecedesCurrent.selector);
        executor.advanceBatchCursor(1);

        // Target past the live (unpriced) batch is rejected
        vm.expectRevert(IQueueKeeperExecutor.QueueKeeperExecutorBatchCursorPastCurrent.selector);
        executor.advanceBatchCursor(batchId + 1);
    }

    function test_AdvanceBatchCursor_AccessControl() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        executor.advanceBatchCursor(2);
    }

    // ============ MAX_BATCH_SCAN Boundary Tests ============

    function test_CheckUpkeep_ScanWindowBoundedByMaxBatchScan() public {
        // Build a backlog larger than MAX_BATCH_SCAN where the cursor batch is
        // affordable. Price via Controller directly (no minBatchAge warps) so
        // every batch stays inside MAX_BATCH_PROCESSING_TIME and remains
        // non-skippable — otherwise PriceBatch upkeeps would auto-advance past
        // post-commitment leftovers and defeat the scan-window assertion.
        uint256 maxScan = executor.MAX_BATCH_SCAN();
        uint256 backlog = maxScan + 1; // exceed the scan window

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
            _queueExit(users[i], smallExit);
            controller.priceBatch();
        }

        assertEq(executor.nextBatchIdToProcess(), 1);
        assertEq(exitQueue.currentBatchId(), backlog + 1);
        assertGt(exitQueue.currentBatchId() - executor.nextBatchIdToProcess(), maxScan);

        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, 1));
    }

    // ============ Dead / empty cursor skip Tests ============

    function test_CheckUpkeep_SkipsPostCommitmentBatch_ProcessesLater() public {
        // Batch 1 priced but permanently unaffordable; after the commitment
        // window it becomes skippable so a *freshly* priced batch 2 is reachable
        // without admin advanceBatchCursor.
        uint256 stuckBatch = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, stuckBatch));

        vm.deal(address(controller), 0);
        assertEq(executor.nextBatchIdToProcess(), stuckBatch);

        // Still inside the commitment window: nothing actionable
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);

        // Expire only the stuck batch, then restore NAV so a fresh exit can price,
        // and price a new live batch so it is not itself post-commitment.
        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);
        assertEq(executor.nextLiveBatchIdToProcess(), stuckBatch + 1);

        vm.deal(address(controller), BOOTSTRAP_DEPOSIT);
        _fundUser2WithTokens();
        uint256 liveBatch = _queueExit(user2, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, liveBatch));
        // PriceBatch advances past the dead stuck batch before pricing
        assertEq(executor.nextBatchIdToProcess(), liveBatch);

        bytes memory performData;
        (upkeepNeeded, performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, liveBatch));

        _performUpkeep(performData);
        assertEq(exitQueue.unprocessedUsersCount(liveBatch), 0);
        assertEq(executor.nextBatchIdToProcess(), liveBatch + 1);
        // Stuck request remains for the owner to close via the escape hatch
        assertEq(exitQueue.unprocessedUsersCount(stuckBatch), 1);
    }

    function test_CheckUpkeep_EmptyBatches_ReturnsAdvanceCursor() public {
        // User escapes after pricing → batch empty but cursor still pinned until
        // an upkeep persists the skip (no ProcessRequests to trigger advance).
        uint256 emptyBatch = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, emptyBatch));

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);
        vm.prank(user);
        amm.cancelRedemption(emptyBatch);
        assertEq(exitQueue.unprocessedUsersCount(emptyBatch), 0);
        assertEq(executor.nextBatchIdToProcess(), emptyBatch);

        (bool upkeepNeeded, bytes memory performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IQueueKeeperExecutor.QueueAction.AdvanceCursor, emptyBatch + 1));

        vm.expectEmit(true, true, false, true, address(executor));
        emit IQueueKeeperExecutor.QueueUpkeepPerformed(
            IQueueKeeperExecutor.QueueAction.AdvanceCursor, emptyBatch + 1, 0
        );
        _performUpkeep(performData);
        assertEq(executor.nextBatchIdToProcess(), emptyBatch + 1);

        (upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_PerformUpkeep_AdvanceCursor_NoProgress_Reverts() public {
        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.AdvanceCursor, 1));
    }

    function test_PerformUpkeep_AdvanceCursor_EncodedTargetUnreachable_Reverts() public {
        // Real progress exists (one empty batch to skip), but the encoded
        // batchId claims a target the live recompute cannot actually reach —
        // simulates bogus/manipulated performData rather than a benign race.
        uint256 emptyBatch = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, emptyBatch));

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);
        vm.prank(user);
        amm.cancelRedemption(emptyBatch);
        assertEq(executor.nextLiveBatchIdToProcess(), emptyBatch + 1);

        vm.prank(forwarder);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoUpkeepNeeded.selector);
        executor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.AdvanceCursor, emptyBatch + 100));

        // The honest target still succeeds
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.AdvanceCursor, emptyBatch + 1));
        assertEq(executor.nextBatchIdToProcess(), emptyBatch + 1);
    }

    function test_PerformUpkeep_AdvanceCursor_ActualExceedsEncodedTarget_Succeeds() public {
        // Loose bound: the live recompute reaching further than the encoded
        // target (e.g. the cursor already advanced via another upkeep or
        // governance since checkUpkeep last simulated) is not penalized.
        uint256 emptyBatch = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, emptyBatch));

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);
        vm.prank(user);
        amm.cancelRedemption(emptyBatch);

        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.AdvanceCursor, emptyBatch));
        assertEq(executor.nextBatchIdToProcess(), emptyBatch + 1);
    }

    function test_CheckUpkeep_SkippableBacklogBeyondMaxBatchScan_Recovers() public {
        // PoC: MAX_BATCH_SCAN unaffordable priced batches pin the stored cursor so
        // a batch at cursor+MAX_BATCH_SCAN is outside the scan window. After the
        // commitment window, AdvanceCursor (and/or PriceBatch) skips the dead
        // window; a freshly priced batch beyond it is then processable without
        // governance advanceBatchCursor.
        uint256 maxScan = executor.MAX_BATCH_SCAN();
        uint256 skippableCount = maxScan; // batches 1..MAX_BATCH_SCAN
        uint256 smallExit = 0.01 ether;
        uint256 tokensPerUser = 500e18;

        address[] memory skipUsers = new address[](skippableCount);
        for (uint256 i = 0; i < skippableCount; i++) {
            skipUsers[i] = makeAddr(string(abi.encodePacked("skip", i)));
            vm.prank(user);
            token.transfer(skipUsers[i], tokensPerUser);
        }

        registry.grantRole(Auth.KEEPER_ROLE, address(this));
        for (uint256 i = 0; i < skippableCount; i++) {
            _queueExit(skipUsers[i], smallExit);
            controller.priceBatch();
        }

        // One more priced batch sitting just outside the scan window from cursor 1
        address beyondUser = makeAddr("beyondWindow");
        vm.prank(user);
        token.transfer(beyondUser, tokensPerUser);
        uint256 beyondBatch = _queueExit(beyondUser, smallExit);
        assertEq(beyondBatch, skippableCount + 1);
        controller.priceBatch();

        vm.deal(address(controller), 0);
        assertEq(executor.nextBatchIdToProcess(), 1);
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded);

        // Expire commitment on the whole backlog (shared pricedAt)
        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);
        // One peek hop skips exactly MAX_BATCH_SCAN dead batches → lands on beyondBatch
        assertEq(executor.nextLiveBatchIdToProcess(), beyondBatch);

        // Persist the skip; beyondBatch is also dead so a second hop clears it
        assertTrue(_checkAndPerform()); // AdvanceCursor → beyondBatch
        assertEq(executor.nextBatchIdToProcess(), beyondBatch);
        assertTrue(_checkAndPerform()); // AdvanceCursor → beyondBatch + 1
        assertEq(executor.nextBatchIdToProcess(), beyondBatch + 1);

        // Restore NAV before a fresh exit (Controller was drained for the stall)
        vm.deal(address(controller), BOOTSTRAP_DEPOSIT);

        // Fresh batch after the dead window is reachable and processable
        address freshUser = makeAddr("freshLive");
        vm.prank(user);
        token.transfer(freshUser, tokensPerUser);
        uint256 freshBatch = _queueExit(freshUser, smallExit);
        _warpPastMinBatchAge();
        assertTrue(_checkAndPerform()); // PriceBatch (also keeps cursor in sync)
        assertEq(exitQueue.currentBatchId(), freshBatch + 1);

        bytes memory performData;
        (upkeepNeeded, performData) = executor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, freshBatch));

        _performUpkeep(performData);
        assertEq(exitQueue.unprocessedUsersCount(freshBatch), 0);
        assertEq(executor.nextBatchIdToProcess(), freshBatch + 1);
    }

    function test_PriceBatch_AdvancesCursorPastEmptyBatches() public {
        uint256 emptyBatch = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, emptyBatch));

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);
        vm.prank(user);
        amm.cancelRedemption(emptyBatch);

        _fundUser2WithTokens();
        uint256 nextBatch = _queueExit(user2, EXIT_ETH);
        _warpPastMinBatchAge();

        assertEq(executor.nextBatchIdToProcess(), emptyBatch);
        _performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, nextBatch));
        // PriceBatch path advances past the empty batch before pricing
        assertEq(executor.nextBatchIdToProcess(), emptyBatch + 1);
        (bool canBeProcessed,,,,) = exitQueue.batchInfo(nextBatch);
        assertTrue(canBeProcessed);
    }
}
