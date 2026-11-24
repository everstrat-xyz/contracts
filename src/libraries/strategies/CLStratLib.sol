// SPDX-License-Identifier: MIT
// Solidity compiles GPL-licensed Uniswap V3 math into this library's bytecode.
// Distribution of the combined build is subject to GPL-2.0-or-later.
pragma solidity ^0.8.30;
// solhint-disable compiler-version, gas-strict-inequalities

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {FixedPoint96} from "../integrations/uniswap/FixedPoint96.sol";
import {FullMath} from "../integrations/uniswap/FullMath.sol";
import {TickMath} from "../integrations/uniswap/TickMath.sol";

import {IConverter} from "../../interfaces/IConverter.sol";
import {IOracle} from "../../interfaces/IOracle.sol";
import {IUniCLStrat} from "../../interfaces/strategies/IUniCLStrat.sol";

/**
 * @title CLStratLib
 * @notice Shared externally linked library holding oracle-bounded swap execution and
 *         inventory-ratio math, so the strategy stays under the EIP-170 runtime size limit.
 * @dev Entry points are `public` on purpose — `internal` library functions are inlined into the
 *      caller and would not shrink the strategy. Public library functions run via DELEGATECALL in
 *      the strategy's context: `address(this)` is the strategy, the Converter sees the strategy as
 *      `msg.sender` (and pulls its tokens under the strategy's own allowances), and reverts carry
 *      the `IUniCLStrat` errors unchanged. The library holds no state and no funds, and its address
 *      is fixed at link time, so it adds no trust surface beyond the strategy bytecode itself.
 */
library CLStratLib {
    using SafeERC20 for IERC20Metadata;

    /// @notice Swap routing / bounds snapshot read from strategy storage at call time.
    struct SwapConfig {
        IConverter converter;
        IOracle oracle;
        address adapter;
        address weth;
        address pairedToken;
        uint256 slippageBps;
    }

    uint256 internal constant BASIS_POINTS = 10_000;
    /// @dev Denominator of Uniswap V3 fee tiers (hundredths of a bip).
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    uint256 internal constant SWAP_DEADLINE_OFFSET = 15 minutes;
    /// @dev Maximum deviation between an adapter quote and the Chainlink-implied amount; see
    ///      `UniCLStrat.MAX_QUOTE_DEVIATION_BPS` for the fee-tier interaction.
    uint256 internal constant MAX_QUOTE_DEVIATION_BPS = 200;

    // ============ Inventory Math ============

    /**
     * @notice Inventory swap that moves idle balances to the value ratio a range needs at spot.
     * @dev For a range [a, b] and spot p (sqrt prices), the token0 : token1 value split in token1
     *      units is `p·(b − p)/b : (p − a)` (all token0 below the range, all token1 above it).
     *      Cost-adjusted: selling Δ of the excess token only adds Δ·(1 − cost) of the other, so
     *      total value drops by cost·Δ and `Δ = excess / (1 − cost·w_sold)`, where `w_sold` is the
     *      target share of the sold token. `_swapCostBps` is the route's measured cost (see
     *      {routeCostBps}), not a fee tier: the route generally does not trade through the strategy
     *      pool. Returns `_amountIn == 0` when the swap value is at or below `_minSwapBps` of the total.
     * @return _sellToken1 True to sell token1 for token0, false to sell token0 for token1
     * @return _amountIn Amount of the sold token (its own units)
     */
    function inventorySwap(
        uint160 _sqrtPriceX96,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _balance0,
        uint256 _balance1,
        uint256 _swapCostBps,
        uint256 _minSwapBps
    ) public pure returns (bool _sellToken1, uint256 _amountIn) {
        (uint256 _weight0, uint256 _weight1) = _valueWeights(_sqrtPriceX96, _tickLower, _tickUpper);
        uint256 _weightSum = _weight0 + _weight1;

        uint256 _value0 = token0InToken1(_balance0, _sqrtPriceX96);
        uint256 _total = _value0 + _balance1;
        if (_total == 0) return (false, 0);

        uint256 _target1 = FullMath.mulDiv(_total, _weight1, _weightSum);
        uint256 _minSwapValue = _total * _minSwapBps / BASIS_POINTS;

        if (_balance1 > _target1) {
            uint256 _swap1 = _costAdjusted(_balance1 - _target1, _weight1, _weightSum, _swapCostBps);
            if (_swap1 > _minSwapValue) return (true, _swap1);
        } else {
            uint256 _target0 = _total - _target1;
            if (_value0 > _target0) {
                uint256 _swap0Value = _costAdjusted(_value0 - _target0, _weight0, _weightSum, _swapCostBps);
                if (_swap0Value > _minSwapValue) return (false, _token1InToken0(_swap0Value, _sqrtPriceX96));
            }
        }
    }

    /**
     * @notice {inventorySwap} sized with the measured cost of the route the swap will actually
     *         trade on ({routeCostBps}), rather than the strategy pool's fee tier.
     * @dev An untradable route is left unadjusted; the swap itself then rejects it with its
     *      specific error.
     * @return _sellWeth True to sell WETH for the paired token, false for the reverse
     * @return _amountIn Amount of the sold token (its own units); 0 when no swap is needed
     */
    function routedInventorySwap(
        SwapConfig memory _config,
        bytes memory _wethToPairedPath,
        bytes memory _pairedToWethPath,
        address _token0,
        uint160 _sqrtPriceX96,
        IUniCLStrat.Position memory _range,
        uint256 _balance0,
        uint256 _balance1,
        uint256 _minSwapBps
    ) public returns (bool _sellWeth, uint256 _amountIn) {
        bool _sellToken1;
        (_sellToken1, _amountIn) =
            inventorySwap(_sqrtPriceX96, _range.tickLower, _range.tickUpper, _balance0, _balance1, 0, _minSwapBps);
        if (_amountIn == 0) return (false, 0);

        _sellWeth = (_token0 == _config.weth) != _sellToken1;
        (bool _tradable, uint256 _costBps) =
            routeCostBps(_config, _sellWeth ? _wethToPairedPath : _pairedToWethPath, _amountIn, false);
        if (_tradable && _costBps > 0) {
            (, _amountIn) = inventorySwap(
                _sqrtPriceX96, _range.tickLower, _range.tickUpper, _balance0, _balance1, _costBps, _minSwapBps
            );
        }
    }

    /// @notice Value of `_amount0` token0 in token1 units at `_sqrtPriceX96`.
    function token0InToken1(uint256 _amount0, uint160 _sqrtPriceX96) public pure returns (uint256) {
        return
            FullMath.mulDiv(FullMath.mulDiv(_amount0, _sqrtPriceX96, FixedPoint96.Q96), _sqrtPriceX96, FixedPoint96.Q96);
    }

    function _token1InToken0(uint256 _amount1, uint160 _sqrtPriceX96) private pure returns (uint256) {
        return
            FullMath.mulDiv(FullMath.mulDiv(_amount1, FixedPoint96.Q96, _sqrtPriceX96), FixedPoint96.Q96, _sqrtPriceX96);
    }

    /// @dev Token0 : token1 value weights (token1 units, sqrtX96 scale) of range [lower, upper] at spot.
    function _valueWeights(uint160 _sqrtPriceX96, int24 _tickLower, int24 _tickUpper)
        private
        pure
        returns (uint256 _weight0, uint256 _weight1)
    {
        uint160 _sqrtA = TickMath.getSqrtRatioAtTick(_tickLower);
        uint160 _sqrtB = TickMath.getSqrtRatioAtTick(_tickUpper);
        if (_sqrtPriceX96 <= _sqrtA) return (1, 0);
        if (_sqrtPriceX96 >= _sqrtB) return (0, 1);
        _weight0 = FullMath.mulDiv(_sqrtPriceX96, _sqrtB - _sqrtPriceX96, _sqrtB);
        _weight1 = _sqrtPriceX96 - _sqrtA;
    }

    /// @dev `excess / (1 − cost·weightSold/weightSum)`
    function _costAdjusted(uint256 _excess, uint256 _weightSold, uint256 _weightSum, uint256 _costBps)
        private
        pure
        returns (uint256)
    {
        uint256 _denominator = BASIS_POINTS * _weightSum;
        return FullMath.mulDiv(_excess, _denominator, _denominator - _costBps * _weightSold);
    }

    // ============ Oracle-Bounded Swaps ============

    /**
     * @notice Swaps `_amountIn` along `_path` via the shared Converter, using an on-chain
     *         quote as the base for slippage protection.
     *
     * @dev ── Security model for the on-chain quote ──────────────────────────────────
     *      swapExactIn derives `_minAmountOut` from `converter.quoteSwapExactAmountIn()`. The quote
     *      and the swap execute ATOMICALLY in the same transaction (same block, same
     *      `block.timestamp`), so the quote-then-swap pattern on its own provides no
     *      protection against same-block pool manipulation: an attacker who can move the
     *      quote source before this transaction executes (a flash loan in the same block,
     *      or a miner/builder ordering attack) moves the derived `_minAmountOut` along
     *      with the execution price. The layers below are what make the pattern safe,
     *      NOT the quote itself:
     *
     *      0. **TWAP-based quote source**: the UniswapV3ConverterAdapter prices off the
     *         pool TWAP cross-checked against Chainlink — neither input is movable within
     *         a single block, so a same-block manipulation cannot drag the quote (and
     *         hence `_minAmountOut`) toward a manipulated execution price. Other adapters
     *         may quote from spot pool state, which is why the strategy keeps its own
     *         adapter-agnostic defence layers (1–3 below).
     *
     *      1. **Calm-period guard** (`_isCalm`): a *caller-path* check, not
     *         enforced in this helper. Minting callers (`deposit` /
     *         `investIdleETH` / `rebalance`, and the re-add branch of
     *         `withdraw`) require calm before inventory swaps. `withdraw` →
     *         {tryTopUpWeth} reaches this helper while the pool may be
     *         dislocated; layers 0, 2, and 3 carry that path. Rationale:
     *         `docs/STRATEGY_GUARDRAILS.md` §1.1.1.
     *
     *      2. **Slippage cap** (`MAX_SWAP_SLIPPAGE_BPS = 200`): even against a
     *         manipulated quote, the minimum output floor caps the loss at 2 % of the
     *         quoted amount.
     *
     *      3. **Oracle bounds** (`MAX_QUOTE_DEVIATION_BPS = 200`): the quoted amount is
     *         cross-referenced against an independent price source (Chainlink) to detect
     *         quote manipulation in any swap pool (not just the strategy pool).  Both an
     *         upper and a lower bound are enforced symmetrically — a quote below the floor
     *         or above the ceiling reverts.  This layer does not rely on pool state and
     *         is enforced here even when the adapter performs its own oracle cross-check.
     *
     *      ── Fee interaction with the oracle bounds ──────────────────────────────────────
     *      Adapter quotes are net of the DEX pool fee, while the Chainlink reference is a
     *      gross mid-price. Even with TWAP and Chainlink perfectly aligned, the quote sits
     *      `fee tier` bps below the oracle amount, consuming part of the floor budget.
     *      MAX_QUOTE_DEVIATION_BPS (200) therefore must exceed the route's fee tier — see
     *      the constant's documentation.
     *     ────────────────────────────────────────────────────────────────────────────
     *
     *      A per-swap deadline (`block.timestamp + SWAP_DEADLINE_OFFSET`) is forwarded to
     *      the Converter/router, but it is NOT a defence layer: it is computed from
     *      `block.timestamp` at execution time, so it can never expire within this
     *      transaction. It only satisfies the router interface.
     */
    function swapExactIn(SwapConfig memory _config, bytes memory _path, uint256 _amountIn)
        public
        returns (uint256 _amountOut)
    {
        if (_amountIn == 0) return 0;

        IConverter _converter = _config.converter;

        uint256 _quotedAmount;
        try _converter.quoteSwapExactAmountIn(_config.adapter, _path, _amountIn) returns (uint256 _result) {
            _quotedAmount = _result;
        } catch {
            revert IUniCLStrat.UniCLStratQuoteFailed();
        }

        // Oracle sanity bounds: reject quotes that deviate too far from the
        // Chainlink mid-price in either direction. Both floors and ceilings catch
        // flash-loan-assisted manipulation of the quote pool (which may be a different
        // fee tier than the strategy pool).
        uint256 _oracleAmountOut = _calculateOracleAmountOut(_config, _path, _amountIn);
        _enforceOracleBounds(_quotedAmount, _oracleAmountOut);

        uint256 _minAmountOut = _quotedAmount * (BASIS_POINTS - _config.slippageBps) / BASIS_POINTS;

        _amountOut = _converter.executeSwapExactAmountIn(
            _config.adapter, _path, _amountIn, _minAmountOut, block.timestamp + SWAP_DEADLINE_OFFSET
        );
    }

    /**
     * @notice Measures what trading `_amount` along `_path` actually costs, against the oracle.
     * @dev The route is configured independently of the strategy pool (another fee tier, a
     *      multi-hop path, or a non-Uniswap adapter), so its cost cannot be read off the strategy
     *      pool's fee tier. Exact-input (`_exactOut == false`, `_amount` is the input): cost is the
     *      quoted output's shortfall vs the oracle output. Exact-output (`_amount` is the output):
     *      cost is the quoted input's excess over the oracle input. Captures route fees, price
     *      impact and route-vs-oracle drift; rounded up, and 0 when the route beats the oracle.
     *      Never reverts on a bad route: `_tradable` is false when the quote fails or falls outside
     *      the {MAX_QUOTE_DEVIATION_BPS} band, i.e. exactly when {swapExactIn} / {swapExactOut}
     *      would refuse the trade.
     */
    function routeCostBps(SwapConfig memory _config, bytes memory _path, uint256 _amount, bool _exactOut)
        public
        returns (bool _tradable, uint256 _costBps)
    {
        if (_amount == 0) return (true, 0);

        uint256 _quoted;
        uint256 _oracle;
        if (_exactOut) {
            try _config.converter.quoteSwapExactAmountOut(_config.adapter, _path, _amount) returns (uint256 _result) {
                _quoted = _result;
            } catch {
                return (false, 0);
            }
            _oracle = _calculateOracleAmountIn(_config, _path, _amount);
        } else {
            try _config.converter.quoteSwapExactAmountIn(_config.adapter, _path, _amount) returns (uint256 _result) {
                _quoted = _result;
            } catch {
                return (false, 0);
            }
            _oracle = _calculateOracleAmountOut(_config, _path, _amount);
        }
        if (_oracle == 0) return (false, 0);

        _tradable = _withinOracleBounds(_quoted, _oracle);
        uint256 _loss =
            _exactOut ? (_quoted > _oracle ? _quoted - _oracle : 0) : (_oracle > _quoted ? _oracle - _quoted : 0);
        _costBps = (_loss * BASIS_POINTS + _oracle - 1) / _oracle;
    }

    function _withinOracleBounds(uint256 _quoted, uint256 _oracleAmount) private pure returns (bool) {
        return _quoted >= _oracleAmount * (BASIS_POINTS - MAX_QUOTE_DEVIATION_BPS) / BASIS_POINTS
            && _quoted <= _oracleAmount * (BASIS_POINTS + MAX_QUOTE_DEVIATION_BPS) / BASIS_POINTS;
    }

    /**
     * @notice Reverts when a DEX-quoted amount deviates from the oracle-implied amount by more
     *         than `MAX_QUOTE_DEVIATION_BPS` in either direction.
     * @dev Shared by both swap directions. For exact-input swaps `_quoted`/`_oracleAmount` are
     *      output amounts; for exact-output swaps they are input amounts. The symmetric
     *      floor/ceiling band is direction-agnostic, so a single helper serves both. Reverts
     *      with {UniCLStratQuoteBelowOracleFloor} or {UniCLStratQuoteExceedsOracleCeiling}.
     * @param _quoted The amount returned by the DEX adapter quote
     * @param _oracleAmount The independent oracle-implied amount to bound against
     */
    function _enforceOracleBounds(uint256 _quoted, uint256 _oracleAmount) private pure {
        uint256 _oracleFloor = _oracleAmount * (BASIS_POINTS - MAX_QUOTE_DEVIATION_BPS) / BASIS_POINTS;
        uint256 _oracleCeiling = _oracleAmount * (BASIS_POINTS + MAX_QUOTE_DEVIATION_BPS) / BASIS_POINTS;
        if (_quoted < _oracleFloor) {
            revert IUniCLStrat.UniCLStratQuoteBelowOracleFloor(_quoted, _oracleAmount);
        }
        if (_quoted > _oracleCeiling) {
            revert IUniCLStrat.UniCLStratQuoteExceedsOracleCeiling(_quoted, _oracleAmount);
        }
    }

    /**
     * @notice Computes the fair expected swap output using the protocol oracle (Chainlink)
     *         as an independent price source, decoupled from any DEX pool state.
     * @dev Decodes the output token from the DEX route path and derives the oracle-based
     *      expected amount via the protocol's ETH/USD and token/USD price feeds.
     *      The path encoding is adapter-specific; this function extracts the last 20 bytes
     *      which, for Uniswap V3 packed encoding, is always the final output token.
     * @param _config Swap routing snapshot (Converter, Oracle, adapter, tokens, slippage)
     * @param _path Adapter-specific route bytes
     * @param _amountIn The input amount for the swap
     * @return _oracleAmountOut The oracle-based fair output amount in token decimals
     */
    function _calculateOracleAmountOut(SwapConfig memory _config, bytes memory _path, uint256 _amountIn)
        private
        view
        returns (uint256 _oracleAmountOut)
    {
        // Decode the output token using the adapter-agnostic helper rather than
        // assuming a specific path encoding (Uniswap V3 packed, etc.).  This keeps
        // the oracle ceiling correct even if setRouteConfig is called with a
        // non-Uniswap adapter (Curve, Balancer, etc.).
        (, address _outToken) = _config.converter.routeTokens(_config.adapter, _path);

        if (_outToken == _config.weth) {
            // pairedToken -> WETH: compute pairedToken value in ETH using oracle
            return _tokenValueInETH(_config, _config.pairedToken, _amountIn);
        } else {
            // WETH -> pairedToken: compute WETH value in pairedToken using oracle
            return _ethValueToTokenAmount(_config, _outToken, _amountIn);
        }
    }

    /**
     * @notice Swaps along `_path` for exactly `_amountOut` of the output token via the
     *         shared Converter, with an oracle-bounded, slippage-padded input cap.
     *
     * @dev Symmetric counterpart of {swapExactIn} — the same
     *      in-helper security model applies (TWAP-based quote, slippage cap,
     *      oracle bounds), mirrored onto the input side: the quoted required
     *      input is checked against the Chainlink-implied input, and the
     *      slippage tolerance pads the input MAXIMUM instead of flooring the
     *      output minimum. The calm-period guard is a caller-path check, not
     *      enforced here; {tryTopUpWeth} (withdraw) is the intended non-calm caller and runs
     *      this helper inside a try/catch, so a revert here skips the conversion rather than
     *      blocking the payout.
     *
     *      Balance-cap fallback: if the slippage-padded maximum input exceeds the
     *      strategy's balance of the input token, the exact output is unaffordable.
     *      Instead of reverting, the function falls back to a best-effort exact-input
     *      swap of the whole input-token balance — the same "cap the input at the
     *      available balance" pattern used by `UniCLStrat._swapWethToPairedToken` and
     *      `UniCLStrat._swapPairedTokenToWeth`.
     *
     * @param _path Adapter-specific route bytes (forward encoding, same as exact-input)
     * @param _amountOut The exact output amount desired
     * @return _amountIn The input amount actually spent
     */
    function swapExactOut(SwapConfig memory _config, bytes memory _path, uint256 _amountOut)
        public
        returns (uint256 _amountIn)
    {
        if (_amountOut == 0) return 0;

        IConverter _converter = _config.converter;

        uint256 _quotedAmountIn;
        try _converter.quoteSwapExactAmountOut(_config.adapter, _path, _amountOut) returns (uint256 _result) {
            _quotedAmountIn = _result;
        } catch {
            revert IUniCLStrat.UniCLStratQuoteFailed();
        }

        // Oracle sanity bounds on the required input (mirror of swapExactIn's output
        // bounds): a quote demanding too much input (above the ceiling) overprices the
        // swap; one demanding too little (below the floor) signals a manipulated quote.
        uint256 _oracleAmountIn = _calculateOracleAmountIn(_config, _path, _amountOut);
        _enforceOracleBounds(_quotedAmountIn, _oracleAmountIn);

        uint256 _maxAmountIn = _quotedAmountIn * (BASIS_POINTS + _config.slippageBps) / BASIS_POINTS;

        (address _inToken,) = _converter.routeTokens(_config.adapter, _path);
        uint256 _inBalance = IERC20Metadata(_inToken).balanceOf(address(this));

        // Balance-cap fallback: the exact output is unaffordable — swap the whole
        // input-token balance best-effort via the exact-input path instead.
        if (_maxAmountIn > _inBalance) {
            swapExactIn(_config, _path, _inBalance);
            return _inBalance;
        }

        return _converter.executeSwapExactAmountOut(
            _config.adapter, _path, _amountOut, _maxAmountIn, block.timestamp + SWAP_DEADLINE_OFFSET
        );
    }

    /// @notice Attempts to convert all remaining paired tokens after a near-full withdrawal.
    function drainPairedToWeth() public {
        _tryConvertToWeth(0);
    }

    /**
     * @notice Attempts to reach `_targetWethBalance` by buying the WETH shortfall with paired tokens.
     * @dev Runs {swapExactOut} through the strategy's self-only hook
     *      `IUniCLStrat.selfConvertToWeth` inside a try/catch: if the route cannot be traded
     *      (quote fails, or is outside the oracle band) or the swap reverts, the paired token
     *      stays in the strategy (still in NAV) and `withdraw` pays out the WETH it already
     *      has instead of reverting the whole payout (audit G7). Emits
     *      `IUniCLStrat.WethConversionSkipped` from the strategy (delegatecall context). The
     *      catch is parameterless so a hostile route cannot grief with a returndata bomb.
     * @param _weth WETH address
     * @param _targetWethBalance WETH balance to reach
     */
    function tryTopUpWeth(address _weth, uint256 _targetWethBalance) public {
        uint256 _wethBalance = IERC20Metadata(_weth).balanceOf(address(this));
        if (_wethBalance >= _targetWethBalance) return;

        _tryConvertToWeth(_targetWethBalance - _wethBalance);
    }

    function _tryConvertToWeth(uint256 _amountOut) private {
        try IUniCLStrat(address(this)).selfConvertToWeth(_amountOut) {}
        catch {
            emit IUniCLStrat.WethConversionSkipped();
        }
    }

    /**
     * @notice Computes the fair required swap input for an exact output using the protocol
     *         oracle (Chainlink) as an independent price source.
     * @dev Input-side mirror of {_calculateOracleAmountOut}: decodes the input token from the
     *      route via the adapter-agnostic helper and converts the desired output amount
     *      into input-token terms through the oracle cross-rate.
     * @param _config Swap routing snapshot (Converter, Oracle, adapter, tokens, slippage)
     * @param _path Adapter-specific route bytes
     * @param _amountOut The desired output amount of the swap
     * @return _oracleAmountIn The oracle-based fair input amount in token decimals
     */
    function _calculateOracleAmountIn(SwapConfig memory _config, bytes memory _path, uint256 _amountOut)
        private
        view
        returns (uint256 _oracleAmountIn)
    {
        (address _inToken,) = _config.converter.routeTokens(_config.adapter, _path);

        if (_inToken == _config.weth) {
            // WETH -> pairedToken: required WETH input equals the ETH value of the output
            return _tokenValueInETH(_config, _config.pairedToken, _amountOut);
        } else {
            // pairedToken -> WETH: required pairedToken input for the ETH-denominated output
            return _ethValueToTokenAmount(_config, _inToken, _amountOut);
        }
    }

    // ============ Configuration Validation ============

    /// @notice Reverts unless the adapter/routes are valid WETH <-> paired-token routes on the Converter.
    function validateRouteConfig(
        IConverter _converter,
        address _swapAdapter,
        bytes memory _wethToPairedTokenPath,
        bytes memory _pairedTokenToWethPath,
        address _weth,
        address _pairedToken
    ) public view {
        if (_swapAdapter == address(0)) revert IUniCLStrat.UniCLStratInvalidRouteConfig();
        if (_swapAdapter.code.length == 0) revert IUniCLStrat.UniCLStratInvalidRouteConfig();
        if (!_converter.validateRoute(_swapAdapter, _wethToPairedTokenPath)) {
            revert IUniCLStrat.UniCLStratInvalidRouteConfig();
        }
        if (!_converter.validateRoute(_swapAdapter, _pairedTokenToWethPath)) {
            revert IUniCLStrat.UniCLStratInvalidRouteConfig();
        }

        (address _tokenIn, address _tokenOut) = _converter.routeTokens(_swapAdapter, _wethToPairedTokenPath);
        if (_tokenIn != _weth || _tokenOut != _pairedToken) revert IUniCLStrat.UniCLStratInvalidRouteConfig();

        (_tokenIn, _tokenOut) = _converter.routeTokens(_swapAdapter, _pairedTokenToWethPath);
        if (_tokenIn != _pairedToken || _tokenOut != _weth) revert IUniCLStrat.UniCLStratInvalidRouteConfig();
    }

    // ============ Alt Position ============

    /**
     * @notice Which token dominates the caller's idle balances, compared in token1 units at spot.
     * @return _hasLeftover False when the dominant side is at or below `_minValue`
     * @return _leftoverIsToken1 True when token1 dominates
     */
    function leftoverSide(address _token0, address _token1, uint160 _sqrtPriceX96, uint256 _minValue)
        public
        view
        returns (bool _hasLeftover, bool _leftoverIsToken1)
    {
        uint256 _value0 = token0InToken1(IERC20Metadata(_token0).balanceOf(address(this)), _sqrtPriceX96);
        uint256 _value1 = IERC20Metadata(_token1).balanceOf(address(this));
        _leftoverIsToken1 = _value1 > _value0;
        _hasLeftover = (_leftoverIsToken1 ? _value1 : _value0) > _minValue;
    }

    // ============ Emergency ============

    /**
     * @notice Best-effort transfer of the caller's (`address(this)`) whole `_token` balance to `_to`.
     * @dev Returns false instead of reverting when `balanceOf` reverts or the transfer fails, so a
     *      paused / blacklisted token cannot roll back the caller's ETH sweep. Parameterless catch
     *      (returndata-bomb safe); {SafeERC20-trySafeTransfer} rather than try/catch on `transfer`,
     *      since empty returndata from USDT-style tokens cannot be decoded as `bool` and would
     *      revert outside catch scope. A zero balance is a successful no-op.
     */
    function trySweepToken(address _token, address _to) public returns (bool) {
        try IERC20Metadata(_token).balanceOf(address(this)) returns (uint256 _balance) {
            return _balance == 0 || IERC20Metadata(_token).trySafeTransfer(_to, _balance);
        } catch {
            return false;
        }
    }

    // ============ Valuation ============

    /// @notice Gross oracle ETH value of `_amount0` token0 plus `_amount1` token1 (no exit-cost deduction).
    function pairValueInETH(
        IOracle _oracle,
        address _weth,
        address _token0,
        address _token1,
        uint256 _amount0,
        uint256 _amount1
    ) public view returns (uint256) {
        return _valueInETH(_oracle, _weth, _token0, _amount0) + _valueInETH(_oracle, _weth, _token1, _amount1);
    }

    /**
     * @notice ETH value of the pair net of the estimated cost of converting the paired token to WETH.
     * @dev Exit-cost deduction (audit G2): every payout leaves the strategy as ETH, so the
     *      paired-token share of the inventory must be swapped before it can be redeemed. Marking
     *      it at the gross oracle price would let a redeemer exit at a price that ignores that
     *      cost and leave it with the holders who remain. The paired-token value is therefore
     *      marked down by the configured route fee estimate plus the strategy's slippage
     *      tolerance, rounded up to the nearest wei. WETH is valued at its 1:1 unwrap rate.
     * @param _exitRouteFeePips Estimated paired-token to WETH route fee in parts per million
     * @param _slippageBps The strategy's swap slippage tolerance (bps)
     */
    function adjustedPairValueInETH(
        IOracle _oracle,
        address _weth,
        address _token0,
        address _token1,
        uint256 _amount0,
        uint256 _amount1,
        uint256 _exitRouteFeePips,
        uint256 _slippageBps
    ) public view returns (uint256) {
        uint256 _value0 = _valueInETH(_oracle, _weth, _token0, _amount0);
        uint256 _value1 = _valueInETH(_oracle, _weth, _token1, _amount1);
        uint256 _pairedValue = _token0 == _weth ? _value1 : _value0;
        return _value0 + _value1 - exitCostInETH(_pairedValue, _exitRouteFeePips, _slippageBps);
    }

    /**
     * @notice Estimated ETH cost of converting `_pairedValue` (ETH terms) of paired token to WETH:
     *         `_exitRouteFeePips` plus `_slippageBps`, rounded up.
     * @dev The deployment supplies the fee estimate because routes use adapter-specific encodings.
     */
    function exitCostInETH(uint256 _pairedValue, uint256 _exitRouteFeePips, uint256 _slippageBps)
        public
        pure
        returns (uint256)
    {
        if (_pairedValue == 0) return 0;
        uint256 _costPips = _exitRouteFeePips + _slippageBps * (FEE_DENOMINATOR / BASIS_POINTS);
        return (_pairedValue * _costPips + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;
    }

    /// @notice Gross oracle value in ETH of the paired token.
    function pairedValueInETH(IOracle _oracle, address _pairedToken, uint256 _amount) public view returns (uint256) {
        if (_amount == 0) return 0;
        // Direct token -> ETH cross-rate (single rounding step, both feeds staleness-checked).
        return _oracle.convert(_pairedToken, address(0), _amount, IERC20Metadata(_pairedToken).decimals(), 18);
    }

    function _valueInETH(IOracle _oracle, address _weth, address _token, uint256 _amount)
        private
        view
        returns (uint256)
    {
        if (_token == _weth) return _amount;
        return pairedValueInETH(_oracle, _token, _amount);
    }

    function _tokenValueInETH(SwapConfig memory _config, address _token, uint256 _amount)
        private
        view
        returns (uint256)
    {
        return _valueInETH(_config.oracle, _config.weth, _token, _amount);
    }

    function _ethValueToTokenAmount(SwapConfig memory _config, address _token, uint256 _ethAmount)
        private
        view
        returns (uint256)
    {
        if (_ethAmount == 0) return 0;
        if (_token == _config.weth) return _ethAmount;
        // Direct ETH -> token cross-rate (single rounding step, both feeds staleness-checked).
        return _config.oracle.convert(address(0), _token, _ethAmount, 18, IERC20Metadata(_token).decimals());
    }
}
