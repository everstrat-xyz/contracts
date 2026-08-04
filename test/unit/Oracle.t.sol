// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {Registry} from "registry/Registry.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

/**
 * @title OracleTest
 * @notice Comprehensive unit tests for Oracle contract
 * @dev Tests all functionality including edge cases and error conditions
 */
contract OracleTest is ProtocolTestBase {
    Oracle public oracle;
    Registry public registry;
    MockPriceFeed public mockPriceFeed;
    MockERC20 public mockToken;

    address public admin = address(0x1);
    address public oracleManager = address(0x2);
    address public user = address(0x3);

    uint256 public constant INITIAL_PRICE = 2000e8; // $2000 with 8 decimals
    uint256 public constant STALENESS_INTERVAL = 3600; // 1 hour
    uint256 public constant PRICE_PRECISION = 1e18;

    event UsdFeedAdded(address indexed token, address priceFeed, uint256 stalenessInterval);
    event TokenRemoved(address indexed token);
    event UsdFeedUpdated(address indexed token, address oldPriceFeed, address newPriceFeed);
    event UsdStalenessIntervalUpdated(
        address indexed token, uint256 oldStalenessInterval, uint256 newStalenessInterval
    );
    event PairFeedAdded(address indexed tokenA, address indexed tokenB, address priceFeed, uint256 stalenessInterval);
    event PairFeedRemoved(address indexed tokenA, address indexed tokenB);
    event PairFeedUpdated(address indexed tokenA, address indexed tokenB, address oldPriceFeed, address newPriceFeed);
    event PairStalenessIntervalUpdated(
        address indexed tokenA, address indexed tokenB, uint256 oldStalenessInterval, uint256 newStalenessInterval
    );

    function setUp() public {
        // Deploy mock contracts
        mockPriceFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        mockToken = new MockERC20("Mock Token", "MTK", 18);

        registry = _deployRegistry(admin);

        Oracle oracleImpl = new Oracle();
        bytes memory initData = abi.encodeWithSelector(Oracle.initialize.selector, address(registry));
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), initData);
        oracle = Oracle(address(oracleProxy));

        // Oracle feed/token configuration is gated by ADMIN_ROLE; oracleManager is the
        // dedicated admin-authorized caller used across these tests.
        vm.startPrank(admin);
        registry.grantRole(Auth.ADMIN_ROLE, oracleManager);
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsRoles() public view {
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, admin));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, oracleManager));
    }

    // ============ Update Token Info Tests ============

    function test_UpdateUsdFeedInfo_AddNewToken() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        assertTrue(oracle.isTokenSupported(address(mockToken)));
        assertEq(oracle.getSupportedTokenCount(), 1);

        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(mockToken));
        assertEq(address(tokenInfo.priceFeed), address(mockPriceFeed));
        assertEq(tokenInfo.stalenessInterval, STALENESS_INTERVAL);
    }

    function test_UpdateUsdFeedInfo_AddNativeETH() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(0), address(mockPriceFeed), STALENESS_INTERVAL);

        assertTrue(oracle.isTokenSupported(address(0)));
        assertEq(oracle.getSupportedTokenCount(), 1);

        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(0));
        assertEq(address(tokenInfo.priceFeed), address(mockPriceFeed));
        assertEq(tokenInfo.stalenessInterval, STALENESS_INTERVAL);
    }

    function test_UpdateUsdFeedInfo_EmitsUsdFeedAddedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit UsdFeedAdded(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
    }

    function test_UpdateUsdFeedInfo_UpdateExisting() public {
        // Add token first time
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Update with new price feed and staleness interval
        MockPriceFeed newPriceFeed = new MockPriceFeed(8, int256(3000e8));
        uint256 newStalenessInterval = STALENESS_INTERVAL * 2;

        vm.expectEmit(true, true, true, true);
        emit UsdFeedUpdated(address(mockToken), address(mockPriceFeed), address(newPriceFeed));

        vm.expectEmit(true, true, true, true);
        emit UsdStalenessIntervalUpdated(address(mockToken), STALENESS_INTERVAL, newStalenessInterval);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(newPriceFeed), newStalenessInterval);

        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(mockToken));
        assertEq(address(tokenInfo.priceFeed), address(newPriceFeed));
        assertEq(tokenInfo.stalenessInterval, newStalenessInterval);
    }

    function test_UpdateUsdFeedInfo_UpdateOnlyPriceFeed() public {
        // Add token first
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Update only price feed
        MockPriceFeed newPriceFeed = new MockPriceFeed(8, int256(3000e8));

        vm.expectEmit(true, true, true, true);
        emit UsdFeedUpdated(address(mockToken), address(mockPriceFeed), address(newPriceFeed));

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(newPriceFeed), STALENESS_INTERVAL);

        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(mockToken));
        assertEq(address(tokenInfo.priceFeed), address(newPriceFeed));
        assertEq(tokenInfo.stalenessInterval, STALENESS_INTERVAL);
    }

    function test_UpdateUsdFeedInfo_UpdateOnlyStalenessInterval() public {
        // Add token first
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Update only staleness interval
        uint256 newStalenessInterval = STALENESS_INTERVAL * 2;

        vm.expectEmit(true, true, true, true);
        emit UsdStalenessIntervalUpdated(address(mockToken), STALENESS_INTERVAL, newStalenessInterval);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), newStalenessInterval);

        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(mockToken));
        assertEq(address(tokenInfo.priceFeed), address(mockPriceFeed));
        assertEq(tokenInfo.stalenessInterval, newStalenessInterval);
    }

    function test_UpdateUsdFeedInfo_RevertNothingToUpdate() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Try to update with same values
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleNothingToUpdate.selector);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
    }

    function test_UpdateUsdFeedInfo_InvalidInputs() public {
        // Zero price feed
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleZeroAddress.selector);
        oracle.updateUsdFeedInfo(address(mockToken), address(0), STALENESS_INTERVAL);

        // Zero staleness interval
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleZeroStalenessInterval.selector);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), 0);
    }

    function test_UpdateUsdFeedInfo_AccessControl() public {
        vm.prank(user);
        vm.expectRevert();
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
    }

    // ============ Remove Token Tests ============

    function test_RemoveToken_Success() public {
        // Add token first
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Remove token
        vm.expectEmit(true, true, true, true);
        emit TokenRemoved(address(mockToken));

        vm.prank(oracleManager);
        oracle.removeToken(address(mockToken));

        assertFalse(oracle.isTokenSupported(address(mockToken)));
        assertEq(oracle.getSupportedTokenCount(), 0);
    }

    function test_RemoveToken_NativeETH() public {
        // Add native ETH first
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(0), address(mockPriceFeed), STALENESS_INTERVAL);

        // Remove native ETH
        vm.expectEmit(true, true, true, true);
        emit TokenRemoved(address(0));

        vm.prank(oracleManager);
        oracle.removeToken(address(0));

        assertFalse(oracle.isTokenSupported(address(0)));
        assertEq(oracle.getSupportedTokenCount(), 0);
    }

    function test_RemoveToken_InvalidConditions() public {
        // Not registered
        vm.prank(oracleManager);
        vm.expectRevert();
        oracle.removeToken(address(mockToken));
    }

    function test_RemoveToken_AccessControl() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        vm.prank(user);
        vm.expectRevert();
        oracle.removeToken(address(mockToken));
    }

    // ============ Get Price Tests ============

    function test_GetUsdPrice_Success() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        (uint256 price, uint256 timestamp) = oracle.getUsdPrice(address(mockToken));

        // Price should be normalized to 18 decimals
        assertEq(price, INITIAL_PRICE * 1e10); // 2000e18
        assertEq(timestamp, 1);
    }

    function test_GetUsdPrice_WithStalenessCheck() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        uint256 price = oracle.getUsdPriceWithStalenessCheck(address(mockToken), STALENESS_INTERVAL);
        assertEq(price, INITIAL_PRICE * 1e10);
    }

    function test_GetUsdPrice_InvalidToken() public {
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.getUsdPrice(address(mockToken));

        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.getUsdPriceWithStalenessCheck(address(mockToken), STALENESS_INTERVAL);
    }

    function test_GetUsdPrice_RevertInvalidPrice() public {
        // Create price feed with negative price
        MockPriceFeed negativePriceFeed = new MockPriceFeed(8, int256(-1000e8));

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(negativePriceFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleInvalidPrice.selector);
        oracle.getUsdPrice(address(mockToken));
    }

    function test_GetUsdPrice_RevertStalePrice() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Fast forward time to make price stale
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);

        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.getUsdPrice(address(mockToken));
    }

    function test_GetUsdPriceWithStalenessCheck_RevertStalePrice() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Fast forward time to make price stale
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);

        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.getUsdPriceWithStalenessCheck(address(mockToken), STALENESS_INTERVAL);
    }

    // ============ Convert Token to USD Tests ============

    function test_ConvertTokenToUSD_Success() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        uint256 tokenAmount = 1e18; // 1 token with 18 decimals
        uint256 usdAmount = oracle.convertTokenToUSD(address(mockToken), tokenAmount, 18);

        // Price is 2000e18 (normalized), so 1 token = 2000 USD
        assertEq(usdAmount, 2000e18);
    }

    function test_ConvertTokenToUSD_DifferentDecimals() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        uint256 tokenAmount = 1e8; // 1 token with 8 decimals
        uint256 usdAmount = oracle.convertTokenToUSD(address(mockToken), tokenAmount, 8);

        // Should normalize to 18 decimals first, then multiply by price
        assertEq(usdAmount, 2000e18);
    }

    function test_ConvertTokenToUSD_InvalidConditions() public {
        // Not registered
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.convertTokenToUSD(address(mockToken), 1e18, 18);

        // Stale price
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.convertTokenToUSD(address(mockToken), 1e18, 18);

        // Invalid price
        MockPriceFeed negativePriceFeed = new MockPriceFeed(8, int256(-1000e8));
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(negativePriceFeed), STALENESS_INTERVAL);
        vm.expectRevert(IOracle.OracleInvalidPrice.selector);
        oracle.convertTokenToUSD(address(mockToken), 1e18, 18);
    }

    // ============ Convert USD to Token Tests ============

    function test_ConvertUsdToToken_Success() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        uint256 usdAmount = 2000e18; // 2000 USD
        uint256 tokenAmount = oracle.convertUsdToToken(address(mockToken), usdAmount, 18);

        // Price is 2000e18, so 2000 USD = 1 token
        assertEq(tokenAmount, 1e18);
    }

    function test_ConvertUsdToToken_DifferentDecimals() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        uint256 usdAmount = 2000e18; // 2000 USD
        uint256 tokenAmount = oracle.convertUsdToToken(address(mockToken), usdAmount, 8);

        // Should return 1e8 (1 token with 8 decimals)
        assertEq(tokenAmount, 1e8);
    }

    function test_ConvertUsdToToken_InvalidConditions() public {
        // Not registered
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.convertUsdToToken(address(mockToken), 2000e18, 18);

        // Stale price
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.convertUsdToToken(address(mockToken), 2000e18, 18);

        // Invalid price
        MockPriceFeed negativePriceFeed = new MockPriceFeed(8, int256(-1000e8));
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(negativePriceFeed), STALENESS_INTERVAL);
        vm.expectRevert(IOracle.OracleInvalidPrice.selector);
        oracle.convertUsdToToken(address(mockToken), 2000e18, 18);
    }

    // ============ Convert (Direct Token-to-Token) Tests ============

    function test_Convert_Success() public {
        // tokenIn at $2000, ETH (tokenOut) at $4000
        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(INITIAL_PRICE * 2));
        vm.startPrank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
        vm.stopPrank();

        // 1 token at $2000 = 0.5 ETH at $4000
        uint256 amountOut = oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
        assertEq(amountOut, 5e17);

        // Inverse direction: 1 ETH at $4000 = 2 tokens at $2000
        amountOut = oracle.convert(address(0), address(mockToken), 1e18, 18, 18);
        assertEq(amountOut, 2e18);
    }

    function test_Convert_DifferentDecimals() public {
        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(INITIAL_PRICE * 2));
        vm.startPrank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
        vm.stopPrank();

        // 1 token with 6 input decimals at $2000 = 0.5 ETH with 18 output decimals
        uint256 amountOut = oracle.convert(address(mockToken), address(0), 1e6, 6, 18);
        assertEq(amountOut, 5e17);

        // 1 ETH with 18 input decimals = 2 tokens with 6 output decimals
        amountOut = oracle.convert(address(0), address(mockToken), 1e18, 18, 6);
        assertEq(amountOut, 2e6);
    }

    function test_Convert_SameToken_ConvertsDecimalsOnly() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        uint256 amountOut = oracle.convert(address(mockToken), address(mockToken), 1e6, 6, 18);
        assertEq(amountOut, 1e18);
    }

    function test_Convert_MatchesChainedConversions() public {
        // Cross-rate must agree with convertTokenToUSD -> convertUsdToToken chaining
        // when no precision is lost (round prices).
        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(INITIAL_PRICE * 2));
        vm.startPrank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
        vm.stopPrank();

        uint256 tokenAmount = 3e18;
        uint256 usdAmount = oracle.convertTokenToUSD(address(mockToken), tokenAmount, 18);
        uint256 chained = oracle.convertUsdToToken(address(0), usdAmount, 18);
        uint256 direct = oracle.convert(address(mockToken), address(0), tokenAmount, 18, 18);

        assertEq(direct, chained);
    }

    function test_Convert_InvalidConditions() public {
        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(INITIAL_PRICE * 2));

        // tokenIn not registered
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.convert(address(mockToken), address(0), 1e18, 18, 18);

        // tokenOut not registered
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.convert(address(mockToken), address(0), 1e18, 18, 18);

        // Stale price on either side reverts (both feeds share the same update time here)
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
    }

    function test_Convert_RevertsWhenOutputFeedStale() public {
        // Only the OUTPUT feed is stale: the input feed stays fresh
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        MockPriceFeed staleEthFeed = new MockPriceFeed(8, int256(INITIAL_PRICE * 2));
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(0), address(staleEthFeed), STALENESS_INTERVAL);

        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        mockPriceFeed.setUpdatedAt(block.timestamp); // refresh only the input feed

        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
    }

    // ============ Pair Feed Tests ============

    function _registerTokenAndEthUsdFeeds() internal returns (MockPriceFeed ethUsdFeed) {
        ethUsdFeed = new MockPriceFeed(8, int256(INITIAL_PRICE * 2)); // ETH = $4000
        vm.startPrank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL); // token = $2000
        oracle.updateUsdFeedInfo(address(0), address(ethUsdFeed), STALENESS_INTERVAL);
        vm.stopPrank();
    }

    function test_UpdatePairFeedInfo_AddPair() public {
        _registerTokenAndEthUsdFeeds();
        // Direct feed: 1 mockToken = 0.5 ETH
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7)); // 0.5 with 8 decimals

        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        assertTrue(oracle.isPairSupported(address(mockToken), address(0)));
        IOracle.FeedInfo memory pairInfo = oracle.getPairFeedInfo(address(mockToken), address(0));
        assertEq(address(pairInfo.priceFeed), address(pairFeed));
        assertEq(pairInfo.stalenessInterval, STALENESS_INTERVAL);
    }

    function test_UpdatePairFeedInfo_EmitsPairFeedAdded() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));

        vm.expectEmit(true, true, true, true);
        emit PairFeedAdded(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);
    }

    function test_UpdatePairFeedInfo_UpdateExisting() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));
        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        MockPriceFeed newPairFeed = new MockPriceFeed(8, int256(6e7));
        uint256 newStaleness = STALENESS_INTERVAL * 2;

        vm.expectEmit(true, true, true, true);
        emit PairFeedUpdated(address(mockToken), address(0), address(pairFeed), address(newPairFeed));
        vm.expectEmit(true, true, true, true);
        emit PairStalenessIntervalUpdated(address(mockToken), address(0), STALENESS_INTERVAL, newStaleness);

        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(newPairFeed), newStaleness);

        IOracle.FeedInfo memory pairInfo = oracle.getPairFeedInfo(address(mockToken), address(0));
        assertEq(address(pairInfo.priceFeed), address(newPairFeed));
        assertEq(pairInfo.stalenessInterval, newStaleness);
    }

    function test_UpdatePairFeedInfo_RevertNothingToUpdate() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));
        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleNothingToUpdate.selector);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);
    }

    function test_UpdatePairFeedInfo_InvalidInputs() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));

        // Identical tokens
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleIdenticalTokens.selector);
        oracle.updatePairFeedInfo(address(mockToken), address(mockToken), address(pairFeed), STALENESS_INTERVAL);

        // Zero price feed
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleZeroAddress.selector);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(0), STALENESS_INTERVAL);

        // Zero staleness
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleZeroStalenessInterval.selector);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), 0);

        // Unsupported token on either side
        MockERC20 unsupported = new MockERC20("Unsupported", "UNS", 18);
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.updatePairFeedInfo(address(unsupported), address(0), address(pairFeed), STALENESS_INTERVAL);

        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.updatePairFeedInfo(address(mockToken), address(unsupported), address(pairFeed), STALENESS_INTERVAL);
    }

    function test_UpdatePairFeedInfo_AccessControl() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));

        vm.prank(user);
        vm.expectRevert();
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);
    }

    function test_UpdatePairFeedInfo_RevertInvalidFeedDecimals() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed invalidFeed = new MockPriceFeed(19, int256(5e7));

        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleInvalidFeedDecimals.selector);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(invalidFeed), STALENESS_INTERVAL);

        assertFalse(oracle.isPairSupported(address(mockToken), address(0)));
    }

    function test_RemovePairFeedInfo_Success() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));
        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        vm.expectEmit(true, true, true, true);
        emit PairFeedRemoved(address(mockToken), address(0));

        vm.prank(oracleManager);
        oracle.removePairFeedInfo(address(mockToken), address(0));

        assertFalse(oracle.isPairSupported(address(mockToken), address(0)));
    }

    function test_GetSupportedPairs_ReturnsRegisteredQuotes() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));
        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        address[] memory pairs = oracle.getSupportedPairs(address(mockToken));
        assertEq(pairs.length, 1);
        assertEq(pairs[0], address(0));
    }

    function test_RemoveToken_ClearsOutboundAndInboundPairs() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed outFeed = new MockPriceFeed(8, int256(5e7));
        MockPriceFeed inFeed = new MockPriceFeed(8, int256(2e8));

        vm.startPrank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(outFeed), STALENESS_INTERVAL);
        oracle.updatePairFeedInfo(address(0), address(mockToken), address(inFeed), STALENESS_INTERVAL);
        vm.stopPrank();

        assertTrue(oracle.isPairSupported(address(mockToken), address(0)));
        assertTrue(oracle.isPairSupported(address(0), address(mockToken)));

        vm.expectEmit(true, true, true, true);
        emit PairFeedRemoved(address(mockToken), address(0));
        vm.expectEmit(true, true, true, true);
        emit PairFeedRemoved(address(0), address(mockToken));
        vm.expectEmit(true, false, false, true);
        emit TokenRemoved(address(mockToken));

        vm.prank(oracleManager);
        oracle.removeToken(address(mockToken));

        assertFalse(oracle.isTokenSupported(address(mockToken)));
        assertFalse(oracle.isPairSupported(address(mockToken), address(0)));
        assertFalse(oracle.isPairSupported(address(0), address(mockToken)));
        assertEq(oracle.getSupportedPairs(address(0)).length, 0);
    }

    function test_RemovePairFeedInfo_RevertNotRegistered() public {
        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OraclePairNotRegistered.selector);
        oracle.removePairFeedInfo(address(mockToken), address(0));
    }

    function test_GetPairFeedInfo_RevertNotRegistered() public {
        vm.expectRevert(IOracle.OraclePairNotRegistered.selector);
        oracle.getPairFeedInfo(address(mockToken), address(0));
    }

    function test_GetPairPrice_Success() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7)); // 0.5 with 8 decimals

        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        (uint256 price, uint256 timestamp) = oracle.getPairPrice(address(mockToken), address(0));
        assertEq(price, 5e17);
        assertEq(timestamp, block.timestamp);
    }

    function test_GetPairPrice_RevertNotRegistered() public {
        vm.expectRevert(IOracle.OraclePairNotRegistered.selector);
        oracle.getPairPrice(address(mockToken), address(0));
    }

    function test_GetPairPrice_RevertStale() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));
        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.getPairPrice(address(mockToken), address(0));
    }

    function test_GetPairPriceWithStalenessCheck_CustomStaleness() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7));
        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        // Custom bound is stricter than elapsed time -> still stale
        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.getPairPriceWithStalenessCheck(address(mockToken), address(0), STALENESS_INTERVAL);

        // Looser custom bound allows the read
        uint256 price = oracle.getPairPriceWithStalenessCheck(address(mockToken), address(0), STALENESS_INTERVAL + 10);
        assertEq(price, 5e17);
    }

    function test_Convert_PrefersDirectPairFeed() public {
        // USD cross-rate would give 0.5 ETH per token ($2000 / $4000).
        // Direct pair quotes 0.25 ETH per token — convert must use the pair.
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(25e6)); // 0.25 with 8 decimals

        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        uint256 amountOut = oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
        assertEq(amountOut, 25e16); // 0.25 ETH
    }

    function test_Convert_UsesInvertedPairFeed() public {
        // Only ETH/token feed registered (2 tokens per ETH). convert(token -> ETH) inverts it.
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed invertedFeed = new MockPriceFeed(8, int256(2e8)); // 2.0 tokens per ETH

        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(0), address(mockToken), address(invertedFeed), STALENESS_INTERVAL);

        // 1 token -> 0.5 ETH via inverse of 2 tokens/ETH
        uint256 amountOut = oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
        assertEq(amountOut, 5e17);
    }

    function test_Convert_FallsBackToUsdCrossRateWithoutPair() public {
        _registerTokenAndEthUsdFeeds();

        // No pair registered: 1 token at $2000 = 0.5 ETH at $4000
        uint256 amountOut = oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
        assertEq(amountOut, 5e17);
    }

    function test_Convert_StalePairFeedDoesNotFallBackToUsd() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(25e6));
        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        // Keep USD feeds fresh so a silent fallback would succeed
        mockPriceFeed.setUpdatedAt(block.timestamp);
        // ethUsdFeed from helper is not accessible — refresh via getUsdFeedInfo
        IOracle.FeedInfo memory ethInfo = oracle.getUsdFeedInfo(address(0));
        MockPriceFeed(address(ethInfo.priceFeed)).setUpdatedAt(block.timestamp);

        vm.expectRevert(IOracle.OracleStalePrice.selector);
        oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
    }

    function test_Convert_AfterPairRemovalUsesUsdCrossRate() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(25e6)); // 0.25 ETH/token
        vm.startPrank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);
        oracle.removePairFeedInfo(address(mockToken), address(0));
        vm.stopPrank();

        uint256 amountOut = oracle.convert(address(mockToken), address(0), 1e18, 18, 18);
        assertEq(amountOut, 5e17); // USD cross-rate again
    }

    function test_Convert_DirectPair_DifferentDecimals() public {
        _registerTokenAndEthUsdFeeds();
        MockPriceFeed pairFeed = new MockPriceFeed(8, int256(5e7)); // 0.5 ETH per token

        vm.prank(oracleManager);
        oracle.updatePairFeedInfo(address(mockToken), address(0), address(pairFeed), STALENESS_INTERVAL);

        uint256 amountOut = oracle.convert(address(mockToken), address(0), 1e6, 6, 18);
        assertEq(amountOut, 5e17);
    }

    // ============ View Function Tests ============

    function test_GetSupportedTokenCount_Empty() public view {
        assertEq(oracle.getSupportedTokenCount(), 0);
    }

    function test_GetSupportedTokenCount_Multiple() public {
        vm.startPrank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        MockERC20 token2 = new MockERC20("Token2", "TK2", 18);
        MockPriceFeed priceFeed2 = new MockPriceFeed(8, int256(3000e8));
        oracle.updateUsdFeedInfo(address(token2), address(priceFeed2), STALENESS_INTERVAL);
        vm.stopPrank();

        assertEq(oracle.getSupportedTokenCount(), 2);
    }

    function test_GetSupportedTokens_Empty() public view {
        address[] memory tokens = oracle.getSupportedTokens();
        assertEq(tokens.length, 0);
    }

    function test_GetSupportedTokens_Multiple() public {
        vm.startPrank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        MockERC20 token2 = new MockERC20("Token2", "TK2", 18);
        MockPriceFeed priceFeed2 = new MockPriceFeed(8, int256(3000e8));
        oracle.updateUsdFeedInfo(address(token2), address(priceFeed2), STALENESS_INTERVAL);
        vm.stopPrank();

        address[] memory tokens = oracle.getSupportedTokens();
        assertEq(tokens.length, 2);

        // Check that both tokens are in the array
        bool found1 = false;
        bool found2 = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(mockToken)) found1 = true;
            if (tokens[i] == address(token2)) found2 = true;
        }
        assertTrue(found1);
        assertTrue(found2);
    }

    function test_IsTokenSupported_False() public view {
        assertFalse(oracle.isTokenSupported(address(mockToken)));
    }

    function test_IsTokenSupported_True() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        assertTrue(oracle.isTokenSupported(address(mockToken)));
    }

    function test_IsTokenSupported_NativeETH() public {
        // Add native ETH (address(0))
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(0), address(mockPriceFeed), STALENESS_INTERVAL);

        assertTrue(oracle.isTokenSupported(address(0)));
    }

    function test_GetUsdFeedInfo_Success() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(mockToken));
        assertEq(address(tokenInfo.priceFeed), address(mockPriceFeed));
        assertEq(tokenInfo.stalenessInterval, STALENESS_INTERVAL);
    }

    function test_GetUsdFeedInfo_InvalidToken() public {
        vm.expectRevert(IOracle.OracleTokenNotSupported.selector);
        oracle.getUsdFeedInfo(address(mockToken));
    }

    // ============ Edge Cases and Fuzz Tests ============

    function testFuzz_GetUsdPriceWithStalenessCheck(uint256 maxStaleness) public {
        vm.assume(maxStaleness > 0 && maxStaleness < type(uint256).max);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // The mock price feed has updatedAt = 1, so staleness check depends on block.timestamp - 1
        // For small maxStaleness values, it should revert due to staleness
        if (maxStaleness >= block.timestamp - 1) {
            uint256 price = oracle.getUsdPriceWithStalenessCheck(address(mockToken), maxStaleness);
            assertEq(price, INITIAL_PRICE * 1e10);
        } else {
            vm.expectRevert(IOracle.OracleStalePrice.selector);
            oracle.getUsdPriceWithStalenessCheck(address(mockToken), maxStaleness);
        }
    }

    function testFuzz_AddMultipleTokens(uint8 tokenCount) public {
        vm.assume(tokenCount > 0 && tokenCount <= 10);

        for (uint8 i = 0; i < tokenCount; i++) {
            MockERC20 token = new MockERC20(string(abi.encodePacked("Token", i)), string(abi.encodePacked("TK", i)), 18);
            MockPriceFeed priceFeed = new MockPriceFeed(8, int256(INITIAL_PRICE + i * 100e8));

            vm.prank(oracleManager);
            oracle.updateUsdFeedInfo(address(token), address(priceFeed), STALENESS_INTERVAL);
        }

        assertEq(oracle.getSupportedTokenCount(), tokenCount);

        address[] memory supportedTokens = oracle.getSupportedTokens();
        assertEq(supportedTokens.length, tokenCount);
    }

    function test_PriceFeedWithDifferentDecimals() public {
        // Test with 18 decimal price feed
        MockPriceFeed priceFeed18 = new MockPriceFeed(18, int256(2000e18));
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(priceFeed18), STALENESS_INTERVAL);

        (uint256 price,) = oracle.getUsdPrice(address(mockToken));
        // Should already be normalized to 18 decimals
        assertEq(price, 2000e18);
    }

    function test_ConvertTokenToUSD_WithDifferentPriceFeedDecimals() public {
        // Test with 18 decimal price feed
        MockPriceFeed priceFeed18 = new MockPriceFeed(18, int256(2000e18));
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(priceFeed18), STALENESS_INTERVAL);

        uint256 tokenAmount = 1e18;
        uint256 usdAmount = oracle.convertTokenToUSD(address(mockToken), tokenAmount, 18);
        assertEq(usdAmount, 2000e18);
    }

    function test_GetUsdPriceWithStalenessCheck_CustomStaleness() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // Use a larger staleness check than the token's default
        uint256 customStaleness = STALENESS_INTERVAL * 2;
        uint256 price = oracle.getUsdPriceWithStalenessCheck(address(mockToken), customStaleness);
        assertEq(price, INITIAL_PRICE * 1e10);
    }

    function test_GetUsdPriceWithStalenessCheck_StricterStaleness() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL * 2);

        // Use a stricter staleness check than the token's default
        uint256 strictStaleness = STALENESS_INTERVAL;
        uint256 price = oracle.getUsdPriceWithStalenessCheck(address(mockToken), strictStaleness);
        assertEq(price, INITIAL_PRICE * 1e10);
    }

    // ============ Integration Tests ============

    function test_CompleteWorkflow() public {
        // 1. Add token with price feed
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        // 2. Get price
        (uint256 price, uint256 timestamp) = oracle.getUsdPrice(address(mockToken));
        assertEq(price, INITIAL_PRICE * 1e10);

        // 3. Update price feed and staleness interval
        MockPriceFeed newPriceFeed = new MockPriceFeed(8, int256(3000e8));
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(newPriceFeed), STALENESS_INTERVAL * 2);

        // 4. Get updated price
        (price, timestamp) = oracle.getUsdPrice(address(mockToken));
        assertEq(price, 3000e18);

        // 5. Verify updated staleness interval
        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(mockToken));
        assertEq(tokenInfo.stalenessInterval, STALENESS_INTERVAL * 2);

        // 6. Remove token
        vm.prank(oracleManager);
        oracle.removeToken(address(mockToken));

        assertFalse(oracle.isTokenSupported(address(mockToken)));
    }

    // ============ Chainlink Safety Checks ============

    // --- updatedAt == 0 ---

    function test_GetUsdPrice_RevertUpdatedAtZero() public {
        MockPriceFeed zeroTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        zeroTimestampFeed.setUpdatedAt(0);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(zeroTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleNoRoundData.selector);
        oracle.getUsdPrice(address(mockToken));
    }

    function test_GetUsdPriceWithStalenessCheck_RevertUpdatedAtZero() public {
        MockPriceFeed zeroTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        zeroTimestampFeed.setUpdatedAt(0);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(zeroTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleNoRoundData.selector);
        oracle.getUsdPriceWithStalenessCheck(address(mockToken), STALENESS_INTERVAL);
    }

    function test_ConvertTokenToUSD_RevertUpdatedAtZero() public {
        MockPriceFeed zeroTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        zeroTimestampFeed.setUpdatedAt(0);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(zeroTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleNoRoundData.selector);
        oracle.convertTokenToUSD(address(mockToken), 1e18, 18);
    }

    function test_ConvertUsdToToken_RevertUpdatedAtZero() public {
        MockPriceFeed zeroTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        zeroTimestampFeed.setUpdatedAt(0);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(zeroTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleNoRoundData.selector);
        oracle.convertUsdToToken(address(mockToken), 1e18, 18);
    }

    // --- updatedAt > block.timestamp ---

    function test_GetUsdPrice_RevertInvalidTimestamp() public {
        MockPriceFeed futureTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        futureTimestampFeed.setUpdatedAt(block.timestamp + 1);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(futureTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleInvalidTimestamp.selector);
        oracle.getUsdPrice(address(mockToken));
    }

    function test_GetUsdPriceWithStalenessCheck_RevertInvalidTimestamp() public {
        MockPriceFeed futureTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        futureTimestampFeed.setUpdatedAt(block.timestamp + 1);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(futureTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleInvalidTimestamp.selector);
        oracle.getUsdPriceWithStalenessCheck(address(mockToken), STALENESS_INTERVAL);
    }

    function test_ConvertTokenToUSD_RevertInvalidTimestamp() public {
        MockPriceFeed futureTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        futureTimestampFeed.setUpdatedAt(block.timestamp + 1);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(futureTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleInvalidTimestamp.selector);
        oracle.convertTokenToUSD(address(mockToken), 1e18, 18);
    }

    function test_ConvertUsdToToken_RevertInvalidTimestamp() public {
        MockPriceFeed futureTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        futureTimestampFeed.setUpdatedAt(block.timestamp + 1);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(futureTimestampFeed), STALENESS_INTERVAL);

        vm.expectRevert(IOracle.OracleInvalidTimestamp.selector);
        oracle.convertUsdToToken(address(mockToken), 1e18, 18);
    }

    function test_GetUsdPrice_PassesWhenUpdatedAtEqualsBlockTimestamp() public {
        MockPriceFeed currentTimestampFeed = new MockPriceFeed(8, int256(INITIAL_PRICE));
        currentTimestampFeed.setUpdatedAt(block.timestamp);

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(currentTimestampFeed), STALENESS_INTERVAL);

        (uint256 price, uint256 timestamp) = oracle.getUsdPrice(address(mockToken));
        assertEq(price, INITIAL_PRICE * 1e10);
        assertEq(timestamp, block.timestamp);
    }

    // --- decimals > 18 on feed registration ---

    function test_UpdateUsdFeedInfo_RevertInvalidFeedDecimals_OnAdd() public {
        MockPriceFeed invalidFeed = new MockPriceFeed(19, int256(INITIAL_PRICE));

        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleInvalidFeedDecimals.selector);
        oracle.updateUsdFeedInfo(address(mockToken), address(invalidFeed), STALENESS_INTERVAL);

        assertFalse(oracle.isTokenSupported(address(mockToken)));
    }

    function test_UpdateUsdFeedInfo_RevertInvalidFeedDecimals_OnUpdate() public {
        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(mockPriceFeed), STALENESS_INTERVAL);

        MockPriceFeed invalidFeed = new MockPriceFeed(20, int256(INITIAL_PRICE));

        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleInvalidFeedDecimals.selector);
        oracle.updateUsdFeedInfo(address(mockToken), address(invalidFeed), STALENESS_INTERVAL);

        // Original feed must remain unchanged after rejected update
        IOracle.FeedInfo memory tokenInfo = oracle.getUsdFeedInfo(address(mockToken));
        assertEq(address(tokenInfo.priceFeed), address(mockPriceFeed));
    }

    function test_UpdateUsdFeedInfo_AcceptsFeedWithExactly18Decimals() public {
        MockPriceFeed feed18 = new MockPriceFeed(18, int256(2000e18));

        vm.prank(oracleManager);
        oracle.updateUsdFeedInfo(address(mockToken), address(feed18), STALENESS_INTERVAL);

        assertTrue(oracle.isTokenSupported(address(mockToken)));
        (uint256 price,) = oracle.getUsdPrice(address(mockToken));
        assertEq(price, 2000e18);
    }

    function testFuzz_UpdateUsdFeedInfo_RevertInvalidFeedDecimals(uint8 _decimals) public {
        vm.assume(_decimals > 18);
        MockPriceFeed invalidFeed = new MockPriceFeed(_decimals, int256(INITIAL_PRICE));

        vm.prank(oracleManager);
        vm.expectRevert(IOracle.OracleInvalidFeedDecimals.selector);
        oracle.updateUsdFeedInfo(address(mockToken), address(invalidFeed), STALENESS_INTERVAL);
    }
}
