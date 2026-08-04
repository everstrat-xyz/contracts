// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IConverterAdapter
 * @notice Generic DEX adapter interface used by the Converter to abstract away
 *         per-DEX route encoding, validation, and execution.
 * @dev Each supported DEX (Uniswap V3, Curve, Balancer, 1inch, etc.) ships its own
 *      adapter implementing this interface. The Converter whitelists adapter
 *      addresses and dispatches swaps to them, so it never hard-casts to a
 *      DEX-specific router or quoter.
 *
 *      Route bytes are opaque to the Converter. The adapter is the sole authority
 *      on how a route is encoded, which token it starts/ends with, and how it is
 *      executed against the underlying DEX. This keeps the Converter a true generic
 *      facade: adding a DEX with a different path scheme (flat pair lists, custom
 *      hooks, fee tiers, etc.) requires only a new adapter, not a Converter change.
 *
 *      Token custody during a swap: the Converter pulls `tokenIn` from the caller and
 *      then DELEGATECALLs {swapExactAmountIn}/{swapExactAmountOut} on the adapter. The adapter
 *      code executes in the Converter's context — the input tokens already sit on
 *      `address(this)` (the Converter), so the adapter approves the DEX router
 *      directly and trades, delivering the output to `_recipient`. There is no
 *      intermediate approve/transferFrom round-trip through the adapter.
 *
 *      ROUTE ENCODING CONTRACT: every entry point — exact-input and exact-output alike —
 *      takes the same FORWARD route encoding (input token first, output token last, as
 *      decoded by {routeTokens}). If the underlying DEX consumes a different encoding
 *      for one of the directions (e.g. Uniswap V3's `exactOutput()` takes reverse-encoded
 *      paths), the adapter MUST perform that translation internally. This keeps the
 *      Converter's `routeTokens`-based token custody (pull `tokenIn`, return `tokenOut`)
 *      correct for both swap directions.
 *
 *      DELEGATECALL CONTRACT REQUIREMENTS: because swap execution runs in the
 *      Converter's storage context, adapters MUST be stateless — configuration only
 *      via immutables/constants (embedded in code, valid under delegatecall) and no
 *      storage reads or writes. A storage-touching adapter would read/corrupt the
 *      Converter's storage layout. Adapters are admin-whitelisted and fully trusted.
 *
 *      {validateRoute}/{routeTokens}/{quoteExactAmountIn}/{quoteExactAmountOut} are dispatched
 *      via regular CALLs (not delegatecall).
 */
interface IConverterAdapter {
    /**
     * @notice Returns a human-readable adapter name (e.g. "UniswapV3ConverterAdapter")
     */
    function name() external view returns (string memory);

    /**
     * @notice Returns the version of the adapter implementation
     * @return string Version string (e.g. "1.0.0")
     */
    function version() external pure returns (string memory);

    /**
     * @notice Validates that a route blob is well-formed for this adapter's DEX
     * @dev Each adapter enforces its own encoding scheme. Returning false (rather
     *      than reverting) lets the Converter surface a uniform error.
     * @param _route The DEX-specific route/path bytes
     * @return _valid True if the route is well-formed for this adapter
     */
    function validateRoute(bytes calldata _route) external view returns (bool _valid);

    /**
     * @notice Returns the input and output token addresses for a route
     * @dev Decoded per the adapter's own encoding scheme.
     * @param _route The DEX-specific route/path bytes
     * @return _tokenIn The input token (what the Converter pulls from the caller)
     * @return _tokenOut The output token (what the Converter returns to the caller)
     */
    function routeTokens(bytes calldata _route) external view returns (address _tokenIn, address _tokenOut);

    /**
     * @notice Returns the expected output for a route and input amount (exact-input quote)
     * @dev Called on-chain by strategies via the Converter's `quoteSwapExactAmountIn()` to estimate
     *      expected output before executing a swap.
     *      NOTE: declared **non-view** (`external returns`) on purpose — some DEX quoters
     *      (e.g. the Uniswap V3 Quoter) simulate the swap and write transient storage, so
     *      a staticcall would revert. Implementations that price without simulation (e.g.
     *      TWAP + Chainlink) MAY override with `view` (a more restrictive mutability).
     *      Off-chain consumers should invoke via `eth_call`.
     * @param _route The DEX-specific route/path bytes
     * @param _amountIn The input amount
     * @return _amountOut The expected output amount
     */
    function quoteExactAmountIn(bytes calldata _route, uint256 _amountIn) external returns (uint256 _amountOut);

    /**
     * @notice Returns the required input for a route and desired output amount (exact-output quote)
     * @dev Same non-view rationale as {quoteExactAmountIn}. Takes the same FORWARD route
     *      encoding as {quoteExactAmountIn} (see contract-level route encoding contract).
     * @param _route The DEX-specific route/path bytes
     * @param _amountOut The desired output amount
     * @return _amountIn The required input amount
     */
    function quoteExactAmountOut(bytes calldata _route, uint256 _amountOut) external returns (uint256 _amountIn);

    /**
     * @notice Executes a swap against the underlying DEX (exact-input)
     * @dev Invoked by the Converter via DELEGATECALL: the code runs in the Converter's
     *      context, the input tokens already sit on `address(this)`, and the adapter
     *      approves the DEX router directly (clearing any residual approval afterwards).
     *      The adapter must enforce `_minAmountOut` and `_deadline` via the underlying
     *      DEX (or directly). Implementations must be stateless (see contract-level docs).
     * @param _route The DEX-specific route/path bytes
     * @param _amountIn The input amount
     * @param _minAmountOut The minimum acceptable output amount (caller-supplied slippage bound)
     * @param _recipient The address that receives the output token
     * @param _deadline The timestamp after which the swap must revert
     * @return _amountOut The output amount received
     */
    function swapExactAmountIn(
        bytes calldata _route,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _recipient,
        uint256 _deadline
    ) external returns (uint256 _amountOut);

    /**
     * @notice Executes a swap against the underlying DEX (exact-output)
     * @dev Similar to {swapExactAmountIn} (also invoked via DELEGATECALL) but specifies the
     *      exact output amount and a maximum input amount as slippage protection. The
     *      underlying DEX computes the actual input consumed; any unspent input simply
     *      remains on `address(this)` (the Converter), which refunds it to the caller.
     *
     *      Takes the same FORWARD route encoding as {swapExactAmountIn} (see contract-level
     *      route encoding contract). If the underlying DEX consumes exact-output routes
     *      in a different encoding (e.g. Uniswap V3's reverse-ordered paths), the adapter
     *      performs that translation internally — callers never reverse routes themselves.
     *
     * @param _route The DEX-specific route/path bytes (same forward encoding as {swapExactAmountIn})
     * @param _amountOut The exact output amount desired
     * @param _amountInMaximum The maximum acceptable input amount (caller-supplied slippage bound)
     * @param _recipient The address that receives the output token
     * @param _deadline The timestamp after which the swap must revert
     * @return _amountIn The input amount actually spent
     */
    function swapExactAmountOut(
        bytes calldata _route,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        address _recipient,
        uint256 _deadline
    ) external returns (uint256 _amountIn);
}
