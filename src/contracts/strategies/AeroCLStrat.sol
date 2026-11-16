// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version

import {CLStrat} from "./CLStrat.sol";
import {CLPoolLib} from "../../libraries/strategies/CLPoolLib.sol";

/**
 * @title AeroCLStrat
 * @notice Native-ETH concentrated-liquidity strategy for Aero pools.
 * @dev Uses the shared CLStrat implementation with the Slipstream pool ABI and factory lookup.
 *      Direct pool positions earn swap fees; no NFT or gauge staking.
 */
contract AeroCLStrat is CLStrat {
    constructor(DeploymentConfig memory _params) CLStrat(_params, CLPoolLib.Venue.Slipstream) {}

    function name() external pure returns (string memory) {
        return "Aero Concentrated Liquidity Strategy";
    }

    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
