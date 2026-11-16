// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, use-natspec, func-name-mixedcase
pragma solidity ^0.8.30;

import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";
import {UniCLStratTestBase} from "../helpers/UniCLStratTestBase.sol";

contract UniCLStratFuzzTest is UniCLStratTestBase {
    uint256 public constant MIN_DEPOSIT = 1 wei;
    uint256 public constant MIN_WITHDRAW_DEPOSIT = 1 ether;
    uint256 public constant MAX_PAYABLE_DEPOSIT = MAX_TOTAL_NAV / 2;
    uint256 public constant NAV_TOLERANCE = 10 wei;

    function testFuzz_DepositTracksAccounting(uint256 _amount) public {
        _amount = bound(_amount, MIN_DEPOSIT, MAX_PAYABLE_DEPOSIT);

        _deposit(_amount);

        assertEq(strategy.totalDeposited(), _amount);
        assertTrue(strategy.initTicks());
        assertTrue(strategy.isHealthy());
        assertLe(strategy.navInETH(), _amount);
        assertLe(_grossNavInETH(), _amount);
        assertApproxEqAbs(_grossNavInETH(), _amount, NAV_TOLERANCE);
    }

    function testFuzz_WithdrawTracksAccounting(uint256 _depositAmount, uint256 _withdrawAmount) public {
        _depositAmount = bound(_depositAmount, MIN_WITHDRAW_DEPOSIT, MAX_PAYABLE_DEPOSIT);
        _withdrawAmount = bound(_withdrawAmount, MIN_DEPOSIT, _depositAmount);

        _deposit(_depositAmount);
        uint256 navBeforeWithdrawal = strategy.navInETH();
        uint256 grossNavBeforeWithdrawal = _grossNavInETH();
        if (_withdrawAmount > navBeforeWithdrawal) _withdrawAmount = navBeforeWithdrawal;

        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, _withdrawAmount);

        // A full-NAV request drains the strategy and may pay out more than requested (the
        // unspent exit-cost mark-down); any other request pays out exactly what was asked.
        if (_withdrawAmount == navBeforeWithdrawal) {
            assertGe(withdrawn, _withdrawAmount);
        } else {
            assertEq(withdrawn, _withdrawAmount);
        }
        assertEq(receiver.balance, withdrawn);
        assertEq(strategy.totalWithdrawn(), withdrawn);
        assertApproxEqAbs(_grossNavInETH(), grossNavBeforeWithdrawal - withdrawn, NAV_TOLERANCE);
    }

    function testFuzz_MaxDepositReflectsCapacity(uint256 _amount) public {
        _amount = bound(_amount, MIN_DEPOSIT, MAX_PAYABLE_DEPOSIT);

        _deposit(_amount);

        uint256 expectedMaxDeposit = MAX_TOTAL_NAV - strategy.navInETH();
        assertEq(strategy.maxDeposit(), expectedMaxDeposit);
    }
}
