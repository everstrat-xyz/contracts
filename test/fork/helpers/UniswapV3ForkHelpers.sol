// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, one-contract-per-file
pragma solidity ^0.8.30;

/**
 * @title ICanonicalSwapRouter
 * @notice Subset of the mainnet Uniswap V3 SwapRouter used by fork-test pool manipulation.
 */
interface ICanonicalSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata _params) external payable returns (uint256 amountOut);
}
