// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, gas-strict-inequalities

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {FullMath} from "../integrations/uniswap/FullMath.sol";
import {LiquidityAmounts} from "../integrations/uniswap/LiquidityAmounts.sol";
import {TickMath} from "../integrations/uniswap/TickMath.sol";
import {TickUtils} from "../integrations/uniswap/TickUtils.sol";

import {IOracle} from "../../interfaces/IOracle.sol";
import {IUniCLStrat} from "../../interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../../interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {ICLPool} from "../../interfaces/integrations/aero/ICLPool.sol";

import {UniCLStratLib} from "./UniCLStratLib.sol";

/**
 * @title AeroCLPositionLib
 * @notice Position layer of the Aero (Slipstream) concentrated-liquidity strategies: how the
 *         strategy's main and alt ranges are held, read, minted, burned and collected, plus the
 *         LP-fee accounting and valuation built on those reads.
 * @dev Externally linked (`public` entry points run via DELEGATECALL in the strategy's context, so
 *      `address(this)` is the strategy and every pool call is made by the strategy). Holds no state
 *      or funds of its own: everything lives in the caller's {RangeState}.
 *
 *      Every pool interaction goes through the private primitives in the "Position Primitives"
 *      section (`_read`, `_tryRead`, `_mint`, `_burn`, `_collect`). They are the only code that
 *      knows *how* a position is held — today, directly in the pool, keyed by
 *      `keccak256(owner, tickLower, tickUpper)`. Range decisions (which ticks, how much, in what
 *      order) live in {AeroCLRangeLib} and never touch the pool directly, so a different holding
 *      model (e.g. NonfungiblePositionManager NFTs staked in a gauge) can be added here without
 *      changing range management.
 *
 *      Slipstream `slot0` has 6 fields; spot is read only through {slot0}. Never call
 *      `UniCLStratLib.requireTwapOracle` or `IUniswapV3Pool.slot0` for an Aero pool (7-field decode
 *      reverts). The LP-fee accounting reuses `UniCLStratLib.LpFeeState` and has the same semantics
 *      as the UniCLStrat implementation.
 */
library AeroCLPositionLib {
    /**
     * @notice All range-management state of a strategy, passed by storage pointer.
     * @param main Main range (two-sided around spot)
     * @param alt Single-sided range parking the leftover token
     * @param lpFees LP-fee accounting (earned / charged / owed snapshot)
     * @param initTicks Main range has been placed at least once
     * @param minting Set for the duration of a `mint` so the pool callback can be authenticated
     */
    struct RangeState {
        IUniCLStrat.Position main;
        IUniCLStrat.Position alt;
        UniCLStratLib.LpFeeState lpFees;
        bool initTicks;
        bool minting;
    }

    // ============ Spot ============

    /// @notice Slipstream 6-field `slot0` (no `feeProtocol`). `_observationCardinality` is the in-use cardinality.
    function slot0(IUniswapV3Pool _pool)
        internal
        view
        returns (uint160 _sqrtPriceX96, int24 _tick, uint16 _observationCardinality)
    {
        (_sqrtPriceX96, _tick,, _observationCardinality,,) = ICLPool(address(_pool)).slot0();
    }

    function sqrtPrice(IUniswapV3Pool _pool) internal view returns (uint160 _sqrtPriceX96) {
        (_sqrtPriceX96,,) = slot0(_pool);
    }

    function currentTick(IUniswapV3Pool _pool) internal view returns (int24 _tick) {
        (, _tick,) = slot0(_pool);
    }

    // ============ Mint ============

    /**
     * @notice Adds as much of the strategy's idle token0/token1 to `_position` as fits at spot.
     * @dev No-op for invalid ticks or zero liquidity. For the main range, also a no-op when one side
     *      would be zero (minting a one-sided main is never intended). `pool.mint` has no price bound
     *      of its own: callers must ensure the pool is calm. The pool pays itself in the strategy's
     *      `uniswapV3MintCallback`, which checks `_state.minting`.
     */
    function mintPosition(
        IUniswapV3Pool _pool,
        RangeState storage _state,
        IUniCLStrat.Position memory _position,
        address _token0,
        address _token1
    ) public {
        if (!_isValid(_position)) return;

        uint160 _sqrtPriceX96 = sqrtPrice(_pool);
        uint160 _sqrtA = TickMath.getSqrtRatioAtTick(_position.tickLower);
        uint160 _sqrtB = TickMath.getSqrtRatioAtTick(_position.tickUpper);
        uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPriceX96,
            _sqrtA,
            _sqrtB,
            IERC20Metadata(_token0).balanceOf(address(this)),
            IERC20Metadata(_token1).balanceOf(address(this))
        );
        if (_liquidity == 0) return;

        if (_position.tickLower == _state.main.tickLower && _position.tickUpper == _state.main.tickUpper) {
            (uint256 _amount0, uint256 _amount1) =
                LiquidityAmounts.getAmountsForLiquidity(_sqrtPriceX96, _sqrtA, _sqrtB, _liquidity);
            if (_amount0 == 0 || _amount1 == 0) return;
        }

        _mint(_pool, _state, _position, _liquidity);
    }

    // ============ Removal & Partial Burn ============

    /// @notice Pokes both positions so accrued fees materialize in owed tokens (no liquidity removed).
    function pokePositions(IUniswapV3Pool _pool, RangeState storage _state) public {
        _pokePositions(_pool, _state);
    }

    /**
     * @notice Removes all liquidity from both positions and collects everything owed.
     * @dev Poke before accruing so fee growth since the last update is folded into owed. Accrue
     *      before collect so the delta is locked into `earned*` before owed is zeroed. Accruing after
     *      a full burn would also pick up withdrawn principal briefly sitting in owed.
     */
    function removeAllLiquidity(IUniswapV3Pool _pool, RangeState storage _state) public {
        _pokePositions(_pool, _state);
        _accrueLpFees(_pool, _state);
        _removePosition(_pool, _state.main);
        _removePosition(_pool, _state.alt);
        _state.lpFees.snapshot0 = 0;
        _state.lpFees.snapshot1 = 0;
    }

    /// @notice Removes the alt position entirely (poke → accrue → burn → collect → re-base snapshot).
    function removeAltLiquidity(IUniswapV3Pool _pool, RangeState storage _state) public {
        _pokePositions(_pool, _state);
        _accrueLpFees(_pool, _state);
        _removePosition(_pool, _state.alt);
        _refreshSnapshot(_pool, _state);
    }

    /**
     * @notice Burns (and collects) roughly `_value` ETH worth of pool inventory: alt first (it is
     *         out of range and earns nothing), then main.
     * @dev Pokes and accrues LP fees first, and re-bases the fee snapshot on the remaining owed
     *      after, since a burn credits principal to owed. Positions are valued at
     *      `_twapSqrtPriceX96` (including owed tokens) and priced via the Oracle. Each burn rounds up
     *      and is capped at the whole position; everything owed is collected.
     */
    function decreaseLiquidityForValue(
        IUniswapV3Pool _pool,
        RangeState storage _state,
        IOracle _oracle,
        address _weth,
        address _token0,
        address _token1,
        uint256 _value,
        uint160 _twapSqrtPriceX96
    ) public {
        _pokePositions(_pool, _state);
        _accrueLpFees(_pool, _state);

        uint256 _remaining =
            _burnForValue(_pool, _state.alt, _oracle, _weth, _token0, _token1, _value, _twapSqrtPriceX96);
        if (_remaining > 0) {
            _burnForValue(_pool, _state.main, _oracle, _weth, _token0, _token1, _remaining, _twapSqrtPriceX96);
        }

        _refreshSnapshot(_pool, _state);
    }

    /// @notice True when either position holds liquidity.
    function hasLiquidity(IUniswapV3Pool _pool, RangeState storage _state) public view returns (bool) {
        return _liquidityOf(_pool, _state.main) > 0 || _liquidityOf(_pool, _state.alt) > 0;
    }

    // ============ Alt Position ============

    /**
     * @notice State of the alt position relative to a leftover token.
     * @return _occupied Alt currently holds liquidity
     * @return _holdsOnlyLeftover Alt sits entirely on the side that holds only the leftover token
     *         (all token1 when `tick >= tickUpper`, all token0 when `tick < tickLower`)
     */
    function altState(IUniswapV3Pool _pool, RangeState storage _state, int24 _tick, bool _leftoverIsToken1)
        public
        view
        returns (bool _occupied, bool _holdsOnlyLeftover)
    {
        IUniCLStrat.Position memory _alt = _state.alt;
        if (!_isValid(_alt)) return (false, false);
        _occupied = _liquidityOf(_pool, _alt) > 0;
        _holdsOnlyLeftover = _leftoverIsToken1 ? _tick >= _alt.tickUpper : _tick < _alt.tickLower;
    }

    /**
     * @notice Places the single-sided alt range next to spot: below it for a token1 leftover,
     *         above it for a token0 leftover.
     * @dev Reverts `UniCLStratPositionNotEmpty` if the current alt still holds liquidity or owed
     *      tokens — NAV and fee accounting only read the current position, so reassigning a
     *      non-empty one would orphan its value.
     */
    function placeAlt(
        IUniswapV3Pool _pool,
        RangeState storage _state,
        int24 _tick,
        bool _leftoverIsToken1,
        int24 _tickSpacing,
        int24 _width
    ) public {
        IUniCLStrat.Position memory _alt = _state.alt;
        if (_isValid(_alt)) {
            (uint128 _liquidity, uint128 _owed0, uint128 _owed1) = _read(_pool, _alt);
            if (_liquidity > 0 || _owed0 > 0 || _owed1 > 0) revert IUniCLStrat.UniCLStratPositionNotEmpty();
        }

        int24 _tickFloor = TickUtils.floor(_tick, _tickSpacing);
        if (_leftoverIsToken1) {
            (_state.alt.tickLower, _state.alt.tickUpper) = (_tickFloor - _width, _tickFloor - _tickSpacing);
        } else {
            (_state.alt.tickLower, _state.alt.tickUpper) = (_tickFloor + _tickSpacing, _tickFloor + _width);
        }
    }

    // ============ LP-Fee Accounting ============

    /**
     * @notice Flushes `owed - snapshot` into `earned*`, advances the snapshot, and returns the
     *         uncharged amounts. Required before collect and before settle charges.
     */
    function accrueLpFees(IUniswapV3Pool _pool, RangeState storage _state)
        public
        returns (uint256 _uncharged0, uint256 _uncharged1)
    {
        _accrueLpFees(_pool, _state);
        UniCLStratLib.LpFeeState storage _fees = _state.lpFees;
        return (_fees.earned0 - _fees.charged0, _fees.earned1 - _fees.charged1);
    }

    /**
     * @notice Writes off pending LP fees (emergency exit): best-effort accrue, then charged = earned.
     * @dev On a degraded pool the owed read falls back to the snapshot, so accrue is a no-op and this
     *      cannot revert. See `UniCLStratLib.resetLpFeeAccounting` for why counters are not zeroed.
     */
    function resetLpFeeAccounting(IUniswapV3Pool _pool, RangeState storage _state) public {
        UniCLStratLib.LpFeeState storage _fees = _state.lpFees;
        (bool _ok, uint256 _current0, uint256 _current1) = _tryLpFeesOwed(_pool, _state);
        if (_ok) _accrueFrom(_fees, _current0, _current1);
        _fees.charged0 = _fees.earned0;
        _fees.charged1 = _fees.earned1;
    }

    /**
     * @notice Uncharged LP fees including the live `owed - snapshot` delta, so pending/settle see
     *         fees materialized since the last accrue without a sync flush (sync is poke-only).
     */
    function unchargedLpFeeAmounts(IUniswapV3Pool _pool, RangeState storage _state)
        public
        view
        returns (uint256 _uncharged0, uint256 _uncharged1)
    {
        UniCLStratLib.LpFeeState storage _fees = _state.lpFees;
        (uint256 _current0, uint256 _current1) = _lpFeesOwed(_pool, _state);
        uint256 _earned0 = _fees.earned0;
        uint256 _earned1 = _fees.earned1;
        if (_current0 > _fees.snapshot0) _earned0 += _current0 - _fees.snapshot0;
        if (_current1 > _fees.snapshot1) _earned1 += _current1 - _fees.snapshot1;
        return (_earned0 - _fees.charged0, _earned1 - _fees.charged1);
    }

    // ============ Valuation ============

    /**
     * @notice ETH value of the strategy's idle token0/token1 balances plus both positions
     *         (liquidity marked at `_twapSqrtPriceX96`, plus owed tokens).
     * @dev Excludes native ETH (added by the caller). Priced via Oracle cross-rates.
     */
    function inventoryValueInETH(
        IUniswapV3Pool _pool,
        RangeState storage _state,
        IOracle _oracle,
        address _weth,
        address _token0,
        address _token1,
        uint160 _twapSqrtPriceX96
    ) public view returns (uint256) {
        (uint256 _main0, uint256 _main1) = _positionAmounts(_pool, _state.main, _twapSqrtPriceX96);
        (uint256 _alt0, uint256 _alt1) = _positionAmounts(_pool, _state.alt, _twapSqrtPriceX96);
        return UniCLStratLib.pairValueInETH(
            _oracle,
            _weth,
            _token0,
            _token1,
            IERC20Metadata(_token0).balanceOf(address(this)) + _main0 + _alt0,
            IERC20Metadata(_token1).balanceOf(address(this)) + _main1 + _alt1
        );
    }

    // ============ Private: Accounting ============

    function _accrueLpFees(IUniswapV3Pool _pool, RangeState storage _state) private {
        (uint256 _current0, uint256 _current1) = _lpFeesOwed(_pool, _state);
        _accrueFrom(_state.lpFees, _current0, _current1);
    }

    function _accrueFrom(UniCLStratLib.LpFeeState storage _fees, uint256 _current0, uint256 _current1) private {
        if (_current0 > _fees.snapshot0) _fees.earned0 += _current0 - _fees.snapshot0;
        if (_current1 > _fees.snapshot1) _fees.earned1 += _current1 - _fees.snapshot1;
        _fees.snapshot0 = _current0;
        _fees.snapshot1 = _current1;
    }

    /// @dev Re-bases the snapshot on the aggregate owed left after a partial collect.
    function _refreshSnapshot(IUniswapV3Pool _pool, RangeState storage _state) private {
        (_state.lpFees.snapshot0, _state.lpFees.snapshot1) = _lpFeesOwed(_pool, _state);
    }

    /// @dev Fail-closed aggregate owed across both positions.
    function _lpFeesOwed(IUniswapV3Pool _pool, RangeState storage _state)
        private
        view
        returns (uint256 _amount0, uint256 _amount1)
    {
        (, uint128 _main0, uint128 _main1) = _read(_pool, _state.main);
        (, uint128 _alt0, uint128 _alt1) = _read(_pool, _state.alt);
        return (uint256(_main0) + uint256(_alt0), uint256(_main1) + uint256(_alt1));
    }

    /// @dev Best-effort aggregate owed; `_ok == false` if either read reverts (all-or-nothing: the
    ///      snapshot is aggregate, so mixing a live leg with it is unsafe).
    function _tryLpFeesOwed(IUniswapV3Pool _pool, RangeState storage _state)
        private
        view
        returns (bool _ok, uint256 _amount0, uint256 _amount1)
    {
        (bool _mainOk, uint128 _main0, uint128 _main1) = _tryRead(_pool, _state.main);
        if (!_mainOk) return (false, 0, 0);
        (bool _altOk, uint128 _alt0, uint128 _alt1) = _tryRead(_pool, _state.alt);
        if (!_altOk) return (false, 0, 0);
        return (true, uint256(_main0) + uint256(_alt0), uint256(_main1) + uint256(_alt1));
    }

    // ============ Private: Liquidity ============

    function _pokePositions(IUniswapV3Pool _pool, RangeState storage _state) private {
        _pokePosition(_pool, _state.main);
        _pokePosition(_pool, _state.alt);
    }

    function _pokePosition(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position) private {
        if (!_isValid(_position)) return;
        if (_liquidityOf(_pool, _position) > 0) _burn(_pool, _position, 0);
    }

    function _removePosition(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position) private {
        if (!_isValid(_position)) return;
        uint128 _liquidity = _liquidityOf(_pool, _position);
        if (_liquidity > 0) _burn(_pool, _position, _liquidity);
        _collect(_pool, _position);
    }

    function _burnForValue(
        IUniswapV3Pool _pool,
        IUniCLStrat.Position memory _position,
        IOracle _oracle,
        address _weth,
        address _token0,
        address _token1,
        uint256 _value,
        uint160 _twapSqrtPriceX96
    ) private returns (uint256 _remaining) {
        if (!_isValid(_position)) return _value;

        uint128 _liquidity = _liquidityOf(_pool, _position);
        if (_liquidity == 0) return _value;

        (uint256 _amount0, uint256 _amount1) = _positionAmounts(_pool, _position, _twapSqrtPriceX96);
        uint256 _positionValue = UniCLStratLib.pairValueInETH(_oracle, _weth, _token0, _token1, _amount0, _amount1);

        uint128 _burnLiquidity = _liquidity;
        if (_positionValue > _value) {
            uint256 _share = FullMath.mulDiv(_liquidity, _value, _positionValue) + 1;
            if (_share < _liquidity) _burnLiquidity = uint128(_share);
        } else {
            _remaining = _value - _positionValue;
        }

        _burn(_pool, _position, _burnLiquidity);
        _collect(_pool, _position);
    }

    /// @dev Amounts held by a position (liquidity at `_sqrtPriceX96` plus owed); zero for invalid ticks.
    function _positionAmounts(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position, uint160 _sqrtPriceX96)
        private
        view
        returns (uint256 _amount0, uint256 _amount1)
    {
        if (!_isValid(_position)) return (0, 0);

        (uint128 _liquidity, uint128 _owed0, uint128 _owed1) = _read(_pool, _position);
        if (_liquidity > 0) {
            (_amount0, _amount1) = LiquidityAmounts.getAmountsForLiquidity(
                _sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(_position.tickLower),
                TickMath.getSqrtRatioAtTick(_position.tickUpper),
                _liquidity
            );
        }
        _amount0 += _owed0;
        _amount1 += _owed1;
    }

    function _liquidityOf(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position)
        private
        view
        returns (uint128 _liquidity)
    {
        if (!_isValid(_position)) return 0;
        (_liquidity,,) = _read(_pool, _position);
    }

    function _isValid(IUniCLStrat.Position memory _position) private pure returns (bool) {
        return _position.tickLower < _position.tickUpper && _position.tickLower >= TickMath.MIN_TICK
            && _position.tickUpper <= TickMath.MAX_TICK;
    }

    // ============ Position Primitives (direct pool positions) ============
    // The only code that knows how a position is held. A position is owned by the strategy in the
    // pool itself, keyed by `keccak256(owner, tickLower, tickUpper)`.

    /// @dev Liquidity and owed tokens. Reads unconditionally (an unused key returns zeros), fail-closed.
    function _read(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position)
        private
        view
        returns (uint128 _liquidity, uint128 _owed0, uint128 _owed1)
    {
        (_liquidity,,, _owed0, _owed1) = _pool.positions(_key(_position));
    }

    /// @dev {_read} that reports a revert instead of bubbling it. Parameterless catch — binding the
    ///      revert data would copy unbounded returndata from a degraded pool.
    function _tryRead(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position)
        private
        view
        returns (bool _ok, uint128 _owed0, uint128 _owed1)
    {
        try _pool.positions(_key(_position)) returns (uint128, uint256, uint256, uint128 _o0, uint128 _o1) {
            return (true, _o0, _o1);
        } catch {}
    }

    function _mint(
        IUniswapV3Pool _pool,
        RangeState storage _state,
        IUniCLStrat.Position memory _position,
        uint128 _liquidity
    ) private {
        _state.minting = true;
        try _pool.mint(address(this), _position.tickLower, _position.tickUpper, _liquidity, "") {
            _state.minting = false;
        } catch (bytes memory _reason) {
            assembly {
                revert(add(_reason, 32), mload(_reason))
            }
        }
    }

    /// @dev `_liquidity == 0` is a poke: accrued fees move into owed without removing liquidity.
    function _burn(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position, uint128 _liquidity) private {
        _pool.burn(_position.tickLower, _position.tickUpper, _liquidity);
    }

    function _collect(IUniswapV3Pool _pool, IUniCLStrat.Position memory _position) private {
        _pool.collect(address(this), _position.tickLower, _position.tickUpper, type(uint128).max, type(uint128).max);
    }

    function _key(IUniCLStrat.Position memory _position) private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), _position.tickLower, _position.tickUpper));
    }
}
