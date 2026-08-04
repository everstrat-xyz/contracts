// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, one-contract-per-file
// solhint-disable immutable-vars-naming, named-parameters-mapping, gas-custom-errors, gas-strict-inequalities
// solhint-disable gas-calldata-parameters
pragma solidity ^0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniswapV3Router} from "../../src/interfaces/integrations/uniswap/IUniswapV3Router.sol";
import {IUniswapV3Pool} from "../../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "../../src/interfaces/integrations/uniswap/IUniswapV3Factory.sol";
import {IWETH} from "../../src/interfaces/integrations/IWETH.sol";
import {LiquidityAmounts} from "../../src/libraries/integrations/uniswap/LiquidityAmounts.sol";
import {TickMath} from "../../src/libraries/integrations/uniswap/TickMath.sol";
import {MockERC20} from "./MockERC20.sol";

interface IUniCLStratMintCallback {
    function uniswapV3MintCallback(uint256 _amount0, uint256 _amount1, bytes calldata _data) external;
}

contract MockWETH is MockERC20, IWETH {
    uint8 public constant WETH_DECIMALS = 18;

    constructor() MockERC20("Wrapped Ether", "WETH", WETH_DECIMALS) {}

    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 _amount) external override {
        _burn(msg.sender, _amount);
        (bool _success,) = payable(msg.sender).call{value: _amount}("");
        require(_success, "WETH_TRANSFER_FAILED");
    }
}

contract MockUniswapV3Factory is IUniswapV3Factory {
    mapping(bytes32 => address) private _pools;

    function setPool(address _tokenA, address _tokenB, uint24 _fee, address _pool) external {
        _pools[_poolKey(_tokenA, _tokenB, _fee)] = _pool;
        _pools[_poolKey(_tokenB, _tokenA, _fee)] = _pool;
    }

    function getPool(address _tokenA, address _tokenB, uint24 _fee) external view override returns (address) {
        return _pools[_poolKey(_tokenA, _tokenB, _fee)];
    }

    function _poolKey(address _tokenA, address _tokenB, uint24 _fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_tokenA, _tokenB, _fee));
    }
}

contract MockUniCLRouter is IUniswapV3Router {
    using SafeERC20 for IERC20Metadata;

    uint24 public constant POOL_FEE = 3000;

    MockWETH public immutable weth;
    MockERC20 public immutable pairedToken;

    bytes public wethToPairedTokenPath;
    bytes public pairedTokenToWethPath;

    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;
    uint256 public lastDeadline;
    uint256 public lastAmountOut;
    uint256 public lastAmountInMaximum;

    constructor(MockWETH _weth, MockERC20 _pairedToken) {
        weth = _weth;
        pairedToken = _pairedToken;
        wethToPairedTokenPath = abi.encodePacked(address(_weth), POOL_FEE, address(_pairedToken));
        pairedTokenToWethPath = abi.encodePacked(address(_pairedToken), POOL_FEE, address(_weth));
    }

    function exactInput(ExactInputParams calldata _params) external payable returns (uint256 amountOut) {
        lastAmountIn = _params.amountIn;
        lastAmountOutMinimum = _params.amountOutMinimum;
        lastDeadline = _params.deadline;
        amountOut = _params.amountIn;

        if (keccak256(_params.path) == keccak256(wethToPairedTokenPath)) {
            IERC20Metadata(address(weth)).safeTransferFrom(msg.sender, address(this), _params.amountIn);
            pairedToken.mint(_params.recipient, amountOut);
        } else if (keccak256(_params.path) == keccak256(pairedTokenToWethPath)) {
            IERC20Metadata(address(pairedToken)).safeTransferFrom(msg.sender, address(this), _params.amountIn);
            weth.mint(_params.recipient, amountOut);
        } else {
            revert("UNKNOWN_PATH");
        }
    }

    function exactOutput(ExactOutputParams calldata _params) external payable returns (uint256 amountIn) {
        lastAmountOut = _params.amountOut;
        lastAmountInMaximum = _params.amountInMaximum;
        lastDeadline = _params.deadline;

        // Uniswap V3 exact-output paths are REVERSE-encoded: the first token is the
        // OUTPUT token and the last token is the INPUT token. A reversed
        // wethToPairedTokenPath therefore equals pairedTokenToWethPath and vice versa.
        if (keccak256(_params.path) == keccak256(pairedTokenToWethPath)) {
            // tokenOut = pairedToken, tokenIn = weth
            amountIn = _params.amountOut; // 1:1 mock price, consumes only what is needed
            require(amountIn <= _params.amountInMaximum, "TOO_MUCH_REQUESTED");
            IERC20Metadata(address(weth)).safeTransferFrom(msg.sender, address(this), amountIn);
            pairedToken.mint(_params.recipient, _params.amountOut);
        } else if (keccak256(_params.path) == keccak256(wethToPairedTokenPath)) {
            // tokenOut = weth, tokenIn = pairedToken
            amountIn = _params.amountOut;
            require(amountIn <= _params.amountInMaximum, "TOO_MUCH_REQUESTED");
            IERC20Metadata(address(pairedToken)).safeTransferFrom(msg.sender, address(this), amountIn);
            weth.mint(_params.recipient, _params.amountOut);
        } else {
            revert("UNKNOWN_PATH");
        }
    }
}

contract MockUniCLPool is IUniswapV3Pool {
    using SafeERC20 for IERC20Metadata;

    uint24 public constant POOL_FEE = 3000;

    struct PositionState {
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint128 pendingOwed0;
        uint128 pendingOwed1;
    }

    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee = POOL_FEE;
    int24 public immutable override tickSpacing;

    int24 public currentTick;
    int24 public twapTick;
    uint160 public currentSqrtPriceX96;
    bool public observeShouldRevert;
    bool public poolShouldRevert;

    mapping(bytes32 => PositionState) public positionStates;

    constructor(address _token0, address _token1, int24 _tickSpacing, int24 _initialTick) {
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        setCurrentTick(_initialTick);
    }

    function setCurrentTick(int24 _currentTick) public {
        currentTick = _currentTick;
        twapTick = _currentTick;
        currentSqrtPriceX96 = TickMath.getSqrtRatioAtTick(_currentTick);
    }

    function setCurrentTickWithoutTwap(int24 _currentTick) external {
        currentTick = _currentTick;
        currentSqrtPriceX96 = TickMath.getSqrtRatioAtTick(_currentTick);
    }

    function setObserveShouldRevert(bool _observeShouldRevert) external {
        observeShouldRevert = _observeShouldRevert;
    }

    /// @notice Simulates a degraded/halted pool: positions, mint, burn, and collect all revert
    function setPoolShouldRevert(bool _poolShouldRevert) external {
        poolShouldRevert = _poolShouldRevert;
    }

    // IUniswapV3Pool implementation
    // Pool functions are implemented below

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (currentSqrtPriceX96, currentTick, 0, 0, 0, 0, true);
    }

    function observe(uint32[] calldata _secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeShouldRevert) revert("OLD");

        tickCumulatives = new int56[](_secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](_secondsAgos.length);

        for (uint256 i; i < _secondsAgos.length; ++i) {
            tickCumulatives[i] = -int56(twapTick) * int56(uint56(_secondsAgos[i]));
        }
    }

    function positions(bytes32 _key)
        external
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        if (poolShouldRevert) revert("POOL_DEGRADED");
        PositionState memory _position = positionStates[_key];
        return (_position.liquidity, 0, 0, _position.tokensOwed0, _position.tokensOwed1);
    }

    function mint(address _recipient, int24 _tickLower, int24 _tickUpper, uint128 _amount, bytes calldata _data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (poolShouldRevert) revert("POOL_DEGRADED");
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_tickLower),
            TickMath.getSqrtRatioAtTick(_tickUpper),
            _amount
        );

        IUniCLStratMintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, _data);

        bytes32 _key = _positionKey(_recipient, _tickLower, _tickUpper);
        PositionState storage _position = positionStates[_key];
        _materializePendingFees(_position);
        _position.liquidity += _amount;
    }

    function burn(int24 _tickLower, int24 _tickUpper, uint128 _amount)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (poolShouldRevert) revert("POOL_DEGRADED");
        bytes32 _key = _positionKey(msg.sender, _tickLower, _tickUpper);
        PositionState storage _position = positionStates[_key];

        _materializePendingFees(_position);

        if (_amount == 0) {
            return (0, 0);
        }

        if (_amount > _position.liquidity) _amount = _position.liquidity;

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            currentSqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_tickLower),
            TickMath.getSqrtRatioAtTick(_tickUpper),
            _amount
        );

        _position.liquidity -= _amount;
        _position.tokensOwed0 += _toUint128(amount0);
        _position.tokensOwed1 += _toUint128(amount1);

        _fundPoolOwedTokens(amount0, amount1);
    }

    function collect(address _recipient, int24 _tickLower, int24 _tickUpper, uint128, uint128)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        if (poolShouldRevert) revert("POOL_DEGRADED");
        bytes32 _key = _positionKey(msg.sender, _tickLower, _tickUpper);
        PositionState storage _position = positionStates[_key];
        amount0 = _position.tokensOwed0;
        amount1 = _position.tokensOwed1;
        _position.tokensOwed0 = 0;
        _position.tokensOwed1 = 0;

        _fundPoolOwedTokens(amount0, amount1);

        if (amount0 > 0) IERC20Metadata(token0).safeTransfer(_recipient, amount0);
        if (amount1 > 0) IERC20Metadata(token1).safeTransfer(_recipient, amount1);
    }

    function accrueFees(address _owner, int24 _tickLower, int24 _tickUpper, uint128 _amount0, uint128 _amount1)
        external
    {
        bytes32 _key = _positionKey(_owner, _tickLower, _tickUpper);
        PositionState storage _position = positionStates[_key];
        _position.pendingOwed0 += _amount0;
        _position.pendingOwed1 += _amount1;
    }

    function _materializePendingFees(PositionState storage _position) internal {
        if (_position.pendingOwed0 == 0 && _position.pendingOwed1 == 0) return;

        _fundPoolOwedTokens(_position.pendingOwed0, _position.pendingOwed1);
        _position.tokensOwed0 += _position.pendingOwed0;
        _position.tokensOwed1 += _position.pendingOwed1;
        _position.pendingOwed0 = 0;
        _position.pendingOwed1 = 0;
    }

    function _positionKey(address _owner, int24 _tickLower, int24 _tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_owner, _tickLower, _tickUpper));
    }

    function _toUint128(uint256 _amount) internal pure returns (uint128) {
        require(_amount <= type(uint128).max, "UINT128_OVERFLOW");
        return uint128(_amount);
    }

    function _fundPoolOwedTokens(uint256 _amount0, uint256 _amount1) internal {
        uint256 _balance0 = IERC20Metadata(token0).balanceOf(address(this));
        uint256 _balance1 = IERC20Metadata(token1).balanceOf(address(this));

        if (_amount0 > _balance0) MockWETH(payable(token0)).mint(address(this), _amount0 - _balance0);
        if (_amount1 > _balance1) MockERC20(token1).mint(address(this), _amount1 - _balance1);
    }
}
