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
import {IKeeperExecutorBase} from "../../src/interfaces/automation/IKeeperExecutorBase.sol";
import {IQueueKeeperExecutor} from "../../src/interfaces/automation/IQueueKeeperExecutor.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

contract QueueKeeperExecutorTest is ProtocolTestBase {
    uint256 public constant ETH_PRICE = 4000e8;
    uint256 public constant STALENESS_INTERVAL = 3600;
    uint256 public constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 public constant EXIT_ETH = 1 ether;
    uint256 public constant PRICE_TOLERANCE = 1e17;
    uint256 public constant MIN_TOKENS_TO_MINT = 1;

    Registry public registry;
    ExitQueue public exitQueue;
    AMM public amm;
    Controller public controller;
    Oracle public oracle;
    EVE public token;
    QueueKeeperExecutor public executor;

    address public admin;
    address public automationAccount;
    address public user;
    address public stranger;

    function setUp() public {
        admin = address(this);
        automationAccount = makeAddr("mimicSmartAccount");
        user = makeAddr("user");
        stranger = makeAddr("stranger");

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
        // Executors start inert; the automation operator's smart account is bound
        // after task creation (the address only exists then).
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

    function _warpPastMinBatchAge() internal {
        vm.warp(block.timestamp + executor.minBatchAge());
    }

    // ============ Caller allowlist auth ============

    function test_Perform_InertUntilCallerAllowed() public {
        QueueKeeperExecutor fresh = new QueueKeeperExecutor(address(registry));
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoAllowedCallers.selector);
        vm.prank(automationAccount);
        fresh.perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(uint256(1)));
    }

    function test_Perform_OnlyAllowlistedCaller() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        vm.expectRevert(abi.encodeWithSelector(IKeeperExecutorBase.KeeperExecutorUnauthorizedCaller.selector, stranger));
        vm.prank(stranger);
        executor.perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));

        // The allowlisted proxy still goes through.
        _perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));
        (bool canBeProcessed,,,,) = exitQueue.batchInfo(batchId);
        assertTrue(canBeProcessed);
    }

    function test_AllowExecutorCaller_OnlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(); // RegistryClientMissingRole
        executor.allowExecutorCaller(makeAddr("other"));
    }

    function test_RemoveExecutorCaller_RestoresInert() public {
        executor.removeExecutorCaller(automationAccount);
        assertEq(executor.executorCallerCount(), 0);
        assertTrue(!executor.isExecutorCaller(automationAccount));

        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorNoAllowedCallers.selector);
        vm.prank(automationAccount);
        executor.perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(uint256(1)));
    }

    function test_AllowExecutorCaller_RejectsZeroAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(IKeeperExecutorBase.KeeperExecutorUnauthorizedCaller.selector, address(0))
        );
        executor.allowExecutorCaller(address(0));
    }

    // ============ Pause ============

    function test_WhenPaused_PerformReverts() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        executor.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(automationAccount);
        executor.perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));
    }

    // ============ Checker ============

    function test_Checker_NoWork_CannotExec() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));
        _perform(uint8(IQueueKeeperExecutor.QueueAction.ProcessRequests), abi.encode(batchId, uint256(0), uint256(1)));

        (IQueueKeeperExecutor.QueueAction action,,) = executor.queueUpkeepStatus();
        assertEq(uint8(action), uint8(IQueueKeeperExecutor.QueueAction.None));

        (bool canExec, bytes memory execPayload) = executor.checker();
        assertTrue(!canExec);
        // Not empty: the checker returns a human-readable reason string when canExec=false.
        assertTrue(execPayload.length > 0);
    }

    function test_Checker_PriceBatch_CalldataTargetsPerform() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        (bool canExec, bytes memory execPayload) = executor.checker();
        assertTrue(canExec);
        assertTrue(execPayload.length > 4);

        // execPayload is the exact calldata for perform: submitting it as the
        // allowlisted proxy must price the batch.
        vm.prank(automationAccount);
        (bool ok,) = address(executor).call(execPayload);
        assertTrue(ok);
        (bool canBeProcessed,,,,) = exitQueue.batchInfo(batchId);
        assertTrue(canBeProcessed);
    }

    function test_MaxBatchScan_MatchesExitQueueLiveCap() public view {
        assertEq(executor.MAX_BATCH_SCAN(), exitQueue.MAX_LIVE_PRICED_BATCHES());
    }

    // ============ Cursor skippability ============

    /// @dev `_isBatchSkippable` checks "is priced" FIRST. An unpriced batch — including an
    ///      empty current batch — must never be skipped: it can still receive requests and
    ///      has to be priced before the cursor may move past it.
    function test_NextLiveBatchId_DoesNotSkipUnpricedCurrentBatch() public view {
        // Nothing queued yet: batch 1 is current, unpriced, and empty.
        assertEq(exitQueue.currentBatchId(), 1);
        assertEq(exitQueue.unprocessedUsersCount(1), 0);
        assertEq(executor.nextLiveBatchIdToProcess(), 1);
        assertEq(executor.nextBatchIdToProcess(), 1);
    }

    /// @dev A priced batch with no unprocessed users is fully settled — the cursor advances.
    function test_NextLiveBatchId_SkipsFullySettledBatch() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));
        _perform(uint8(IQueueKeeperExecutor.QueueAction.ProcessRequests), abi.encode(batchId, uint256(0), uint256(1)));

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        assertGt(executor.nextLiveBatchIdToProcess(), batchId);
    }

    /// @dev A priced batch past MAX_BATCH_PROCESSING_TIME is skippable — users self-serve via
    ///      the ExitQueue escape hatch, so the keeper stops blocking the cursor on it.
    function test_NextLiveBatchId_SkipsExpiredBatch() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));

        // Still inside the processing window: real work, cursor stays put.
        assertEq(executor.nextLiveBatchIdToProcess(), batchId);
        assertGt(exitQueue.unprocessedUsersCount(batchId), 0);

        vm.warp(block.timestamp + exitQueue.MAX_BATCH_PROCESSING_TIME() + 1);
        assertGt(executor.nextLiveBatchIdToProcess(), batchId);
        assertEq(executor.affordableRequests(batchId), 0);

        vm.prank(automationAccount);
        vm.expectRevert(IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector);
        executor.perform(
            uint8(IQueueKeeperExecutor.QueueAction.ProcessRequests), abi.encode(batchId, uint256(0), uint256(1))
        );
    }

    // ============ Actions ============

    function test_QueueUpkeepStatus_AndPriceBatch() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        (IQueueKeeperExecutor.QueueAction action, uint256 statusBatchId, uint256 count) = executor.queueUpkeepStatus();
        assertEq(uint8(action), uint8(IQueueKeeperExecutor.QueueAction.PriceBatch));
        assertEq(statusBatchId, batchId);
        assertEq(count, 0);

        vm.expectEmit(true, true, false, true, address(executor));
        emit IQueueKeeperExecutor.QueueUpkeepPerformed(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId, 0);
        _perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));

        (bool canBeProcessed,,,,) = exitQueue.batchInfo(batchId);
        assertTrue(canBeProcessed);
    }

    function test_ProcessRequests_RevalidatesRange() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _perform(uint8(IQueueKeeperExecutor.QueueAction.PriceBatch), abi.encode(batchId));

        (IQueueKeeperExecutor.QueueAction action, uint256 statusBatchId, uint256 count) = executor.queueUpkeepStatus();
        assertEq(uint8(action), uint8(IQueueKeeperExecutor.QueueAction.ProcessRequests));
        assertEq(statusBatchId, batchId);
        assertEq(count, 1);

        // Over-claim reverts
        vm.prank(automationAccount);
        vm.expectRevert(IQueueKeeperExecutor.KeeperExecutorNoUpkeepNeeded.selector);
        executor.perform(
            uint8(IQueueKeeperExecutor.QueueAction.ProcessRequests), abi.encode(batchId, uint256(0), uint256(2))
        );

        // Exact claim succeeds (pull-over-push: ETH lands in AMM claimableBalances)
        _perform(uint8(IQueueKeeperExecutor.QueueAction.ProcessRequests), abi.encode(batchId, uint256(0), uint256(1)));
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        assertApproxEqAbs(amm.claimableBalances(user), EXIT_ETH, 1);
    }
}
