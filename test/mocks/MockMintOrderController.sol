// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EVE} from "../../src/contracts/EVE.sol";

/**
 * @title MockMintOrderController
 * @notice Controller stand-in used to assert AMM-3 enter ordering mid-call.
 * @dev On `receive`, requires `eve.totalSupply() >= minSupplyOnReceive`. That holds only if
 *      EVE was minted *before* ETH was forwarded — transfer-then-mint fails this check while
 *      ETH is still in flight to the Controller.
 */
contract MockMintOrderController {
    EVE public immutable eve;
    uint256 public minSupplyOnReceive;
    bool public received;

    error MintOrderControllerEthArrivedBeforeMint(uint256 supply, uint256 minSupply);

    constructor(address _eve) {
        eve = EVE(_eve);
    }

    function expectMinSupplyOnReceive(uint256 _minSupply) external {
        minSupplyOnReceive = _minSupply;
        received = false;
    }

    receive() external payable {
        received = true;
        uint256 supply = eve.totalSupply();
        if (supply < minSupplyOnReceive) {
            revert MintOrderControllerEthArrivedBeforeMint(supply, minSupplyOnReceive);
        }
    }
}
