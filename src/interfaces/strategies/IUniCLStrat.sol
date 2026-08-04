// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, use-natspec, gas-indexed-events
pragma solidity ^0.8.30;

import {IStrategy} from "../IStrategy.sol";

/**
 * @title IUniCLStrat
 * @notice Interface-level declarations for the Uniswap concentrated liquidity strategy.
 *         Swap, wrap, and unwrap operations are delegated to the shared IConverter.
 */
interface IUniCLStrat is IStrategy {
    // ============ Structs ============

    struct Position {
        int24 tickLower;
        int24 tickUpper;
    }

    struct AddressConfig {
        address registry;
        address weth;
        address pool;
    }

    struct RouteConfig {
        address swapAdapter;
        bytes wethToPairedTokenPath;
        bytes pairedTokenToWethPath;
    }

    struct StrategyConfig {
        int24 positionWidth;
        int24 rebalanceTickThreshold;
        int56 maxTickDeviation;
        uint32 twapInterval;
        uint32 shortTwapInterval;
        uint256 maxTotalNAV;
    }

    struct DeploymentConfig {
        AddressConfig addresses;
        RouteConfig routes;
        StrategyConfig strategy;
    }

    // ============ Events ============

    event PositionWidthUpdated(int24 oldWidth, int24 newWidth);
    event RebalanceTickThresholdUpdated(int24 oldThreshold, int24 newThreshold);
    event MaxTickDeviationUpdated(int56 oldDeviation, int56 newDeviation);
    event TwapIntervalUpdated(uint32 oldInterval, uint32 newInterval);
    event ShortTwapIntervalUpdated(uint32 oldInterval, uint32 newInterval);
    event MaxTotalNAVUpdated(uint256 oldMaxTotalNAV, uint256 newMaxTotalNAV);
    event RouteConfigUpdated(address indexed swapAdapter, bytes wethToPairedTokenPath, bytes pairedTokenToWethPath);
    event SwapSlippageUpdated(uint256 indexed oldSlippage, uint256 newSlippage);
    /// @notice Emitted when the best-effort pool unwind on pause reverted and was skipped
    event LiquidityUnwindSkipped();
    /// @notice Emitted when the best-effort paired-token transfer on `emergencyExit` reverted and was skipped
    event PairedTokenTransferSkipped();

    // ============ Errors ============

    error UniCLStratZeroAddress();
    error UniCLStratInvalidPool();
    error UniCLStratInvalidConfig();
    error UniCLStratCallerNotPool();
    error UniCLStratCallerNotSelf();
    error UniCLStratInvalidMintCallback();
    error UniCLStratNotCalm();
    error UniCLStratTransferFailed();
    error UniCLStratInsufficientWETH();
    error UniCLStratPoolTWAPNotAvailable();
    error UniCLStratNotPaused();
    error UniCLStratInvalidRouteConfig();
    error UniCLStratQuoteFailed();
    error UniCLStratQuoteExceedsOracleCeiling(uint256 quoted, uint256 oracleMinOut);
    error UniCLStratQuoteBelowOracleFloor(uint256 quoted, uint256 oracleMinOut);

    // ============ Functions ============

    function setPositionWidth(int24 _newPositionWidth) external;

    function setRebalanceTickThreshold(int24 _newRebalanceTickThreshold) external;

    function setMaxTickDeviation(int56 _newMaxTickDeviation) external;

    function setTwapInterval(uint32 _newTwapInterval) external;

    function setShortTwapInterval(uint32 _newShortTwapInterval) external;

    function setMaxTotalNAV(uint256 _newMaxTotalNAV) external;

    function setRouteConfig(
        address _swapAdapter,
        bytes calldata _wethToPairedTokenPath,
        bytes calldata _pairedTokenToWethPath
    ) external;

    function swapSlippageBps() external view returns (uint256);

    function setSwapSlippageBps(uint256 _newSwapSlippageBps) external;

    function pause() external;

    function unpause() external;
}
