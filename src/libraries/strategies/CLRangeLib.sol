// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, gas-strict-inequalities

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {TickMath} from "../integrations/uniswap/TickMath.sol";
import {TickUtils} from "../integrations/uniswap/TickUtils.sol";

import {IUniCLStrat} from "../../interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../../interfaces/integrations/uniswap/IUniswapV3Pool.sol";

import {CLPoolLib} from "./CLPoolLib.sol";
import {CLPositionLib} from "./CLPositionLib.sol";
import {CLStratLib} from "./CLStratLib.sol";

/**
 * @title CLRangeLib
 * @notice Shared range management for Uniswap V3 and Slipstream concentrated-liquidity strategies: main-range
 *         placement and re-centering, the ratio-aware inventory swap, alt placement from the actual
 *         leftover, and WETH sourcing for withdrawals (partial burn, full-unwind fallback).
 * @dev Externally linked; `public` entry points run via DELEGATECALL in the strategy's context and
 *      operate on the strategy's {CLPositionLib.RangeState}. Used by both strategies through {CLStrat};
 *      the venue selects only the pool-state decoding in {CLPoolLib}.
 *
 *      This library decides *which* ranges and *how much*; it never touches the pool's position
 *      API itself. Every mint / burn / collect / position read goes through {CLPositionLib},
 *      so the holding model can change underneath without changing this file. Swaps and
 *      inventory math reuse the venue-agnostic parts of {CLStratLib}.
 *
 *      Callers own the gates: minting paths must be calm and unpaused (`pool.mint` has no price
 *      bound of its own); the withdrawal unwind ({sourceWeth}) is intentionally not calm-gated.
 */
library CLRangeLib {
    /// @dev Inventory swaps (and alt leftovers) smaller than this share (bps) of the deployed value
    ///      are skipped: parking the residual is cheaper than a negligible ratio correction.
    uint256 internal constant MIN_INVENTORY_SWAP_BPS = 10;
    uint256 internal constant BASIS_POINTS = 10_000;

    /**
     * @notice Strategy configuration snapshot read from storage/immutables at call time.
     * @param twapInterval Long TWAP window marking positions in the partial-burn sizing
     */
    struct RangeContext {
        IUniswapV3Pool pool;
        CLPoolLib.Venue venue;
        address token0;
        address token1;
        int24 tickSpacing;
        int24 positionWidth;
        int24 rebalanceTickThreshold;
        uint32 twapInterval;
        CLStratLib.SwapConfig swap;
        bytes wethToPairedTokenPath;
        bytes pairedTokenToWethPath;
    }

    // ============ Placement ============

    /**
     * @notice Deploys idle WETH / paired-token balances: optional ratio swap, main range, then the
     *         leftover in the single-sided alt range. No-op before the main range is placed.
     */
    function deployInventory(RangeContext memory _ctx, CLPositionLib.RangeState storage _state, bool _allowSwap)
        public
    {
        if (!_state.initTicks) return;

        // Leftovers below this (token1 units) stay idle — still counted in NAV and redeployed by
        // the next minting call — instead of paying for an alt mint / re-placement.
        uint256 _minLeftoverValue =
            _idleValueInToken1(_ctx, CLPoolLib.sqrtPrice(_ctx.pool, _ctx.venue)) * MIN_INVENTORY_SWAP_BPS / BASIS_POINTS;

        if (_allowSwap) _swapToMainRatio(_ctx, _state);
        _mint(_ctx, _state, _state.main);
        _deployLeftoverToAlt(_ctx, _state, _minLeftoverValue);
    }

    /// @notice Places the main range on first use, and re-centers it (full unwind) when spot has
    ///         drifted out of the healthy band; otherwise leaves existing positions untouched.
    function recenterIfNeeded(RangeContext memory _ctx, CLPositionLib.RangeState storage _state) public {
        if (!_state.initTicks) {
            _setMainTicks(_ctx, _state);
        } else if (_mainNeedsRecenter(_ctx.pool, _state, _ctx.rebalanceTickThreshold, _ctx.venue)) {
            CLPositionLib.removeAllLiquidity(_ctx.pool, _state);
            _setMainTicks(_ctx, _state);
        }
    }

    /// @notice Full unwind, re-center the main range around spot, then redeploy with the ratio swap.
    function recenter(RangeContext memory _ctx, CLPositionLib.RangeState storage _state) public {
        CLPositionLib.removeAllLiquidity(_ctx.pool, _state);
        _setMainTicks(_ctx, _state);
        deployInventory(_ctx, _state, true);
    }

    /// @notice True when the main range has been placed and spot has left it or drifted past
    ///         `_rebalanceTickThreshold` from its center.
    function mainNeedsRecenter(
        IUniswapV3Pool _pool,
        CLPositionLib.RangeState storage _state,
        int24 _rebalanceTickThreshold,
        CLPoolLib.Venue _venue
    ) public view returns (bool) {
        return _mainNeedsRecenter(_pool, _state, _rebalanceTickThreshold, _venue);
    }

    // ============ Withdrawal Sourcing ============

    /**
     * @notice Makes at least `_wethTarget` WETH available (best effort).
     * @dev The paired -> WETH leg goes through the configured route, which generally does not
     *      trade through this pool, so the decision is driven by that route:
     *      - Route tradable: idle WETH, then idle paired token, then a partial burn of alt followed
     *        by main, sized at TWAP marks and padded by slippage + the route's measured cost. Falls
     *        back to a full unwind if still short.
     *      - Route untradable (quote fails or outside the oracle band): full unwind first.
     *      - `_fullUnwind` (near-full withdrawal): full unwind first, without probing the route.
     */
    function sourceWeth(
        RangeContext memory _ctx,
        CLPositionLib.RangeState storage _state,
        uint256 _wethTarget,
        bool _fullUnwind
    ) public {
        address _weth = _ctx.swap.weth;
        uint256 _wethBalance = IERC20Metadata(_weth).balanceOf(address(this));
        if (_wethBalance >= _wethTarget) return;

        if (!_fullUnwind) {
            uint256 _shortfall = _wethTarget - _wethBalance;
            (bool _tradable, uint256 _costBps) =
                CLStratLib.routeCostBps(_ctx.swap, _ctx.pairedTokenToWethPath, _shortfall, true);
            _fullUnwind = !_tradable;

            if (_tradable) {
                uint256 _needed = _shortfall * (BASIS_POINTS + _ctx.swap.slippageBps + _costBps) / BASIS_POINTS;
                address _paired = _ctx.swap.pairedToken;
                uint256 _pairedBalance = IERC20Metadata(_paired).balanceOf(address(this));
                uint256 _idlePairedValue = _paired == _ctx.token0
                    ? _pairValueInETH(_ctx, _pairedBalance, 0)
                    : _pairValueInETH(_ctx, 0, _pairedBalance);
                if (_needed > _idlePairedValue) {
                    CLPositionLib.decreaseLiquidityForValue(
                        _ctx.pool,
                        _state,
                        _ctx.swap.oracle,
                        _weth,
                        _ctx.token0,
                        _ctx.token1,
                        _needed - _idlePairedValue,
                        _twapSqrtPrice(_ctx)
                    );
                }
            }
        }

        // Pass 0 converts after the (partial or full) unwind above; pass 1 is the full-unwind
        // fallback when the partial path still leaves WETH short and liquidity remains.
        for (uint256 _pass; _pass < 2; ++_pass) {
            if (_fullUnwind) CLPositionLib.removeAllLiquidity(_ctx.pool, _state);
            _convertToWeth(_ctx, _wethTarget);
            if (
                IERC20Metadata(_weth).balanceOf(address(this)) >= _wethTarget
                    || !CLPositionLib.hasLiquidity(_ctx.pool, _state)
            ) return;
            _fullUnwind = true;
        }
    }

    // ============ Private: Placement ============

    function _mint(
        RangeContext memory _ctx,
        CLPositionLib.RangeState storage _state,
        IUniCLStrat.Position memory _position
    ) private {
        CLPositionLib.mintPosition(_ctx.pool, _state, _position, _ctx.token0, _ctx.token1, _ctx.venue);
    }

    /**
     * @dev Parks the inventory left after the main mint in the alt range. The alt range is
     *      single-sided, so it can only hold the token that is actually left over:
     *      - existing alt already holds only that token -> add to it;
     *      - existing alt holds the other token (or straddles spot) -> remove it, offer the
     *        returned tokens to the main range again, then re-place the alt range around the final
     *        leftover. Alt ticks are only reassigned once the old position is empty.
     */
    function _deployLeftoverToAlt(
        RangeContext memory _ctx,
        CLPositionLib.RangeState storage _state,
        uint256 _minLeftoverValue
    ) private {
        (bool _hasLeftover, bool _leftoverIsToken1) = _leftoverSide(_ctx, _minLeftoverValue);
        if (!_hasLeftover) return;

        int24 _tick = CLPoolLib.currentTick(_ctx.pool, _ctx.venue);
        (bool _occupied, bool _holdsOnlyLeftover) = CLPositionLib.altState(_ctx.pool, _state, _tick, _leftoverIsToken1);
        if (_occupied) {
            if (_holdsOnlyLeftover) {
                _mint(_ctx, _state, _state.alt);
                return;
            }

            CLPositionLib.removeAltLiquidity(_ctx.pool, _state);

            _mint(_ctx, _state, _state.main);
            (_hasLeftover, _leftoverIsToken1) = _leftoverSide(_ctx, _minLeftoverValue);
            if (!_hasLeftover) return;
        }

        CLPositionLib.placeAlt(
            _ctx.pool, _state, _tick, _leftoverIsToken1, _ctx.tickSpacing, _ctx.positionWidth * _ctx.tickSpacing
        );
        _mint(_ctx, _state, _state.alt);
    }

    /// @dev Only called when the main position is empty (first placement or after a full unwind).
    function _setMainTicks(RangeContext memory _ctx, CLPositionLib.RangeState storage _state) private {
        int24 _width = _ctx.positionWidth * _ctx.tickSpacing;
        (_state.main.tickLower, _state.main.tickUpper) =
            TickUtils.baseTicks(CLPoolLib.currentTick(_ctx.pool, _ctx.venue), _width, _ctx.tickSpacing);
        _state.initTicks = true;
    }

    function _mainNeedsRecenter(
        IUniswapV3Pool _pool,
        CLPositionLib.RangeState storage _state,
        int24 _rebalanceTickThreshold,
        CLPoolLib.Venue _venue
    ) private view returns (bool) {
        if (!_state.initTicks) return false;

        int24 _tick = CLPoolLib.currentTick(_pool, _venue);
        int24 _lower = _state.main.tickLower;
        int24 _upper = _state.main.tickUpper;
        if (_tick <= _lower || _tick >= _upper) return true;

        int24 _centerTick = (_lower + _upper) / 2;
        return _abs(_tick - _centerTick) > _abs(_rebalanceTickThreshold);
    }

    /// @dev Which token dominates the idle inventory, compared in token1 units at spot.
    function _leftoverSide(RangeContext memory _ctx, uint256 _minValue) private view returns (bool, bool) {
        return CLStratLib.leftoverSide(_ctx.token0, _ctx.token1, CLPoolLib.sqrtPrice(_ctx.pool, _ctx.venue), _minValue);
    }

    function _idleValueInToken1(RangeContext memory _ctx, uint160 _sqrtPriceX96) private view returns (uint256) {
        return CLStratLib.token0InToken1(IERC20Metadata(_ctx.token0).balanceOf(address(this)), _sqrtPriceX96)
            + IERC20Metadata(_ctx.token1).balanceOf(address(this));
    }

    // ============ Private: Swaps ============

    /**
     * @dev Swaps the idle inventory towards the value ratio the main range needs at the current
     *      (calm-gated) spot price, cost-adjusted on the configured route; see
     *      {CLStratLib-routedInventorySwap}. Residuals are parked in the alt range.
     */
    function _swapToMainRatio(RangeContext memory _ctx, CLPositionLib.RangeState storage _state) private {
        (bool _sellWeth, uint256 _amountIn) = CLStratLib.routedInventorySwap(
            _ctx.swap,
            _ctx.wethToPairedTokenPath,
            _ctx.pairedTokenToWethPath,
            _ctx.token0,
            CLPoolLib.sqrtPrice(_ctx.pool, _ctx.venue),
            _state.main,
            IERC20Metadata(_ctx.token0).balanceOf(address(this)),
            IERC20Metadata(_ctx.token1).balanceOf(address(this)),
            MIN_INVENTORY_SWAP_BPS
        );
        if (_amountIn == 0) return;

        if (_sellWeth) {
            _swapCapped(_ctx, _ctx.swap.weth, _ctx.wethToPairedTokenPath, _amountIn);
        } else {
            _swapCapped(_ctx, _ctx.swap.pairedToken, _ctx.pairedTokenToWethPath, _amountIn);
        }
    }

    /// @dev Oracle-bounded exact-input swap of `_amountIn`, capped at the strategy's `_tokenIn` balance.
    function _swapCapped(RangeContext memory _ctx, address _tokenIn, bytes memory _path, uint256 _amountIn) private {
        uint256 _balance = IERC20Metadata(_tokenIn).balanceOf(address(this));
        CLStratLib.swapExactIn(_ctx.swap, _path, _amountIn > _balance ? _balance : _amountIn);
    }

    /// @dev Exact-output top-up to `_targetWethAmount` (balance-cap fallback in {CLStratLib-swapExactOut}).
    function _convertToWeth(RangeContext memory _ctx, uint256 _targetWethAmount) private {
        uint256 _wethBalance = IERC20Metadata(_ctx.swap.weth).balanceOf(address(this));
        if (_wethBalance >= _targetWethAmount) return;
        CLStratLib.swapExactOut(_ctx.swap, _ctx.pairedTokenToWethPath, _targetWethAmount - _wethBalance);
    }

    // ============ Private: Valuation ============

    function _pairValueInETH(RangeContext memory _ctx, uint256 _amount0, uint256 _amount1)
        private
        view
        returns (uint256)
    {
        return CLStratLib.pairValueInETH(_ctx.swap.oracle, _ctx.swap.weth, _ctx.token0, _ctx.token1, _amount0, _amount1);
    }

    /// @dev Long-TWAP sqrt price; reverts `UniCLStratPoolTWAPNotAvailable` (fail-closed).
    function _twapSqrtPrice(RangeContext memory _ctx) private view returns (uint160) {
        (bool _ok, int24 _meanTick) = TickUtils.tryMeanTick(_ctx.pool, _ctx.twapInterval);
        if (!_ok) revert IUniCLStrat.UniCLStratPoolTWAPNotAvailable();
        return TickMath.getSqrtRatioAtTick(_meanTick);
    }

    function _abs(int24 _value) private pure returns (uint24) {
        return uint24(_value < 0 ? -_value : _value);
    }
}
