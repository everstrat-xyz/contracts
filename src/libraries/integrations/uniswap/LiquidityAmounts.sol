// SPDX-License-Identifier: MIT
// Adapted from Uniswap V3 Periphery's LiquidityAmounts library.
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec, reason-string, gas-custom-errors, ordering
// solhint-disable gas-strict-inequalities

import {FixedPoint96} from "./FixedPoint96.sol";
import {FullMath} from "./FullMath.sol";

library LiquidityAmounts {
    function toUint128(uint256 _x) private pure returns (uint128 y) {
        require((y = uint128(_x)) == _x);
    }

    function getLiquidityForAmount0(uint160 _sqrtRatioAX96, uint160 _sqrtRatioBX96, uint256 _amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (_sqrtRatioAX96 > _sqrtRatioBX96) {
            (_sqrtRatioAX96, _sqrtRatioBX96) = (_sqrtRatioBX96, _sqrtRatioAX96);
        }
        uint256 intermediate = FullMath.mulDiv(_sqrtRatioAX96, _sqrtRatioBX96, FixedPoint96.Q96);
        return toUint128(FullMath.mulDiv(_amount0, intermediate, _sqrtRatioBX96 - _sqrtRatioAX96));
    }

    function getLiquidityForAmount1(uint160 _sqrtRatioAX96, uint160 _sqrtRatioBX96, uint256 _amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (_sqrtRatioAX96 > _sqrtRatioBX96) {
            (_sqrtRatioAX96, _sqrtRatioBX96) = (_sqrtRatioBX96, _sqrtRatioAX96);
        }
        return toUint128(FullMath.mulDiv(_amount1, FixedPoint96.Q96, _sqrtRatioBX96 - _sqrtRatioAX96));
    }

    function getLiquidityForAmounts(
        uint160 _sqrtRatioX96,
        uint160 _sqrtRatioAX96,
        uint160 _sqrtRatioBX96,
        uint256 _amount0,
        uint256 _amount1
    ) internal pure returns (uint128 liquidity) {
        if (_sqrtRatioAX96 > _sqrtRatioBX96) {
            (_sqrtRatioAX96, _sqrtRatioBX96) = (_sqrtRatioBX96, _sqrtRatioAX96);
        }

        if (_sqrtRatioX96 <= _sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(_sqrtRatioAX96, _sqrtRatioBX96, _amount0);
        } else if (_sqrtRatioX96 < _sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(_sqrtRatioX96, _sqrtRatioBX96, _amount0);
            uint128 liquidity1 = getLiquidityForAmount1(_sqrtRatioAX96, _sqrtRatioX96, _amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(_sqrtRatioAX96, _sqrtRatioBX96, _amount1);
        }
    }

    function getAmount0ForLiquidity(uint160 _sqrtRatioAX96, uint160 _sqrtRatioBX96, uint128 _liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (_sqrtRatioAX96 > _sqrtRatioBX96) {
            (_sqrtRatioAX96, _sqrtRatioBX96) = (_sqrtRatioBX96, _sqrtRatioAX96);
        }

        return FullMath.mulDiv(
            uint256(_liquidity) << FixedPoint96.RESOLUTION, _sqrtRatioBX96 - _sqrtRatioAX96, _sqrtRatioBX96
        ) / _sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(uint160 _sqrtRatioAX96, uint160 _sqrtRatioBX96, uint128 _liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (_sqrtRatioAX96 > _sqrtRatioBX96) {
            (_sqrtRatioAX96, _sqrtRatioBX96) = (_sqrtRatioBX96, _sqrtRatioAX96);
        }

        return FullMath.mulDiv(_liquidity, _sqrtRatioBX96 - _sqrtRatioAX96, FixedPoint96.Q96);
    }

    function getAmountsForLiquidity(
        uint160 _sqrtRatioX96,
        uint160 _sqrtRatioAX96,
        uint160 _sqrtRatioBX96,
        uint128 _liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (_sqrtRatioAX96 > _sqrtRatioBX96) {
            (_sqrtRatioAX96, _sqrtRatioBX96) = (_sqrtRatioBX96, _sqrtRatioAX96);
        }

        if (_sqrtRatioX96 <= _sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(_sqrtRatioAX96, _sqrtRatioBX96, _liquidity);
        } else if (_sqrtRatioX96 < _sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(_sqrtRatioX96, _sqrtRatioBX96, _liquidity);
            amount1 = getAmount1ForLiquidity(_sqrtRatioAX96, _sqrtRatioX96, _liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(_sqrtRatioAX96, _sqrtRatioBX96, _liquidity);
        }
    }
}
