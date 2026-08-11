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
import {StrategyKeeperExecutor} from "../../src/contracts/automation/StrategyKeeperExecutor.sol";
import {CREQueueExecutor} from "../../src/contracts/automation/CREQueueExecutor.sol";
import {CREStrategyExecutor} from "../../src/contracts/automation/CREStrategyExecutor.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IQueueKeeperExecutor} from "../../src/interfaces/automation/IQueueKeeperExecutor.sol";
import {IStrategyKeeperExecutor} from "../../src/interfaces/automation/IStrategyKeeperExecutor.sol";
import {ICREQueueExecutor} from "../../src/interfaces/automation/ICREQueueExecutor.sol";
import {ICREStrategyExecutor} from "../../src/interfaces/automation/ICREStrategyExecutor.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {CRETestUtils} from "../helpers/CRETestUtils.sol";

/**
 * @title CREParityTest
 * @notice Asserts CRE executors produce the same protocol state transitions as CLA
 *         `performUpkeep` for each keeper action.
 */
contract CREParityTest is ProtocolTestBase, CRETestUtils {
    uint256 public constant ETH_PRICE = 4000e8;
    uint256 public constant BOOTSTRAP_DEPOSIT = 20 ether;
    uint256 public constant EXIT_ETH = 1 ether;
    uint256 public constant PRICE_TOLERANCE = 1e17;

    Registry public registry;
    ExitQueue public exitQueue;
    AMM public amm;
    Controller public controller;
    Oracle public oracle;
    EVE public token;
    StrategyManager public strategyManager;

    address public claForwarder;
    address public creForwarder;
    address public workflowOwner;
    address public user;
    bytes32 public workflowId;
    bytes10 public workflowName;
    uint64 internal _seq;

    function setUp() public {
        claForwarder = makeAddr("claForwarder");
        creForwarder = makeAddr("creForwarder");
        workflowOwner = makeAddr("workflowOwner");
        user = makeAddr("user");
        workflowId = keccak256("parity");
        workflowName = bytes10("parity----");

        ProtocolContracts memory contracts = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        token = contracts.token;
        exitQueue = contracts.exitQueue;
        controller = contracts.controller;
        oracle = contracts.oracle;
        amm = contracts.amm;
        strategyManager = contracts.strategyManager;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), 3600);

        vm.deal(user, BOOTSTRAP_DEPOSIT);
        vm.prank(user);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(1);
    }

    function _queueExit(uint256 amount) internal returns (uint256 batchId) {
        vm.startPrank(user);
        token.approve(address(amm), type(uint256).max);
        batchId = amm.exit(amount, token.balanceOf(user), PRICE_TOLERANCE);
        vm.stopPrank();
    }

    function _bindCre(CREQueueExecutor cre) internal {
        cre.setExpectedWorkflowOwner(workflowOwner);
        cre.setExpectedWorkflowName(workflowName);
        cre.setExpectedWorkflowId(workflowId);
    }

    function _bindCre(CREStrategyExecutor cre) internal {
        cre.setExpectedWorkflowOwner(workflowOwner);
        cre.setExpectedWorkflowName(workflowName);
        cre.setExpectedWorkflowId(workflowId);
    }

    function _creOnReport(CREQueueExecutor cre, uint8 action, bytes memory params) internal {
        _seq += 1;
        bytes memory report = _encodeReport(TEST_CHAIN_SELECTOR, _seq, uint64(block.timestamp), action, params);
        vm.prank(creForwarder);
        cre.onReport(_encodeMetadata(workflowId, workflowName, workflowOwner), report);
    }

    function _creOnReport(CREStrategyExecutor cre, uint8 action) internal {
        _seq += 1;
        bytes memory report = _encodeReport(TEST_CHAIN_SELECTOR, _seq, uint64(block.timestamp), action, "");
        vm.prank(creForwarder);
        cre.onReport(_encodeMetadata(workflowId, workflowName, workflowOwner), report);
    }

    function test_Parity_PriceBatch() public {
        // Snapshot A: CLA
        uint256 snap = vm.snapshotState();
        QueueKeeperExecutor cla = new QueueKeeperExecutor(address(registry));
        registry.grantRole(Auth.KEEPER_ROLE, address(cla));
        cla.setForwarder(claForwarder);
        uint256 batchId = _queueExit(EXIT_ETH);
        vm.warp(block.timestamp + cla.minBatchAge());
        vm.prank(claForwarder);
        cla.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));
        (bool claProcessed, uint256 claPrice,,,) = exitQueue.batchInfo(batchId);
        uint256 claCurrent = exitQueue.currentBatchId();

        // Snapshot B: CRE
        vm.revertToState(snap);
        CREQueueExecutor cre =
            new CREQueueExecutor(address(registry), creForwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        registry.grantRole(Auth.KEEPER_ROLE, address(cre));
        _bindCre(cre);
        batchId = _queueExit(EXIT_ETH);
        vm.warp(block.timestamp + cre.minBatchAge());
        _creOnReport(cre, uint8(ICREQueueExecutor.QueueAction.PriceBatch), abi.encode(batchId));
        (bool creProcessed, uint256 crePrice,,,) = exitQueue.batchInfo(batchId);

        assertEq(claProcessed, creProcessed);
        assertEq(claPrice, crePrice);
        assertEq(claCurrent, exitQueue.currentBatchId());
    }

    function test_Parity_ProcessRequests() public {
        uint256 snap = vm.snapshotState();

        QueueKeeperExecutor cla = new QueueKeeperExecutor(address(registry));
        registry.grantRole(Auth.KEEPER_ROLE, address(cla));
        cla.setForwarder(claForwarder);
        uint256 batchId = _queueExit(EXIT_ETH);
        vm.warp(block.timestamp + cla.minBatchAge());
        vm.prank(claForwarder);
        cla.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.PriceBatch, batchId));
        uint256 userBalBefore = user.balance;
        vm.prank(claForwarder);
        cla.performUpkeep(abi.encode(IQueueKeeperExecutor.QueueAction.ProcessRequests, batchId));
        uint256 claDelta = user.balance - userBalBefore;
        uint256 claUnprocessed = exitQueue.unprocessedUsersCount(batchId);

        vm.revertToState(snap);
        CREQueueExecutor cre =
            new CREQueueExecutor(address(registry), creForwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        registry.grantRole(Auth.KEEPER_ROLE, address(cre));
        _bindCre(cre);
        batchId = _queueExit(EXIT_ETH);
        vm.warp(block.timestamp + cre.minBatchAge());
        _creOnReport(cre, uint8(ICREQueueExecutor.QueueAction.PriceBatch), abi.encode(batchId));
        userBalBefore = user.balance;
        _creOnReport(
            cre, uint8(ICREQueueExecutor.QueueAction.ProcessRequests), abi.encode(batchId, uint256(0), uint256(1))
        );
        uint256 creDelta = user.balance - userBalBefore;

        assertEq(claDelta, creDelta);
        assertEq(claUnprocessed, exitQueue.unprocessedUsersCount(batchId));
    }

    function test_Parity_DepositExcess() public {
        MockStrategy strategy = new MockStrategy("Strategy", address(controller), address(strategyManager));
        strategy.setIsHealthy(true);
        strategy.setMaxDeposit(100 ether);
        strategyManager.addStrategy(address(strategy), 100, 100);

        uint256 snap = vm.snapshotState();

        QueueKeeperExecutor queueCla = new QueueKeeperExecutor(address(registry));
        StrategyKeeperExecutor cla = new StrategyKeeperExecutor(address(registry));
        registry.registerContract(Auth.QUEUE_KEEPER_EXECUTOR, address(queueCla));
        registry.registerContract(Auth.STRATEGY_KEEPER_EXECUTOR, address(cla));
        registry.grantRole(Auth.KEEPER_ROLE, address(cla));
        cla.setForwarder(claForwarder);
        vm.deal(address(controller), 5 ether);
        cla.setMinDepositETH(0.1 ether);
        vm.prank(claForwarder);
        cla.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.DepositExcess));
        uint256 claStrategyBal = address(strategy).balance;

        vm.revertToState(snap);

        CREQueueExecutor queueCre =
            new CREQueueExecutor(address(registry), creForwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        CREStrategyExecutor cre =
            new CREStrategyExecutor(address(registry), creForwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        registry.registerContract(Auth.QUEUE_KEEPER_EXECUTOR, address(queueCre));
        registry.registerContract(Auth.STRATEGY_KEEPER_EXECUTOR, address(cre));
        registry.grantRole(Auth.KEEPER_ROLE, address(cre));
        _bindCre(cre);
        vm.deal(address(controller), 5 ether);
        cre.setMinDepositETH(0.1 ether);
        _creOnReport(cre, uint8(ICREStrategyExecutor.StrategyAction.DepositExcess));

        assertEq(claStrategyBal, address(strategy).balance);
    }
}
