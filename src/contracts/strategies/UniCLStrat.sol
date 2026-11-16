// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version

import {CLStrat} from "./CLStrat.sol";
import {CLPoolLib} from "../../libraries/strategies/CLPoolLib.sol";

/**
 * @title UniCLStrat
 * @notice Native-ETH concentrated-liquidity strategy for Uniswap pools.
 * @dev Uses the shared CLStrat implementation with the UniswapV3 pool ABI and factory lookup.
 *      Direct pool positions earn swap fees; no NFT or gauge staking.
 */
contract UniCLStrat is CLStrat {
    constructor(DeploymentConfig memory _params) CLStrat(_params, CLPoolLib.Venue.UniswapV3) {}

    function name() external pure returns (string memory) {
        return "Uniswap Concentrated Liquidity Strategy";
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}
