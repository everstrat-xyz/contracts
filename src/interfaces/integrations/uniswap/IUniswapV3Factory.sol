// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec

/**
 * @title IUniswapV3Factory
 * @notice Uniswap V3 Factory interface covering the functions used by the protocol.
 */
interface IUniswapV3Factory {
    /**
     * @notice Returns the pool address for a given pair of tokens and a fee tier
     * @param _tokenA One of the two tokens of the pool (order-insensitive)
     * @param _tokenB The other token of the pool
     * @param _fee The fee tier of the pool
     * @return pool The pool address, or address(0) if it does not exist
     */
    function getPool(address _tokenA, address _tokenB, uint24 _fee) external view returns (address pool);
}
