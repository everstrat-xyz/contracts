// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec, gas-increment-by-one

import {IUniswapV3Pool} from "../../../interfaces/integrations/uniswap/IUniswapV3Pool.sol";

library TickUtils {
    function floor(int24 _tick, int24 _tickSpacing) internal pure returns (int24) {
        int24 compressed = _tick / _tickSpacing;
        if (_tick < 0 && _tick % _tickSpacing != 0) compressed--;
        return compressed * _tickSpacing;
    }

    function baseTicks(int24 _currentTick, int24 _baseThreshold, int24 _tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 tickFloor = floor(_currentTick, _tickSpacing);
        tickLower = tickFloor - _baseThreshold;
        tickUpper = tickFloor + _baseThreshold;
    }

    /// @notice Arithmetic mean tick of `_pool` over the trailing `_interval` seconds.
    /// @dev Rounds toward negative infinity, matching Uniswap's OracleLibrary.consult.
    ///      Bubbles the pool's revert when the observation buffer cannot cover `_interval`.
    function meanTick(IUniswapV3Pool _pool, uint32 _interval) internal view returns (int24) {
        (int56[] memory tickCumulatives,) = _pool.observe(_observationWindow(_interval));
        return meanTickFromCumulatives(tickCumulatives[1] - tickCumulatives[0], _interval);
    }

    /// @notice Non-reverting variant of {meanTick}.
    /// @return success False when the pool cannot serve the requested interval
    ///         (observation buffer too small), in which case the tick is zero.
    function tryMeanTick(IUniswapV3Pool _pool, uint32 _interval) internal view returns (bool success, int24 tick) {
        try _pool.observe(_observationWindow(_interval)) returns (int56[] memory tickCumulatives, uint160[] memory) {
            return (true, meanTickFromCumulatives(tickCumulatives[1] - tickCumulatives[0], _interval));
        } catch {
            return (false, 0);
        }
    }

    /// @notice Derives the mean tick from a tick-cumulative delta, rounding toward negative infinity.
    function meanTickFromCumulatives(int56 _delta, uint32 _interval) internal pure returns (int24 tick) {
        tick = int24(_delta / int56(uint56(_interval)));
        if (_delta < 0 && (_delta % int56(uint56(_interval)) != 0)) tick--;
    }

    function _observationWindow(uint32 _interval) private pure returns (uint32[] memory secondsAgos) {
        secondsAgos = new uint32[](2);
        secondsAgos[0] = _interval;
        secondsAgos[1] = 0;
    }
}
