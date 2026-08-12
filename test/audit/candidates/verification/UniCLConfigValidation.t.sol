// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {stdError} from "forge-std/StdError.sol";

import {UniCLStrat} from "../../../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../../../src/interfaces/strategies/IUniCLStrat.sol";
import {UniCLStratTestBase} from "../../../helpers/UniCLStratTestBase.sol";

contract UniCLConfigValidationVerificationTest is UniCLStratTestBase {
    function test_ConstructorAcceptsWidthThatPanicsOnFirstDeposit() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.positionWidth = type(int24).max;

        UniCLStrat unsafeStrategy = new UniCLStrat(config);
        assertEq(unsafeStrategy.positionWidth(), type(int24).max);

        vm.deal(strategyManager, DEPOSIT_AMOUNT);
        vm.startPrank(strategyManager);
        vm.expectRevert(stdError.arithmeticError);
        unsafeStrategy.deposit{value: DEPOSIT_AMOUNT}();
        vm.stopPrank();
    }

    function test_AdminCanSetDeviationThatPanicsHealthCheck() public {
        pool.setCurrentTick(1);

        vm.prank(admin);
        strategy.setMaxTickDeviation(type(int56).max);
        assertEq(strategy.maxTickDeviation(), type(int56).max);

        vm.expectRevert(stdError.arithmeticError);
        strategy.isHealthy();
    }
}
