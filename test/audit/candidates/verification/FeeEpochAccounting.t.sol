// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {UniCLStratTestBase} from "../../../helpers/UniCLStratTestBase.sol";
import {IUniCLStrat} from "../../../../src/interfaces/strategies/IUniCLStrat.sol";

/// @dev Independent regressions for fee-rate epochs and the settle-before-withdraw ordering.
contract FeeEpochAccountingVerificationTest is UniCLStratTestBase {
    uint256 private constant OLD_FEE_BPS = 500;
    uint256 private constant NEW_FEE_BPS = 2_000;
    uint256 private constant FEE0 = 0.4 ether;
    uint256 private constant FEE1 = 0.2 ether;

    function test_A_CurrentRateRepricesSameHistoricalUnchargedFeeBase() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory main = _mainPosition();
        pool.accrueFees(address(strategy), main.tickLower, main.tickUpper, uint128(FEE0), uint128(FEE1));

        vm.prank(strategyManager);
        strategy.sync();

        uint256 oldRateFee = strategy.pendingPerformanceFeeInETH(OLD_FEE_BPS);
        uint256 newRateFee = strategy.pendingPerformanceFeeInETH(NEW_FEE_BPS);
        assertEq(oldRateFee, (FEE0 + FEE1) * OLD_FEE_BPS / 10_000);
        assertEq(newRateFee, (FEE0 + FEE1) * NEW_FEE_BPS / 10_000);
        assertEq(newRateFee, oldRateFee * NEW_FEE_BPS / OLD_FEE_BPS);

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(NEW_FEE_BPS), newRateFee);
        assertEq(strategy.pendingPerformanceFeeInETH(NEW_FEE_BPS), 0);
    }

    function test_B_FirstFullWithdrawDiscoversFeesButLeavesTheirBacking() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory main = _mainPosition();
        pool.accrueFees(address(strategy), main.tickLower, main.tickUpper, uint128(FEE0), uint128(FEE1));

        // This is StrategyManager's pre-withdraw settlement: it intentionally does not poke.
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);

        uint256 visibleNavBefore = strategy.maxWithdrawal();
        vm.prank(strategyManager);
        assertEq(strategy.withdraw(receiver, visibleNavBefore), visibleNavBefore);

        // Withdrawal poked/accrued the hidden fees. Because its requested amount was capped
        // by the pre-poke NAV, their value remains locally backed rather than being depleted.
        uint256 pending = strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS);
        uint256 residualNav = strategy.navInETH();
        assertEq(pending, (FEE0 + FEE1) * PERFORMANCE_FEE_BPS / 10_000);
        assertApproxEqAbs(residualNav, FEE0 + FEE1, 100);
        assertGe(residualNav, pending);

        // A normal next pre-withdraw settlement charges before the residual is drained.
        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), pending);
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }
}
