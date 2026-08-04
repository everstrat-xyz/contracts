// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockController
 * @notice Mock controller for testing AMM
 */
contract MockController {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
}
