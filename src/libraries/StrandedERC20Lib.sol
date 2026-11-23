// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IConverter} from "../interfaces/IConverter.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IStrategyManager} from "../interfaces/IStrategyManager.sol";
import {Math} from "./Math.sol";

/**
 * @title StrandedERC20Lib
 * @notice Externally linked library that sells an ERC-20 held by the StrategyManager for ETH
 *         through the shared Converter and delivers the ETH to the Controller.
 * @dev The entry point is `public` on purpose: an `internal` function would be inlined into the
 *      StrategyManager, which has no EIP-170 headroom for it. Public library functions run via
 *      DELEGATECALL, so approvals, transfers and the Converter's caller check all act as the
 *      StrategyManager. The library holds no state and no funds.
 */
library StrandedERC20Lib {
    using SafeERC20 for IERC20;

    uint256 internal constant BASIS_POINTS = 10_000;

    /**
     * @notice Swaps `_amountIn` of `_token` into WETH along `_path` and unwraps it to `_controller`.
     * @dev The WETH received must meet the larger of `_minETHOut` and the Oracle value of
     *      `_amountIn` discounted by `_maxSlippageBps` or the swap reverts with
     *      `ConverterInsufficientOutput`. Grants the calling contract
     *      `CONVERTER_CALLER_ROLE` via the Converter on first use, which only the registered
     *      StrategyManager may do.
     * @return ethOut ETH delivered to `_controller`
     */
    function convertToETH(
        IConverter _converter,
        IOracle _oracle,
        address _controller,
        address _token,
        address _adapter,
        bytes calldata _path,
        uint256 _amountIn,
        uint256 _minETHOut,
        uint256 _maxSlippageBps
    ) public returns (uint256 ethOut) {
        address weth = _converter.weth();
        (address tokenIn, address tokenOut) = _converter.routeTokens(_adapter, _path);
        if (tokenIn != _token || tokenOut != weth) revert IStrategyManager.StrategyManagerInvalidRecoveryRoute();

        uint256 oracleValue =
            _oracle.convert(_token, address(0), _amountIn, IERC20Metadata(_token).decimals(), Math.DECIMALS_NORMALIZED);
        uint256 minOut = OZMath.max(_minETHOut, oracleValue * (BASIS_POINTS - _maxSlippageBps) / BASIS_POINTS);

        if (!_converter.isCaller(address(this))) _converter.grantCallerRole(address(this));

        IERC20(_token).forceApprove(address(_converter), _amountIn);
        uint256 wethBefore = IERC20(weth).balanceOf(address(this));
        _converter.executeSwapExactAmountIn(_adapter, _path, _amountIn, minOut, block.timestamp);
        ethOut = IERC20(weth).balanceOf(address(this)) - wethBefore;
        IERC20(_token).forceApprove(address(_converter), 0);

        if (ethOut < minOut) revert IConverter.ConverterInsufficientOutput();
        IERC20(weth).forceApprove(address(_converter), ethOut);
        _converter.unwrapWETH(ethOut, _controller);
    }
}
