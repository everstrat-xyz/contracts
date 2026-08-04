// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, one-contract-per-file
// solhint-disable immutable-vars-naming, named-parameters-mapping, gas-custom-errors, gas-strict-inequalities
// solhint-disable gas-calldata-parameters
pragma solidity ^0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWETH} from "../../src/interfaces/integrations/IWETH.sol";
import {IConverter} from "../../src/interfaces/IConverter.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockWETH} from "./UniCLStratMocks.sol";

contract MockConverter is IConverter {
    using SafeERC20 for IERC20Metadata;

    MockWETH internal immutable mockWeth;
    MockERC20 public immutable pairedToken;
    address public strategyManager;

    bytes public wethToPairedTokenPath;
    bytes public pairedTokenToWethPath;

    bool public wrapShouldRevert;
    bool public unwrapShouldRevert;
    bool public swapShouldRevert;
    bool public quoteShouldRevert;

    /// @notice When > 0, overrides the default 1:1 quote with a multiplier (in bps).
    ///         Used to simulate inflated quotes that exceed the oracle ceiling.
    uint256 public quoteMultiplierBps;

    mapping(address => bool) public callerRoleGranted;
    mapping(address => bool) private _allowedAdapters;
    bool private _paused;

    // Track calls for test assertions
    uint256 public lastExecuteSwapExactAmountOutCall;

    constructor(MockWETH _weth, MockERC20 _pairedToken, address _strategyManager) {
        mockWeth = _weth;
        pairedToken = _pairedToken;
        strategyManager = _strategyManager;
        wethToPairedTokenPath = abi.encodePacked(address(_weth), uint24(3000), address(_pairedToken));
        pairedTokenToWethPath = abi.encodePacked(address(_pairedToken), uint24(3000), address(_weth));
    }

    function weth() external view override returns (address) {
        return address(mockWeth);
    }

    /// @notice Allows the StrategyManager test to wire itself in for role-gating validation
    function setStrategyManager(address _strategyManager) external {
        strategyManager = _strategyManager;
    }

    function setWrapShouldRevert(bool _shouldRevert) external {
        wrapShouldRevert = _shouldRevert;
    }

    function setUnwrapShouldRevert(bool _shouldRevert) external {
        unwrapShouldRevert = _shouldRevert;
    }

    function setSwapShouldRevert(bool _shouldRevert) external {
        swapShouldRevert = _shouldRevert;
    }

    function setQuoteMultiplierBps(uint256 _bps) external {
        quoteMultiplierBps = _bps;
    }

    function setQuoteShouldRevert(bool _shouldRevert) external {
        quoteShouldRevert = _shouldRevert;
    }

    receive() external payable {}

    function routeTokens(address, bytes calldata _path)
        external
        pure
        override
        returns (address tokenIn, address tokenOut)
    {
        if (_path.length < 43) revert("CONVERTER_INVALID_ROUTE");
        tokenIn = address(bytes20(_path[0:20]));
        tokenOut = address(bytes20(_path[_path.length - 20:]));
    }

    function grantCallerRole(address _account) external override {
        if (msg.sender != strategyManager) revert("UNAUTHORIZED");
        callerRoleGranted[_account] = true;
    }

    function revokeCallerRole(address _account) external override {
        if (msg.sender != strategyManager) revert("UNAUTHORIZED");
        callerRoleGranted[_account] = false;
    }

    function isCaller(address _account) external view override returns (bool) {
        return callerRoleGranted[_account];
    }

    function executeSwapExactAmountIn(address, bytes calldata _path, uint256 _amountIn, uint256, uint256)
        external
        override
        returns (uint256)
    {
        if (swapShouldRevert) revert("CONVERTER_SWAP_FAILED");
        if (_path.length < 43) revert("CONVERTER_INVALID_ROUTE");
        address _tokenIn = address(bytes20(_path[0:20]));
        address _tokenOut = address(bytes20(_path[_path.length - 20:]));
        if (_tokenIn == address(mockWeth) && _tokenOut == address(pairedToken)) {
            IERC20Metadata(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
            pairedToken.mint(msg.sender, _amountIn);
            return _amountIn;
        }
        if (_tokenIn == address(pairedToken) && _tokenOut == address(mockWeth)) {
            IERC20Metadata(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
            mockWeth.mint(msg.sender, _amountIn);
            return _amountIn;
        }
        return 0;
    }

    function executeSwapExactAmountOut(
        address,
        bytes calldata _path,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint256
    ) external override returns (uint256 _amountIn) {
        if (swapShouldRevert) revert("CONVERTER_SWAP_FAILED");
        if (_path.length < 43) revert("CONVERTER_INVALID_ROUTE");
        lastExecuteSwapExactAmountOutCall++;
        address _tokenIn = address(bytes20(_path[0:20]));
        address _tokenOut = address(bytes20(_path[_path.length - 20:]));
        // 1:1 mock price (scaled by quoteMultiplierBps when set): consume only the input
        // actually needed, mirroring the real Converter's surplus refund behaviour.
        _amountIn = quoteMultiplierBps > 0 ? _amountOut * 10_000 / quoteMultiplierBps : _amountOut;
        require(_amountIn <= _amountInMaximum, "CONVERTER_EXCESSIVE_INPUT");
        IERC20Metadata(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        MockERC20(_tokenOut).mint(msg.sender, _amountOut);
    }

    function quoteSwapExactAmountIn(address, bytes calldata _path, uint256 _amountIn)
        external
        override
        returns (uint256)
    {
        if (quoteShouldRevert) revert("CONVERTER_QUOTE_FAILED");
        if (_path.length < 43) revert("CONVERTER_INVALID_ROUTE");
        if (quoteMultiplierBps > 0) {
            return _amountIn * quoteMultiplierBps / 10_000;
        }
        // Mock does a 1:1 swap, so quoted amount equals input amount
        return _amountIn;
    }

    function quoteSwapExactAmountOut(address, bytes calldata _path, uint256 _amountOut)
        external
        override
        returns (uint256 _amountIn)
    {
        if (quoteShouldRevert) revert("CONVERTER_QUOTE_FAILED");
        if (_path.length < 43) revert("CONVERTER_INVALID_ROUTE");
        if (quoteMultiplierBps > 0) {
            return _amountOut * 10_000 / quoteMultiplierBps;
        }
        return _amountOut;
    }

    function wrapETH() external payable override {
        if (wrapShouldRevert) revert("CONVERTER_WRAP_FAILED");
        mockWeth.deposit{value: msg.value}();
        IERC20Metadata(address(mockWeth)).safeTransfer(msg.sender, msg.value);
    }

    function unwrapWETH(uint256 _amount, address _receiver) external override {
        if (unwrapShouldRevert) revert("CONVERTER_UNWRAP_FAILED");
        IERC20Metadata(address(mockWeth)).safeTransferFrom(msg.sender, address(this), _amount);
        mockWeth.withdraw(_amount);
        (bool _success,) = payable(_receiver).call{value: _amount}("");
        require(_success, "MOCK_ETH_TRANSFER_FAILED");
    }

    // ============ IConverter remaining interface functions ============

    function setAllowedAdapter(address _adapter, bool _allowed) external override {
        _allowedAdapters[_adapter] = _allowed;
    }

    function isAdapterAllowed(address _adapter) external view override returns (bool) {
        return _allowedAdapters[_adapter];
    }

    function getAllowedAdapters() external view override returns (address[] memory) {
        revert("MOCK_NOT_IMPLEMENTED");
    }

    function validateRoute(address, bytes calldata) external view override returns (bool) {
        return true;
    }

    function paused() external view override returns (bool) {
        return _paused;
    }

    function pause() external override {
        _paused = true;
    }

    function unpause() external override {
        _paused = false;
    }
}
