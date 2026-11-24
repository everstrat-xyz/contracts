// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version

import {IUniCLStrat} from "../../interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../../interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "../../interfaces/integrations/uniswap/IUniswapV3Factory.sol";
import {ICLPool} from "../../interfaces/integrations/aero/ICLPool.sol";
import {ICLFactory} from "../../interfaces/integrations/aero/ICLFactory.sol";
import {TickUtils} from "../integrations/uniswap/TickUtils.sol";

/// @title CLPoolLib
/// @notice Venue-specific pool decoding and provenance for the shared CL strategy implementation.
library CLPoolLib {
    enum Venue {
        UniswapV3,
        Slipstream
    }

    /// @notice Verifies pool provenance before trusting its mint callback.
    function requireProvenance(IUniswapV3Pool _pool, address _factory, address _token0, address _token1, Venue _venue)
        internal
        view
    {
        address _canonicalPool = _venue == Venue.Slipstream
            ? ICLFactory(_factory).getPool(_token0, _token1, _pool.tickSpacing())
            : IUniswapV3Factory(_factory).getPool(_token0, _token1, _pool.fee());
        if (_canonicalPool != address(_pool)) revert IUniCLStrat.UniCLStratInvalidPool();
    }

    /// @notice Reads spot and in-use cardinality using the venue's exact slot0 layout.
    function slot0(IUniswapV3Pool _pool, Venue _venue)
        internal
        view
        returns (uint160 _sqrtPriceX96, int24 _tick, uint16 _observationCardinality)
    {
        if (_venue == Venue.Slipstream) {
            (_sqrtPriceX96, _tick,, _observationCardinality,,) = ICLPool(address(_pool)).slot0();
        } else {
            (_sqrtPriceX96, _tick,, _observationCardinality,,,) = _pool.slot0();
        }
    }

    function sqrtPrice(IUniswapV3Pool _pool, Venue _venue) internal view returns (uint160 _sqrtPriceX96) {
        (_sqrtPriceX96,,) = slot0(_pool, _venue);
    }

    function currentTick(IUniswapV3Pool _pool, Venue _venue) internal view returns (int24 _tick) {
        (, _tick,) = slot0(_pool, _venue);
    }

    /**
     * @notice Requires both a usable TWAP window and enough in-use observations to cover it.
     * @dev `observe` interpolates between the observations that bracket the window start, so
     *      covering `ceil(interval / blockSeconds)` blocks needs one slot more (#63 CPO-01).
     */
    function requireTwapOracle(
        IUniswapV3Pool _pool,
        Venue _venue,
        uint32 _interval,
        uint16 _minCardinality,
        uint32 _maxBlockSeconds
    ) internal view {
        (bool _available,) = TickUtils.tryMeanTick(_pool, _interval);
        if (!_available) revert IUniCLStrat.UniCLStratPoolTWAPNotAvailable();

        uint256 _required = (uint256(_interval) + _maxBlockSeconds - 1) / _maxBlockSeconds + 1;
        if (_required < _minCardinality) _required = _minCardinality;
        if (_required > type(uint16).max) revert IUniCLStrat.UniCLStratInvalidConfig();

        (,, uint16 _cardinality) = slot0(_pool, _venue);
        if (_cardinality < _required) {
            revert IUniCLStrat.UniCLStratInsufficientObservationCardinality(_cardinality, uint16(_required));
        }
    }
}
