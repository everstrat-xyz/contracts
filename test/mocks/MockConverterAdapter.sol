// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, gas-custom-errors
// solhint-disable gas-strict-inequalities, immutable-vars-naming, one-contract-per-file
pragma solidity ^0.8.30;

import {IConverterAdapter} from "../../src/interfaces/IConverterAdapter.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockWETH} from "./UniCLStratMocks.sol";

/// @notice Configurable adapter mock for exercising the Converter's dispatch in negative
///         and edge-case scenarios. Uses the Uniswap V3 packed-path encoding for token decoding and
///         mints output tokens (1:1 by default) so swaps can be driven without a live DEX.
/// @dev swap/swapExactAmountOut are executed via DELEGATECALL from the Converter, where direct
///      storage reads would hit the Converter's storage instead of this mock's. The `_self`
///      immutable (embedded in code, valid under delegatecall) lets the delegatecalled code
///      read this mock's own configuration through external calls to its public getters.
contract MockConverterAdapter is IConverterAdapter {
    uint256 public constant ONE = 1e18;
    uint256 private constant _ADDR_SIZE = 20;

    MockWETH public immutable weth;
    MockERC20 public immutable pairedToken;
    MockConverterAdapter private immutable _self;

    bool public validateRouteResult = true;
    bool public shouldRevertSwap;
    bool public shouldRevertSwapExactOutput;
    bool public shouldRevertQuote;
    bool public shouldRevertRouteTokens;
    uint256 public outputMultiplier = ONE;
    uint256 public quoteMultiplier = ONE;
    // Scales the output actually minted by `swapExactAmountOut` relative to the requested
    // `_amountOut` (ONE = exact). Values < ONE simulate a misreporting adapter that produces
    // less than promised, exercising the Converter's output balance-delta guard.
    uint256 public exactOutputMintMultiplier = ONE;

    constructor(MockWETH _weth, MockERC20 _pairedToken) {
        weth = _weth;
        pairedToken = _pairedToken;
        _self = this;
    }

    function setValidateRouteResult(bool _result) external {
        validateRouteResult = _result;
    }

    function setShouldRevertSwap(bool _shouldRevert) external {
        shouldRevertSwap = _shouldRevert;
    }

    function setShouldRevertSwapExactOutput(bool _shouldRevert) external {
        shouldRevertSwapExactOutput = _shouldRevert;
    }

    function setShouldRevertQuote(bool _shouldRevert) external {
        shouldRevertQuote = _shouldRevert;
    }

    function setShouldRevertRouteTokens(bool _shouldRevert) external {
        shouldRevertRouteTokens = _shouldRevert;
    }

    function setOutputMultiplier(uint256 _multiplier) external {
        outputMultiplier = _multiplier;
    }

    function setQuoteMultiplier(uint256 _multiplier) external {
        quoteMultiplier = _multiplier;
    }

    function setExactOutputMintMultiplier(uint256 _multiplier) external {
        exactOutputMintMultiplier = _multiplier;
    }

    function name() external pure override returns (string memory) {
        return "MockConverterAdapter";
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    function validateRoute(bytes calldata) external view override returns (bool) {
        return validateRouteResult;
    }

    function routeTokens(bytes calldata _route) external view override returns (address _tokenIn, address _tokenOut) {
        if (shouldRevertRouteTokens) revert("ROUTE_TOKENS_FAILED");
        _tokenIn = address(bytes20(_route[0:_ADDR_SIZE]));
        _tokenOut = address(bytes20(_route[_route.length - _ADDR_SIZE:_route.length]));
    }

    function quoteExactAmountIn(bytes calldata, uint256 _amountIn) external view override returns (uint256) {
        if (shouldRevertQuote) revert("QUOTE_FAILED");
        return _amountIn * quoteMultiplier / ONE;
    }

    function quoteExactAmountOut(bytes calldata, uint256 _amountOut) external view override returns (uint256) {
        if (shouldRevertQuote) revert("QUOTE_FAILED");
        return _amountOut * ONE / quoteMultiplier;
    }

    /// @dev Delegatecall context: input tokens already sit on address(this) (the Converter);
    ///      the mock just mints the output to the recipient. Config is read via `_self`.
    function swapExactAmountIn(bytes calldata _route, uint256 _amountIn, uint256, address _recipient, uint256)
        external
        override
        returns (uint256 _amountOut)
    {
        MockConverterAdapter _config = _self;
        if (_config.shouldRevertSwap()) revert("SWAP_FAILED");

        address _tokenOut = address(bytes20(_route[_route.length - _ADDR_SIZE:_route.length]));

        _amountOut = _amountIn * _config.outputMultiplier() / ONE;
        MockERC20(_tokenOut).mint(_recipient, _amountOut);
    }

    /// @dev Delegatecall context: unspent input remains on address(this) (the Converter).
    ///      The consumed input is transferred out to this mock (simulating the DEX router
    ///      pulling payment) so the Converter's balance-delta spend measurement sees it.
    function swapExactAmountOut(
        bytes calldata _route,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        address _recipient,
        uint256
    ) external override returns (uint256 _amountIn) {
        MockConverterAdapter _config = _self;
        if (_config.shouldRevertSwapExactOutput()) revert("SWAP_EXACT_OUTPUT_FAILED");

        address _tokenIn = address(bytes20(_route[0:_ADDR_SIZE]));
        address _tokenOut = address(bytes20(_route[_route.length - _ADDR_SIZE:_route.length]));

        _amountIn = _amountInMaximum * ONE / _config.outputMultiplier();
        MockERC20(_tokenIn).transfer(address(_config), _amountIn);
        MockERC20(_tokenOut).mint(_recipient, _amountOut * _config.exactOutputMintMultiplier() / ONE);
    }
}
