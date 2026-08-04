// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

library Math {
    /**
     * @dev Amount of decimals in a normalized value representation.
     */
    uint8 internal constant DECIMALS_NORMALIZED = 18;
    /**
     * @dev Multiplication over this factor transforms "full tokens" representation
     * into normalized one (e.g. 1 ether * NORMALIZATION_FACTOR = 10^18 wei).
     */
    uint256 internal constant NORMALIZATION_FACTOR = 10 ** DECIMALS_NORMALIZED;

    /**
     * @dev Factor that represents 100% of a value, which means that
     * any arbitrary number of percents is calculated as:
     * percents representation = SCALE_FACTOR * number of percents / 100,
     * and corresponding fraction of a value is calculated as:
     * value * percents representation / SCALE_FACTOR.
     */
    uint256 internal constant SCALE_FACTOR = 1e18;

    /**
     * @notice Asset decimals are too high.
     */
    error MathDecimalsTooHigh();

    /**
     * @notice Relative difference is invalid.
     */
    error MathInvalidRelativeDifference();

    /**
     * @notice Convert an amount from one decimal precision to another.
     * @param _amount The amount to convert.
     * @param _fromDecimals Current decimal places.
     * @param _toDecimals Target decimal places.
     */
    function convertDecimals(uint256 _amount, uint8 _fromDecimals, uint8 _toDecimals) internal pure returns (uint256) {
        if (_fromDecimals > 18 || _toDecimals > 18) {
            revert MathDecimalsTooHigh();
        }

        if (_fromDecimals == _toDecimals) {
            return _amount;
        }
        if (_fromDecimals < _toDecimals) {
            return _amount * (10 ** uint256(_toDecimals - _fromDecimals));
        } else {
            return _amount / (10 ** uint256(_fromDecimals - _toDecimals));
        }
    }

    /**
     * @notice Normalizes decimals number in a value representation,
     * i.e. converts decimals to 18.
     * @param _amount The amount to normalize.
     * @param _fromDecimals Current decimal places.
     */
    function normalizeDecimals(uint256 _amount, uint8 _fromDecimals) internal pure returns (uint256) {
        return convertDecimals(_amount, _fromDecimals, DECIMALS_NORMALIZED);
    }

    /**
     * @notice Unnormalizes decimals number in a value representation,
     * i.e. converts decimals from 18 to `_toDecimals`.
     * @param _amount The amount to normalize.
     * @param _toDecimals Target decimal places.
     */
    function unnormalizeDecimals(uint256 _amount, uint8 _toDecimals) internal pure returns (uint256) {
        return convertDecimals(_amount, DECIMALS_NORMALIZED, _toDecimals);
    }

    /**
     * @notice Convert amount from Asset A to Asset B using price of Asset A in Asset B terms.
     * @param _normalizedAmount The normalized amount of Asset A to convert.
     * @param _normalizedPrice The normalized price of Asset A in Asset B terms (e.g., ETH price in USDC).
     * @return uint256 The normalized amount of Asset B.
     */
    function convertAssets(uint256 _normalizedAmount, uint256 _normalizedPrice) internal pure returns (uint256) {
        return (_normalizedAmount * _normalizedPrice) / NORMALIZATION_FACTOR;
    }

    /**
     * @notice Convert amount from Asset B to Asset A using price of Asset A in Asset B terms.
     * @param _normalizedAmount The normalized amount of Asset B to convert.
     * @param _normalizedPrice The normalized price of Asset A in Asset B terms (e.g., ETH price in USDC).
     * @return uint256 The normalized amount of Asset A.
     */
    function convertAssetsInverse(uint256 _normalizedAmount, uint256 _normalizedPrice)
        internal
        pure
        returns (uint256)
    {
        return (_normalizedAmount * NORMALIZATION_FACTOR) / _normalizedPrice;
    }

    /**
     * @notice Calculates the base price of a protocol token:
     * base_price = NAV_total / token_supply.
     * @dev The caller must ensure `_totalSupply` is non-zero.
     * @param _navTotal Total NAV backing the token supply (normalized).
     * @param _totalSupply Total minted protocol tokens (normalized).
     * @return uint256 The base price of 1 protocol token (normalized).
     */
    function basePrice(uint256 _navTotal, uint256 _totalSupply) internal pure returns (uint256) {
        return (_navTotal * NORMALIZATION_FACTOR) / _totalSupply;
    }

    /**
     * @notice Calculates the premium price of a protocol token:
     * premium_price = NAV_total / (token_supply * cw).
     * @dev The caller must ensure `_totalSupply` is non-zero and `_cw`
     * belongs to the range (0; SCALE_FACTOR].
     * @param _navTotal Total NAV backing the token supply (normalized).
     * @param _totalSupply Total minted protocol tokens (normalized).
     * @param _cw Connector weight of the bonding curve, range (0; SCALE_FACTOR].
     * @return uint256 The premium price of 1 protocol token (normalized).
     */
    function premiumPrice(uint256 _navTotal, uint256 _totalSupply, uint256 _cw) internal pure returns (uint256) {
        uint256 adjustedSupply = (_totalSupply * _cw) / SCALE_FACTOR;
        return (_navTotal * NORMALIZATION_FACTOR) / adjustedSupply;
    }

    /**
     * @notice Check if _a is relatively less than _b by a given difference percentage.
     * @param _a First value.
     * @param _b Second value.
     * @param _difference Relative difference in range [0; SCALE_FACTOR],
     * for example, 5e17 represents 0.5.
     * @return bool True if _a is relatively less than _b by a given relative difference.
     */
    function isRelativelyLessThan(uint256 _a, uint256 _b, uint256 _difference) internal pure returns (bool) {
        if (_difference > SCALE_FACTOR) revert MathInvalidRelativeDifference();

        return _a * SCALE_FACTOR < _b * (SCALE_FACTOR - _difference);
    }
}
