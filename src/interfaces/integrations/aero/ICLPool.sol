// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec, ordering

/**
 * @title ICLPool
 * @notice Minimal interface for Aero (Slipstream) concentrated-liquidity pools, covering only the
 *         surface that differs from `IUniswapV3Pool` or is Slipstream-specific.
 * @dev Our own declarations of the deployed ABI — not vendored from Dromos (their protocol code is
 *      under a restricted-use license). The shared surface (`token0/1`, `tickSpacing`, `observe`,
 *      `positions`, `mint`, `burn`, `collect`, `uniswapV3MintCallback`) is ABI-identical to
 *      Uniswap V3 and is called through `IUniswapV3Pool`.
 */
interface ICLPool {
    /// @notice Slipstream `slot0` has 6 fields: unlike Uniswap V3 there is no `feeProtocol`.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);

    /// @notice Current swap fee in pips (1e-6). Dynamic when a swap-fee hook is attached.
    function fee() external view returns (uint24);

    /// @notice Share (pips) of unstaked LPs' swap fees diverted away from them.
    function unstakedFee() external view returns (uint24);

    function factory() external view returns (address);
    function gauge() external view returns (address);

    function swap(
        address _recipient,
        bool _zeroForOne,
        int256 _amountSpecified,
        uint160 _sqrtPriceLimitX96,
        bytes calldata _data
    ) external returns (int256 amount0, int256 amount1);
}
