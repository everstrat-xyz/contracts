// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {RegistryClientUpgradeable} from "registry/client/RegistryClientUpgradeable.sol";

import {Auth} from "../libraries/Auth.sol";

import {IConverter} from "interfaces/IConverter.sol";
import {IConverterAdapter} from "interfaces/IConverterAdapter.sol";
import {IWETH} from "interfaces/integrations/IWETH.sol";

/**
 * @title Converter
 * @notice Shared protocol module that handles WETH wrapping, unwrapping, and DEX swap executions.
 * @dev Upgradeable contract using UUPS pattern. Role and peer addresses are resolved from the
 *      protocol Registry. Strategies call through granted caller permissions managed by the
 *      registered StrategyManager contract, using `CONVERTER_CALLER_ROLE` on the Registry administered
 *      by `CONVERTER_CALLER_MANAGER_ROLE` (held by the Converter).
 *      `pause()` is `ADMIN_ROLE` or `SECURITY_ROLE`; `unpause()` is `ADMIN_ROLE` only.
 */
contract Converter is
    IConverter,
    Initializable,
    UUPSUpgradeable,
    RegistryClientUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ State Variables ============

    /// @notice The WETH contract
    IWETH private _weth;

    /// @notice DEX adapter allowlist stored as an EnumerableSet for on-chain enumeration
    EnumerableSet.AddressSet private _allowedAdapters;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Receive Function ============

    receive() external payable {}

    // ============ Initialization ============

    /**
     * @notice Initialises the Converter contract
     * @param _registry The protocol Registry (role authority and contract addresses)
     * @param _wethAddress The address of the WETH contract
     */
    function initialize(address _registry, address _wethAddress) public initializer {
        if (_wethAddress == address(0)) revert ConverterZeroAddress();

        __UUPSUpgradeable_init();
        __RegistryClient_init(_registry);
        __Pausable_init();
        __ReentrancyGuard_init();

        _weth = IWETH(_wethAddress);

        emit ConverterInitialized(_registry, _wethAddress);
    }

    // ============ WETH Functions ============

    /**
     * @inheritdoc IConverter
     */
    function wrapETH() external payable override onlyAuthRole(Auth.CONVERTER_CALLER_ROLE) whenNotPaused nonReentrant {
        uint256 _amount = msg.value;
        if (_amount == 0) return;

        _weth.deposit{value: _amount}();
        _weth.safeTransfer(msg.sender, _amount);

        emit ETHWrapped(msg.sender, _amount);
    }

    /**
     * @inheritdoc IConverter
     */
    function unwrapWETH(uint256 _amount, address _receiver)
        external
        override
        onlyAuthRole(Auth.CONVERTER_CALLER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (_amount == 0) return;
        if (_receiver == address(0)) revert ConverterZeroAddress();

        _weth.safeTransferFrom(msg.sender, address(this), _amount);
        _weth.withdraw(_amount);

        (bool _success,) = payable(_receiver).call{value: _amount}("");
        if (!_success) revert ConverterETHTransferFailed();

        emit WETHUnwrapped(msg.sender, _receiver, _amount);
    }

    // ============ Swap Functions ============

    /**
     * @inheritdoc IConverter
     */
    function executeSwapExactAmountIn(
        address _adapter,
        bytes calldata _path,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint256 _deadline
    )
        external
        override
        onlyAuthRole(Auth.CONVERTER_CALLER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 _amountOut)
    {
        return _executeSwapExactAmountIn(_adapter, _path, _amountIn, _minAmountOut, _deadline);
    }

    /**
     * @inheritdoc IConverter
     */
    function executeSwapExactAmountOut(
        address _adapter,
        bytes calldata _path,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint256 _deadline
    )
        external
        override
        onlyAuthRole(Auth.CONVERTER_CALLER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 _amountIn)
    {
        if (_amountOut == 0) return 0;
        if (_deadline < block.timestamp) revert ConverterDeadlineExpired();
        if (!_allowedAdapters.contains(_adapter)) revert ConverterAdapterNotAllowed();

        // Validate route upfront before pulling tokens.
        _validateRoute(_adapter, _path);

        (address _tokenIn, address _tokenOut) = _adapterRouteTokens(_adapter, _path);

        // The full maximum must be available before the swap — the DEX router pulls
        // payment mid-swap and the exact amount is unknown until it executes. Any
        // unspent input is refunded below, in the same transaction.
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountInMaximum);

        uint256 _balanceInBefore = IERC20(_tokenIn).balanceOf(address(this));
        uint256 _balanceOutBefore = IERC20(_tokenOut).balanceOf(address(this));

        // Dispatch via delegatecall: the adapter code runs in this contract's context, so the
        // input tokens stay here and the adapter approves the DEX router directly — no
        // intermediate approve/transferFrom round-trip through the adapter.
        _dispatchSwap(
            _adapter,
            abi.encodeCall(
                IConverterAdapter.swapExactAmountOut, (_path, _amountOut, _amountInMaximum, address(this), _deadline)
            )
        );

        // Measure the spent input from the actual balance delta rather than trusting the
        // adapter-reported amount: an adapter that misreports its spend could otherwise
        // strand input on this contract (over-report) or be refunded from funds it
        // actually consumed (under-report). The delta also makes the bound below
        // enforceable against an adapter that spends pre-existing Converter balance.
        // The exact-input path below does the same — it sizes the caller's payout from a
        // measured balance delta rather than the value the adapter reports.
        _amountIn = _balanceInBefore - IERC20(_tokenIn).balanceOf(address(this));

        if (_amountIn > _amountInMaximum) revert ConverterExcessiveInput();

        // Confirm the adapter actually produced at least the requested output from the
        // measured balance delta, symmetric to the input-side accounting above and to the
        // exact-input path's output measurement. Without this, a misreporting adapter that
        // delivers less than `_amountOut` would have the shortfall covered from any
        // pre-existing `_tokenOut` balance on the Converter by the transfer below.
        if (IERC20(_tokenOut).balanceOf(address(this)) - _balanceOutBefore < _amountOut) {
            revert ConverterInsufficientOutput();
        }

        // Refund any unused input tokens back to the caller. Under delegatecall the
        // unspent input never leaves this contract; we forward it to msg.sender.
        uint256 _surplus = _amountInMaximum - _amountIn;
        if (_surplus > 0) {
            IERC20(_tokenIn).safeTransfer(msg.sender, _surplus);
        }

        IERC20(_tokenOut).safeTransfer(msg.sender, _amountOut);

        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _amountIn, _amountOut);
    }

    /**
     * @inheritdoc IConverter
     */
    function quoteSwapExactAmountIn(address _adapter, bytes calldata _path, uint256 _amountIn)
        external
        override
        returns (uint256 _amountOut)
    {
        if (!_allowedAdapters.contains(_adapter)) revert ConverterAdapterNotAllowed();
        return _quoteSwapExactAmountIn(_adapter, _path, _amountIn);
    }

    /**
     * @inheritdoc IConverter
     */
    function quoteSwapExactAmountOut(address _adapter, bytes calldata _path, uint256 _amountOut)
        external
        override
        returns (uint256 _amountIn)
    {
        if (!_allowedAdapters.contains(_adapter)) revert ConverterAdapterNotAllowed();
        return _quoteSwapExactAmountOut(_adapter, _path, _amountOut);
    }

    // ============ Role Management ============

    /**
     * @inheritdoc IConverter
     */
    function grantCallerRole(address _account) external override onlyAuthContract(Auth.STRATEGY_MANAGER) {
        if (_account == address(0)) revert ConverterZeroAddress();
        registry().grantRole(Auth.CONVERTER_CALLER_ROLE, _account);
        emit CallerRoleGranted(_account);
    }

    /**
     * @inheritdoc IConverter
     */
    function revokeCallerRole(address _account) external override onlyAuthContract(Auth.STRATEGY_MANAGER) {
        if (_account == address(0)) revert ConverterZeroAddress();
        registry().revokeRole(Auth.CONVERTER_CALLER_ROLE, _account);
        emit CallerRoleRevoked(_account);
    }

    // ============ Configuration ============

    /**
     * @inheritdoc IConverter
     */
    function setAllowedAdapter(address _adapter, bool _allowed) external override onlyAuthRole(Auth.ADMIN_ROLE) {
        if (_adapter == address(0)) revert ConverterZeroAddress();
        if (_allowed && _adapter.code.length == 0) revert ConverterNoCode();

        if (_allowed) {
            if (!_allowedAdapters.add(_adapter)) revert ConverterAdapterAlreadyAllowed();
        } else {
            if (!_allowedAdapters.remove(_adapter)) revert ConverterAdapterNotAllowed();
        }

        emit AdapterUpdated(_adapter, _allowed);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IConverter
     */
    function weth() external view override returns (address) {
        return address(_weth);
    }

    /**
     * @inheritdoc IConverter
     */
    function paused() public view override(PausableUpgradeable, IConverter) returns (bool) {
        return super.paused();
    }

    /**
     * @inheritdoc IConverter
     */
    function isAdapterAllowed(address _adapter) external view override returns (bool) {
        return _allowedAdapters.contains(_adapter);
    }

    /**
     * @inheritdoc IConverter
     */
    function getAllowedAdapters() external view override returns (address[] memory) {
        return _allowedAdapters.values();
    }

    /**
     * @inheritdoc IConverter
     */
    function routeTokens(address _adapter, bytes calldata _path) external view override returns (address, address) {
        if (!_allowedAdapters.contains(_adapter)) revert ConverterAdapterNotAllowed();
        return _adapterRouteTokens(_adapter, _path);
    }

    /**
     * @inheritdoc IConverter
     */
    function validateRoute(address _adapter, bytes calldata _route) external view override returns (bool _valid) {
        if (!_allowedAdapters.contains(_adapter)) revert ConverterAdapterNotAllowed();
        return _isValidRoute(_adapter, _route);
    }

    /**
     * @inheritdoc IConverter
     */
    function isCaller(address _account) external view override returns (bool) {
        return registry().hasRole(Auth.CONVERTER_CALLER_ROLE, _account);
    }

    // ============ Emergency Functions ============

    /**
     * @inheritdoc IConverter
     */
    function pause() external override onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IConverter
     */
    function unpause() external override onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }

    // ============ Upgrade Functions ============

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only addresses with ADMIN_ROLE on the Registry can authorize upgrades
     * @param _newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address _newImplementation) internal override onlyAuthRole(Auth.ADMIN_ROLE) {}

    // ============ Internal Helpers ============

    /**
     * @notice Core swap logic (exact-input). Pulls input tokens from the caller, dispatches
     *         execution to the route's whitelisted adapter via delegatecall, and returns the
     *         output to the caller.
     * @dev The adapter is whitelisted and trusted; it owns route decoding and the DEX call.
     *      Dispatch uses DELEGATECALL so the adapter code executes in this contract's
     *      context: the input tokens never leave the Converter and the adapter makes a
     *      single approval directly to the DEX router. This removes the double
     *      approve/transferFrom round-trip (Converter→adapter→router) of a CALL-based
     *      dispatch. The trust assumption is unchanged — only ADMIN_ROLE can whitelist
     *      adapters, and whitelisted adapters must be stateless (immutables only) so they
     *      cannot touch the Converter's storage (see {IConverterAdapter}).
     *      Slippage is enforced by the caller-supplied minimum.
     *      validateRoute is called upfront to reject invalid routes early with a clear revert.
     */
    function _executeSwapExactAmountIn(
        address _adapter,
        bytes memory _path,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint256 _deadline
    ) internal returns (uint256 _amountOut) {
        if (_amountIn == 0) return 0;
        if (_deadline < block.timestamp) revert ConverterDeadlineExpired();
        if (!_allowedAdapters.contains(_adapter)) revert ConverterAdapterNotAllowed();

        // Validate route upfront before pulling tokens.
        _validateRoute(_adapter, _path);

        (address _tokenIn, address _tokenOut) = _adapterRouteTokens(_adapter, _path);

        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 _balanceBefore = IERC20(_tokenOut).balanceOf(address(this));

        // Ignore the adapter-reported output and size the payout from the measured balance
        // delta instead: a misreporting adapter could otherwise over-pay the caller from
        // pre-existing Converter balance (over-report) or strand produced output here
        // (under-report). Mirrors the exact-output accounting above.
        _dispatchSwap(
            _adapter,
            abi.encodeCall(
                IConverterAdapter.swapExactAmountIn, (_path, _amountIn, _minAmountOut, address(this), _deadline)
            )
        );

        _amountOut = IERC20(_tokenOut).balanceOf(address(this)) - _balanceBefore;

        if (_amountOut < _minAmountOut) revert ConverterInsufficientOutput();

        IERC20(_tokenOut).safeTransfer(msg.sender, _amountOut);

        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _amountIn, _amountOut);
    }

    /**
     * @notice Dispatches an encoded swap to a whitelisted adapter via delegatecall.
     * @dev Reverts with ConverterSwapFailed when the adapter reverts or returns malformed
     *      data (a single uint256 amount is expected). Delegatecalling a code-less adapter
     *      (e.g. selfdestructed after whitelisting) returns success with empty returndata,
     *      which the length check rejects.
     * @param _adapter The whitelisted adapter to delegatecall
     * @param _callData ABI-encoded {IConverterAdapter.swapExactAmountIn} or {IConverterAdapter.swapExactAmountOut} call
     * @return _amount The decoded amount returned by the adapter
     */
    function _dispatchSwap(address _adapter, bytes memory _callData) internal returns (uint256 _amount) {
        // slither-disable-next-line controlled-delegatecall — adapter is admin-whitelisted
        (bool _success, bytes memory _returnData) = _adapter.delegatecall(_callData);
        if (!_success || _returnData.length != 32) revert ConverterSwapFailed();
        _amount = abi.decode(_returnData, (uint256));
    }

    /**
     * @notice Dispatches a quote to the adapter via a direct interface call (exact-input).
     * @dev Uses a normal external call (not staticcall) because some DEX quoters are
     *      non-view — e.g. the Uniswap V3 Quoter simulates the swap via an internal call
     *      that writes to transient storage, so a staticcall would revert on mainnet. By
     *      using a direct interface call on IConverterAdapter.quoteExactAmountIn (declared as
     *      `external returns`, not `view`), Solidity emits a CALL opcode, which is correct
     *      for both view (e.g. TWAP + Chainlink based) and non-view adapter quotes.
     */
    function _quoteSwapExactAmountIn(address _adapter, bytes memory _path, uint256 _amountIn)
        internal
        returns (uint256 _amountOut)
    {
        try IConverterAdapter(_adapter).quoteExactAmountIn(_path, _amountIn) returns (uint256 _result) {
            return _result;
        } catch {
            revert ConverterAdapterCallFailed();
        }
    }

    /**
     * @notice Dispatches an exact-output quote to the adapter via a direct interface call.
     */
    function _quoteSwapExactAmountOut(address _adapter, bytes memory _path, uint256 _amountOut)
        internal
        returns (uint256 _amountIn)
    {
        try IConverterAdapter(_adapter).quoteExactAmountOut(_path, _amountOut) returns (uint256 _result) {
            return _result;
        } catch {
            revert ConverterAdapterCallFailed();
        }
    }

    /**
     * @notice Validates a route by asking its adapter via staticcall.
     * @dev Used by the public view function {validateRoute}. Returns false (no revert)
     *      when the route is invalid or the adapter call fails, matching the external
     *      behaviour callers expect from a view function.
     */
    function _isValidRoute(address _adapter, bytes memory _route) internal view returns (bool _valid) {
        try IConverterAdapter(_adapter).validateRoute(_route) returns (bool _result) {
            return _result;
        } catch {
            return false;
        }
    }

    /**
     * @notice Validates a route and reverts if it is invalid.
     * @dev Used by swap execution paths to reject invalid routes early with a clear
     *      error instead of failing inside the adapter with a cryptic error.
     *      Reverts with ConverterAdapterCallFailed when the adapter itself fails (reverts),
     *      and ConverterInvalidRoute when the route is structurally invalid.
     */
    function _validateRoute(address _adapter, bytes memory _route) internal view {
        try IConverterAdapter(_adapter).validateRoute(_route) returns (bool _valid) {
            if (!_valid) revert ConverterInvalidRoute();
        } catch {
            revert ConverterAdapterCallFailed();
        }
    }

    /**
     * @notice Resolves the input/output tokens of a route by asking its adapter.
     */
    function _adapterRouteTokens(address _adapter, bytes memory _path)
        internal
        view
        returns (address _tokenIn, address _tokenOut)
    {
        try IConverterAdapter(_adapter).routeTokens(_path) returns (address _in, address _out) {
            return (_in, _out);
        } catch {
            revert ConverterAdapterCallFailed();
        }
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades.
     *      3 linear slots used: _weth (address, slot 0), _allowedAdapters._inner._values
     *      (dynamic array, slot 1), _allowedAdapters._inner._positions (mapping, slot 2).
     *      RegistryClientUpgradeable uses an ERC-7201 slot (not part of the linear gap).
     *      50 - 3 = 47 reserved slots to stay within the standard 50-slot ceiling.
     */
    uint256[47] private __gap;
}
