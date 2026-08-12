// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {AMM} from "../../../../src/contracts/AMM.sol";
import {ExitQueue} from "../../../../src/contracts/ExitQueue.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {QueueKeeperExecutor} from "../../../../src/contracts/automation/QueueKeeperExecutor.sol";
import {StrategyKeeperExecutor} from "../../../../src/contracts/automation/StrategyKeeperExecutor.sol";

import {Auth} from "../../../../src/libraries/Auth.sol";
import {IQueueKeeperExecutor} from "../../../../src/interfaces/automation/IQueueKeeperExecutor.sol";
import {IStrategyKeeperExecutor} from "../../../../src/interfaces/automation/IStrategyKeeperExecutor.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../../../mocks/MockStrategy.sol";

contract ZeroWeightKeeperVerificationTest is ProtocolTestBase {
    uint256 private constant ETH_PRICE = 4000e8;
    uint256 private constant STALENESS_INTERVAL = 3600;
    uint256 private constant PRICE_TOLERANCE = 1e18;

    Registry private registry;
    Controller private controller;
    EVE private token;
    AMM private amm;
    ExitQueue private exitQueue;
    Oracle private oracle;
    StrategyManager private strategyManager;
    QueueKeeperExecutor private queueExecutor;
    StrategyKeeperExecutor private strategyExecutor;

    address private user;
    address private queueForwarder;
    address private strategyForwarder;

    function setUp() public {
        user = makeAddr("user");
        queueForwarder = makeAddr("queueForwarder");
        strategyForwarder = makeAddr("strategyForwarder");

        ProtocolContracts memory contracts = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        controller = contracts.controller;
        token = contracts.token;
        amm = contracts.amm;
        exitQueue = contracts.exitQueue;
        oracle = contracts.oracle;
        strategyManager = contracts.strategyManager;

        MockPriceFeed ethFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethFeed), STALENESS_INTERVAL);

        queueExecutor = new QueueKeeperExecutor(address(registry));
        strategyExecutor = new StrategyKeeperExecutor(address(registry));

        bytes32[] memory keys = new bytes32[](2);
        address[] memory executors = new address[](2);
        keys[0] = Auth.QUEUE_KEEPER_EXECUTOR;
        keys[1] = Auth.STRATEGY_KEEPER_EXECUTOR;
        executors[0] = address(queueExecutor);
        executors[1] = address(strategyExecutor);
        registry.registerContracts(keys, executors);
        registry.grantRole(Auth.KEEPER_ROLE, address(queueExecutor));
        registry.grantRole(Auth.KEEPER_ROLE, address(strategyExecutor));
        queueExecutor.setForwarder(queueForwarder);
        strategyExecutor.setForwarder(strategyForwarder);
    }

    function _addStrategy(uint8 depositWeight, uint8 withdrawalWeight) internal returns (MockStrategy strategy) {
        strategy = new MockStrategy("Strategy", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy), depositWeight, withdrawalWeight);
    }

    function _enter(uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        amm.enter{value: amount}(1);
    }

    function _strategyAction() internal view returns (IStrategyKeeperExecutor.StrategyAction action) {
        (bool needed, bytes memory data) = strategyExecutor.checkUpkeep("");
        assertTrue(needed);
        action = abi.decode(data, (IStrategyKeeperExecutor.StrategyAction));
    }

    function _performStrategy(IStrategyKeeperExecutor.StrategyAction action) internal {
        vm.prank(strategyForwarder);
        strategyExecutor.performUpkeep(abi.encode(action));
    }

    function test_ZeroDepositWeightRepeatsNoProgressAndStarvesSync() public {
        MockStrategy strategy = _addStrategy(0, 100);
        _enter(1 ether);

        vm.warp(block.timestamp + strategyExecutor.syncInterval() + 1);
        uint256 lastSyncBefore = strategyExecutor.lastSyncAt();

        assertEq(
            uint256(_strategyAction()),
            uint256(IStrategyKeeperExecutor.StrategyAction.DepositExcess),
            "zero-weight strategy is incorrectly treated as deposit capacity"
        );

        _performStrategy(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        assertEq(address(controller).balance, 1 ether, "batch allocator refunds the full amount");
        assertEq(address(strategyManager).balance, 0);
        assertEq(address(strategy).balance, 0);
        assertEq(strategy.totalDeposited(), 0);
        assertEq(strategyExecutor.lastSyncAt(), lastSyncBefore, "lower-priority sync was starved");

        assertEq(
            uint256(_strategyAction()),
            uint256(IStrategyKeeperExecutor.StrategyAction.DepositExcess),
            "identical no-progress action repeats"
        );
        _performStrategy(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        assertEq(address(controller).balance, 1 ether);
        assertEq(strategyExecutor.lastSyncAt(), lastSyncBefore);

        strategyManager.setDepositWeight(address(strategy), 100);
        _performStrategy(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        assertEq(address(controller).balance, 0);
        assertEq(address(strategy).balance, 1 ether, "admin weight repair restores progress");
    }

    function test_ZeroWithdrawalWeightRepeatsAndBlocksQueuedExitUntilWeightFixed() public {
        MockStrategy strategy = _addStrategy(100, 0);
        _enter(10 ether);

        _performStrategy(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        strategy.setNavInETH(address(strategy).balance);
        assertEq(address(strategy).balance, 10 ether);

        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        uint256 batchId = amm.exit(5 ether, token.balanceOf(user), PRICE_TOLERANCE);
        vm.stopPrank();
        controller.priceBatch();

        vm.warp(block.timestamp + strategyExecutor.syncInterval() + 1);
        uint256 lastSyncBefore = strategyExecutor.lastSyncAt();

        assertEq(
            uint256(_strategyAction()),
            uint256(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall),
            "maxWithdrawal ignores zero allocation weight"
        );
        _performStrategy(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
        assertEq(address(controller).balance, 0, "weighted allocator withdraws nothing");
        assertEq(address(strategy).balance, 10 ether);
        assertEq(strategy.totalWithdrawn(), 0);
        assertEq(queueExecutor.affordableRequests(batchId), 0, "queued user remains unserviceable");
        assertEq(strategyExecutor.lastSyncAt(), lastSyncBefore, "lower-priority sync was starved");

        assertEq(
            uint256(_strategyAction()),
            uint256(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall),
            "identical no-progress action repeats"
        );
        _performStrategy(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
        assertEq(address(controller).balance, 0);
        assertEq(exitQueue.unprocessedUsersCount(batchId), 1);

        strategyManager.setWithdrawalWeight(address(strategy), 100);
        _performStrategy(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
        assertEq(address(controller).balance, 5 ether, "admin weight repair restores liquidity");
        assertEq(queueExecutor.affordableRequests(batchId), 1);

        vm.prank(queueForwarder);
        queueExecutor.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));
        assertEq(exitQueue.unprocessedUsersCount(batchId), 0);

        uint256 balanceBefore = user.balance;
        vm.prank(user);
        amm.claim();
        assertApproxEqAbs(user.balance - balanceBefore, 5 ether, 1);
    }
}
