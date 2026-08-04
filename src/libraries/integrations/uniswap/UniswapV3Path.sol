// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title UniswapV3Path
 * @notice Shared helpers for the Uniswap V3 packed path encoding.
 * @dev Uniswap V3 packs multi-hop routes into a single tightly-packed byte string:
 *
 *          [token(20)][fee(3)+token(20)]...[token(20)]
 *
 *        - The first 20 bytes are the input token address.
 *        - Each subsequent hop is 23 bytes: a uint24 fee tier (3 bytes) followed by
 *          the next output token address (20 bytes).
 *        - The final 20 bytes are the ultimate output token address.
 *
 *      A single-hop path is therefore 43 bytes; each additional hop adds 23 bytes.
 *      A valid path satisfies `(length - 20) % 23 == 0`.
 *
 *      This library is the single source of truth for path validation and decoding so
 *      that the Converter adapters and strategies cannot drift apart in their handling
 *      of the encoding.
 */
library UniswapV3Path {
    /// @notice Minimum valid Uniswap V3 path length: tokenIn(20) + fee(3) + tokenOut(20)
    uint256 internal constant MIN_PATH_LENGTH = 43;

    /// @notice Address size in bytes
    uint256 internal constant ADDR_SIZE = 20;

    /// @notice Fee size in bytes (uint24)
    uint256 internal constant FEE_SIZE = 3;

    /// @notice Size of a single hop's `(fee + token)` segment: fee(3) + token(20)
    uint256 internal constant HOP_SIZE = 23;

    /// @notice Thrown when a path is not a well-formed single-hop Uniswap V3 path
    error UniswapV3PathInvalidPath();

    /**
     * @notice Validates the Uniswap V3 packed path encoding
     * @param _path The path bytes
     * @return True if the path is well-formed
     */
    function isValidPath(bytes memory _path) internal pure returns (bool) {
        uint256 _len = _path.length;
        return _len >= MIN_PATH_LENGTH && (_len - ADDR_SIZE) % HOP_SIZE == 0;
    }

    /**
     * @notice Checks whether the path is exactly one hop (single swap)
     * @param _path The path bytes
     * @return True if the path encodes exactly one hop
     */
    function isSingleHop(bytes memory _path) internal pure returns (bool) {
        return _path.length == MIN_PATH_LENGTH;
    }

    /**
     * @notice Decodes the input token (first 20 bytes) of a path
     * @param _path The path bytes (must be well-formed)
     * @return _token The input token address
     */
    function tokenIn(bytes memory _path) internal pure returns (address _token) {
        if (!isValidPath(_path)) revert UniswapV3PathInvalidPath();
        return _readAddress(_path, 0);
    }

    /**
     * @notice Decodes the output token (last 20 bytes) of a path
     * @param _path The path bytes (must be well-formed)
     * @return _token The output token address
     */
    function tokenOut(bytes memory _path) internal pure returns (address _token) {
        if (!isValidPath(_path)) revert UniswapV3PathInvalidPath();
        return _readAddress(_path, _path.length - ADDR_SIZE);
    }

    /**
     * @notice Decodes a single-hop path into its (tokenIn, fee, tokenOut) components
     * @param _path The path bytes (must be a well-formed single hop)
     */
    function decodeSingleHop(bytes memory _path)
        internal
        pure
        returns (address _tokenIn, uint24 _fee, address _tokenOut)
    {
        if (!isValidPath(_path) || !isSingleHop(_path)) revert UniswapV3PathInvalidPath();
        _tokenIn = _readAddress(_path, 0);
        _fee = _readFee(_path, ADDR_SIZE);
        _tokenOut = _readAddress(_path, _path.length - ADDR_SIZE);
    }

    /**
     * @notice Reverses a single-hop path: `(tokenIn, fee, tokenOut)` -> `(tokenOut, fee, tokenIn)`
     * @dev Uniswap V3's `exactOutput()` consumes paths in reverse order (first token is the
     *      OUTPUT token). Callers throughout the protocol always supply forward-encoded paths;
     *      adapters use this helper to produce the router-facing reverse encoding.
     * @param _path The forward-encoded path bytes (must be a well-formed single hop)
     * @return _reversed The reverse-encoded path bytes
     */
    function reverseSingleHop(bytes memory _path) internal pure returns (bytes memory _reversed) {
        (address _tokenIn, uint24 _fee, address _tokenOut) = decodeSingleHop(_path);
        return abi.encodePacked(_tokenOut, _fee, _tokenIn);
    }

    /**
     * @notice Reads an address at a byte offset of a packed byte string
     */
    function _readAddress(bytes memory _path, uint256 _offset) private pure returns (address _token) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _token := shr(96, mload(add(add(_path, 32), _offset)))
        }
    }

    /**
     * @notice Reads a uint24 fee at a byte offset of a packed byte string
     */
    function _readFee(bytes memory _path, uint256 _offset) private pure returns (uint24 _fee) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            _fee := shr(232, mload(add(add(_path, 32), _offset)))
        }
    }
}
