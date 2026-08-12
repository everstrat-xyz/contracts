// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";
import {MockStrategy} from "../../../mocks/MockStrategy.sol";

import {Math} from "../../../../src/libraries/Math.sol";

contract PendingFeeSharePricingTest is ProtocolTestBase {
    uint256 private constant ETH_PRICE = 1_000e8;
    uint256 private constant PERFORMANCE_FEE_BPS = 2_000;

    function _deployWithVisibleFeeBase()
        private
        returns (ProtocolContracts memory protocol, MockStrategy strategy, address incumbent, address redeemer)
    {
        incumbent = makeAddr("incumbent");
        redeemer = makeAddr("redeemer");
        protocol = _deployProtocol(address(this), 1e18);
        protocol.oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, int256(ETH_PRICE))), 1 hours);
        protocol.strategyManager.setDaoTreasury(makeAddr("treasury"));
        protocol.strategyManager.setPerformanceFeeBps(PERFORMANCE_FEE_BPS);

        strategy = new MockStrategy("fee strategy", address(protocol.controller), address(protocol.strategyManager));
        protocol.strategyManager.addStrategy(address(strategy), 100, 100);

        vm.deal(incumbent, 9 ether);
        vm.prank(incumbent);
        protocol.amm.enter{value: 9 ether}(1);
        vm.deal(redeemer, 1 ether);
        vm.prank(redeemer);
        protocol.amm.enter{value: 1 ether}(1);

        protocol.controller.depositToStrategy(address(strategy), 5 ether);
        strategy.setNavInETH(5 ether);

        // Model 1 ETH of already-earned, visible LP fees. It belongs to gross NAV,
        // while 20% is already owed to the treasury but not yet represented in supply.
        vm.deal(address(strategy), 6 ether);
        strategy.setNavInETH(6 ether);
        strategy.setUnchargedLpFeeBaseInETH(1 ether);
        assertEq(protocol.strategyManager.totalNAVInETH(), 11 ether);
        assertEq(protocol.strategyManager.pendingPerformanceFeeInETH(address(strategy)), 0.2 ether);
    }

    function test_ImmediateExitUsesGrossNavAndShiftsPendingFeeToRemainingHolders() external {
        (ProtocolContracts memory protocol,, address incumbent, address redeemer) = _deployWithVisibleFeeBase();
        protocol.controller.provideExitLiquidity(2 ether);

        uint256 redeemerShares = protocol.token.balanceOf(redeemer);
        uint256 grossPayout = redeemerShares * protocol.strategyManager.totalNAVInETH() / protocol.token.totalSupply();
        uint256 netPayout = redeemerShares
            * (
                protocol.strategyManager.totalNAVInETH()
                    - protocol.strategyManager.pendingPerformanceFeeInETH(protocol.strategyManager.strategies()[0])
            ) / protocol.token.totalSupply();

        vm.startPrank(redeemer);
        protocol.token.approve(address(protocol.amm), type(uint256).max);
        protocol.amm.exit(grossPayout, redeemerShares, 0);
        vm.stopPrank();

        assertEq(redeemer.balance, grossPayout);
        assertEq(grossPayout - netPayout, 0.02 ether, "exiter avoids its share of the accrued fee");

        uint256 incumbentShares = protocol.token.balanceOf(incumbent);
        protocol.controller.harvestPerformanceFeeFromStrategies();
        uint256 incumbentValue =
            incumbentShares * protocol.strategyManager.totalNAVInETH() / protocol.token.totalSupply();
        assertLt(incumbentValue, 9.9 ether, "remaining cohort bears the fee after the exit");
    }

    function test_PricedBatchKeepsGrossPriceAfterWithdrawalCrystallizesFee() external {
        (ProtocolContracts memory protocol, MockStrategy strategy,, address redeemer) = _deployWithVisibleFeeBase();

        uint256 redeemerShares = protocol.token.balanceOf(redeemer);
        vm.startPrank(redeemer);
        protocol.token.approve(address(protocol.amm), type(uint256).max);
        uint256 batchId = protocol.amm.exit(1 ether, redeemerShares, 0);
        vm.stopPrank();
        assertEq(batchId, 1);

        protocol.controller.priceBatch();
        (, uint256 fixedPrice,,,) = protocol.exitQueue.batchInfo(batchId);
        (,,, uint256 tokensToBurn,) = protocol.exitQueue.requestInfo(batchId, redeemer);
        uint256 fixedPayout = Math.convertAssets(tokensToBurn, fixedPrice);

        // The production withdrawal path crystallizes and mints the pending fee
        // before sourcing ETH, but the already-priced batch remains unchanged.
        protocol.controller.withdrawFromStrategy(address(strategy), fixedPayout);
        strategy.setNavInETH(address(strategy).balance);
        uint256 postFeePrice = protocol.amm.eveBasePriceInETH();
        assertGt(fixedPrice, postFeePrice);

        protocol.controller.processRequest(batchId, redeemer);
        assertEq(protocol.amm.claimableBalances(redeemer), fixedPayout);
        assertGt(fixedPayout, Math.convertAssets(tokensToBurn, postFeePrice));
    }
}
