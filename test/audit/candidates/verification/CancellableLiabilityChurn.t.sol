// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {AMM} from "../../../../src/contracts/AMM.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../../../src/contracts/ExitQueue.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {StrategyKeeperExecutor} from "../../../../src/contracts/automation/StrategyKeeperExecutor.sol";
import {QueueKeeperExecutor} from "../../../../src/contracts/automation/QueueKeeperExecutor.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";
import {IConverter} from "../../../../src/interfaces/IConverter.sol";
import {IStrategyKeeperExecutor} from "../../../../src/interfaces/automation/IStrategyKeeperExecutor.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {UniCLStratTestBase} from "../../../helpers/UniCLStratTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../../../mocks/MockStrategy.sol";

contract CancellableLiabilityChurnTest is ProtocolTestBase {
    uint256 internal constant BOOTSTRAP_DEPOSIT = 10 ether;
    uint256 internal constant EXIT_ETH = 1 ether;
    uint256 internal constant COOLDOWN = 6 hours;

    Registry internal registry;
    Controller internal controller;
    EVE internal eve;
    AMM internal amm;
    Oracle internal oracle;
    ExitQueue internal exitQueue;
    StrategyManager internal strategyManager;
    StrategyKeeperExecutor internal strategyKeeper;
    QueueKeeperExecutor internal queueKeeper;
    MockStrategy internal strategy;

    address internal forwarder;
    address internal user;

    function setUp() public {
        forwarder = makeAddr("forwarder");
        user = makeAddr("user");

        ProtocolContracts memory deployed = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        registry = deployed.registry;
        controller = deployed.controller;
        eve = deployed.token;
        amm = deployed.amm;
        oracle = deployed.oracle;
        exitQueue = deployed.exitQueue;
        strategyManager = deployed.strategyManager;

        oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, 4_000e8)), 1 hours);

        strategy = new MockStrategy("strategy", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy), 100, 100);

        strategyKeeper = new StrategyKeeperExecutor(address(registry));
        queueKeeper = new QueueKeeperExecutor(address(registry));
        registry.registerContract(Auth.STRATEGY_KEEPER_EXECUTOR, address(strategyKeeper));
        registry.registerContract(Auth.QUEUE_KEEPER_EXECUTOR, address(queueKeeper));
        registry.grantRole(Auth.KEEPER_ROLE, address(strategyKeeper));
        registry.grantRole(Auth.KEEPER_ROLE, address(queueKeeper));
        strategyKeeper.setForwarder(forwarder);
        queueKeeper.setForwarder(forwarder);

        vm.deal(user, BOOTSTRAP_DEPOSIT);
        vm.prank(user);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(1);

        _perform(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        strategy.setNavInETH(address(strategy).balance);
    }

    function test_CancellableCurrentBatchForcesRepeatableWithdrawalAndRedeposit() public {
        assertEq(strategyManager.strategyDepositCooldown(), 0, "cooldown defaults off");
        strategyManager.setStrategyDepositCooldown(COOLDOWN);

        uint256 eveBefore = eve.balanceOf(user);
        uint256 firstBatch = _queueExit();

        assertTrue(exitQueue.requestCanBeClosed(firstBatch, user), "unpriced request is immediately cancellable");
        assertEq(strategyKeeper.pendingRedemptionNeedsETH(), EXIT_ETH, "cancellable request counted as liability");
        _assertAction(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);

        _perform(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
        assertEq(address(controller).balance, EXIT_ETH, "strategy capital withdrawn for uncommitted request");
        assertEq(strategy.totalWithdrawn(), EXIT_ETH);
        assertTrue(strategyManager.isStrategyInDepositCooldown(address(strategy)));

        vm.prank(user);
        amm.cancelRedemption(firstBatch);
        assertEq(eve.balanceOf(user), eveBefore, "cancel returns every escrowed EVE");
        assertEq(strategyKeeper.pendingRedemptionNeedsETH(), 0);

        (bool needed,) = strategyKeeper.checkUpkeep("");
        assertFalse(needed, "cooldown leaves withdrawn ETH idle");

        vm.warp(block.timestamp + COOLDOWN);
        _assertAction(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        _perform(IStrategyKeeperExecutor.StrategyAction.DepositExcess);
        assertEq(address(controller).balance, 0);
        assertEq(address(strategy).balance, BOOTSTRAP_DEPOSIT);

        uint256 secondBatch = _queueExit();
        assertEq(secondBatch, firstBatch, "cancel permits requeue into same unpriced batch");
        _assertAction(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
        _perform(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall);
        vm.prank(user);
        amm.cancelRedemption(secondBatch);

        assertEq(eve.balanceOf(user), eveBefore, "attacker capital is restored after second cycle");
        assertEq(strategy.totalWithdrawn(), 2 * EXIT_ETH, "same EVE position induced two withdrawals");
    }

    function _queueExit() internal returns (uint256 batchId) {
        vm.startPrank(user);
        eve.approve(address(amm), type(uint256).max);
        batchId = amm.exit(EXIT_ETH, eve.balanceOf(user), 0);
        vm.stopPrank();
    }

    function _perform(IStrategyKeeperExecutor.StrategyAction action) internal {
        vm.prank(forwarder);
        strategyKeeper.performUpkeep(abi.encode(action));
    }

    function _assertAction(IStrategyKeeperExecutor.StrategyAction expected) internal view {
        (bool needed, bytes memory data) = strategyKeeper.checkUpkeep("");
        assertTrue(needed);
        assertEq(data, abi.encode(expected));
    }
}

contract CancellableLiabilityUniCLCostPathTest is UniCLStratTestBase {
    function test_LpBackedWithdrawalForcesInventorySwap() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 pairedAtConverterBefore = pairedToken.balanceOf(address(converter));

        vm.expectCall(address(converter), abi.encodeWithSelector(IConverter.executeSwapExactAmountIn.selector));
        vm.prank(strategyManager);
        strategy.withdraw(receiver, WITHDRAW_AMOUNT);

        assertGt(
            pairedToken.balanceOf(address(converter)), pairedAtConverterBefore, "withdrawal rebalanced through a swap"
        );
    }
}
