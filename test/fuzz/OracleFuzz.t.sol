// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../../src/libraries/Auth.sol";

/**
 * @title OracleFuzzTest
 * @notice Fuzz tests for Oracle price boundaries and edge cases
 * @dev Uses fuzzing to test Oracle with various price inputs
 */
contract OracleFuzzTest is ProtocolTestBase {
    Oracle public oracle;
    Registry public registry;
    MockPriceFeed public priceFeed;
    MockERC20 public token;

    address public admin = address(0x1);
    uint256 public constant STALENESS_INTERVAL = 3600;

    function setUp() public {
        token = new MockERC20("TEST", "TEST", 18);
        priceFeed = new MockPriceFeed(8, int256(100e8));

        registry = _deployRegistry(admin);

        Oracle oracleImpl = new Oracle();
        bytes memory initData = abi.encodeWithSelector(Oracle.initialize.selector, address(registry));
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), initData);
        oracle = Oracle(address(oracleProxy));

        vm.startPrank(admin);
        oracle.updateUsdFeedInfo(address(token), address(priceFeed), STALENESS_INTERVAL);
        vm.stopPrank();
    }

    /// @notice Fuzz test for price boundaries
    /// @param price The price to test (bounded to reasonable range)
    function testFuzz_PriceBoundaries(uint256 price) public {
        // Bound price to reasonable range (1e8 to 1e15)
        price = bound(price, 1e8, 1e15);

        // Update price feed
        priceFeed.setPrice(int256(price));

        // Should get price successfully
        (uint256 returnedPrice, uint256 timestamp) = oracle.getUsdPrice(address(token));

        // Price should be normalized to 18 decimals
        assertGt(returnedPrice, 0);
        assertGt(timestamp, 0);
    }

    /// @notice Fuzz test for timestamp boundaries
    /// @param timeOffset Time offset from current block (bounded)
    function testFuzz_TimestampBoundaries(uint256 timeOffset) public {
        // Bound to reasonable range (0 to 2 years)
        // We'll test both past and future by using timeOffset as absolute value
        timeOffset = bound(timeOffset, 0, 730 days);

        // Test past timestamps (older than current)
        // Use timeOffset to go back in time, but ensure we don't underflow
        uint256 pastTimestamp;
        if (timeOffset > block.timestamp) {
            pastTimestamp = 0; // Very old timestamp
        } else {
            pastTimestamp = block.timestamp - timeOffset;
        }

        // Update with past timestamp
        priceFeed.updatePrice(int256(100e8), pastTimestamp);

        // updatedAt == 0 means no round data at all
        if (pastTimestamp == 0) {
            vm.expectRevert(IOracle.OracleNoRoundData.selector);
            oracle.getUsdPrice(address(token));
        } else if (block.timestamp > pastTimestamp && block.timestamp - pastTimestamp > STALENESS_INTERVAL) {
            vm.expectRevert(IOracle.OracleStalePrice.selector);
            oracle.getUsdPrice(address(token));
        } else {
            (uint256 price,) = oracle.getUsdPrice(address(token));
            assertGt(price, 0);
        }
    }

    /// @notice Fuzz test for staleness interval
    /// @param interval Staleness interval to test
    function testFuzz_StalenessInterval(uint256 interval) public {
        // Bound to reasonable range (1 minute to 1 day)
        interval = bound(interval, 60, 86400);

        // Remove old token
        vm.prank(admin);
        oracle.removeToken(address(token));

        // Add with new interval
        vm.prank(admin);
        oracle.updateUsdFeedInfo(address(token), address(priceFeed), interval);

        // Price should work
        (uint256 price,) = oracle.getUsdPrice(address(token));
        assertGt(price, 0);
    }

    /// @notice Fuzz test for multiple price updates
    /// @param numUpdates Number of price updates to perform
    function testFuzz_MultiplePriceUpdates(uint256 numUpdates) public {
        // Bound to reasonable number of updates
        numUpdates = bound(numUpdates, 1, 100);

        for (uint256 i = 0; i < numUpdates; i++) {
            uint256 price = 100e8 + (i * 1e8);
            priceFeed.setPrice(int256(price));
            vm.warp(block.timestamp + 1);

            (uint256 returnedPrice,) = oracle.getUsdPrice(address(token));
            assertGt(returnedPrice, 0);
        }
    }

    /// @notice Fuzz test for price feed decimals
    /// @param decimals Number of decimals (bounded to 0-18)
    function testFuzz_PriceFeedDecimals(uint8 decimals) public {
        // Bound decimals to valid range (0-18) as Math library enforces this
        decimals = uint8(bound(uint256(decimals), 0, 18));

        // Create new price feed with specific decimals
        MockPriceFeed newFeed = new MockPriceFeed(decimals, int256(100e8));

        // Create new token
        MockERC20 newToken = new MockERC20("NEW", "NEW", 18);

        // Add to oracle
        vm.prank(admin);
        oracle.updateUsdFeedInfo(address(newToken), address(newFeed), STALENESS_INTERVAL);

        // Should get price (normalized to 18 decimals)
        (uint256 price,) = oracle.getUsdPrice(address(newToken));
        assertGt(price, 0);
    }
}
