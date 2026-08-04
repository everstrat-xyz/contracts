// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, use-natspec, gas-custom-errors, gas-small-strings
pragma solidity ^0.8.30;

/// @notice Minimal price oracle mock implementing only the IOracle conversion functions
///         used by Converter adapters. Prices are USD per whole token with 18 decimals
///         (e.g. 1e18 = $1). Native ETH is keyed as address(0), matching the real Oracle.
contract MockSimpleOracle {
    uint256 public constant PRICE_SCALE = 1e18;

    bool public shouldRevert;
    mapping(address => uint256) public prices;

    function setPrice(address _token, uint256 _price) external {
        prices[_token] = _price;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function convertTokenToUSD(address _token, uint256 _amount, uint8 _inputDecimals) external view returns (uint256) {
        if (shouldRevert) revert("ORACLE_FAILED");
        return _amount * prices[_token] / (10 ** _inputDecimals);
    }

    function convertUsdToToken(address _token, uint256 _amount, uint8 _outputDecimals)
        external
        view
        returns (uint256)
    {
        if (shouldRevert) revert("ORACLE_FAILED");
        return _amount * (10 ** _outputDecimals) / prices[_token];
    }

    function convert(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint8 _inputDecimals,
        uint8 _outputDecimals
    ) external view returns (uint256) {
        if (shouldRevert) revert("ORACLE_FAILED");
        uint256 _normalizedAmountIn = _amountIn * PRICE_SCALE / (10 ** _inputDecimals);
        return (_normalizedAmountIn * prices[_tokenIn] / prices[_tokenOut]) * (10 ** _outputDecimals) / PRICE_SCALE;
    }
}
