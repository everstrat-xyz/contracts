// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec, ordering

/**
 * @title IUniswapV3Pool
 * @notice Uniswap V3 Pool interface covering the functions used by the protocol.
 */
interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observe(uint32[] calldata _secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function positions(bytes32 _key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function mint(address _recipient, int24 _tickLower, int24 _tickUpper, uint128 _amount, bytes calldata _data)
        external
        returns (uint256 amount0, uint256 amount1);

    function burn(int24 _tickLower, int24 _tickUpper, uint128 _amount)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(
        address _recipient,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _amount0Requested,
        uint128 _amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);
}
