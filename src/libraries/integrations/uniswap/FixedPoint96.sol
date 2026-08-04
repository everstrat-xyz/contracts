// SPDX-License-Identifier: MIT
// Adapted from Uniswap V3 Core's FixedPoint96 library.
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec

library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}
