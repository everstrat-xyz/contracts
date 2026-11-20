// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {IRegistry} from "interfaces/IRegistry.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {Math} from "../../src/libraries/Math.sol";
import {FixedPoint96} from "../../src/libraries/integrations/uniswap/FixedPoint96.sol";
import {FullMath} from "../../src/libraries/integrations/uniswap/FullMath.sol";
import {LiquidityAmounts} from "../../src/libraries/integrations/uniswap/LiquidityAmounts.sol";
import {TickMath} from "../../src/libraries/integrations/uniswap/TickMath.sol";
import {TickUtils} from "../../src/libraries/integrations/uniswap/TickUtils.sol";
import {UniswapV3Path} from "../../src/libraries/integrations/uniswap/UniswapV3Path.sol";

/// @dev External wrappers so reverts inside internal library code surface at a call boundary.
contract LibrariesHarness {
    function mulDiv(uint256 _a, uint256 _b, uint256 _denominator) external pure returns (uint256) {
        return FullMath.mulDiv(_a, _b, _denominator);
    }

    function getSqrtRatioAtTick(int24 _tick) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(_tick);
    }

    function getLiquidityForAmount0(uint160 _a, uint160 _b, uint256 _amount0) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount0(_a, _b, _amount0);
    }

    function getLiquidityForAmount1(uint160 _a, uint160 _b, uint256 _amount1) external pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmount1(_a, _b, _amount1);
    }

    function getLiquidityForAmounts(uint160 _p, uint160 _a, uint160 _b, uint256 _amount0, uint256 _amount1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(_p, _a, _b, _amount0, _amount1);
    }

    function getAmount0ForLiquidity(uint160 _a, uint160 _b, uint128 _liquidity) external pure returns (uint256) {
        return LiquidityAmounts.getAmount0ForLiquidity(_a, _b, _liquidity);
    }

    function getAmount1ForLiquidity(uint160 _a, uint160 _b, uint128 _liquidity) external pure returns (uint256) {
        return LiquidityAmounts.getAmount1ForLiquidity(_a, _b, _liquidity);
    }

    function getAmountsForLiquidity(uint160 _p, uint160 _a, uint160 _b, uint128 _liquidity)
        external
        pure
        returns (uint256, uint256)
    {
        return LiquidityAmounts.getAmountsForLiquidity(_p, _a, _b, _liquidity);
    }

    function floor(int24 _tick, int24 _tickSpacing) external pure returns (int24) {
        return TickUtils.floor(_tick, _tickSpacing);
    }

    function meanTickFromCumulatives(int56 _delta, uint32 _interval) external pure returns (int24) {
        return TickUtils.meanTickFromCumulatives(_delta, _interval);
    }

    function tokenIn(bytes memory _path) external pure returns (address) {
        return UniswapV3Path.tokenIn(_path);
    }

    function tokenOut(bytes memory _path) external pure returns (address) {
        return UniswapV3Path.tokenOut(_path);
    }

    function decodeSingleHop(bytes memory _path) external pure returns (address, uint24, address) {
        return UniswapV3Path.decodeSingleHop(_path);
    }

    function reverseSingleHop(bytes memory _path) external pure returns (bytes memory) {
        return UniswapV3Path.reverseSingleHop(_path);
    }

    function convertDecimals(uint256 _amount, uint8 _from, uint8 _to) external pure returns (uint256) {
        return Math.convertDecimals(_amount, _from, _to);
    }

    function isRelativelyLessThan(uint256 _a, uint256 _b, uint256 _difference) external pure returns (bool) {
        return Math.isRelativelyLessThan(_a, _b, _difference);
    }

    function strategyKeeperExecutor(address _registry) external view returns (address) {
        return Auth.strategyKeeperExecutor(IRegistry(_registry));
    }
}

contract LibrariesTest is Test {
    LibrariesHarness internal lib;

    address internal constant TOKEN_A = address(0xA11CE);
    address internal constant TOKEN_B = address(0xB0B);
    address internal constant TOKEN_C = address(0xC0FFEE);
    uint24 internal constant FEE = 3000;

    /// @dev Uniswap V3 TickMath.MIN_SQRT_RATIO / MAX_SQRT_RATIO.
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @dev Reference values floor(sqrt(1.0001^tick) * 2^96), computed at 80-digit precision.
    uint256 internal constant TICK_REL_TOLERANCE = 1e8; // 1e-10

    function setUp() public {
        lib = new LibrariesHarness();
    }

    // ──────────────────────────────────────────────────────────────────────
    // FullMath
    // ──────────────────────────────────────────────────────────────────────

    function test_FullMath_MulDiv_SingleWordProduct() public view {
        assertEq(lib.mulDiv(6, 7, 4), 10);
        assertEq(lib.mulDiv(0, type(uint256).max, 1), 0);
    }

    function test_FullMath_MulDiv_ZeroDenominatorReverts() public {
        vm.expectRevert();
        lib.mulDiv(1, 1, 0);
    }

    function test_FullMath_MulDiv_FullWidthProduct() public view {
        // 2^255 * 4 overflows 256 bits; the 512-bit path must still return 2^254.
        assertEq(lib.mulDiv(1 << 255, 4, 8), 1 << 254);
        assertEq(lib.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
        // Non-zero remainder and an odd denominator exercise the remainder/inverse steps.
        assertEq(lib.mulDiv(type(uint256).max, type(uint256).max - 1, type(uint256).max), type(uint256).max - 1);
        assertEq(lib.mulDiv(type(uint256).max, 3, 7), (type(uint256).max / 7) * 3 + ((type(uint256).max % 7) * 3) / 7);
    }

    function test_FullMath_MulDiv_ResultOverflowReverts() public {
        // denominator <= high word of the product: the result does not fit in 256 bits.
        vm.expectRevert();
        lib.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max - 1);

        vm.expectRevert();
        lib.mulDiv(1 << 255, 4, 1);
    }

    function testFuzz_FullMath_MulDiv_MatchesNativeWhenNoOverflow(uint128 _a, uint128 _b, uint256 _d) public view {
        _d = bound(_d, 1, type(uint256).max);
        assertEq(lib.mulDiv(_a, _b, _d), (uint256(_a) * uint256(_b)) / _d);
    }

    function testFuzz_FullMath_MulDiv_FullWidthRoundTrip(uint256 _a, uint256 _b) public view {
        _a = bound(_a, 1, type(uint256).max);
        _b = bound(_b, 1, type(uint256).max);
        // (a * b) / b == a for any non-zero b, even when a * b needs 512 bits.
        assertEq(lib.mulDiv(_a, _b, _b), _a);
    }

    // ──────────────────────────────────────────────────────────────────────
    // TickMath
    // ──────────────────────────────────────────────────────────────────────

    function test_TickMath_Extremes() public view {
        assertEq(lib.getSqrtRatioAtTick(TickMath.MIN_TICK), MIN_SQRT_RATIO);
        assertEq(lib.getSqrtRatioAtTick(TickMath.MAX_TICK), MAX_SQRT_RATIO);
        assertEq(lib.getSqrtRatioAtTick(0), uint160(FixedPoint96.Q96));
    }

    function test_TickMath_ReferenceValues() public view {
        assertApproxEqRel(lib.getSqrtRatioAtTick(1), 79232123823359799118286999567, TICK_REL_TOLERANCE);
        assertApproxEqRel(lib.getSqrtRatioAtTick(-1), 79224201403219477170569942573, TICK_REL_TOLERANCE);
        assertApproxEqRel(lib.getSqrtRatioAtTick(50), 79426470787362580746886972460, TICK_REL_TOLERANCE);
        assertApproxEqRel(lib.getSqrtRatioAtTick(-50), 79030349367926598376800521321, TICK_REL_TOLERANCE);
        assertApproxEqRel(lib.getSqrtRatioAtTick(100000), 11755562826496067164730007768449, TICK_REL_TOLERANCE);
        // 524287 = 0x7FFFF sets every bit below 0x80000, so each multiplier step runs.
        assertApproxEqRel(lib.getSqrtRatioAtTick(524287), 19189247130466284822469633862652052790146, TICK_REL_TOLERANCE);
        assertApproxEqRel(lib.getSqrtRatioAtTick(-524287), 327115581591561468, TICK_REL_TOLERANCE);
    }

    function test_TickMath_OutOfRangeReverts() public {
        vm.expectRevert(bytes("T"));
        lib.getSqrtRatioAtTick(TickMath.MAX_TICK + 1);

        vm.expectRevert(bytes("T"));
        lib.getSqrtRatioAtTick(TickMath.MIN_TICK - 1);
    }

    function testFuzz_TickMath_StrictlyIncreasing(int24 _tick) public view {
        _tick = int24(bound(_tick, TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        assertLt(lib.getSqrtRatioAtTick(_tick), lib.getSqrtRatioAtTick(_tick + 1));
    }

    function testFuzz_TickMath_WithinBounds(int24 _tick) public view {
        _tick = int24(bound(_tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        uint160 _sqrtP = lib.getSqrtRatioAtTick(_tick);
        assertGe(_sqrtP, MIN_SQRT_RATIO);
        assertLe(_sqrtP, MAX_SQRT_RATIO);
    }

    // ──────────────────────────────────────────────────────────────────────
    // LiquidityAmounts
    // ──────────────────────────────────────────────────────────────────────

    function test_LiquidityAmounts_SingleSidedFunctionsIgnoreBoundOrder() public view {
        uint160 _a = lib.getSqrtRatioAtTick(-600);
        uint160 _b = lib.getSqrtRatioAtTick(600);

        assertEq(lib.getLiquidityForAmount0(_b, _a, 1 ether), lib.getLiquidityForAmount0(_a, _b, 1 ether));
        assertEq(lib.getLiquidityForAmount1(_b, _a, 1 ether), lib.getLiquidityForAmount1(_a, _b, 1 ether));
        assertEq(lib.getAmount0ForLiquidity(_b, _a, 1e18), lib.getAmount0ForLiquidity(_a, _b, 1e18));
        assertEq(lib.getAmount1ForLiquidity(_b, _a, 1e18), lib.getAmount1ForLiquidity(_a, _b, 1e18));
    }

    function test_LiquidityAmounts_RangeFunctionsIgnoreBoundOrder() public view {
        uint160 _a = lib.getSqrtRatioAtTick(-600);
        uint160 _b = lib.getSqrtRatioAtTick(600);
        uint160[3] memory _prices =
            [lib.getSqrtRatioAtTick(-1200), uint160(FixedPoint96.Q96), lib.getSqrtRatioAtTick(1200)];

        for (uint256 i; i < _prices.length; ++i) {
            assertEq(
                lib.getLiquidityForAmounts(_prices[i], _b, _a, 1 ether, 2 ether),
                lib.getLiquidityForAmounts(_prices[i], _a, _b, 1 ether, 2 ether)
            );
            (uint256 _r0, uint256 _r1) = lib.getAmountsForLiquidity(_prices[i], _b, _a, 1e18);
            (uint256 _o0, uint256 _o1) = lib.getAmountsForLiquidity(_prices[i], _a, _b, 1e18);
            assertEq(_r0, _o0);
            assertEq(_r1, _o1);
        }
    }

    function test_LiquidityAmounts_RangeFunctionsUseTheRightSide() public view {
        uint160 _a = lib.getSqrtRatioAtTick(-600);
        uint160 _b = lib.getSqrtRatioAtTick(600);

        // Below range: only token0 counts. Above range: only token1 counts.
        (uint256 _below0, uint256 _below1) = lib.getAmountsForLiquidity(lib.getSqrtRatioAtTick(-1200), _a, _b, 1e18);
        assertGt(_below0, 0);
        assertEq(_below1, 0);
        (uint256 _above0, uint256 _above1) = lib.getAmountsForLiquidity(lib.getSqrtRatioAtTick(1200), _a, _b, 1e18);
        assertEq(_above0, 0);
        assertGt(_above1, 0);

        assertEq(
            lib.getLiquidityForAmounts(lib.getSqrtRatioAtTick(-1200), _a, _b, 1 ether, 0),
            lib.getLiquidityForAmount0(_a, _b, 1 ether)
        );
        assertEq(
            lib.getLiquidityForAmounts(lib.getSqrtRatioAtTick(1200), _a, _b, 0, 1 ether),
            lib.getLiquidityForAmount1(_a, _b, 1 ether)
        );
    }

    function test_LiquidityAmounts_LiquidityAboveUint128Reverts() public {
        uint160 _a = lib.getSqrtRatioAtTick(0);
        uint160 _b = lib.getSqrtRatioAtTick(1);

        vm.expectRevert();
        lib.getLiquidityForAmount1(_a, _b, type(uint128).max);

        vm.expectRevert();
        lib.getLiquidityForAmount0(_a, _b, type(uint128).max);
    }

    // ──────────────────────────────────────────────────────────────────────
    // TickUtils
    // ──────────────────────────────────────────────────────────────────────

    function test_TickUtils_FloorRoundsTowardNegativeInfinity() public view {
        assertEq(lib.floor(15, 10), 10);
        assertEq(lib.floor(10, 10), 10);
        assertEq(lib.floor(0, 10), 0);
        assertEq(lib.floor(-10, 10), -10);
        assertEq(lib.floor(-1, 10), -10);
        assertEq(lib.floor(-15, 10), -20);
    }

    function test_TickUtils_MeanTickRoundsTowardNegativeInfinity() public view {
        assertEq(lib.meanTickFromCumulatives(7, 2), 3);
        assertEq(lib.meanTickFromCumulatives(-6, 2), -3);
        assertEq(lib.meanTickFromCumulatives(-7, 2), -4);
        assertEq(lib.meanTickFromCumulatives(0, 1800), 0);
    }

    function testFuzz_TickUtils_FloorIsAlignedAndNotAbove(int24 _tick, int24 _spacing) public view {
        _spacing = int24(bound(_spacing, 1, 16384));
        _tick = int24(bound(_tick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        int24 _floor = lib.floor(_tick, _spacing);
        assertEq(_floor % _spacing, 0);
        assertLe(_floor, _tick);
        assertGt(int256(_floor) + _spacing, int256(_tick));
    }

    // ──────────────────────────────────────────────────────────────────────
    // UniswapV3Path
    // ──────────────────────────────────────────────────────────────────────

    function test_UniswapV3Path_TokenInAndOut() public view {
        bytes memory _single = abi.encodePacked(TOKEN_A, FEE, TOKEN_B);
        assertEq(lib.tokenIn(_single), TOKEN_A);
        assertEq(lib.tokenOut(_single), TOKEN_B);

        bytes memory _multi = abi.encodePacked(TOKEN_A, FEE, TOKEN_B, uint24(500), TOKEN_C);
        assertEq(lib.tokenIn(_multi), TOKEN_A);
        assertEq(lib.tokenOut(_multi), TOKEN_C);
    }

    function test_UniswapV3Path_TokenInAndOut_RevertOnMalformedPath() public {
        bytes memory _short = abi.encodePacked(TOKEN_A, FEE);
        bytes memory _ragged = abi.encodePacked(TOKEN_A, FEE, TOKEN_B, uint8(1));

        vm.expectRevert(UniswapV3Path.UniswapV3PathInvalidPath.selector);
        lib.tokenIn(_short);
        vm.expectRevert(UniswapV3Path.UniswapV3PathInvalidPath.selector);
        lib.tokenIn(_ragged);
        vm.expectRevert(UniswapV3Path.UniswapV3PathInvalidPath.selector);
        lib.tokenOut(_short);
        vm.expectRevert(UniswapV3Path.UniswapV3PathInvalidPath.selector);
        lib.tokenOut(_ragged);
    }

    function test_UniswapV3Path_DecodeAndReverseSingleHop() public view {
        (address _in, uint24 _fee, address _out) = lib.decodeSingleHop(abi.encodePacked(TOKEN_A, FEE, TOKEN_B));
        assertEq(_in, TOKEN_A);
        assertEq(_fee, FEE);
        assertEq(_out, TOKEN_B);
        assertEq(lib.reverseSingleHop(abi.encodePacked(TOKEN_A, FEE, TOKEN_B)), abi.encodePacked(TOKEN_B, FEE, TOKEN_A));
    }

    function test_UniswapV3Path_DecodeSingleHop_RevertsOnMultiHopOrMalformed() public {
        vm.expectRevert(UniswapV3Path.UniswapV3PathInvalidPath.selector);
        lib.decodeSingleHop(abi.encodePacked(TOKEN_A, FEE, TOKEN_B, uint24(500), TOKEN_C));

        vm.expectRevert(UniswapV3Path.UniswapV3PathInvalidPath.selector);
        lib.decodeSingleHop(abi.encodePacked(TOKEN_A, FEE));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Math
    // ──────────────────────────────────────────────────────────────────────

    function test_Math_ConvertDecimals() public view {
        assertEq(lib.convertDecimals(1e6, 6, 18), 1e18);
        assertEq(lib.convertDecimals(1e18, 18, 6), 1e6);
        assertEq(lib.convertDecimals(123, 8, 8), 123);
    }

    function test_Math_ConvertDecimals_RevertsAbove18() public {
        vm.expectRevert(Math.MathDecimalsTooHigh.selector);
        lib.convertDecimals(1, 19, 18);

        vm.expectRevert(Math.MathDecimalsTooHigh.selector);
        lib.convertDecimals(1, 18, 19);
    }

    function test_Math_IsRelativelyLessThan() public view {
        assertTrue(lib.isRelativelyLessThan(94, 100, 5e16));
        assertFalse(lib.isRelativelyLessThan(95, 100, 5e16));
        assertFalse(lib.isRelativelyLessThan(0, 100, 1e18));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Auth
    // ──────────────────────────────────────────────────────────────────────

    function test_Auth_StrategyKeeperExecutor_ReadsItsRegistryKey() public {
        address registry = makeAddr("registry");
        address executor = makeAddr("strategyKeeperExecutor");
        vm.mockCall(
            registry,
            abi.encodeWithSelector(IRegistry.getContractByKey.selector, Auth.STRATEGY_KEEPER_EXECUTOR),
            abi.encode(executor)
        );
        assertEq(lib.strategyKeeperExecutor(registry), executor);
    }

    function test_Math_IsRelativelyLessThan_RevertsAboveOne() public {
        vm.expectRevert(Math.MathInvalidRelativeDifference.selector);
        lib.isRelativelyLessThan(1, 2, 1e18 + 1);
    }
}
