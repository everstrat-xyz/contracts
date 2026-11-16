// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, one-contract-per-file
pragma solidity ^0.8.30;

/**
 * @title IAeroCLFactoryForkAdmin
 * @notice Admin / permissionless `CLFactory` entry points that only fork tests use.
 * @dev Kept out of the production `ICLFactory`, which is deliberately minimal (read-only lookups
 *      the strategy and deploy script need). Our own declarations of the deployed ABI.
 */
interface IAeroCLFactoryForkAdmin {
    /// @notice Permissionless: creates and initializes a pool for an enabled tick spacing.
    function createPool(address _tokenA, address _tokenB, int24 _tickSpacing, uint160 _sqrtPriceX96)
        external
        returns (address pool);

    function unstakedFeeModule() external view returns (address);
    function unstakedFeeManager() external view returns (address);
}

/**
 * @title IAeroCustomUnstakedFeeModule
 * @notice Per-pool unstaked-fee override behind `CLFactory.getUnstakedFee`.
 * @dev `setCustomFee` is gated on `CLFactory.unstakedFeeManager()`; fees are in pips (1e-6).
 */
interface IAeroCustomUnstakedFeeModule {
    function setCustomFee(address _pool, uint24 _fee) external;
    function customFee(address _pool) external view returns (uint24);
}
