// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../src/contracts/Controller.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {CREQueueExecutor} from "../../src/contracts/automation/CREQueueExecutor.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {ICREReceiverBase} from "../../src/interfaces/automation/ICREReceiverBase.sol";
import {ICREQueueExecutor} from "../../src/interfaces/automation/ICREQueueExecutor.sol";
import {IReceiver} from "../../src/interfaces/automation/IReceiver.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {CRETestUtils} from "../helpers/CRETestUtils.sol";

contract CREQueueExecutorTest is ProtocolTestBase, CRETestUtils {
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
    CREQueueExecutor public executor;

    address public admin;
    address public forwarder;
    address public workflowOwner;
    address public user;
    bytes32 public workflowId;
    bytes10 public workflowName;

    uint64 internal _seq;

    function setUp() public {
        admin = address(this);
        forwarder = makeAddr("keystoneForwarder");
        workflowOwner = makeAddr("workflowOwner");
        user = makeAddr("user");
        workflowId = keccak256("queue-keeper-v1");
        workflowName = bytes10("queue-keep");

        ProtocolContracts memory contracts = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        oracle = contracts.oracle;
        amm = contracts.amm;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);

        executor = new CREQueueExecutor(address(registry), forwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));
        executor.setExpectedWorkflowOwner(workflowOwner);
        executor.setExpectedWorkflowName(workflowName);
        executor.setExpectedWorkflowId(workflowId);

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

    function _metadata() internal view returns (bytes memory) {
        return _encodeMetadata(workflowId, workflowName, workflowOwner);
    }

    function _onReport(uint8 action, bytes memory params) internal {
        _seq += 1;
        bytes memory report = _encodeReport(TEST_CHAIN_SELECTOR, _seq, uint64(block.timestamp), action, params);
        vm.prank(forwarder);
        executor.onReport(_metadata(), report);
    }

    function _warpPastMinBatchAge() internal {
        vm.warp(block.timestamp + executor.minBatchAge());
    }

    // ============ Auth / replay / staleness ============

    function test_OnReport_OnlyForwarder() public {
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            1,
            uint64(block.timestamp),
            uint8(ICREQueueExecutor.QueueAction.PriceBatch),
            abi.encode(uint256(1))
        );
        vm.expectRevert(ICREReceiverBase.CREReceiverOnlyForwarder.selector);
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_WrongWorkflowId() public {
        executor.setExpectedWorkflowId(keccak256("other"));
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            1,
            uint64(block.timestamp),
            uint8(ICREQueueExecutor.QueueAction.PriceBatch),
            abi.encode(uint256(1))
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverUnexpectedWorkflow.selector);
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_NameWithoutOwnerRejected() public {
        CREQueueExecutor unbound =
            new CREQueueExecutor(address(registry), forwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        unbound.setExpectedWorkflowName(workflowName); // owner unset
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR, 1, uint64(block.timestamp), uint8(ICREQueueExecutor.QueueAction.None), ""
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverUnexpectedWorkflow.selector);
        unbound.onReport(_metadata(), report);
    }

    function test_OnReport_UnboundRejected() public {
        CREQueueExecutor unbound =
            new CREQueueExecutor(address(registry), forwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR, 1, uint64(block.timestamp), uint8(ICREQueueExecutor.QueueAction.None), ""
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverWorkflowUnbound.selector);
        unbound.onReport(_metadata(), report);
    }

    function test_OnReport_WrongChain() public {
        _seq = 0;
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR + 1,
            1,
            uint64(block.timestamp),
            uint8(ICREQueueExecutor.QueueAction.PriceBatch),
            abi.encode(uint256(1))
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverWrongChain.selector);
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_ReplaySequence() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _onReport(uint8(ICREQueueExecutor.QueueAction.PriceBatch), abi.encode(batchId));

        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            _seq,
            uint64(block.timestamp),
            uint8(ICREQueueExecutor.QueueAction.ProcessRequests),
            abi.encode(batchId, uint256(0), uint256(1))
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverReplayedSequence.selector);
        executor.onReport(_metadata(), report);
    }

    function test_OnReport_StaleReport() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            1,
            uint64(block.timestamp - TEST_MAX_REPORT_AGE - 1),
            uint8(ICREQueueExecutor.QueueAction.PriceBatch),
            abi.encode(batchId)
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverStaleReport.selector);
        executor.onReport(_metadata(), report);
    }

    function test_SupportsIReceiverInterface() public view {
        assertTrue(executor.supportsInterface(type(IReceiver).interfaceId));
    }

    // ============ Actions ============

    function test_QueueUpkeepStatus_AndPriceBatch() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();

        (ICREQueueExecutor.QueueAction action, uint256 statusBatchId, uint256 count) = executor.queueUpkeepStatus();
        assertEq(uint8(action), uint8(ICREQueueExecutor.QueueAction.PriceBatch));
        assertEq(statusBatchId, batchId);
        assertEq(count, 0);

        vm.expectEmit(true, true, false, true, address(executor));
        emit ICREQueueExecutor.QueueUpkeepPerformed(ICREQueueExecutor.QueueAction.PriceBatch, batchId, 0);
        _onReport(uint8(ICREQueueExecutor.QueueAction.PriceBatch), abi.encode(batchId));

        (bool canBeProcessed,,,,) = exitQueue.batchInfo(batchId);
        assertTrue(canBeProcessed);
    }

    function test_ProcessRequests_RevalidatesRange() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        _onReport(uint8(ICREQueueExecutor.QueueAction.PriceBatch), abi.encode(batchId));

        (ICREQueueExecutor.QueueAction action, uint256 statusBatchId, uint256 count) = executor.queueUpkeepStatus();
        assertEq(uint8(action), uint8(ICREQueueExecutor.QueueAction.ProcessRequests));
        assertEq(statusBatchId, batchId);
        assertEq(count, 1);

        // Over-claim reverts
        bytes memory bad = abi.encode(batchId, uint256(0), uint256(2));
        _seq += 1;
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            _seq,
            uint64(block.timestamp),
            uint8(ICREQueueExecutor.QueueAction.ProcessRequests),
            bad
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREQueueExecutor.KeeperExecutorNoUpkeepNeeded.selector);
        executor.onReport(_metadata(), report);

        // Exact claim succeeds (pull-over-push: ETH lands in AMM claimableBalances)
        _onReport(uint8(ICREQueueExecutor.QueueAction.ProcessRequests), abi.encode(batchId, uint256(0), uint256(1)));
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        assertApproxEqAbs(amm.claimableBalances(user), EXIT_ETH, 1);
    }

    function test_WhenPaused_OnReportReverts() public {
        uint256 batchId = _queueExit(user, EXIT_ETH);
        _warpPastMinBatchAge();
        executor.pause();

        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            1,
            uint64(block.timestamp),
            uint8(ICREQueueExecutor.QueueAction.PriceBatch),
            abi.encode(batchId)
        );
        vm.prank(forwarder);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        executor.onReport(_metadata(), report);
    }

    function test_Metadata_RequiresAtLeast62Bytes() public {
        bytes memory shortMeta = abi.encodePacked(workflowId, bytes10("queue-keep"), bytes19(0)); // 61 bytes
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR, 1, uint64(block.timestamp), uint8(ICREQueueExecutor.QueueAction.None), ""
        );
        vm.prank(forwarder);
        vm.expectRevert(ICREReceiverBase.CREReceiverInvalidMetadata.selector);
        executor.onReport(shortMeta, report);
    }
}
