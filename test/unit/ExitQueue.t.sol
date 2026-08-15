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
        assertEq(exitQueue.version(), "1.0.0");
        assertEq(exitQueue.liveScanFromBatchId(), INITIAL_BATCH_ID);
        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(liability, 0);
        assertEq(escrowed, 0);
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
        exitQueue.priceBatch(EVE_PRICE_1);

        // Pull request
        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

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

    function test_Controller_CanPriceBatch() public {
        // Push a request first
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        // Price the batch
        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        (bool canBeProcessed, uint256 finalPrice,,,) = exitQueue.batchInfo(INITIAL_BATCH_ID);
        assertTrue(canBeProcessed);
        assertEq(finalPrice, EVE_PRICE_1);
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
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.prank(unauthorized);
        vm.expectRevert();
        exitQueue.pullRequest(batchId, user1);
    }

    function test_Unauthorized_CannotPriceBatch() public {
        // Push a request first
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(unauthorized);
        vm.expectRevert();
        exitQueue.priceBatch(EVE_PRICE_1);
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

        (,, uint256 totalTokens,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokens, TOKENS_TO_BURN_1);

        // Add another request
        vm.prank(amm);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);

        (,, totalTokens,,) = exitQueue.batchInfo(batchId);
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

    // ============ PriceBatch Tests ============

    function test_PriceBatch_EmitsEvent() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.expectEmit(true, false, false, false);
        emit IExitQueue.BatchPriced(INITIAL_BATCH_ID);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);
    }

    function test_PriceBatch_SetsBatchInfo() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_2);

        (bool canBeProcessed, uint256 finalPrice, uint256 totalTokens, uint256 createdAt,) =
            exitQueue.batchInfo(batchId);

        assertTrue(canBeProcessed);
        assertEq(finalPrice, EVE_PRICE_2);
        assertEq(totalTokens, TOKENS_TO_BURN_1);
        assertEq(createdAt, block.timestamp);
    }

    function test_PriceBatch_IncrementsCurrentBatchId() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertEq(exitQueue.currentBatchId(), INITIAL_BATCH_ID);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        assertEq(exitQueue.currentBatchId(), INITIAL_BATCH_ID + 1);
    }

    function test_PriceBatch_EmptyBatch_Reverts() public {
        vm.prank(controller);
        vm.expectRevert(IExitQueue.ExitQueueBatchIsEmpty.selector);
        exitQueue.priceBatch(EVE_PRICE_1);
    }

    function test_PriceBatch_WhenPaused_Reverts() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        exitQueue.pause();

        vm.prank(controller);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        exitQueue.priceBatch(EVE_PRICE_1);
    }

    // ============ PullRequest Tests ============

    function test_PullRequest_EmitsEvent() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.expectEmit(true, true, false, false);
        emit IExitQueue.RequestPulled(batchId, user1, true); // isWithinTolerance = true

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);
    }

    function test_PullRequest_MarksAsProcessed() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

        (bool processed,,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
    }

    function test_PullRequest_RemovesFromUnprocessedUsers() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_PullRequest_UpdatesBatchTotalTokens() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        (,, uint256 totalTokensBefore,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokensBefore, TOKENS_TO_BURN_1 + TOKENS_TO_BURN_2);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

        (,, uint256 totalTokensAfter,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokensAfter, TOKENS_TO_BURN_2);
    }

    function test_PullRequest_NotPriced_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueBatchCannotBeProcessed.selector);
        exitQueue.pullRequest(batchId, user1);
    }

    function test_PullRequest_AlreadyProcessed_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestAlreadyProcessed.selector);
        exitQueue.pullRequest(batchId, user1);
    }

    function test_PullRequest_NotInBatch_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestNotInBatch.selector);
        exitQueue.pullRequest(batchId, user2); // user2 not in batch
    }

    function test_PullRequest_WhenPaused_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        exitQueue.pause();

        vm.prank(amm);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        exitQueue.pullRequest(batchId, user1);
    }

    // ============ Slippage Protection Tests ============

    function test_PullRequest_WithinTolerance_NoSlippage() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_5_PCT);

        // Price drops by 3% (within 5% tolerance)
        uint256 droppedPrice = (EVE_PRICE_1 * 97e16) / Math.SCALE_FACTOR; // 97% of original

        vm.prank(controller);
        exitQueue.priceBatch(droppedPrice);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

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
        exitQueue.priceBatch(droppedPrice);

        vm.expectEmit(true, true, false, false);
        emit IExitQueue.RequestPulled(batchId, user1, false); // isWithinTolerance = false

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

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
        exitQueue.priceBatch(droppedPrice);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

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
        exitQueue.priceBatch(EVE_PRICE_1);

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

        (,, uint256 totalTokensBefore,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokensBefore, TOKENS_TO_BURN_1 + TOKENS_TO_BURN_2);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        (,, uint256 totalTokensAfter,,) = exitQueue.batchInfo(batchId);
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
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

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

    function test_CloseRequest_AfterPricing_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        // Price the batch - this makes it processable
        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        // Verify batch is now processable
        (bool canBeProcessed,,,,) = exitQueue.batchInfo(batchId);
        assertTrue(canBeProcessed, "Batch should be processable after pricing");

        // Attempting to close request after pricing should revert
        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_CloseRequest_AfterPricing_WithMultipleUsers() public {
        // Add multiple users to the batch
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        // Price the batch
        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

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

    function test_CloseRequest_AfterPricing_AtExactlyMaxProcessingTime_Reverts() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        // At exactly MAX_BATCH_PROCESSING_TIME, close should still revert (upper bound is exclusive)
        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()));

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        exitQueue.closeRequest(batchId, user1);
    }

    function test_CloseRequest_AfterPricing_WhenMaxProcessingTimeExceeded_Succeeds() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

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

    function test_CloseRequest_AfterPricing_WhenMaxProcessingTimeExceeded_WithMultipleUsers() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

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

    function test_BatchInfo_UnpricedBatch() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        (bool canBeProcessed, uint256 finalPrice, uint256 totalTokens, uint256 createdAt, uint256 pricedAt) =
            exitQueue.batchInfo(batchId);

        assertFalse(canBeProcessed);
        assertEq(finalPrice, 0);
        assertEq(totalTokens, TOKENS_TO_BURN_1);
        assertEq(createdAt, block.timestamp);
        assertEq(pricedAt, 0, "Unpriced batch should have pricedAt zero");
    }

    function test_BatchInfo_PricedBatch() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_2);

        (bool canBeProcessed, uint256 finalPrice, uint256 totalTokens, uint256 createdAt, uint256 pricedAt) =
            exitQueue.batchInfo(batchId);

        assertTrue(canBeProcessed);
        assertEq(finalPrice, EVE_PRICE_2);
        assertEq(totalTokens, TOKENS_TO_BURN_1);
        assertEq(createdAt, block.timestamp);
        assertEq(pricedAt, block.timestamp, "Priced batch should have pricedAt set to priceBatch time");
    }

    function test_BatchInfo_PricedBatch_PricedAtSetWhenPriceBatchCalled() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        (,,, uint256 createdAtBeforePrice,) = exitQueue.batchInfo(batchId);
        vm.warp(block.timestamp + 1 hours);
        uint256 expectedPricedAt = block.timestamp;

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_2);

        (,,, uint256 createdAt, uint256 pricedAt) = exitQueue.batchInfo(batchId);

        assertEq(createdAt, createdAtBeforePrice, "createdAt is when batch was created");
        assertEq(pricedAt, expectedPricedAt, "pricedAt is when priceBatch was called");
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

    function test_RequestCanBeClosed_UnpricedBatch_ReturnsTrue() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        assertTrue(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_PricedBatch_WithinWindow_ReturnsFalse() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        assertFalse(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_PricedBatch_AtExactlyMaxProcessingTime_ReturnsFalse() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()));

        assertFalse(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_PricedBatch_WhenMaxProcessingTimeExceeded_ReturnsTrue() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        assertTrue(exitQueue.requestCanBeClosed(batchId, user1));
    }

    function test_RequestCanBeClosed_AlreadyProcessed_ReturnsFalse() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

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
        exitQueue.priceBatch(EVE_PRICE_1);

        // Second batch (currentBatchId incremented)
        vm.prank(amm);
        uint256 batchId2 = exitQueue.pushRequest(user2, EVE_PRICE_2, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);

        assertEq(batchId1, INITIAL_BATCH_ID);
        assertEq(batchId2, INITIAL_BATCH_ID + 1);

        // Verify both batches exist independently
        (bool canBeProcessed1,,,,) = exitQueue.batchInfo(batchId1);
        (bool canBeProcessed2,,,,) = exitQueue.batchInfo(batchId2);

        assertTrue(canBeProcessed1);
        assertFalse(canBeProcessed2); // Not priced yet
    }

    // ============ Edge Cases ============

    function test_ProcessMultipleRequestsInBatch() public {
        vm.startPrank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user2, EVE_PRICE_1, TOKENS_TO_BURN_2, PRICE_TOLERANCE_1_PCT);
        exitQueue.pushRequest(user3, EVE_PRICE_1, TOKENS_TO_BURN_3, PRICE_TOLERANCE_1_PCT);
        vm.stopPrank();

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        // Process all requests
        vm.startPrank(amm);
        exitQueue.pullRequest(batchId, user1);
        exitQueue.pullRequest(batchId, user2);
        exitQueue.pullRequest(batchId, user3);
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
        exitQueue.priceBatch(EVE_PRICE_1);

        // Pull user3's request
        vm.prank(amm);
        exitQueue.pullRequest(batchId, user3);

        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
    }

    function test_ZeroTokensToBurn() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, 0, PRICE_TOLERANCE_1_PCT);

        (,, uint256 totalTokens,,) = exitQueue.batchInfo(batchId);
        assertEq(totalTokens, 0);
    }

    function test_ZeroPriceTolerance() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, 0);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_3); // Price drops significantly

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

        // With zero tolerance, any price drop should trigger slippage
        (bool processed, bool closedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user1);
        assertTrue(processed);
        assertTrue(closedDueToSlippage);
    }

    function test_LiveRedemptionOffsets_UnpricedIsZero() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(liability, 0);
        assertEq(escrowed, 0);
    }

    function test_LiveRedemptionOffsets_AfterPriceBatch() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(escrowed, TOKENS_TO_BURN_1);
        assertEq(liability, Math.convertAssets(TOKENS_TO_BURN_1, EVE_PRICE_1));
        assertEq(exitQueue.liveScanFromBatchId(), INITIAL_BATCH_ID);
    }

    function test_LiveRedemptionOffsets_PullReducesOffsets() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.prank(amm);
        exitQueue.pullRequest(batchId, user1);

        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(liability, 0);
        assertEq(escrowed, 0);
        assertEq(exitQueue.liveScanFromBatchId(), INITIAL_BATCH_ID + 1);
    }

    function test_LiveRedemptionOffsets_LapsesAfterExpiryWithoutWrite() public {
        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(liability, 0);
        assertEq(escrowed, 0);
        // lo is not advanced until a write
        assertEq(exitQueue.liveScanFromBatchId(), INITIAL_BATCH_ID);
    }

    function test_PullRequest_RevertsAfterExpiry() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueBatchExpired.selector);
        exitQueue.pullRequest(batchId, user1);
    }

    function test_CloseRequest_AfterExpiryAdvancesLo() public {
        vm.prank(amm);
        uint256 batchId = exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);

        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.prank(amm);
        exitQueue.closeRequest(batchId, user1);

        assertEq(exitQueue.liveScanFromBatchId(), INITIAL_BATCH_ID + 1);
        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(liability, 0);
        assertEq(escrowed, 0);
    }

    function test_PriceBatch_RevertsWhenLiveWindowFull() public {
        uint256 cap = exitQueue.MAX_LIVE_PRICED_BATCHES();
        for (uint256 i; i < cap; ++i) {
            vm.prank(amm);
            exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
            vm.prank(controller);
            exitQueue.priceBatch(EVE_PRICE_1);
        }

        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        vm.prank(controller);
        vm.expectRevert(IExitQueue.ExitQueueTooManyLivePricedBatches.selector);
        exitQueue.priceBatch(EVE_PRICE_1);
    }

    function test_PriceBatch_AfterExpiryFreesWidthCap() public {
        uint256 cap = exitQueue.MAX_LIVE_PRICED_BATCHES();
        for (uint256 i; i < cap; ++i) {
            vm.prank(amm);
            exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
            vm.prank(controller);
            exitQueue.priceBatch(EVE_PRICE_1);
        }

        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.prank(amm);
        exitQueue.pushRequest(user1, EVE_PRICE_1, TOKENS_TO_BURN_1, PRICE_TOLERANCE_1_PCT);
        vm.prank(controller);
        exitQueue.priceBatch(EVE_PRICE_1);

        (uint256 liability, uint256 escrowed) = exitQueue.liveRedemptionOffsets();
        assertEq(escrowed, TOKENS_TO_BURN_1);
        assertEq(liability, Math.convertAssets(TOKENS_TO_BURN_1, EVE_PRICE_1));
    }

    function test_PushRequest_TokensOverflow() public {
        vm.prank(amm);
        vm.expectRevert(IExitQueue.ExitQueueTokensOverflow.selector);
        exitQueue.pushRequest(user1, EVE_PRICE_1, uint256(type(uint128).max) + 1, PRICE_TOLERANCE_1_PCT);
    }
}
