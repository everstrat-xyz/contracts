// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockPriceFeed
 * @notice Mock Chainlink price feed for testing
 */
contract MockPriceFeed is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _price;
    uint256 private _updatedAt;
    bool private _stale;
    uint80 private _roundId = 1;
    string private _description = "Mock Price Feed";

    constructor(uint8 decimals_, int256 price_) {
        _decimals = decimals_;
        _price = price_;
        _updatedAt = block.timestamp;
        _stale = false;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function setDescription(string memory description_) external {
        _description = description_;
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    function setStale(bool stale) external {
        _stale = stale;
        if (stale) {
            // Ensure we don't underflow
            if (block.timestamp > 7200) {
                _updatedAt = block.timestamp - 7200; // 2 hours ago
            } else {
                _updatedAt = 1; // Non-zero but old enough to be stale
            }
        } else {
            _updatedAt = block.timestamp;
        }
    }

    function updatePrice(int256 newPrice, uint256 timestamp) external {
        _price = newPrice;
        _updatedAt = timestamp;
        _stale = false;
    }

    function isStale() external view returns (bool) {
        return _stale;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }
}
