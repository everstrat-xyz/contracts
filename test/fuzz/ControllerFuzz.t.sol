// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IController} from "../../src/interfaces/IController.sol";

import {Controller} from "../../src/contracts/Controller.sol";
import {AMM} from "../../src/contracts/AMM.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title ControllerFuzzTest
 * @notice Fuzz tests for the Controller's numeric-input keeper functions
 * @dev Focuses on provideExitLiquidity over the full uint256 input range
 */
contract ControllerFuzzTest is ProtocolTestBase {
    Controller public controller;
    AMM public amm;

    address public owner;

    function setUp() public {
        owner = address(this);

        ProtocolContracts memory contracts = _deployProtocol(owner, 5e17);
        controller = contracts.controller;
        amm = contracts.amm;
    }

    function testFuzz_ProvideExitLiquidity_ValidRange(uint256 _amount, uint256 _balance) public {
        _balance = bound(_balance, 1, type(uint128).max);
        _amount = bound(_amount, 1, _balance);

        vm.deal(address(controller), _balance);

        uint256 ammBalanceBefore = address(amm).balance;

        controller.provideExitLiquidity(_amount);

        assertEq(address(amm).balance, ammBalanceBefore + _amount);
        assertEq(address(controller).balance, _balance - _amount);
    }

    function testFuzz_ProvideExitLiquidity_InsufficientBalance(uint256 _amount, uint256 _balance) public {
        _amount = bound(_amount, 2, type(uint128).max);
        _balance = bound(_balance, 0, _amount - 1);

        vm.deal(address(controller), _balance);

        vm.expectRevert(IController.ControllerInsufficientBalance.selector);
        controller.provideExitLiquidity(_amount);
    }
}
