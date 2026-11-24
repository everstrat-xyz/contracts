// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec, ordering

/**
 * @title ICLFactory
 * @notice Minimal interface for the Aero (Slipstream) `CLFactory`.
 * @dev Our own declarations of the deployed ABI (see {ICLPool}). Unlike Uniswap V3, pools are
 *      keyed by tick spacing, not fee: only the `int24` tick-spacing `getPool` is declared and
 *      used here, never a fee-keyed lookup.
 */
interface ICLFactory {
    function getPool(address _tokenA, address _tokenB, int24 _tickSpacing) external view returns (address pool);
    function isPool(address _pool) external view returns (bool);

    /// @notice Swap-fee hook attached to `_pool` (dynamic fee module), or `address(0)` if none.
    function getPoolSwapHook(address _pool) external view returns (address);

    /// @notice Effective unstaked-fee share (pips) for `_pool`.
    function getUnstakedFee(address _pool) external view returns (uint24);
}
