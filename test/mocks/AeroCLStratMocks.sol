// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, one-contract-per-file
// solhint-disable immutable-vars-naming, named-parameters-mapping, gas-custom-errors, gas-strict-inequalities
// solhint-disable gas-calldata-parameters
pragma solidity ^0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LiquidityAmounts} from "../../src/libraries/integrations/uniswap/LiquidityAmounts.sol";
import {TickMath} from "../../src/libraries/integrations/uniswap/TickMath.sol";
import {MockERC20} from "./MockERC20.sol";
import {IUniCLStratMintCallback, MockWETH} from "./UniCLStratMocks.sol";

/// @dev Aero `CLFactory` mock: pools keyed by tick spacing, not fee.
contract MockAeroCLFactory {
    mapping(bytes32 => address) private _pools;

    function setPool(address _tokenA, address _tokenB, int24 _tickSpacing, address _pool) external {
        _pools[_poolKey(_tokenA, _tokenB, _tickSpacing)] = _pool;
        _pools[_poolKey(_tokenB, _tokenA, _tickSpacing)] = _pool;
    }

    function getPool(address _tokenA, address _tokenB, int24 _tickSpacing) external view returns (address) {
        return _pools[_poolKey(_tokenA, _tokenB, _tickSpacing)];
    }

    function _poolKey(address _tokenA, address _tokenB, int24 _tickSpacing) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_tokenA, _tokenB, _tickSpacing));
    }
}

/// @dev Aero (Slipstream) pool mock. Same behaviour as `MockUniCLPool`, except `slot0` has the
///      Slipstream 6-field layout (no `feeProtocol`), so a Uniswap-layout decode reverts.
contract MockAeroCLPool {
    using SafeERC20 for IERC20Metadata;

    uint24 public constant POOL_FEE = 3000;

    struct PositionState {
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint128 pendingOwed0;
        uint128 pendingOwed1;
    }

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee = POOL_FEE;
    int24 public immutable tickSpacing;

    int24 public currentTick;
    int24 public twapTick;
    uint160 public currentSqrtPriceX96;
    bool public observeShouldRevert;
    bool public poolShouldRevert;
    /// @dev 0 = no cap (every lookback succeeds). Non-zero: `observe` reverts OLD when any
    ///      `secondsAgo` exceeds the cap, modelling a ring that cannot cover a longer window.
    uint32 public maxObserveSecondsAgo;
    /// @dev In-use Uniswap observation cardinality (`slot0` field). Default covers
    ///      UniCLStrat's `ceil(3600 / 12)` setter window used in unit tests.
    uint16 public inUseObservationCardinality = 1024;

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

    function setMaxObserveSecondsAgo(uint32 _maxObserveSecondsAgo) external {
        maxObserveSecondsAgo = _maxObserveSecondsAgo;
    }

    function setObservationCardinality(uint16 _observationCardinality) external {
        inUseObservationCardinality = _observationCardinality;
    }

    /// @notice Simulates a degraded/halted pool: positions, mint, burn, and collect all revert
    function setPoolShouldRevert(bool _poolShouldRevert) external {
        poolShouldRevert = _poolShouldRevert;
    }

    // Slipstream pool surface (ABI-identical to Uniswap V3 except `slot0`)

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        )
    {
        return (currentSqrtPriceX96, currentTick, 0, inUseObservationCardinality, inUseObservationCardinality, true);
    }

    function observe(uint32[] calldata _secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (observeShouldRevert) revert("OLD");
        if (maxObserveSecondsAgo != 0) {
            for (uint256 i; i < _secondsAgos.length; ++i) {
                if (_secondsAgos[i] > maxObserveSecondsAgo) revert("OLD");
            }
        }

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
