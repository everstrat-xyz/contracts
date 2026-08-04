// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IConverterAdapter} from "../IConverterAdapter.sol";

/// @notice Interface for the UniswapV3ConverterAdapter, a stateless DEX adapter that
///         wraps Uniswap V3 swaps with TWAP + Chainlink security, deployed behind
///         the shared Converter module.
interface IUniswapV3ConverterAdapter is IConverterAdapter {
    // ============ Errors ============

    /// @notice Thrown when a zero address is provided to the constructor
    error UniswapV3ConverterAdapterZeroAddress();

    /// @notice Thrown when a route is malformed for the Uniswap V3 path scheme
    error UniswapV3ConverterAdapterInvalidRoute();

    /// @notice Thrown when the route exceeds MAX_PATH_LENGTH hops
    error UniswapV3ConverterAdapterMultiHopNotSupported();

    /// @notice Thrown when the TWAP interval is below MIN_TWAP_INTERVAL
    error UniswapV3ConverterAdapterInvalidTwapInterval();

    /// @notice Thrown when no pool exists for the route's (tokenIn, tokenOut, fee) triple
    error UniswapV3ConverterAdapterPoolNotFound();

    /// @notice Thrown when the TWAP-implied amount deviates too far from the Chainlink-implied amount
    error UniswapV3ConverterAdapterQuoteDeviation(uint256 twapAmount, uint256 oracleAmount);
}
