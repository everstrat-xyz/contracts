// SPDX-License-Identifier: MIT
// Adapted from Uniswap V3 Core's FullMath library.
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec, reason-string, gas-custom-errors

library FullMath {
    function mulDiv(uint256 _a, uint256 _b, uint256 _denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(_a, _b, not(0))
                prod0 := mul(_a, _b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                require(_denominator > 0);
                assembly {
                    result := div(prod0, _denominator)
                }
                return result;
            }

            require(_denominator > prod1);

            uint256 remainder;
            assembly {
                remainder := mulmod(_a, _b, _denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = _denominator & (~_denominator + 1);
            assembly {
                _denominator := div(_denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }

            prod0 |= prod1 * twos;

            uint256 inv = (3 * _denominator) ^ 2;
            inv *= 2 - _denominator * inv;
            inv *= 2 - _denominator * inv;
            inv *= 2 - _denominator * inv;
            inv *= 2 - _denominator * inv;
            inv *= 2 - _denominator * inv;
            inv *= 2 - _denominator * inv;

            result = prod0 * inv;
            return result;
        }
    }
}
