// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec

/**
 * @title IDynamicSwapFeeHook
 * @notice Minimal read interface for the Aero (Slipstream) dynamic swap-fee hook.
 * @dev Our own declaration of the deployed ABI (see {ICLPool}). Used only by deploy-time probes.
 */
interface IDynamicSwapFeeHook {
    /// @notice Per-pool dynamic fee configuration; fees are in pips (1e-6).
    /// @return baseFee Static base fee (0 = factory default)
    /// @return feeCap Maximum total fee (base + dynamic) the pool can charge
    function dynamicFeeConfig(address _pool)
        external
        view
        returns (uint24 baseFee, uint24 feeCap, uint64 scalingFactor, bool initialFeeEnabled, uint24 initialFee);
}
