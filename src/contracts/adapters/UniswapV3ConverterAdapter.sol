// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IConverterAdapter} from "../../interfaces/IConverterAdapter.sol";
import {IUniswapV3ConverterAdapter} from "../../interfaces/adapters/IUniswapV3ConverterAdapter.sol";
import {IOracle} from "../../interfaces/IOracle.sol";
import {IUniswapV3Router} from "../../interfaces/integrations/uniswap/IUniswapV3Router.sol";
import {IUniswapV3Factory} from "../../interfaces/integrations/uniswap/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../../interfaces/integrations/uniswap/IUniswapV3Pool.sol";

import {FullMath} from "../../libraries/integrations/uniswap/FullMath.sol";
import {TickMath} from "../../libraries/integrations/uniswap/TickMath.sol";
import {TickUtils} from "../../libraries/integrations/uniswap/TickUtils.sol";
import {UniswapV3Path} from "../../libraries/integrations/uniswap/UniswapV3Path.sol";

/**
 * @title UniswapV3ConverterAdapter
 * @notice Converter adapter for Uniswap V3-style routers using the packed
 *         `(tokenIn, fee, tokenOut, fee, ...)` multi-hop path encoding.
 * @dev Static/immutable ("code is law"). The Converter whitelists this adapter and
 *      dispatches swaps to it via DELEGATECALL — see {swapExactAmountIn}/{swapExactAmountOut}.
 *      The adapter is therefore intentionally STATELESS: it holds only immutables (which
 *      are embedded in code and remain valid under delegatecall) and never reads or
 *      writes storage, so it cannot corrupt the Converter's storage layout.
 *
 *      Path encoding (Uniswap V3): a tightly packed byte string of
 *      `20 (token) + 3 (uint24 fee) + 20 (token) [+ 3 + 20 ...]`. A valid path is at
 *      least 43 bytes (single hop) and satisfies `(length - 20) % 23 == 0`. Encoding
 *      helpers live in the shared {UniswapV3Path} library.
 *      For the initial release, only single-hop paths are allowed (MAX_PATH_LENGTH = 1).
 *
 *      All entry points — exact-input AND exact-output — take the FORWARD path encoding
 *      `(tokenIn, fee, tokenOut)`. Uniswap V3's `exactOutput()` consumes reverse-encoded
 *      paths, so {swapExactAmountOut} reverses the path internally before calling the
 *      router; callers never deal with the reversed encoding.
 *
 *      ── Quote security model ─────────────────────────────────────────────────────
 *      Quotes are NOT served by the Uniswap Quoter (which simulates against spot pool
 *      state and is trivially movable with a flash loan inside one block). Instead:
 *
 *        1. The mid-price is derived from the pool's TWAP over `twapInterval`
 *           (arithmetic mean tick via `pool.observe()`), which an attacker can only
 *           move by holding a skewed price across the whole window — prohibitively
 *           expensive against arbitrage.
 *        2. The TWAP-implied amount is cross-checked against an independent
 *           Chainlink-based amount (via the protocol Oracle). If the two deviate by
 *           more than `MAX_ORACLE_DEVIATION_BPS`, the quote reverts with
 *           {UniswapV3ConverterAdapterQuoteDeviation}. The comparison is performed on
 *           GROSS (pre-fee) amounts: the pool fee is applied only after the check, so
 *           the fee tier does not consume any of the deviation budget — a perfectly
 *           Chainlink-aligned TWAP passes the check regardless of the fee tier.
 *        3. The returned amount is net of the pool fee (exact-input) / grossed up by
 *           the pool fee (exact-output), so callers can apply their slippage tolerance
 *           directly on top of it.
 *
 *      As a result {quoteExactAmountIn}/{quoteExactAmountOut} are `view` (no Quoter
 *      simulation) and safe to use on-chain as a slippage baseline.
 */
contract UniswapV3ConverterAdapter is IUniswapV3ConverterAdapter {
    using SafeERC20 for IERC20;
    using UniswapV3Path for bytes;

    // ============ Constants ============

    /// @notice Uniswap V3 fee denominator (fees are expressed in hundredths of a bip)
    uint256 private constant _FEE_DENOMINATOR = 1_000_000;

    /// @notice Basis points denominator
    uint256 private constant _BASIS_POINTS = 10_000;

    /// @notice Maximum number of hops allowed. Set to 1 for the initial release.
    ///         Multi-hop support can be added later via a separate adapter.
    uint256 public constant MAX_PATH_LENGTH = 1;

    /// @notice Maximum allowed deviation between the TWAP-implied amount and the
    ///         Chainlink-implied amount (2%). Beyond this, quotes revert. Compared on
    ///         gross (pre-fee) amounts, so the budget is independent of the fee tier.
    uint256 public constant MAX_ORACLE_DEVIATION_BPS = 200;

    /// @notice Minimum TWAP window. Short windows are cheap to manipulate.
    uint32 public constant MIN_TWAP_INTERVAL = 60;

    // ============ State Variables ============

    /// @notice The Uniswap V3 swap router
    IUniswapV3Router public immutable router;

    /// @notice The Uniswap V3 factory used to resolve pools for TWAP quotes
    IUniswapV3Factory public immutable factory;

    /// @notice The protocol Oracle (Chainlink-backed) used to cross-check TWAP quotes
    IOracle public immutable oracle;

    /// @notice The WETH address, mapped to address(0) (native ETH) for Oracle lookups
    address public immutable weth;

    /// @notice TWAP window in seconds used for quotes
    uint32 public immutable twapInterval;

    // ============ Errors ============
    // Errors are declared in {IUniswapV3ConverterAdapter} and inherited.

    // ============ Constructor ============

    constructor(address _router, address _factory, address _oracle, address _weth, uint32 _twapInterval) {
        if (_router == address(0)) revert UniswapV3ConverterAdapterZeroAddress();
        if (_factory == address(0)) revert UniswapV3ConverterAdapterZeroAddress();
        if (_oracle == address(0)) revert UniswapV3ConverterAdapterZeroAddress();
        if (_weth == address(0)) revert UniswapV3ConverterAdapterZeroAddress();
        if (_twapInterval < MIN_TWAP_INTERVAL) revert UniswapV3ConverterAdapterInvalidTwapInterval();

        router = IUniswapV3Router(_router);
        factory = IUniswapV3Factory(_factory);
        oracle = IOracle(_oracle);
        weth = _weth;
        twapInterval = _twapInterval;
    }

    // ============ IConverterAdapter ============

    /**
     * @inheritdoc IConverterAdapter
     */
    function name() external pure override returns (string memory) {
        return "UniswapV3ConverterAdapter";
    }

    /**
     * @inheritdoc IConverterAdapter
     */
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    /**
     * @inheritdoc IConverterAdapter
     */
    function validateRoute(bytes calldata _route) external pure override returns (bool _valid) {
        return _route.isValidPath() && _route.isSingleHop();
    }

    /**
     * @inheritdoc IConverterAdapter
     */
    function routeTokens(bytes calldata _route) external pure override returns (address _tokenIn, address _tokenOut) {
        if (!_route.isValidPath() || !_route.isSingleHop()) revert UniswapV3ConverterAdapterInvalidRoute();
        (_tokenIn,, _tokenOut) = _route.decodeSingleHop();
    }

    /**
     * @inheritdoc IConverterAdapter
     * @dev Flash-loan resistant: priced off the pool TWAP (not spot/Quoter state) and
     *      cross-checked against Chainlink via the protocol Oracle on gross (pre-fee)
     *      amounts. Returns the TWAP-implied output net of the pool fee. Reverts with
     *      {UniswapV3ConverterAdapterQuoteDeviation} if TWAP and Chainlink disagree
     *      by more than MAX_ORACLE_DEVIATION_BPS.
     */
    function quoteExactAmountIn(bytes calldata _route, uint256 _amountIn)
        external
        view
        override
        returns (uint256 _amountOut)
    {
        if (!_route.isValidPath()) revert UniswapV3ConverterAdapterInvalidRoute();
        if (!_route.isSingleHop()) revert UniswapV3ConverterAdapterMultiHopNotSupported();

        (address _tokenIn, uint24 _fee, address _tokenOut) = _route.decodeSingleHop();

        // Both amounts are gross of the pool fee, so the deviation check is not skewed
        // by the fee tier (see contract-level docs).
        uint256 _twapOut = _twapQuote(_tokenIn, _tokenOut, _fee, _amountIn);
        uint256 _oracleOut = _oracleQuote(_tokenIn, _tokenOut, _amountIn);
        _checkDeviation(_twapOut, _oracleOut);

        // Net of the pool fee so callers can apply slippage tolerance directly.
        return _twapOut * (_FEE_DENOMINATOR - _fee) / _FEE_DENOMINATOR;
    }

    /**
     * @inheritdoc IConverterAdapter
     * @dev Same TWAP + Chainlink security model as {quoteExactAmountIn}, inverted: returns
     *      the TWAP-implied input grossed up by the pool fee. Takes the same FORWARD
     *      path encoding as {quoteExactAmountIn}.
     */
    function quoteExactAmountOut(bytes calldata _route, uint256 _amountOut)
        external
        view
        override
        returns (uint256 _amountIn)
    {
        if (!_route.isValidPath()) revert UniswapV3ConverterAdapterInvalidRoute();
        if (!_route.isSingleHop()) revert UniswapV3ConverterAdapterMultiHopNotSupported();

        (address _tokenIn, uint24 _fee, address _tokenOut) = _route.decodeSingleHop();

        // Both amounts are gross of the pool fee (see {quoteExactAmountIn}).
        uint256 _twapIn = _twapQuote(_tokenOut, _tokenIn, _fee, _amountOut);
        uint256 _oracleIn = _oracleQuote(_tokenOut, _tokenIn, _amountOut);
        _checkDeviation(_twapIn, _oracleIn);

        // Gross up by the pool fee: the router will consume fee on the input side.
        return _twapIn * _FEE_DENOMINATOR / (_FEE_DENOMINATOR - _fee);
    }

    /**
     * @inheritdoc IConverterAdapter
     * @dev Executed via DELEGATECALL from the Converter: the input tokens already sit
     *      on `address(this)` (the Converter), so no transferFrom/approve round-trip
     *      through the adapter is needed — a single approval is made directly to the
     *      router and cleared afterwards.
     */
    function swapExactAmountIn(
        bytes calldata _route,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _recipient,
        uint256 _deadline
    ) external override returns (uint256 _amountOut) {
        if (!_route.isValidPath() || !_route.isSingleHop()) revert UniswapV3ConverterAdapterInvalidRoute();

        (address _tokenIn,,) = _route.decodeSingleHop();

        IERC20(_tokenIn).forceApprove(address(router), _amountIn);

        _amountOut = router.exactInput(
            IUniswapV3Router.ExactInputParams({
                path: _route,
                recipient: _recipient,
                amountIn: _amountIn,
                amountOutMinimum: _minAmountOut,
                deadline: _deadline
            })
        );

        // Clear any residual approval (router may consume less than _amountIn for fee-on-transfer tokens).
        IERC20(_tokenIn).forceApprove(address(router), 0);
    }

    /**
     * @inheritdoc IConverterAdapter
     * @dev Executed via DELEGATECALL from the Converter (see {swapExactAmountIn}). Any
     *      unspent input simply remains on `address(this)` (the Converter), which
     *      refunds it to the caller — no explicit refund transfer is needed here.
     *
     *      Takes the same FORWARD path encoding `(tokenIn, fee, tokenOut)` as
     *      {swapExactAmountIn}. Uniswap V3's `exactOutput()` consumes reverse-encoded
     *      paths (first token is the OUTPUT token), so the path is reversed here via
     *      {UniswapV3Path.reverseSingleHop} before being handed to the router.
     */
    function swapExactAmountOut(
        bytes calldata _route,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        address _recipient,
        uint256 _deadline
    ) external override returns (uint256 _amountIn) {
        if (!_route.isValidPath() || !_route.isSingleHop()) revert UniswapV3ConverterAdapterInvalidRoute();

        (address _tokenIn,,) = _route.decodeSingleHop();

        IERC20(_tokenIn).forceApprove(address(router), _amountInMaximum);

        _amountIn = router.exactOutput(
            IUniswapV3Router.ExactOutputParams({
                path: _route.reverseSingleHop(),
                recipient: _recipient,
                amountOut: _amountOut,
                amountInMaximum: _amountInMaximum,
                deadline: _deadline
            })
        );

        // Clear residual approval for any unspent allowance.
        IERC20(_tokenIn).forceApprove(address(router), 0);
    }

    // ============ Internal Helpers ============

    /**
     * @notice Computes the TWAP-implied amount of `_quoteToken` for `_baseAmount` of `_baseToken`
     * @dev Resolves the pool from the factory and derives the arithmetic mean tick
     *      over `twapInterval` via `pool.observe()`. Gross amount — pool fee is NOT applied here.
     */
    function _twapQuote(address _baseToken, address _quoteToken, uint24 _fee, uint256 _baseAmount)
        internal
        view
        returns (uint256)
    {
        address _pool = factory.getPool(_baseToken, _quoteToken, _fee);
        if (_pool == address(0)) revert UniswapV3ConverterAdapterPoolNotFound();

        return
            _quoteAtTick(TickUtils.meanTick(IUniswapV3Pool(_pool), twapInterval), _baseAmount, _baseToken, _quoteToken);
    }

    /**
     * @notice Converts `_baseAmount` of `_baseToken` into `_quoteToken` terms at a given tick
     * @dev Port of Uniswap's OracleLibrary.getQuoteAtTick generalised to uint256 amounts.
     */
    function _quoteAtTick(int24 _tick, uint256 _baseAmount, address _baseToken, address _quoteToken)
        internal
        pure
        returns (uint256)
    {
        uint160 _sqrtRatioX96 = TickMath.getSqrtRatioAtTick(_tick);

        if (_sqrtRatioX96 <= type(uint128).max) {
            uint256 _ratioX192 = uint256(_sqrtRatioX96) * _sqrtRatioX96;
            return _baseToken < _quoteToken
                ? FullMath.mulDiv(_ratioX192, _baseAmount, 1 << 192)
                : FullMath.mulDiv(1 << 192, _baseAmount, _ratioX192);
        }

        uint256 _ratioX128 = FullMath.mulDiv(_sqrtRatioX96, _sqrtRatioX96, 1 << 64);
        return _baseToken < _quoteToken
            ? FullMath.mulDiv(_ratioX128, _baseAmount, 1 << 128)
            : FullMath.mulDiv(1 << 128, _baseAmount, _ratioX128);
    }

    /**
     * @notice Computes the Chainlink-implied amount of `_tokenOut` for `_amountIn` of `_tokenIn`
     * @dev Routes through the protocol Oracle's `convert` (prefers a registered direct/inverted
     *      Token A / Token B pair feed, otherwise a USD cross-rate from both Token / USD feeds,
     *      validated for staleness). WETH is mapped to address(0) (native ETH) for feed lookups.
     */
    function _oracleQuote(address _tokenIn, address _tokenOut, uint256 _amountIn) internal view returns (uint256) {
        return oracle.convert(
            _oracleToken(_tokenIn),
            _oracleToken(_tokenOut),
            _amountIn,
            IERC20Metadata(_tokenIn).decimals(),
            IERC20Metadata(_tokenOut).decimals()
        );
    }

    /**
     * @notice Maps WETH to address(0) (native ETH) for Oracle feed lookups
     */
    function _oracleToken(address _token) internal view returns (address) {
        return _token == weth ? address(0) : _token;
    }

    /**
     * @notice Reverts if the TWAP-implied amount deviates from the Chainlink-implied
     *         amount by more than MAX_ORACLE_DEVIATION_BPS in either direction
     */
    function _checkDeviation(uint256 _twapAmount, uint256 _oracleAmount) internal pure {
        uint256 _floor = _oracleAmount * (_BASIS_POINTS - MAX_ORACLE_DEVIATION_BPS) / _BASIS_POINTS;
        uint256 _ceiling = _oracleAmount * (_BASIS_POINTS + MAX_ORACLE_DEVIATION_BPS) / _BASIS_POINTS;
        if (_twapAmount < _floor || _twapAmount > _ceiling) {
            revert UniswapV3ConverterAdapterQuoteDeviation(_twapAmount, _oracleAmount);
        }
    }
}
