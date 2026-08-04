// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IConverter
 * @notice Interface for the Converter contract that centralises WETH wrapping,
 *         unwrapping, and DEX swap execution.
 * @dev The Converter is a shared protocol module used by StrategyManager and
 *      registered strategies. It enforces an adapter allowlist, caller authorisation
 *      via `CONVERTER_CALLER_ROLE` on the Registry (administered by `CONVERTER_CALLER_MANAGER_ROLE` held
 *      by the Converter), caller-supplied slippage bounds, and deadlines.
 *
 *      Roles are resolved from the protocol Registry:
 *        - ADMIN_ROLE (Auth): pause/unpause, adapter management, upgrades
 *        - STRATEGY_MANAGER (Auth): grant/revoke caller permissions via grantCallerRole/revokeCallerRole
 *
 *      Routing is caller-owned: each strategy supplies the adapter and the
 *      adapter-specific route bytes at call time. The Converter only verifies that the
 *      adapter is whitelisted and dispatches execution to it. A Uniswap strategy
 *      points at the Uniswap adapter, a Curve strategy at the Curve adapter, and so on.
 *      Adding a new DEX only requires whitelisting its adapter — the swap interface does
 *      not change.
 */
interface IConverter {
    // ============ Errors ============

    /**
     * @notice Thrown when a zero address is provided
     */
    error ConverterZeroAddress();

    /**
     * @notice Thrown when an address that must be a contract has no code
     */
    error ConverterNoCode();

    /**
     * @notice Thrown when the target adapter is not on the allowlist
     */
    error ConverterAdapterNotAllowed();

    /**
     * @notice Thrown when an adapter is already on the allowlist
     */
    error ConverterAdapterAlreadyAllowed();

    /**
     * @notice Thrown when the swap output is below the minimum acceptable amount
     */
    error ConverterInsufficientOutput();

    /**
     * @notice Thrown when the actual input exceeds the maximum acceptable amount in an exact-output swap
     */
    error ConverterExcessiveInput();

    /**
     * @notice Thrown when the swap deadline has expired
     */
    error ConverterDeadlineExpired();

    /**
     * @notice Thrown when the adapter swap dispatch fails
     */
    error ConverterSwapFailed();

    /**
     * @notice Thrown when an adapter view call (routeTokens / quote) fails
     */
    error ConverterAdapterCallFailed();

    /**
     * @notice Thrown when an ETH transfer fails
     */
    error ConverterETHTransferFailed();

    /**
     * @notice Thrown when a route is structurally invalid for the given adapter
     */
    error ConverterInvalidRoute();

    // ============ Events ============

    /**
     * @notice Emitted when native ETH is wrapped into WETH
     */
    event ETHWrapped(address indexed caller, uint256 amount);

    /**
     * @notice Emitted when WETH is unwrapped into native ETH
     */
    event WETHUnwrapped(address indexed caller, address indexed receiver, uint256 amount);

    /**
     * @notice Emitted when a token swap is executed
     */
    event SwapExecuted(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    /**
     * @notice Emitted when an adapter is added to or removed from the allowlist
     */
    event AdapterUpdated(address indexed adapter, bool allowed);

    /**
     * @notice Emitted when the contract is initialised
     */
    event ConverterInitialized(address indexed registry, address indexed weth);

    /**
     * @notice Emitted when CONVERTER_CALLER_ROLE is granted to an account
     */
    event CallerRoleGranted(address indexed account);

    /**
     * @notice Emitted when CONVERTER_CALLER_ROLE is revoked from an account
     */
    event CallerRoleRevoked(address indexed account);

    // ============ Core Functions ============

    /**
     * @notice Returns the address of the WETH contract
     * @return address The address of the WETH contract
     */
    function weth() external view returns (address);

    /**
     * @notice Wraps received native ETH into WETH and transfers the WETH back to the caller
     */
    function wrapETH() external payable;

    /**
     * @notice Pulls WETH from the caller, unwraps it to native ETH, and sends ETH to the receiver
     * @param _amount The amount of WETH to unwrap
     * @param _receiver The address that will receive the native ETH
     */
    function unwrapWETH(uint256 _amount, address _receiver) external;

    /**
     * @notice Executes a token swap through a caller-supplied adapter and route (exact-input)
     * @dev The caller (a strategy) owns the routing decision: it supplies both the adapter
     *      and the adapter-specific route bytes. The Converter only checks that the adapter
     *      is whitelisted, then dispatches execution to it via DELEGATECALL — the input
     *      tokens stay on the Converter and the adapter approves the DEX router directly
     *      (no double approve/transfer through the adapter). Slippage protection is
     *      caller-supplied via `_minAmountOut` (no on-chain quote is used in the execution path).
     * @param _adapter The whitelisted DEX adapter that owns the route encoding and execution
     * @param _path Adapter-specific route bytes
     * @param _amountIn The amount of input token to swap
     * @param _minAmountOut The minimum acceptable amount of output token
     * @param _deadline The timestamp after which the swap will revert
     * @return _amountOut The amount of output token received
     */
    function executeSwapExactAmountIn(
        address _adapter,
        bytes calldata _path,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint256 _deadline
    ) external returns (uint256 _amountOut);

    /**
     * @notice Executes a token swap for an exact output amount (exact-output)
     * @dev The caller specifies the exact output amount they want, with a maximum
     *      input amount as slippage protection. The full `_amountInMaximum` is pulled
     *      from the caller upfront (the DEX router pulls payment mid-swap, so the
     *      maximum must be available); unspent input is refunded in the same call.
     *      The input consumed is measured from the Converter's input-token balance
     *      delta — not the adapter-reported amount — and must not exceed
     *      `_amountInMaximum`.
     *
     *      The `_path` uses the same FORWARD encoding as {executeSwapExactAmountIn} (input token
     *      first, output token last). If the underlying DEX consumes exact-output routes
     *      in a different encoding (e.g. Uniswap V3's reverse-ordered paths), the
     *      adapter performs that translation internally — callers never reverse paths.
     *
     * @param _adapter The whitelisted DEX adapter that owns the route encoding and execution
     * @param _path Adapter-specific route bytes (same forward encoding as {executeSwapExactAmountIn})
     * @param _amountOut The exact amount of output token desired
     * @param _amountInMaximum The maximum acceptable amount of input token (slippage bound)
     * @param _deadline The timestamp after which the swap will revert
     * @return _amountIn The amount of input token actually spent (balance-measured)
     */
    function executeSwapExactAmountOut(
        address _adapter,
        bytes calldata _path,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint256 _deadline
    ) external returns (uint256 _amountIn);

    /**
     * @notice Quotes the expected output of a swap without executing it (exact-input)
     * @dev NOTE: This function is **non-view** (declared as `external returns`, not `external view returns`).
     *      Some adapter quoters simulate the swap and write (transient) storage, so a staticcall
     *      could revert; do NOT assume `eth_call`-with-staticcall semantics apply. Call via
     *      `eth_call` for off-chain estimation. Calling from within a transaction will consume
     *      gas and may revert depending on pool/oracle state. Individual adapters MAY implement
     *      their quote as `view` (e.g. TWAP + Chainlink based), but callers must treat this
     *      entry point as state-mutating.
     *      Permissionless (no access control, no pause check).
     *
     *      On the parameter surface: all three parameters are load-bearing. `_adapter` is
     *      required because the Converter is a multi-DEX facade and routing is caller-owned —
     *      the Converter cannot infer which whitelisted adapter a strategy intends to trade
     *      through. `_path` is opaque to the Converter (only the adapter can decode it), and
     *      `_amountIn` is needed because quotes are amount-dependent (token decimals, pool
     *      fee, and — for spot-state quoters — price impact all scale with the input).
     * @param _adapter The adapter to quote against (must be whitelisted)
     * @param _path Adapter-specific route bytes
     * @param _amountIn The amount of input token
     * @return _amountOut The expected output amount
     */
    function quoteSwapExactAmountIn(address _adapter, bytes calldata _path, uint256 _amountIn)
        external
        returns (uint256 _amountOut);

    /**
     * @notice Quotes the required input for a desired output amount (exact-output)
     * @dev NOTE: This function is **non-view** (declared as `external returns`, not `external view returns`).
     *      Call via `eth_call` for off-chain estimation. Same non-view rationale as {quoteSwapExactAmountIn}.
     *      Calling from within a transaction will consume gas and may revert depending on pool/oracle state.
     *      Permissionless.
     * @param _adapter The adapter to quote against (must be whitelisted)
     * @param _path Adapter-specific route bytes
     * @param _amountOut The desired output amount
     * @return _amountIn The required input amount
     */
    function quoteSwapExactAmountOut(address _adapter, bytes calldata _path, uint256 _amountOut)
        external
        returns (uint256 _amountIn);

    // ============ Role Management ============

    /**
     * @notice Grants caller permission to an account (restricted to registered STRATEGY_MANAGER)
     * @param _account The account to grant caller permission to
     */
    function grantCallerRole(address _account) external;

    /**
     * @notice Revokes caller permission from an account (restricted to registered STRATEGY_MANAGER)
     * @param _account The account to revoke caller permission from
     */
    function revokeCallerRole(address _account) external;

    /**
     * @notice Returns whether an account has caller permission (can call wrap, unwrap, swap)
     * @param _account The account to check
     * @return True if the account has caller permission
     */
    function isCaller(address _account) external view returns (bool);

    // ============ Configuration ============

    /**
     * @notice Adds or removes a DEX adapter from the allowlist
     * @dev SECURITY: whitelisted adapters are executed via DELEGATECALL during swaps and
     *      therefore run with full access to the Converter's storage and balances. Only
     *      audited, stateless adapters (immutables-only, see {IConverterAdapter}) may be
     *      whitelisted.
     * @param _adapter The adapter address
     * @param _allowed Whether the adapter is allowed
     */
    function setAllowedAdapter(address _adapter, bool _allowed) external;

    /**
     * @notice Returns whether an adapter is on the allowlist
     * @param _adapter The adapter address
     * @return True if the adapter is allowed
     */
    function isAdapterAllowed(address _adapter) external view returns (bool);

    /**
     * @notice Returns the full list of allowed adapter addresses
     * @return An array of all currently allowed adapter addresses
     */
    function getAllowedAdapters() external view returns (address[] memory);

    /**
     * @notice Returns the first and last token addresses for a route, as resolved by its adapter
     * @dev Reverts with ConverterAdapterNotAllowed if the adapter is not whitelisted, or
     *      ConverterAdapterCallFailed if the adapter cannot decode the route.
     * @param _adapter The whitelisted DEX adapter that owns the route encoding
     * @param _path Adapter-specific route bytes
     * @return tokenIn The first token in the path (input token)
     * @return tokenOut The last token in the path (output token)
     */
    function routeTokens(address _adapter, bytes calldata _path)
        external
        view
        returns (address tokenIn, address tokenOut);

    /**
     * @notice Validates whether a route is well-formed for the given adapter
     * @dev Each adapter enforces its own route encoding scheme. Reverts with
     *      ConverterAdapterNotAllowed if the adapter is not whitelisted, or
     *      ConverterAdapterCallFailed if the adapter's validateRoute view reverts.
     * @param _adapter The whitelisted DEX adapter that owns the route encoding
     * @param _route Adapter-specific route bytes to validate
     * @return _valid True if the route is well-formed for this adapter
     */
    function validateRoute(address _adapter, bytes calldata _route) external view returns (bool _valid);

    // ============ Emergency ============

    /**
     * @notice Returns whether the contract is paused
     */
    function paused() external view returns (bool);

    /**
     * @notice Pauses the contract
     */
    function pause() external;

    /**
     * @notice Unpauses the contract
     */
    function unpause() external;
}
