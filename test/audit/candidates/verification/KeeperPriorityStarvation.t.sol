// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../../../mocks/MockStrategy.sol";

import {QueueKeeperExecutor} from "../../../../src/contracts/automation/QueueKeeperExecutor.sol";
import {StrategyKeeperExecutor} from "../../../../src/contracts/automation/StrategyKeeperExecutor.sol";
import {IStrategyKeeperExecutor} from "../../../../src/interfaces/automation/IStrategyKeeperExecutor.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";

contract KeeperPriorityStarvationTest is ProtocolTestBase {
    uint256 private constant ETH_PRICE = 4_000e8;

    function test_FailedRebalanceRemainsFirstPriorityWhileRedemptionNeedsLiquidity() external {
        address forwarder = makeAddr("forwarder");
        address user = makeAddr("user");
        ProtocolContracts memory protocol = _deployProtocol(address(this), 1e18);

        MockPriceFeed ethFeed = new MockPriceFeed(8, int256(ETH_PRICE));
        protocol.oracle.updateUsdFeedInfo(address(0), address(ethFeed), 1 hours);

        QueueKeeperExecutor queueExecutor = new QueueKeeperExecutor(address(protocol.registry));
        StrategyKeeperExecutor strategyExecutor = new StrategyKeeperExecutor(address(protocol.registry));
        protocol.registry.registerContract(Auth.QUEUE_KEEPER_EXECUTOR, address(queueExecutor));
        protocol.registry.registerContract(Auth.STRATEGY_KEEPER_EXECUTOR, address(strategyExecutor));
        protocol.registry.grantRole(Auth.KEEPER_ROLE, address(queueExecutor));
        protocol.registry.grantRole(Auth.KEEPER_ROLE, address(strategyExecutor));
        strategyExecutor.setForwarder(forwarder);

        vm.deal(user, 10 ether);
        vm.prank(user);
        protocol.amm.enter{value: 10 ether}(1);

        MockStrategy strategy =
            new MockStrategy("failed rebalance", address(protocol.controller), address(protocol.strategyManager));
        protocol.strategyManager.addStrategy(address(strategy), 100, 100);
        protocol.controller.depositToStrategy(address(strategy), 10 ether);
        strategy.setNavInETH(10 ether);
        strategy.setIsHealthy(false);
        strategy.setRevertRebalance(true);

        vm.startPrank(user);
        protocol.token.approve(address(protocol.amm), type(uint256).max);
        uint256 batchId = protocol.amm.exit(1 ether, protocol.token.balanceOf(user), 0);
        vm.stopPrank();
        assertEq(batchId, 1, "redemption should queue without AMM liquidity");
        protocol.controller.priceBatch();
        assertGt(strategyExecutor.pendingRedemptionNeedsETH(), 0);
        assertEq(address(protocol.controller).balance, 0);

        (bool upkeepNeeded, bytes memory performData) = strategyExecutor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(performData, abi.encode(IStrategyKeeperExecutor.StrategyAction.Rebalance));

        vm.prank(forwarder);
        strategyExecutor.performUpkeep(performData);

        assertEq(address(protocol.controller).balance, 0, "failed rebalance makes no liquidity progress");
        (upkeepNeeded, performData) = strategyExecutor.checkUpkeep("");
        assertTrue(upkeepNeeded);
        assertEq(
            performData,
            abi.encode(IStrategyKeeperExecutor.StrategyAction.Rebalance),
            "the same failed action remains ahead of the shortfall"
        );

        vm.prank(forwarder);
        strategyExecutor.performUpkeep(abi.encode(IStrategyKeeperExecutor.StrategyAction.WithdrawShortfall));
        assertGt(address(protocol.controller).balance, 0, "the lower-priority action was independently executable");
    }
}
