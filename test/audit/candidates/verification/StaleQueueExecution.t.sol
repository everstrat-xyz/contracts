// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Registry} from "registry/Registry.sol";

import {AMM} from "../../../../src/contracts/AMM.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {ExitQueue} from "../../../../src/contracts/ExitQueue.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {QueueKeeperExecutor} from "../../../../src/contracts/automation/QueueKeeperExecutor.sol";
import {IKeeperExecutorBase} from "../../../../src/interfaces/automation/IKeeperExecutorBase.sol";
import {IQueueKeeperExecutor} from "../../../../src/interfaces/automation/IQueueKeeperExecutor.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";

contract StaleQueueExecutionTest is ProtocolTestBase {
    uint256 private constant ETH_PRICE = 4000e8;
    uint256 private constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 private constant EXIT_ETH = 1 ether;
    uint256 private constant PRICE_TOLERANCE = 1e17;

    Registry private registry;
    ExitQueue private exitQueue;
    AMM private amm;
    Controller private controller;
    Oracle private oracle;
    EVE private token;
    QueueKeeperExecutor private executor;

    address private forwarder;
    address private user;

    function setUp() public {
        forwarder = makeAddr("registered Chainlink forwarder");
        user = makeAddr("redeemer");

        ProtocolContracts memory deployed = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        registry = deployed.registry;
        exitQueue = deployed.exitQueue;
        amm = deployed.amm;
        controller = deployed.controller;
        oracle = deployed.oracle;
        token = deployed.token;

        MockPriceFeed feed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(feed), 1 hours);

        executor = new QueueKeeperExecutor(address(registry));
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));
        executor.setForwarder(forwarder);

        vm.deal(user, BOOTSTRAP_DEPOSIT);
        vm.prank(user);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(1);
    }

    function test_StaleProcessPayloadCrossesEscapeBoundaryAndWinsCancellationRace() public {
        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        uint256 batchId = amm.exit(EXIT_ETH, token.balanceOf(user), PRICE_TOLERANCE);
        vm.stopPrank();

        vm.warp(block.timestamp + executor.minBatchAge());
        (bool priceNeeded, bytes memory priceData) = executor.checkUpkeep("");
        assertTrue(priceNeeded);
        assertEq(priceData, abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));
        vm.prank(forwarder);
        executor.performUpkeep(priceData);

        (,,,, uint256 pricedAt) = exitQueue.batchInfo(batchId);
        uint256 escapeBoundary = pricedAt + exitQueue.MAX_BATCH_PROCESSING_TIME();

        // The commitment remains live at equality; user cancellation is still barred.
        vm.warp(escapeBoundary);
        assertFalse(exitQueue.requestCanBeClosed(batchId, user));
        (bool processNeeded, bytes memory staleProcessData) = executor.checkUpkeep("");
        assertTrue(processNeeded);
        assertEq(staleProcessData, abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));

        // One second later a fresh check skips the batch and the user may cancel.
        vm.warp(escapeBoundary + 1);
        assertTrue(exitQueue.requestCanBeClosed(batchId, user));
        (bool freshNeeded, bytes memory freshData) = executor.checkUpkeep("");
        assertTrue(freshNeeded);
        assertEq(freshData, abi.encode(IQueueKeeperExecutor.QueueAction.AdvanceCursor, batchId + 1));

        (,,, uint256 tokensToBurn,) = exitQueue.requestInfo(batchId, user);
        uint256 snapshot = vm.snapshotState();
        uint256 userTokensBeforeCancel = token.balanceOf(user);
        vm.prank(user);
        amm.cancelRedemption(batchId);
        assertEq(token.balanceOf(user), userTokensBeforeCancel + tokensToBurn);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        assertTrue(vm.revertToState(snapshot));

        // Arbitrary callers cannot submit it, but the configured Forwarder can.
        vm.prank(user);
        vm.expectRevert(IKeeperExecutorBase.KeeperExecutorOnlyForwarder.selector);
        executor.performUpkeep(staleProcessData);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(forwarder);
        executor.performUpkeep(staleProcessData);

        (bool processed,,,,) = exitQueue.requestInfo(batchId, user);
        assertTrue(processed);
        assertFalse(exitQueue.requestCanBeClosed(batchId, user));
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);
        assertEq(token.totalSupply(), supplyBefore - tokensToBurn);
        assertApproxEqAbs(amm.claimableBalances(user), EXIT_ETH, 1);
        assertEq(executor.nextBatchIdToProcess(), batchId + 1);
    }
}
