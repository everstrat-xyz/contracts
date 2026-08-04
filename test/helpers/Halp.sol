// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "../mocks/IERC20.sol";

/**
 * @title Halp
 * @notice Helper library for mocking external calls in tests
 * @dev Provides convenient functions for setting up mocks and expectations
 */
library Halp {
    Vm constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /**
     * @notice Mock a call and expect it to be made
     * @param _target The target address to mock
     * @param _callData The calldata to expect
     * @param _returnData The data to return
     */
    function mockExpect(address _target, bytes memory _callData, bytes memory _returnData) internal {
        _vm.etch(_target, new bytes(0x1));
        _vm.mockCall(_target, _callData, _returnData);
        _vm.expectCall(_target, _callData);
    }

    /**
     * @notice Mock a call without expecting it to be made
     * @param _target The target address to mock
     * @param _callData The calldata to mock
     * @param _returnData The data to return
     */
    function mockOnly(address _target, bytes memory _callData, bytes memory _returnData) internal {
        _vm.etch(_target, new bytes(0x1));
        _vm.mockCall(_target, _callData, _returnData);
    }

    /**
     * @notice Expect a call without mocking the return value
     * @param _target The target address
     * @param _callData The calldata to expect
     */
    function expectCall(address _target, bytes memory _callData) internal {
        _vm.expectCall(_target, _callData);
    }

    /**
     * @notice Mock an ERC20 balanceOf call
     * @param _token The token address
     * @param _account The account to mock balance for
     * @param _balance The balance to return
     */
    function mockBalanceOf(address _token, address _account, uint256 _balance) internal {
        mockExpect(_token, abi.encodeCall(IERC20.balanceOf, (_account)), abi.encode(_balance));
    }

    /**
     * @notice Mock an ERC20 allowance call
     * @param _token The token address
     * @param _owner The owner address
     * @param _spender The spender address
     * @param _allowance The allowance to return
     */
    function mockAllowance(address _token, address _owner, address _spender, uint256 _allowance) internal {
        mockExpect(_token, abi.encodeCall(IERC20.allowance, (_owner, _spender)), abi.encode(_allowance));
    }

    /**
     * @notice Mock a price feed call
     * @param _priceFeed The price feed address
     * @param _roundId The round ID
     * @param _price The price to return
     * @param _timestamp The timestamp to return
     * @param _startedAt The started at timestamp
     * @param _answeredInRound The answered in round ID
     */
    function mockPriceFeed(
        address _priceFeed,
        uint80 _roundId,
        int256 _price,
        uint256 _timestamp,
        uint256 _startedAt,
        uint80 _answeredInRound
    ) internal {
        mockExpect(
            _priceFeed,
            abi.encodeCall(IAggregatorV3Interface.latestRoundData, ()),
            abi.encode(_roundId, _price, _timestamp, _startedAt, _answeredInRound)
        );
    }
}

interface IAggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
