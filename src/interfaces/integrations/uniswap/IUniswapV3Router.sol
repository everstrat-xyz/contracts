// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec

/**
 * @title IUniswapV3Router
 * @notice Uniswap V3 SwapRouter interface supporting both exact-input and exact-output swaps.
 */
interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible
     * @param _params The parameters for the swap
     * @return amountOut The amount of output tokens received
     */
    function exactInput(ExactInputParams calldata _params) external payable returns (uint256 amountOut);

    /**
     * @notice Swaps as few input tokens as possible for an exact amount of output tokens
     * @param _params The parameters for the swap
     * @return amountIn The amount of input tokens actually spent
     */
    function exactOutput(ExactOutputParams calldata _params) external payable returns (uint256 amountIn);
}
