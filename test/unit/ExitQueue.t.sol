// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {Registry} from "registry/Registry.sol";
import {IExitQueue} from "../../src/interfaces/IExitQueue.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {Math} from "../../src/libraries/Math.sol";
import {MockAMMStub} from "../mocks/MockAMMStub.sol";
import {MockController} from "../mocks/MockController.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title ExitQueueTest
 * @notice Comprehensive test suite for ExitQueue contract
 */
contract ExitQueueTest is ProtocolTestBase {
    ExitQueue public exitQueue;
    ExitQueue public exitQueueImpl;
    Registry public registry;

    address public admin;
    address public amm;
    address public controller;
    address public user1;
    address public user2;
    address public user3;
    address public unauthorized;

    uint256 public constant INITIAL_BATCH_ID = 1;
    uint256 public constant EVE_PRICE_1 = 1e18; // 1 ETH per EVE
    uint256 public constant EVE_PRICE_2 = 1.1e18; // 1.1 ETH per EVE
    uint256 public constant EVE_PRICE_3 = 0.9e18; // 0.9 ETH per EVE
    uint256 public constant TOKENS_TO_BURN_1 = 100e18;
    uint256 public constant TOKENS_TO_BURN_2 = 200e18;
    uint256 public constant TOKENS_TO_BURN_3 = 150e18;
    uint256 public constant PRICE_TOLERANCE_1_PCT = 1e16; // 1%
    uint256 public constant PRICE_TOLERANCE_5_PCT = 5e16; // 5%

    // ============ Setup ============

    function setUp() public {
        admin = address(this);
        amm = address(new MockAMMStub());
        controller = address(new MockController());
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        unauthorized = makeAddr("unauthorized");

        _deployExitQueueInstance();
        _setupRoles();
    }

    function _deployExitQueueInstance() internal {
        registry = _deployRegistry(admin);
        exitQueue = _deployExitQueue(registry);
    }

    function _setupRoles() internal {
        _registerExitQueuePeers(registry, amm, controller, admin);
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(exitQueue.currentBatchId(), INITIAL_BATCH_ID);
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, admin));
        assertEq(address(exitQueue.registry()), address(registry));
        assertEq(exitQueue.version(), "2.0.0");
        (bool canBeProcessed, uint256 totalTokens, uint256 createdAt, uint256 sealedAt) =
            exitQueue.batchInfo(INITIAL_BATCH_ID);
        assertFalse(canBeProcessed);
        assertEq(totalTokens, 0);
        assertEq(createdAt, block.timestamp);
        assertEq(sealedAt, 0);
    }

    function test_Initialize_ZeroRegistry() public {
        ExitQueue newImpl = new ExitQueue();
        bytes memory initData = abi.encodeWithSelector(ExitQueue.initialize.selector, address(0));

        vm.expectRevert(IRegistryClient.RegistryClientZeroRegistry.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_OnlyOnce() public {
        vm.expectRevert();
        exitQueue.initialize(address(registry));
    }

    // ============ Access Control Tests ============

    function test_AMM_CanPushRequest() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertEq(batchId, INITIAL_BATCH_ID);
    }

    function test_AMM_CanPullRequest() public {
        // Push and price a request first
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        // Pull request
        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        (bool processed,,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
    }

    function test_AMM_CanCloseRequest() public {
        // Push a request
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        // Close request
        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        // Request should be removed
        vm.expectRevert(IExitQueue.ExitQueueRequestNotInBatch.selector);
        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_Controller_CanSealBatch() public {
        // Push a request first
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        // Seal the batch
        vm.prank(controller);
        exitQueue.sealBatch();

        (bool canBeProcessed,,,) = exitQueue.batchInfo(INITIAL_BATCH_ID);
        assertTrue(canBeProcessed);
        assertEq(exitQueue.currentBatchId(), INITIAL_BATCH_ID + 1);
    }

    function test_Unauthorized_CannotPushRequest() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
    }

    function test_Unauthorized_CannotPullRequest() public {
        // Push and price a request first
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(unauthorized);
        vm.expectRevert();
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
    }

    function test_Unauthorized_CannotSealBatch() public {
        // Push a request first
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(unauthorized);
        vm.expectRevert();
        exitQueue.sealBatch();
    }

    function test_Unauthorized_CannotCloseRequest() public {
        // Push a request
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(unauthorized);
        vm.expectRevert();
        exitQueue.closeRequest(batchId, user1);
    }

    // ============ PushRequest Tests ============

    function test_PushRequest_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IExitQueue.RequestPushed(INITIAL_BATCH_ID, user1);

        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
    }

    function test_PushRequest_StoresRequestInfo() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        (bool processed, bool closedDueToSlippage, uint256 priceAtRequest, uint256 tokensToBurn, uint256 tolerance) =
            exitQueue.requestInfo(batchId, user1);

        assertFalse(processed);
        assertFalse(closedDueToSlippage);
        assertEq(priceAtRequest, EVE_PRICE_1);
        assertEq(tokensToBurn, TOKENS_TO_BURN_1);
        assertEq(tolerance, PRICE_TOLERANCE_1_PCT);
    }

    function test_PushRequest_UpdatesBatchTotalTokens() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        (, uint256 totalTokens,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokens, TOKENS_TO_BURN_1);

        // Add another request
        vm.prank(amm);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);

        (, totalTokens,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokens, TOKENS_TO_BURN_1 + TOKENS_TO_BURN_2);
    }

    function test_PushRequest_AddsToUnprocessedUsers() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);

        address[] memory users = exitQueue.unprocessedUsers(batchId);
        assertEq(users.length, 1);
        assertEq(users[0], user1);
    }

    function test_PushRequest_DuplicateUser_Reverts() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestAlreadyInBatch.selector);
        exitQueue.pushRequest(user1, EVE_PRICE_2, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
    }

    function test_PushRequest_WhenPaused_Reverts() public {
        exitQueue.pause();

        vm.prank(amm);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
    }

    function test_PushRequest_MultipleUsers() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        assertEq(exitQueue.unprocessedUsersCount(batchId), 3);

        address[] memory users = exitQueue.unprocessedUsers(batchId);
        assertEq(users.length, 3);
    }

    // ============ SealBatch Tests ============

    function test_SealBatch_EmitsEvent() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.expectEmit(true, false, false, false);
        emit IExitQueue.BatchSealed(INITIAL_BATCH_ID);

        vm.prank(controller);
        exitQueue.sealBatch();
    }

    function test_SealBatch_SetsBatchInfo() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        (bool canBeProcessed, uint256 totalTokens, uint256 createdAt, uint256 sealedAt) = exitQueue.batchInfo(batchId);

        assertTrue(canBeProcessed);
        assertEq(totalTokens, TOKENS_TO_BURN_1);
        assertEq(createdAt, block.timestamp);
        assertEq(sealedAt, block.timestamp);
    }

    function test_SealBatch_IncrementsCurrentBatchId() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertEq(exitQueue.currentBatchId(), INITIAL_BATCH_ID);

        vm.prank(controller);
        exitQueue.sealBatch();

        assertEq(exitQueue.currentBatchId(), INITIAL_BATCH_ID + 1);
    }

    function test_SealBatch_EmptyBatch_Reverts() public {
        vm.prank(controller);
        vm.expectRevert(IExitQueue.ExitQueueBatchIsEmpty.selector);
        exitQueue.sealBatch();
    }

    function test_SealBatch_WhenPaused_Reverts() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        exitQueue.pause();

        vm.prank(controller);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        exitQueue.sealBatch();
    }

    // ============ PullRequest Tests ============

    function test_PullRequest_EmitsEvent() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.expectEmit(true, true, false, true);
        emit IExitQueue.RequestPulled(batchId, user1, EVE_PRICE_1, true); // isWithinTolerance = true

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
    }

    function test_PullRequest_MarksAsProcessed() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        (bool processed,,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
    }

    function test_PullRequest_RemovesFromUnprocessedUsers() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_PullRequest_UpdatesBatchTotalTokens() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.sealBatch();

        (, uint256 totalTokensBefore,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokensBefore, TOKENS_TO_BURN_1 + TOKENS_TO_BURN_2);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        (, uint256 totalTokensAfter,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokensAfter, TOKENS_TO_BURN_2);
    }

    function test_PullRequest_NotSealed_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueBatchCannotBeProcessed.selector);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
    }

    function test_PullRequest_AlreadyProcessed_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestAlreadyProcessed.selector);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
    }

    function test_PullRequest_NotInBatch_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestNotInBatch.selector);
        exitQueue.pullRequest(batchId, user2, EVE_PRICE_1); // user2 not in batch
    }

    function test_PullRequest_WhenPaused_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        exitQueue.pause();

        vm.prank(amm);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
    }

    // ============ Slippage Protection Tests ============

    function test_PullRequest_WithinTolerance_NoSlippage() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_5_PCT);

        // Price drops by 3% (within 5% tolerance)
        uint256 droppedPrice = (EVE_PRICE_1 * 97e16) / Math.SCALE_FACTOR; // 97% of original

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, droppedPrice);

        (bool processed, bool closedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
        assertFalse(closedDueToSlippage);
    }

    function test_PullRequest_ExceedsTolerance_SetsSlippageFlag() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        // Price drops by 10% (exceeds 1% tolerance)
        uint256 droppedPrice = (EVE_PRICE_1 * 9e17) / Math.SCALE_FACTOR; // 90% of original

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.expectEmit(true, true, false, true);
        emit IExitQueue.RequestPulled(batchId, user1, droppedPrice, false); // isWithinTolerance = false

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, droppedPrice);

        (bool processed, bool closedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
        assertTrue(closedDueToSlippage);
    }

    function test_PullRequest_ExactToleranceBoundary() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        // Price drops by exactly 1% (at tolerance boundary)
        uint256 droppedPrice = (EVE_PRICE_1 * 99e16) / Math.SCALE_FACTOR; // 99% of original

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, droppedPrice);

        // At exact boundary, should not be considered slippage (price is not LESS than threshold)
        (bool processed, bool closedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
        assertFalse(closedDueToSlippage);
    }

    // ============ CloseRequest Tests ============

    function test_CloseRequest_EmitsEvent() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.expectEmit(true, true, false, true);
        emit IExitQueue.RequestClosed(batchId, user1, false); // Pre-pricing close, not escape hatch

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_CloseRequest_EmitsEvent_WithViaEscapeHatch_WhenMaxProcessingTimeExceeded() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.expectEmit(true, true, false, true);
        emit IExitQueue.RequestClosed(batchId, user1, true); // Escape hatch: batch not processed in time

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_CloseRequest_RemovesRequest() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        // Request should be completely removed
        (bool processed, bool closedDueToSlippage, uint256 priceAtRequest, uint256 tokensToBurn, uint256 tolerance) =
            exitQueue.requestInfo(batchId, user1);

        assertFalse(processed);
        assertFalse(closedDueToSlippage);
        assertEq(priceAtRequest, 0);
        assertEq(tokensToBurn, 0);
        assertEq(tolerance, 0);
    }

    function test_CloseRequest_RemovesFromUnprocessedUsers() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_CloseRequest_UpdatesBatchTotalTokens() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        (, uint256 totalTokensBefore,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokensBefore, TOKENS_TO_BURN_1 + TOKENS_TO_BURN_2);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        (, uint256 totalTokensAfter,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokensAfter, TOKENS_TO_BURN_2);
    }

    function test_CloseRequest_AllowsReRequestInSameBatch() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        // User can now request again in the same batch
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_2, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);
    }

    function test_CloseRequest_AlreadyProcessed_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestAlreadyProcessed.selector);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_CloseRequest_NotInBatch_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestNotInBatch.selector);
        exitQueue.closeRequest(batchId, user2); // user2 not in batch
    }

    function test_CloseRequest_WorksWhenPaused() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        exitQueue.pause();

        // closeRequest should work even when paused (emergency withdrawal)
        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_CloseRequest_AfterSealing_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        // Price the batch - this makes it processable
        vm.prank(controller);
        exitQueue.sealBatch();

        // Verify batch is now processable
        (bool canBeProcessed,,,) = exitQueue.batchInfo(batchId);
        assertTrue(canBeProcessed, "Batch should be processable after pricing");

        // Attempting to close request after pricing should revert
        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_CloseRequest_AfterSealing_WithMultipleUsers() public {
        // Add multiple users to the batch
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        // Price the batch
        vm.prank(controller);
        exitQueue.sealBatch();

        // All users should not be able to close their requests
        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        exitQueue.closeRequest(batchId, user1);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        exitQueue.closeRequest(batchId, user2);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        exitQueue.closeRequest(batchId, user3);
    }

    function test_CloseRequest_AfterSealing_AtExactlyMaxProcessingTime_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        // At exactly MAX_BATCH_PROCESSING_TIME, close should still revert (upper bound is exclusive)
        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()));

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_CloseRequest_AfterSealing_WhenMaxProcessingTimeExceeded_Succeeds() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        // After MAX_BATCH_PROCESSING_TIME has passed, user can close (escape hatch)
        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        // Request should be completely removed
        (bool processed, bool closedDueToSlippage, uint256 priceAtRequest, uint256 tokensToBurn,) =
            exitQueue.requestInfo(batchId, user1);
        assertFalse(processed);
        assertFalse(closedDueToSlippage);
        assertEq(priceAtRequest, 0);
        assertEq(tokensToBurn, 0);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_CloseRequest_AfterSealing_WhenMaxProcessingTimeExceeded_WithMultipleUsers() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);
        vm.prank(amm);
        exitQueue.closeRequest(batchId, user2);
        vm.prank(amm);
        exitQueue.closeRequest(batchId, user3);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    // ============ View Function Tests ============

    function test_BatchInfo_UnsealedBatch() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        (bool canBeProcessed, uint256 totalTokens, uint256 createdAt, uint256 sealedAt) = exitQueue.batchInfo(batchId);

        assertFalse(canBeProcessed);
        assertEq(totalTokens, TOKENS_TO_BURN_1);
        assertEq(createdAt, block.timestamp);
        assertEq(sealedAt, 0, "Unsealed batch should have sealedAt zero");
    }

    function test_BatchInfo_SealedBatch() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        (bool canBeProcessed, uint256 totalTokens, uint256 createdAt, uint256 sealedAt) = exitQueue.batchInfo(batchId);

        assertTrue(canBeProcessed);
        assertEq(totalTokens, TOKENS_TO_BURN_1);
        assertEq(createdAt, block.timestamp);
        assertEq(sealedAt, block.timestamp, "Sealed batch should have sealedAt set to sealBatch time");
    }

    function test_BatchInfo_SealedBatch_SealedAtSetWhenSealBatchCalled() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        (,, uint256 createdAtBeforeSeal,) = exitQueue.batchInfo(batchId);
        vm.warp(block.timestamp + 1 hours);
        uint256 expectedSealedAt = block.timestamp;

        vm.prank(controller);
        exitQueue.sealBatch();

        (,, uint256 createdAt, uint256 sealedAt) = exitQueue.batchInfo(batchId);

        assertEq(createdAt, createdAtBeforeSeal, "createdAt is when batch was created");
        assertEq(sealedAt, expectedSealedAt, "sealedAt is when sealBatch was called");
    }

    function test_RequestInfo_NonExistentRequest() public view {
        // Request doesn't exist
        (bool processed, bool closedDueToSlippage, uint256 priceAtRequest, uint256 tokensToBurn, uint256 tolerance) =
            exitQueue.requestInfo(1, user1);

        assertFalse(processed);
        assertFalse(closedDueToSlippage);
        assertEq(priceAtRequest, 0);
        assertEq(tokensToBurn, 0);
        assertEq(tolerance, 0);
    }

    function test_RequestCanBeClosed_UnsealedBatch_ReturnsTrue() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertTrue(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_SealedBatch_WithinWindow_ReturnsFalse() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        assertFalse(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_SealedBatch_AtExactlyMaxProcessingTime_ReturnsFalse() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()));

        assertFalse(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_SealedBatch_WhenMaxProcessingTimeExceeded_ReturnsTrue() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        assertTrue(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_AlreadyProcessed_ReturnsFalse() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        assertFalse(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_UserNotInBatch_ReturnsFalse() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertFalse(exitQueue.requestCanBeClosed(batchId, user2));
    }

    function test_RequestCanBeClosed_NonExistentBatch_ReturnsFalse() public view {
        assertFalse(exitQueue.requestCanBeClosed(999, user1));
    }

    function test_UnprocessedUsersCount() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);

        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 2);

        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 3);
        vm.stopPrank();
    }

    function test_UnprocessedUsers_AllUsers() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        address[] memory users = exitQueue.unprocessedUsers(batchId);
        assertEq(users.length, 3);
    }

    function test_UnprocessedUsers_WithRange() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        address[] memory users = exitQueue.unprocessedUsers(batchId, 0, 2);
        assertEq(users.length, 2);
    }

    function test_UnprocessedUsers_InvalidRange_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.expectRevert(IExitQueue.ExitQueueInvalidRange.selector);
        exitQueue.unprocessedUsers(batchId, 1, 0); // startIndex >= endIndex

        vm.expectRevert(IExitQueue.ExitQueueInvalidRange.selector);
        exitQueue.unprocessedUsers(batchId, 0, 10); // endIndex > length
    }

    // ============ Pause/Unpause Tests ============

    function test_Pause_OnlyAdmin() public {
        exitQueue.pause();
        assertTrue(exitQueue.paused());

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        exitQueue.pause();
    }

    function test_Pause_SecurityCanPauseImmediately() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        exitQueue.pause();

        assertTrue(exitQueue.paused());
    }

    function test_SecurityCannotUnpause() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        exitQueue.pause();

        // Recovery stays with ADMIN_ROLE (timelocked in production)
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        exitQueue.unpause();
    }

    function test_Unpause_OnlyAdmin() public {
        exitQueue.pause();

        exitQueue.unpause();
        assertFalse(exitQueue.paused());

        exitQueue.pause();
        vm.prank(unauthorized);
        vm.expectRevert();
        exitQueue.unpause();
    }

    // ============ Multiple Batches Tests ============

    function test_MultipleBatches() public {
        // First batch
        vm.prank(amm);
        uint256 batchId1 = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        // Second batch (currentBatchId incremented)
        vm.prank(amm);
        uint256 batchId2 = exitQueue.pushRequest(user2, EVE_PRICE_2, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);

        assertEq(batchId1, INITIAL_BATCH_ID);
        assertEq(batchId2, INITIAL_BATCH_ID + 1);

        // Verify both batches exist independently
        (bool canBeProcessed1,,,) = exitQueue.batchInfo(batchId1);
        (bool canBeProcessed2,,,) = exitQueue.batchInfo(batchId2);

        assertTrue(canBeProcessed1);
        assertFalse(canBeProcessed2); // Not sealed yet
    }

    // ============ Edge Cases ============

    function test_ProcessMultipleRequestsInBatch() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.sealBatch();

        // Process all requests
        vm.startPrank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
        exitQueue.pullRequest(batchId, user2, EVE_PRICE_1);
        exitQueue.pullRequest(batchId, user3, EVE_PRICE_1);
        vm.stopPrank();

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);

        (bool processed1,,,,) = exitQueue.requestInfo(batchId, user1);
        (bool processed2,,,,) = exitQueue.requestInfo(batchId, user2);
        (bool processed3,,,,) = exitQueue.requestInfo(batchId, user3);

        assertTrue(processed1);
        assertTrue(processed2);
        assertTrue(processed3);
    }

    function test_MixOfCloseAndPull() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        // Close user1's request
        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        // Close user2's request
        vm.prank(amm);
        exitQueue.closeRequest(batchId, user2);

        vm.prank(controller);
        exitQueue.sealBatch();

        // Pull user3's request
        vm.prank(amm);
        exitQueue.pullRequest(batchId, user3, EVE_PRICE_1);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_ZeroTokensToBurn() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, 0, PRICE_TOLERANCE_1_PCT);

        (, uint256 totalTokens,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokens, 0);
    }

    function test_ZeroPriceTolerance() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, 0);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_3); // Price drops significantly

        // With zero tolerance, any price drop should trigger slippage
        (bool processed, bool closedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
        assertTrue(closedDueToSlippage);
    }

    // ============ Settlement Price Tests (audit G1) ============

    function test_SealBatch_DoesNotFixAPrice() public {
        // The same sealed batch settles each request at whatever price the AMM supplies when
        // it pays that request: nothing about the price is stored at seal time.
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_5_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_5_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.expectEmit(true, true, false, true);
        emit IExitQueue.RequestPulled(batchId, user1, EVE_PRICE_1, true);
        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);

        vm.expectEmit(true, true, false, true);
        emit IExitQueue.RequestPulled(batchId, user2, EVE_PRICE_2, true);
        vm.prank(amm);
        exitQueue.pullRequest(batchId, user2, EVE_PRICE_2);
    }

    function test_PullRequest_SlippageIsJudgedAgainstTheSettlementPrice() public {
        // Two identical requests in one batch: the one settled after the price has fallen past
        // the tolerance is closed, the one settled before is not.
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.startPrank(amm);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
        exitQueue.pullRequest(batchId, user2, EVE_PRICE_3);
        vm.stopPrank();

        (, bool closed1,,,) = exitQueue.requestInfo(batchId, user1);
        (, bool closed2,,,) = exitQueue.requestInfo(batchId, user2);
        assertFalse(closed1);
        assertTrue(closed2);
    }

    function test_PullRequest_ZeroPrice_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueZeroPrice.selector);
        exitQueue.pullRequest(batchId, user1, 0);
    }

    function test_PullRequest_RevertsAfterExpiry() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.sealBatch();

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueBatchExpired.selector);
        exitQueue.pullRequest(batchId, user1, EVE_PRICE_1);
    }

    function test_SealBatch_HasNoLiveBatchCap() public {
        // Sealed batches no longer feed a NAV scan, so there is no cap on how many may be live.
        uint256 batches = 30;
        for (uint256 i; i < batches; ++i) {
            vm.prank(amm);
            exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
            vm.prank(controller);
            exitQueue.sealBatch();
        }

        assertEq(exitQueue.currentBatchId(), INITIAL_BATCH_ID + batches);
    }

    function test_PushRequest_TokensOverflow() public {
        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueTokensOverflow.selector);
        exitQueue.pushRequest(user1, EVE_PRICE_1, uint256(type(uint128).max) + 1, PRICE_TOLERANCE_1_PCT);
    }
}
