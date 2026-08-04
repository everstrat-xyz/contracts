// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MockStrategy} from "./MockStrategy.sol";

/**
 * @title MockFeeTakingStrategy
 * @notice MockStrategy variant that retains a fixed withdrawal fee on the contract
 * @dev Simulates strategies (e.g. UniCLStrat) that deduct performance fees before sending ETH to the receiver
 */
contract MockFeeTakingStrategy is MockStrategy {
    constructor(string memory name_, address controller_, address strategyManager_, uint256 withdrawalFeeBps_)
        MockStrategy(name_, controller_, strategyManager_)
    {
        _setWithdrawalFeeBps(withdrawalFeeBps_);
    }
}
