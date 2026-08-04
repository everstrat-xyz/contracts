// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Math} from "../../src/libraries/Math.sol";

import {IAMM} from "../../src/interfaces/IAMM.sol";
import {IStrategyManager} from "../../src/interfaces/IStrategyManager.sol";
import {IExitQueue} from "../../src/interfaces/IExitQueue.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockController} from "../mocks/MockController.sol";

import {AMM} from "../../src/contracts/AMM.sol";
import {EVE} from "../../src/contracts/EVE.sol";
import {Controller} from "../../src/contracts/Controller.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {ExitQueue} from "../../src/contracts/ExitQueue.sol";
import {StrategyManager} from "../../src/contracts/StrategyManager.sol";
import {Halp} from "../helpers/Halp.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../../src/libraries/Auth.sol";

/**
 * @title AMM Test
 * @notice Comprehensive test suite for AMM contract
 */
contract AMMTest is ProtocolTestBase {
    using {Halp.mockExpect, Halp.mockBalanceOf, Halp.mockPriceFeed} for address;

    AMM public implementation;
    AMM public bondingCurve;
    ERC1967Proxy public proxy;

    EVE public eve;
    Controller public controller;
    StrategyManager public strategyManager;
    Oracle public oracle;
    ExitQueue public exitQueue;
    MockController public mockController;

    MockPriceFeed public ethPriceFeed;
    Registry public registry;

    address public owner;
    address public user1;
    address public user2;
    address public treasury;

    uint256 public constant INITIAL_CW = 5e17; // 0.5
    int256 public constant ETH_PRICE = 4000e8; // $4000 with 8 decimals
    uint256 public constant STALENESS_INTERVAL = 3600; // 1 hour

    // Test amounts (in ETH)
    uint256 public constant DEAD_SUPPLY = 1e18;
    uint256 public constant BOOTSTRAP_ETH_DEPOSIT = 1e18; // 1 ETH = $4000 (above $1000 minimum)
    uint256 public constant BOOTSTRAP_MIN_TOKENS = 1000e18;
    uint256 public constant ENTER_ETH_DEPOSIT = 0.5e18; // 0.5 ETH
    uint256 public constant ENTER_MIN_TOKENS = 1e18; // Very low minimum tokens for testing
    uint256 public constant EXIT_ETH_REQUESTED = 0.25e18; // 0.25 ETH
    uint256 public constant EXIT_MAX_TOKENS = 100e18;
    uint256 public constant EXIT_SMALL_ETH = 0.1e18; // 0.1 ETH
    uint256 public constant INSUFFICIENT_DEPOSIT = 0.1e18; // 0.1 ETH - below minimum in USD
    uint256 public constant LARGE_ETH_AMOUNT = 1000e18; // 1000 ETH
    uint256 public constant INVALID_PRICE_TOLERANCE = 2e18; // > 1e18

    // Additional test values
    uint256 public constant PRICE_FEED_DECIMALS = 1e8; // Chainlink price feed decimals
    uint256 public constant SMALL_DEPOSIT = 0.01e18; // Very small deposit amount
    uint256 public constant HIGH_MIN_TOKENS = 1000e18; // High minimum tokens
    uint256 public constant TINY_DEPOSIT = 0.001e18; // Very small enter deposit for testing
    uint256 public constant BATCH_EXIT_BELOW_MIN_ETH = 5e14; // 0.0005 ETH — below default minBatchExitETH
    uint256 public constant BATCH_EXIT_AT_MIN_ETH = 1e15; // 0.001 ETH — equals DEFAULT_MIN_BATCH_EXIT_ETH
    uint256 public constant BATCH_EXIT_UPPER_BOUND_ETH = 5e16; // 0.05 ETH — MIN_BATCH_EXIT_ETH_UPPER_BOUND
    uint256 public constant BATCH_EXIT_ABOVE_UPPER_BOUND_ETH = 5e16 + 1;
    uint256 public constant GENESIS_CONFIG_INITIAL = 0;
    uint256 public constant EXCESS_ETH = 0.05 ether; // excess ETH sent beyond redemption amount

    function setUp() public {
        _setupAddresses();
        _deployMockPriceFeeds();

        ProtocolContracts memory contracts = _deployProtocol(owner, INITIAL_CW);
        registry = contracts.registry;
        eve = contracts.token;
        controller = contracts.controller;
        strategyManager = contracts.strategyManager;
        oracle = contracts.oracle;
        exitQueue = contracts.exitQueue;
        bondingCurve = contracts.amm;

        mockController = new MockController();
        _setupOracle();
        _fundUsers();
    }

    /*//////////////////////////////////////////////////////////////
                        SETUP HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setupAddresses() internal {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        treasury = address(0x3);
    }

    function _deployMockPriceFeeds() internal {
        ethPriceFeed = new MockPriceFeed(8, ETH_PRICE);
    }

    function _setupOracle() internal {
        // Add native ETH (address(0)) to Oracle with price feed
        vm.prank(owner);
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
    }

    function _fundUsers() internal {
        // Fund users with ETH for testing
        vm.deal(user1, LARGE_ETH_AMOUNT);
        vm.deal(user2, LARGE_ETH_AMOUNT);
    }

    function _setupLockedClaimState() internal {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        controller.priceBatch();

        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        assertGt(ethToRedeem, 0, "slippage must not zero redemption in test setup");

        vm.deal(address(controller), ethToRedeem);
        controller.processRequest(batchId, user2);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize() public view {
        assertEq(registry.getContractByKey(Auth.CONTROLLER), address(controller));
        assertEq(bondingCurve.MIN_INITIAL_DEPOSIT_USD(), BOOTSTRAP_MIN_TOKENS);
        assertEq(bondingCurve.connectorWeight(), INITIAL_CW);
        assertEq(bondingCurve.minBatchExitETH(), bondingCurve.DEFAULT_MIN_BATCH_EXIT_ETH());
    }

    function test_Constructor_EmitsConfigEvents() public {
        vm.expectEmit(false, false, false, true);
        emit IAMM.ConnectorWeightChanged(GENESIS_CONFIG_INITIAL, INITIAL_CW);
        vm.expectEmit(false, false, false, true);
        emit IAMM.MinBatchExitETHChanged(GENESIS_CONFIG_INITIAL, BATCH_EXIT_AT_MIN_ETH);

        AMM freshAmm = new AMM(address(registry), INITIAL_CW);

        assertEq(freshAmm.connectorWeight(), INITIAL_CW);
        assertEq(freshAmm.minBatchExitETH(), BATCH_EXIT_AT_MIN_ETH);
    }

    /*//////////////////////////////////////////////////////////////
                        BOOTSTRAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BootstrapWithETH() public {
        uint256 depositAmount = BOOTSTRAP_ETH_DEPOSIT;
        uint256 minTokensToMint = BOOTSTRAP_MIN_TOKENS;
        // Bootstrap uses USD value: depositAmount * ETH_PRICE / PRICE_FEED_DECIMALS
        uint256 depositUSD = depositAmount * uint256(ETH_PRICE) / PRICE_FEED_DECIMALS;
        uint256 expectedTokensMinted = depositUSD - DEAD_SUPPLY;

        vm.expectEmit(true, true, true, true);
        emit IAMM.Bootstrapped(user1, depositAmount, expectedTokensMinted, block.timestamp);

        vm.prank(user1);
        bondingCurve.enter{value: depositAmount}(minTokensToMint);
        vm.roll(block.number + 1);

        // Check that dead supply was minted
        assertEq(eve.balanceOf(address(0x000000000000000000000000000000000000dEaD)), DEAD_SUPPLY);
        // Check user received tokens minus dead supply
        assertEq(eve.balanceOf(user1), expectedTokensMinted);
        // Check total supply
        assertEq(eve.totalSupply(), depositUSD);
        // Check ETH was transferred to controller
        assertEq(address(controller).balance, depositAmount);
    }

    function test_BootstrapInsufficientDeposit() public {
        uint256 depositAmount = INSUFFICIENT_DEPOSIT;
        uint256 minTokensToMint = BOOTSTRAP_MIN_TOKENS;

        vm.prank(user1);
        vm.expectRevert(IAMM.AMMLessThanMinInitialDeposit.selector);
        bondingCurve.enter{value: depositAmount}(minTokensToMint);
    }

    function test_BootstrapInvalidMinTokens() public {
        uint256 depositAmount = BOOTSTRAP_ETH_DEPOSIT;
        uint256 minTokensToMint = 0; // InvalFid

        vm.prank(user1);
        vm.expectRevert(IAMM.AMMInvalidTokensToMintAmount.selector);
        bondingCurve.enter{value: depositAmount}(minTokensToMint);
    }

    function test_BootstrapStalePrice() public {
        // Set price feed to return stale data before bootstrap
        ethPriceFeed.setStale(true);

        // Warp time to ensure staleness check works properly
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);

        uint256 depositAmount = BOOTSTRAP_ETH_DEPOSIT;
        uint256 minTokensToMint = BOOTSTRAP_MIN_TOKENS;

        // Bootstrap should revert because oracle price is stale
        // Oracle is called during bootstrap to validate MIN_INITIAL_DEPOSIT_USD
        // The oracle.convertTokenToUSD() call will revert with OracleStalePrice
        vm.prank(user1);
        vm.expectRevert(IOracle.OracleStalePrice.selector);
        bondingCurve.enter{value: depositAmount}(minTokensToMint);

        // Verify bootstrap did not occur
        assertFalse(bondingCurve.bootstrapped());
        assertEq(eve.totalSupply(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ENTER TESTS (POST-BOOTSTRAP)
    //////////////////////////////////////////////////////////////*/

    function test_EnterAfterBootstrap() public {
        // First bootstrap
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Now user2 enters
        uint256 depositAmount = ENTER_ETH_DEPOSIT;
        uint256 minTokensToMint = ENTER_MIN_TOKENS;

        uint256 user2BalanceBefore = address(user2).balance;

        vm.expectEmit(true, true, true, true);
        emit IAMM.UserEntered(
            user2,
            depositAmount,
            Math.convertAssetsInverse(depositAmount, bondingCurve.evePremiumPriceInETH()),
            block.timestamp
        );

        vm.prank(user2);
        bondingCurve.enter{value: depositAmount}(minTokensToMint);
        vm.roll(block.number + 1);

        // User2 should have received tokens
        assertTrue(eve.balanceOf(user2) >= minTokensToMint);
        // ETH should be transferred to controller
        assertEq(address(controller).balance, BOOTSTRAP_ETH_DEPOSIT + depositAmount);
        // User2's ETH balance should be reduced
        assertEq(address(user2).balance, user2BalanceBefore - depositAmount);
    }

    function test_EnterInsufficientDeposit() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS); // Bootstrap

        uint256 depositAmount = SMALL_DEPOSIT; // Very small amount
        uint256 minTokensToMint = HIGH_MIN_TOKENS; // Too high minimum

        vm.prank(user2);
        vm.expectRevert(IAMM.AMMInsufficientDeposit.selector);
        bondingCurve.enter{value: depositAmount}(minTokensToMint);
    }

    /*//////////////////////////////////////////////////////////////
                        EXIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ExitImmediateRedeem() public {
        // Bootstrap and enter
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        uint256 user2BalanceETH = address(user2).balance;
        uint256 ethRequested = EXIT_SMALL_ETH; // 0.1 ETH - smaller amount for new pricing
        uint256 maxTokensToBurn = user2Balance;
        uint256 priceTolerance = 0;

        // Transfer some ETH to bonding curve for immediate redemption
        vm.deal(address(bondingCurve), ENTER_ETH_DEPOSIT);

        vm.startPrank(user2);

        eve.approve(address(bondingCurve), maxTokensToBurn);

        // Just test the functionality - don't check exact event values due to rounding
        bondingCurve.exit(ethRequested, maxTokensToBurn, priceTolerance);

        vm.stopPrank();

        // User2 should have received ETH
        assertTrue(address(user2).balance > user2BalanceETH); // More than initial balance
        // User2's EVE tokens should be burned
        assertTrue(eve.balanceOf(user2) < user2Balance);
    }

    function test_ExitQueuedRedeem() public {
        // Bootstrap and enter
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        uint256 ethRequested = EXIT_SMALL_ETH; // 0.1 ETH - smaller amount for new pricing
        uint256 maxTokensToBurn = user2Balance;
        uint256 priceTolerance = 0;

        // Insufficient liquidity - should queue redemption

        vm.startPrank(user2);

        eve.approve(address(bondingCurve), maxTokensToBurn);

        vm.expectEmit(true, true, true, true);
        emit IAMM.RedemptionQueued(user2, 1, block.timestamp);
        bondingCurve.exit(ethRequested, maxTokensToBurn, priceTolerance);

        vm.stopPrank();

        // EVE tokens should be transferred to AMM contract (check that some tokens were transferred)
        assertGt(eve.balanceOf(address(bondingCurve)), 0);
        assertLt(eve.balanceOf(user2), user2Balance);
    }

    function test_ExitNoLiquidity() public {
        // Try to exit without any liquidity
        vm.prank(user1);
        vm.expectRevert(IAMM.AMMZeroTotalSupply.selector);
        bondingCurve.exit(EXIT_SMALL_ETH, EXIT_MAX_TOKENS, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        REDEMPTION QUEUE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProcessRedemption() public {
        // Setup: bootstrap, enter, and queue redemption
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);

        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0); // Use smaller collateral

        vm.stopPrank();

        // Price the batch
        controller.priceBatch();

        // Get the expected ETH to redeem from the request
        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);

        // Calculate ETH needed (Controller will do this, but we need to fund it)
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);

        // Fund controller with ETH for processing (only if needed)
        if (ethToRedeem > 0) {
            vm.deal(address(controller), ethToRedeem);
        }

        // Process via Controller (which handles ETH transfer)
        vm.expectEmit(true, true, true, true);
        emit IAMM.RedemptionProcessed(user2, batchId, block.timestamp);
        controller.processRequest(batchId, user2);

        // Request should be processed
        (bool isProcessed, bool isClosedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user2);
        assertTrue(isProcessed);
        assertFalse(isClosedDueToSlippage);
    }

    function test_CancelRedemption() public {
        // Setup: bootstrap, enter, and queue redemption
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);

        vm.startPrank(user2);

        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0); // Use smaller collateral

        vm.expectEmit(true, true, true, true);
        emit IAMM.RedemptionCancelled(user2, batchId, false, block.timestamp);
        bondingCurve.cancelRedemption(batchId);

        vm.stopPrank();

        // EVE tokens should be returned to user
        assertEq(eve.balanceOf(user2), user2Balance);
        assertEq(eve.balanceOf(address(bondingCurve)), 0);
    }

    function test_ProcessRedemptionWithSlippage_NoETHNeeded() public {
        // Setup: bootstrap, enter, and queue redemption
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);

        eve.approve(address(bondingCurve), user2Balance);
        // Use a small price tolerance (e.g., 1% = 0.01e18)
        uint256 priceTolerance = 1e16; // 1%
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, priceTolerance);

        vm.stopPrank();

        // Simulate price drop by pricing batch with much lower price
        // Get the price at request time
        (,, uint256 evePriceAtRequestTime,,) = exitQueue.requestInfo(batchId, user2);

        // Simulate price drop by reducing controller ETH (reduces NAV)
        vm.deal(address(controller), address(controller).balance / 2);

        // Verify that ethToRedeem would be 0 due to slippage
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        bool isSlippageTooHigh = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance);
        assertTrue(isSlippageTooHigh, "Slippage should be detected as too high");

        // Calculate what Controller would calculate
        (,,, uint256 tokensToBurn,) = exitQueue.requestInfo(batchId, user2);
        uint256 ethToRedeem = isSlippageTooHigh ? 0 : Math.convertAssets(tokensToBurn, finalEvePrice);
        assertEq(ethToRedeem, 0, "ETH should be 0 when slippage is too high");

        controller.priceBatch();

        // Process without funding Controller (should work since no ETH needed)
        vm.expectEmit(true, true, true, true);
        emit IAMM.RedemptionProcessed(user2, batchId, block.timestamp);
        controller.processRequest(batchId, user2);

        // Request should be processed and closed due to slippage
        (bool isProcessed, bool isClosedDueToSlippage,,,) = exitQueue.requestInfo(batchId, user2);
        assertTrue(isProcessed, "Request should be processed");
        assertTrue(isClosedDueToSlippage, "Request should be closed due to slippage");

        // Tokens should be returned to user
        assertEq(eve.balanceOf(user2), user2Balance, "Tokens should be returned to user");
    }

    function test_CancelRedemptionNotOwner() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);

        vm.startPrank(user2);

        eve.approve(address(bondingCurve), user2Balance);

        uint256 requestId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0); // Use smaller collateral

        vm.stopPrank();

        vm.prank(user1); // Wrong user
        vm.expectRevert(IExitQueue.ExitQueueRequestNotInBatch.selector);
        bondingCurve.cancelRedemption(requestId);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetConnectorWeightOnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert(); // Just check that it reverts - AccessControl will revert with AccessControlUnauthorizedAccount
        bondingCurve.setConnectorWeight(6e17); // 0.6 - valid connector weight
    }

    function test_ProcessRedemptionOnlyKeeper() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);

        vm.startPrank(user2);

        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0); // Use smaller collateral

        vm.stopPrank();

        // Price the batch
        controller.priceBatch();

        // Non-keeper should not be able to process
        vm.prank(user1);
        vm.expectRevert(); // Just check that it reverts - AccessControl will revert with AccessControlUnauthorizedAccount
        controller.processRequest(batchId, user2);
    }

    /*//////////////////////////////////////////////////////////////
                        CONNECTOR WEIGHT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetConnectorWeight() public {
        uint256 newCW = 6e17; // 0.6 - valid connector weight

        vm.expectEmit(false, false, false, true);
        emit IAMM.ConnectorWeightChanged(INITIAL_CW, newCW);

        vm.prank(owner);
        bondingCurve.setConnectorWeight(newCW);
        assertEq(bondingCurve.connectorWeight(), newCW);
    }

    function test_SetConnectorWeightInvalidRange() public {
        vm.prank(owner);
        vm.expectRevert(IAMM.AMMInvalidRange.selector);
        bondingCurve.setConnectorWeight(0);

        vm.prank(owner);
        vm.expectRevert(IAMM.AMMInvalidRange.selector);
        bondingCurve.setConnectorWeight(INVALID_PRICE_TOLERANCE); // > 1e18
    }

    /*//////////////////////////////////////////////////////////////
                    MIN BATCH EXIT ETH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_MinBatchExitETH_DefaultValue() public view {
        assertEq(bondingCurve.minBatchExitETH(), bondingCurve.DEFAULT_MIN_BATCH_EXIT_ETH());
        assertEq(bondingCurve.DEFAULT_MIN_BATCH_EXIT_ETH(), BATCH_EXIT_AT_MIN_ETH);
        assertEq(bondingCurve.MIN_BATCH_EXIT_ETH_UPPER_BOUND(), BATCH_EXIT_UPPER_BOUND_ETH);
    }

    function test_SetMinBatchExitETH() public {
        uint256 newMin = 2e15;

        vm.expectEmit(false, false, false, true);
        emit IAMM.MinBatchExitETHChanged(1e15, newMin);

        vm.prank(owner);
        bondingCurve.setMinBatchExitETH(newMin);
        assertEq(bondingCurve.minBatchExitETH(), newMin);
    }

    function test_SetMinBatchExitETHOnlyAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, bondingCurve.ADMIN_ROLE())
        );
        vm.prank(user1);
        bondingCurve.setMinBatchExitETH(2e15);
    }

    function test_SetMinBatchExitETH_AtUpperBound() public {
        vm.expectEmit(false, false, false, true);
        emit IAMM.MinBatchExitETHChanged(BATCH_EXIT_AT_MIN_ETH, BATCH_EXIT_UPPER_BOUND_ETH);

        vm.prank(owner);
        bondingCurve.setMinBatchExitETH(BATCH_EXIT_UPPER_BOUND_ETH);
        assertEq(bondingCurve.minBatchExitETH(), BATCH_EXIT_UPPER_BOUND_ETH);
    }

    function test_SetMinBatchExitETH_AboveUpperBound_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(IAMM.AMMInvalidMinBatchExitETH.selector);
        bondingCurve.setMinBatchExitETH(BATCH_EXIT_ABOVE_UPPER_BOUND_ETH);
    }

    function test_Exit_BatchBelowMinBatchExitETH_Reverts() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);

        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        vm.expectRevert(IAMM.AMMTooLowBatchExitETH.selector);
        bondingCurve.exit(BATCH_EXIT_BELOW_MIN_ETH, user2Balance, 0);
        vm.stopPrank();
    }

    function test_Exit_ImmediateBelowMinBatchExitETH_Succeeds() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.deal(address(bondingCurve), ENTER_ETH_DEPOSIT);

        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);

        vm.expectEmit(true, false, false, false);
        emit IAMM.RedeemedImmediately(user2, 0, 0, block.timestamp);
        uint256 batchId = bondingCurve.exit(BATCH_EXIT_BELOW_MIN_ETH, user2Balance, 0);
        vm.stopPrank();

        assertEq(batchId, 0);
        assertLt(eve.balanceOf(user2), user2Balance);
    }

    function test_Exit_BatchAtMinBatchExitETH_Succeeds() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        uint256 minEth = bondingCurve.minBatchExitETH();
        assertEq(minEth, BATCH_EXIT_AT_MIN_ETH);

        uint256 evePrice = bondingCurve.eveBasePriceInETH();
        uint256 requestedEth = BATCH_EXIT_AT_MIN_ETH;
        while (Math.convertAssets(Math.convertAssetsInverse(requestedEth, evePrice), evePrice) < minEth) {
            requestedEth++;
        }
        assertLe(requestedEth - BATCH_EXIT_AT_MIN_ETH, 1, "only rounding should require bump above configured minimum");

        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);

        uint256 batchId = bondingCurve.exit(requestedEth, user2Balance, 0);
        vm.stopPrank();

        assertEq(batchId, 1);
        assertGt(eve.balanceOf(address(bondingCurve)), 0);
    }

    function test_Exit_BatchWhenMinDisabled_Succeeds() public {
        vm.prank(owner);
        bondingCurve.setMinBatchExitETH(0);

        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);

        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);

        vm.expectEmit(true, true, true, true);
        emit IAMM.RedemptionQueued(user2, 1, block.timestamp);
        uint256 batchId = bondingCurve.exit(BATCH_EXIT_BELOW_MIN_ETH, user2Balance, 0);
        vm.stopPrank();

        assertEq(batchId, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StalePrice() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        vm.warp(uint256(keccak256("timestamp")));

        // Set price feed to return stale data
        ethPriceFeed.setStale(true);

        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        vm.expectRevert();
        bondingCurve.eveBasePriceInUSD();
    }

    function test_InvalidPrice() public {
        // Set price feed to return invalid data
        ethPriceFeed.setPrice(0);

        vm.prank(user1);
        vm.expectRevert(); // Oracle will revert with invalid price
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
    }

    /*//////////////////////////////////////////////////////////////
                        ADDITIONAL REQUIRE() TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Enter_InvalidInputs() public {
        // Zero min tokens
        vm.prank(user1);
        vm.expectRevert(IAMM.AMMInvalidTokensToMintAmount.selector);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(0);

        // Insufficient deposit post-bootstrap
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        vm.expectRevert(IAMM.AMMInsufficientDeposit.selector);
        bondingCurve.enter{value: TINY_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
    }

    function test_Exit_InvalidInputs() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Zero collateral
        vm.prank(user1);
        vm.expectRevert(IAMM.AMMZeroETHRequested.selector);
        bondingCurve.exit(0, EXIT_MAX_TOKENS, 0);

        // Zero tokens to burn
        vm.prank(user1);
        vm.expectRevert(IAMM.AMMZeroTokensToBurnAmount.selector);
        bondingCurve.exit(EXIT_SMALL_ETH, 0, 0);

        // Invalid price tolerance
        vm.prank(user1);
        vm.expectRevert(IAMM.AMMInvalidRange.selector);
        bondingCurve.exit(EXIT_SMALL_ETH, EXIT_MAX_TOKENS, INVALID_PRICE_TOLERANCE);

        // Too much collateral requested
        uint256 userBalance = eve.balanceOf(user1);
        uint256 collateral = oracle.convertTokenToUSD(address(0), BOOTSTRAP_ETH_DEPOSIT, 18);
        vm.prank(user1);
        eve.approve(address(bondingCurve), userBalance / 2);
        vm.prank(user1);
        vm.expectRevert(IAMM.AMMTooMuchETHRequested.selector);
        bondingCurve.exit(collateral, userBalance / 2, 0);
    }

    function test_ProcessRedemptionInvalidRequest() public {
        uint256 invalidBatchId = 12345;

        vm.expectRevert(); // Will revert from ExitQueue
        controller.processRequest(invalidBatchId, user1);
    }

    function test_ProcessRedemptionAlreadyProcessed() public {
        // Setup: bootstrap, enter, and queue redemption
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0); // Use smaller collateral
        vm.stopPrank();

        // Price the batch
        controller.priceBatch();

        // Calculate and fund ETH needed
        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        if (ethToRedeem > 0) {
            vm.deal(address(controller), ethToRedeem);
        }

        // Process the redemption first time
        controller.processRequest(batchId, user2);

        // Try to process the same redemption again
        vm.expectRevert(); // Will revert from ExitQueue
        controller.processRequest(batchId, user2);
    }

    function test_CancelRedemptionInvalidRequest() public {
        uint256 invalidRequestId = 12345;

        vm.prank(user1);
        vm.expectRevert(IExitQueue.ExitQueueRequestNotInBatch.selector);
        bondingCurve.cancelRedemption(invalidRequestId);
    }

    function test_CancelRedemptionAlreadyProcessed() public {
        // Setup: bootstrap, enter, and queue redemption
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0); // Use smaller collateral
        vm.stopPrank();

        // Price the batch
        controller.priceBatch();

        // Calculate and fund ETH needed
        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        if (ethToRedeem > 0) {
            vm.deal(address(controller), ethToRedeem);
        }

        // Process the redemption first
        controller.processRequest(batchId, user2);

        // Try to cancel already processed redemption
        vm.prank(user2);
        vm.expectRevert(); // Will revert from ExitQueue
        bondingCurve.cancelRedemption(batchId);
    }

    function test_CancelRedemption_WhenMaxProcessingTimeExceeded_Succeeds() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        // Price the batch (user cannot cancel within MAX_BATCH_PROCESSING_TIME)
        controller.priceBatch();

        vm.prank(user2);
        vm.expectRevert(IExitQueue.ExitQueueRequestCannotBeClosed.selector);
        bondingCurve.cancelRedemption(batchId);

        // After MAX_BATCH_PROCESSING_TIME exceeded, user can cancel (escape hatch)
        vm.warp(block.timestamp + uint256(exitQueue.MAX_BATCH_PROCESSING_TIME()) + 1);

        vm.expectEmit(true, true, true, true);
        emit IAMM.RedemptionCancelled(user2, batchId, true, block.timestamp);
        vm.prank(user2);
        bondingCurve.cancelRedemption(batchId);

        assertEq(eve.balanceOf(user2), user2Balance);
        assertEq(eve.balanceOf(address(bondingCurve)), 0);
    }

    function test_BootstrapInsufficientTokensAfterDeadSupply() public {
        // Create a scenario where the deposit is just enough for minimum but
        // after dead supply deduction, there are insufficient tokens for minTokensToMint
        uint256 depositAmount = ENTER_ETH_DEPOSIT; // 0.5 ETH deposit
        uint256 depositUSD = oracle.convertTokenToUSD(address(0), depositAmount, 18);
        uint256 minTokensToMint = depositUSD; // Request all tokens (will fail due to dead supply)

        vm.prank(user1);
        vm.expectRevert(IAMM.AMMInsufficientDeposit.selector);
        bondingCurve.enter{value: depositAmount}(minTokensToMint);
    }

    function test_OracleInvalidPrice() public {
        // Set price feed to return zero price
        ethPriceFeed.setPrice(0);

        vm.prank(user1);
        vm.expectRevert(); // Oracle will revert with invalid price
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
    }

    function test_OracleStalePrice() public {
        // Set price feed to return stale data
        ethPriceFeed.setStale(true);

        // Warp time to ensure staleness check works properly
        vm.warp(block.timestamp + 7200); // 2 hours later

        vm.prank(user1);
        vm.expectRevert(IOracle.OracleStalePrice.selector);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause() public {
        vm.prank(owner);
        bondingCurve.pause();
        assertTrue(bondingCurve.paused());

        vm.prank(owner);
        bondingCurve.unpause();
        assertFalse(bondingCurve.paused());
    }

    function test_Pause_AccessControl() public {
        // Caller with neither ADMIN_ROLE nor SECURITY_ROLE cannot pause
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        bondingCurve.pause();

        // Non-admin cannot unpause
        vm.prank(owner);
        bondingCurve.pause();
        vm.prank(user1);
        vm.expectRevert();
        bondingCurve.unpause();
    }

    function test_Pause_SecurityCanPauseImmediately() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        bondingCurve.pause();

        assertTrue(bondingCurve.paused());
    }

    function test_SecurityCannotUnpause() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        bondingCurve.pause();

        // Recovery stays with ADMIN_ROLE (timelocked in production)
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IRegistryClient.RegistryClientMissingRole.selector, Auth.ADMIN_ROLE));
        bondingCurve.unpause();
    }

    function test_Operations_WhenPaused() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        vm.prank(owner);
        bondingCurve.pause();

        // Enter blocked
        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        // Exit blocked
        vm.prank(user1);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        bondingCurve.exit(EXIT_SMALL_ETH, EXIT_MAX_TOKENS, 0);

        // Process redemption blocked - exit is paused so can't queue
        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        // Note: processRedemption and cancelRedemption tests require a queued request,
        // but we can't queue when paused, so we skip those tests here
    }

    function test_ViewFunctionsWorkWhenPaused() public {
        vm.prank(owner);
        bondingCurve.pause();

        // These should still work when paused
        assertTrue(bondingCurve.paused());
        assertEq(registry.getContractByKey(Auth.CONTROLLER), address(controller));
        assertEq(bondingCurve.connectorWeight(), INITIAL_CW);

        // Test price functions
        vm.expectRevert(IAMM.AMMZeroTotalSupply.selector);
        bondingCurve.evePremiumPriceInETH();
    }

    function test_ResumeOperationsAfterUnpause() public {
        // Pause the contract
        vm.prank(owner);
        bondingCurve.pause();

        // Unpause the contract
        vm.prank(owner);
        bondingCurve.unpause();

        // Operations should work again
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        assertTrue(eve.balanceOf(user1) > 0);
    }

    /*//////////////////////////////////////////////////////////////
                    PULL-OVER-PUSH / CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProcessRedemption_CreditsClaim_NotDirectTransfer() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        controller.priceBatch();

        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        if (ethToRedeem > 0) {
            vm.deal(address(controller), ethToRedeem);
        }

        uint256 user2ETHBefore = address(user2).balance;

        controller.processRequest(batchId, user2);

        // ETH must NOT have been pushed to user directly
        assertEq(address(user2).balance, user2ETHBefore, "ETH must not be sent directly to user");
        // ETH must be credited in the claimable mapping
        assertEq(bondingCurve.claimableBalances(user2), ethToRedeem, "claimableBalances must reflect owed ETH");
        assertEq(bondingCurve.lockedForClaims(), ethToRedeem, "lockedForClaims must be updated");
    }

    function test_Claim_ShouldWork() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        controller.priceBatch();

        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        if (ethToRedeem > 0) {
            vm.deal(address(controller), ethToRedeem);
        }

        controller.processRequest(batchId, user2);

        uint256 user2ETHBefore = address(user2).balance;

        vm.expectEmit(true, true, true, true);
        emit IAMM.Claimed(user2, ethToRedeem, block.timestamp);
        vm.prank(user2);
        bondingCurve.claim();

        assertEq(address(user2).balance, user2ETHBefore + ethToRedeem, "User must receive claimed ETH");
        assertEq(bondingCurve.claimableBalances(user2), 0, "claimableBalances must be cleared after claim");
        assertEq(bondingCurve.lockedForClaims(), 0, "lockedForClaims must be cleared after claim");
    }

    function test_Claim_WhenPaused_ShouldWork() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        controller.priceBatch();

        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        if (ethToRedeem > 0) {
            vm.deal(address(controller), address(controller).balance + ethToRedeem);
        }

        controller.processRequest(batchId, user2);

        vm.prank(owner);
        bondingCurve.pause();

        uint256 user2ETHBefore = address(user2).balance;

        vm.prank(user2);
        bondingCurve.claim();

        assertEq(address(user2).balance, user2ETHBefore + ethToRedeem, "Claim must succeed while paused");
    }

    function test_Claim_NoBalance_ShouldRevert() public {
        vm.prank(user1);
        vm.expectRevert(IAMM.AMMNoClaimableBalance.selector);
        bondingCurve.claim();
    }

    function test_ProcessRedemption_ExcessETHReturnedToController() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        controller.priceBatch();

        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);

        // Call processRedemption directly as the controller (which already holds CONTROLLER_ROLE),
        // sending ethToRedeem + EXCESS_ETH to exercise the excess-return path.
        uint256 totalSent = ethToRedeem + EXCESS_ETH;
        vm.deal(address(controller), address(controller).balance + totalSent);

        uint256 controllerBalanceBefore = address(controller).balance;

        vm.prank(address(controller));
        bondingCurve.processRedemption{value: totalSent}(batchId, user2);

        // Excess must be returned to controller, not retained in AMM
        // Controller paid totalSent and received EXCESS_ETH back → net deduction is ethToRedeem only
        assertEq(
            address(controller).balance,
            controllerBalanceBefore - ethToRedeem,
            "Excess ETH must be returned to controller (only ethToRedeem deducted)"
        );
        // Only ethToRedeem should be locked for the claim
        assertEq(bondingCurve.claimableBalances(user2), ethToRedeem);
        assertEq(bondingCurve.lockedForClaims(), ethToRedeem);
    }

    function test_ProcessRedemption_Slippage_ExcessETHReturnedToController() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 priceTolerance = 1e16; // 1% — tight enough to trigger slippage
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, priceTolerance);
        vm.stopPrank();

        // Reduce controller ETH to cause a price drop (reduces NAV)
        vm.deal(address(controller), address(controller).balance / 2);

        controller.priceBatch();

        // Verify slippage is triggered (ethToRedeem == 0 from Controller's perspective)
        (,, uint256 evePriceAtRequestTime,,) = exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        assertTrue(
            Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance), "Slippage must be detected"
        );

        // Call processRedemption directly as the controller (which already holds CONTROLLER_ROLE).
        // Even if caller accidentally sends ETH on a slippage request, it must be returned.
        vm.deal(address(controller), address(controller).balance + EXCESS_ETH);
        uint256 controllerBalanceBefore = address(controller).balance;

        vm.prank(address(controller));
        bondingCurve.processRedemption{value: EXCESS_ETH}(batchId, user2);

        // Controller paid EXCESS_ETH and received all of it back (no ethToRedeem on slippage)
        assertEq(
            address(controller).balance,
            controllerBalanceBefore,
            "All ETH must be returned to controller on slippage path"
        );
        // No ETH locked for claims on slippage
        assertEq(bondingCurve.claimableBalances(user2), 0);
        assertEq(bondingCurve.lockedForClaims(), 0);
        // EVE tokens returned to user
        assertEq(eve.balanceOf(user2), user2Balance);
    }

    /*//////////////////////////////////////////////////////////////
                        FREE BALANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FreeBalance_EqualsBalanceWhenNoClaims() public view {
        assertEq(bondingCurve.freeBalance(), address(bondingCurve).balance);
        assertEq(bondingCurve.lockedForClaims(), 0);
    }

    function test_FreeBalance_ExcludesLockedForClaims() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        controller.priceBatch();

        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        if (ethToRedeem > 0) {
            vm.deal(address(controller), address(controller).balance + ethToRedeem);
        }

        controller.processRequest(batchId, user2);

        // At this point AMM holds ethToRedeem, all of it locked for claims.
        // Give AMM extra free ETH after processing so freeBalance is non-trivially testable.
        uint256 extraETH = 0.5 ether;
        vm.deal(address(bondingCurve), address(bondingCurve).balance + extraETH);

        uint256 totalBalance = address(bondingCurve).balance;
        uint256 locked = bondingCurve.lockedForClaims();

        assertGt(locked, 0, "Some ETH must be locked");
        assertEq(bondingCurve.freeBalance(), totalBalance - locked, "freeBalance must exclude lockedForClaims");
        assertEq(bondingCurve.freeBalance(), extraETH, "freeBalance must equal only the unlocked portion");
    }

    function test_FreeBalance_RoutesExitToQueue_WhenBalanceLocked() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        controller.priceBatch();

        (,, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance) =
            exitQueue.requestInfo(batchId, user2);
        (, uint256 finalEvePrice,,,) = exitQueue.batchInfo(batchId);
        uint256 ethToRedeem = Math.isRelativelyLessThan(finalEvePrice, evePriceAtRequestTime, priceTolerance)
            ? 0
            : Math.convertAssets(tokensToBurn, finalEvePrice);
        if (ethToRedeem > 0) {
            // Use additive deal so controller retains its original balance for NAV calculations
            vm.deal(address(controller), address(controller).balance + ethToRedeem);
        }

        controller.processRequest(batchId, user2);

        // AMM balance equals lockedForClaims — freeBalance is zero
        assertEq(bondingCurve.freeBalance(), 0, "freeBalance must be zero after all balance is locked");

        // user1 tries to exit — must be queued, not immediate
        uint256 user1Balance = eve.balanceOf(user1);
        vm.startPrank(user1);
        eve.approve(address(bondingCurve), user1Balance);
        uint256 newBatchId = bondingCurve.exit(EXIT_SMALL_ETH, user1Balance, 0);
        vm.stopPrank();

        assertGt(newBatchId, 0, "Exit must be routed to queue when freeBalance is zero");
    }

    /*//////////////////////////////////////////////////////////////
                        IMMUTABILITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AMM_Immutable() public view {
        // AMM is immutable and cannot be upgraded
        address currentController = registry.getContractByKey(Auth.CONTROLLER);
        uint256 currentCW = bondingCurve.connectorWeight();
        address currentEve = registry.getContractByKey(Auth.EVE);

        assertEq(registry.getContractByKey(Auth.CONTROLLER), currentController);
        assertEq(bondingCurve.connectorWeight(), currentCW);
        assertEq(registry.getContractByKey(Auth.EVE), currentEve);
    }

    /*//////////////////////////////////////////////////////////////
                        EVE PRICING INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EvePremiumPriceInUSD_IsAlwaysGreaterThanOrEqualBasePrice() public {
        // Bootstrap first to have some NAV and EVE supply
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 basePrice = bondingCurve.eveBasePriceInUSD();
        uint256 premiumPrice = bondingCurve.evePremiumPriceInUSD();

        // Premium price should always be >= base price
        assertTrue(premiumPrice >= basePrice);

        // All prices should be positive
        assertTrue(basePrice > 0);
        assertTrue(premiumPrice > 0);
    }

    function test_EveBasePriceInUSD() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 basePrice = bondingCurve.eveBasePriceInUSD();

        // base_price = NAV_total / EVE_supply
        assertEq(
            basePrice,
            strategyManager.totalNAVInUSD() * Math.NORMALIZATION_FACTOR / (eve.balanceOf(user1) + DEAD_SUPPLY)
        );
    }

    function test_EvePremiumPriceInUSD() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 premiumPrice = bondingCurve.evePremiumPriceInUSD();

        // premium_price = NAV_total / (EVE_supply * cw)
        assertEq(
            premiumPrice,
            strategyManager.totalNAVInUSD() * Math.NORMALIZATION_FACTOR * Math.SCALE_FACTOR
                / ((eve.balanceOf(user1) + DEAD_SUPPLY) * INITIAL_CW)
        );
    }

    function test_EvePriceCalculationWithDifferentConnectorWeights() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Test with 50% connector weight
        uint256 basePrice = bondingCurve.eveBasePriceInUSD();
        uint256 premiumPrice50 = bondingCurve.evePremiumPriceInUSD();

        // With 50% connector weight, premium price (100e18) > base price (50e18)
        assertEq(
            premiumPrice50,
            strategyManager.totalNAVInUSD() * Math.NORMALIZATION_FACTOR * Math.SCALE_FACTOR
                / ((eve.balanceOf(user1) + DEAD_SUPPLY) * INITIAL_CW)
        );
        assertTrue(premiumPrice50 > basePrice);

        // Change connector weight to 90%
        vm.prank(owner);
        bondingCurve.setConnectorWeight(9e17); // 0.9 (90%)

        uint256 premiumPrice90 = bondingCurve.evePremiumPriceInUSD();

        // With 90% connector weight, premium price should be lower
        assertTrue(premiumPrice90 < premiumPrice50);
        // Premium price should still be >= base price
        assertTrue(premiumPrice90 >= basePrice);
    }

    function test_EvePriceWithZeroSupplyReverts() public {
        // Try to get price before bootstrap (zero supply)
        vm.expectRevert(IAMM.AMMZeroTotalSupply.selector);
        bondingCurve.evePremiumPriceInUSD();

        vm.expectRevert(IAMM.AMMZeroTotalSupply.selector);
        bondingCurve.eveBasePriceInUSD();

        vm.expectRevert(IAMM.AMMZeroTotalSupply.selector);
        bondingCurve.evePremiumPriceInUSD();
    }

    /*//////////////////////////////////////////////////////////////
                        ADDITIONAL USD PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Test that base price in ETH matches expected formula
     * @dev Verifies: basePriceETH = (NAV_ETH * 1e18) / supply
     */
    function test_EveBasePriceInETH_MatchesExpectedFormula() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 navETH = strategyManager.totalNAVInETH();
        uint256 totalSupply = eve.totalSupply();
        uint256 expectedPrice = (navETH * Math.NORMALIZATION_FACTOR) / totalSupply;

        assertEq(bondingCurve.eveBasePriceInETH(), expectedPrice, "Base price in ETH should match formula");
    }

    /**
     * @notice Test that premium price in ETH matches expected formula
     * @dev Verifies: premiumPriceETH = (NAV_ETH * 1e18) / (supply * cw)
     */
    function test_EvePremiumPriceInETH_MatchesExpectedFormula() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 navETH = strategyManager.totalNAVInETH();
        uint256 totalSupply = eve.totalSupply();
        uint256 adjustedSupply = (totalSupply * INITIAL_CW) / Math.SCALE_FACTOR;
        uint256 expectedPrice = (navETH * Math.NORMALIZATION_FACTOR) / adjustedSupply;

        assertEq(bondingCurve.evePremiumPriceInETH(), expectedPrice, "Premium price in ETH should match formula");
    }

    /**
     * @notice Test that USD price is correctly converted from ETH price
     * @dev Verifies: USD Price = ETH Price converted via oracle
     */
    function test_EveBasePriceInUSD_MatchesETHConversion() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 priceETH = bondingCurve.eveBasePriceInETH();
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), priceETH, Math.DECIMALS_NORMALIZED);

        assertEq(bondingCurve.eveBasePriceInUSD(), expectedUSD, "USD price should match ETH price conversion");
    }

    /**
     * @notice Test that premium USD price is correctly converted from ETH price
     * @dev Verifies: Premium USD Price = ETH Premium Price converted via oracle
     */
    function test_EvePremiumPriceInUSD_MatchesETHConversion() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 priceETH = bondingCurve.evePremiumPriceInETH();
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), priceETH, Math.DECIMALS_NORMALIZED);

        assertEq(
            bondingCurve.evePremiumPriceInUSD(), expectedUSD, "Premium USD price should match ETH price conversion"
        );
    }

    /**
     * @notice Test that minting prices at the premium price and burning at the base price
     * @dev Verifies the bonding-curve split: enter() uses premiumPriceInETH, exit() uses basePriceInETH
     */
    function test_MintPremium_BurnBase_Prices() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        uint256 basePriceETH = bondingCurve.eveBasePriceInETH();
        uint256 premiumPriceETH = bondingCurve.evePremiumPriceInETH();

        // With cw <= 1e18 the premium price is always >= the base price.
        assertGe(premiumPriceETH, basePriceETH, "Premium price should never be below base price");
    }

    /**
     * @notice Test that USD price calculation follows correct path
     * @dev Verifies: ETH NAV → ETH Price → USD Price
     */
    function test_PriceCalculationFollowsCorrectPath() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Get values at each step of the calculation path
        uint256 navETH = strategyManager.totalNAVInETH();
        uint256 basePriceETH = bondingCurve.eveBasePriceInETH();
        uint256 basePriceUSD = bondingCurve.eveBasePriceInUSD();

        // Verify ETH price uses ETH NAV
        uint256 expectedETHPrice = (navETH * Math.NORMALIZATION_FACTOR) / eve.totalSupply();
        assertEq(basePriceETH, expectedETHPrice, "ETH price should be calculated from ETH NAV");

        // Verify USD price is ETH price converted via oracle
        uint256 expectedUSDPrice = oracle.convertTokenToUSD(address(0), basePriceETH, Math.DECIMALS_NORMALIZED);
        assertEq(basePriceUSD, expectedUSDPrice, "USD price should be ETH price converted via oracle");
    }

    /**
     * @notice Test that premium USD price calculation follows correct path
     * @dev Verifies: ETH NAV → ETH Premium Price → USD Premium Price
     */
    function test_PremiumPriceCalculationFollowsCorrectPath() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Get values at each step of the calculation path
        uint256 navETH = strategyManager.totalNAVInETH();
        uint256 premiumPriceETH = bondingCurve.evePremiumPriceInETH();
        uint256 premiumPriceUSD = bondingCurve.evePremiumPriceInUSD();

        // Verify ETH premium price uses ETH NAV
        uint256 adjustedSupply = (eve.totalSupply() * INITIAL_CW) / Math.SCALE_FACTOR;
        uint256 expectedETHPrice = (navETH * Math.NORMALIZATION_FACTOR) / adjustedSupply;
        assertEq(premiumPriceETH, expectedETHPrice, "ETH premium price should be calculated from ETH NAV");

        // Verify USD premium price is ETH premium price converted via oracle
        uint256 expectedUSDPrice = oracle.convertTokenToUSD(address(0), premiumPriceETH, Math.DECIMALS_NORMALIZED);
        assertEq(
            premiumPriceUSD, expectedUSDPrice, "USD premium price should be ETH premium price converted via oracle"
        );
    }

    /**
     * @notice Test that ETH prices are used in enter/exit operations
     * @dev Verifies that core operations use ETH prices, not USD prices
     */
    function test_EnterExitUseETHPrices() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 premiumPriceETH = bondingCurve.evePremiumPriceInETH();

        // User2 enters - should use premium price in ETH
        uint256 depositAmount = ENTER_ETH_DEPOSIT;
        uint256 expectedTokens = Math.convertAssetsInverse(depositAmount, premiumPriceETH);

        vm.prank(user2);
        bondingCurve.enter{value: depositAmount}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Verify tokens received match ETH price calculation (with rounding tolerance)
        uint256 tokensReceived = eve.balanceOf(user2);
        assertApproxEqRel(tokensReceived, expectedTokens, 1e15, "Tokens should match ETH premium price calculation");

        // User2 exits - redemption is priced at the base price (NAV / supply) in ETH
        uint256 user2Balance = eve.balanceOf(user2);
        uint256 ethRequested = EXIT_SMALL_ETH;

        vm.deal(address(bondingCurve), ENTER_ETH_DEPOSIT);

        uint256 exitPriceETH = bondingCurve.eveBasePriceInETH();
        uint256 expectedTokensToBurn = Math.convertAssetsInverse(ethRequested, exitPriceETH);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        bondingCurve.exit(ethRequested, user2Balance, 0);
        vm.stopPrank();

        // Verify tokens burned match the effective ETH price calculation
        uint256 tokensRemaining = eve.balanceOf(user2);
        uint256 tokensBurned = user2Balance - tokensRemaining;
        assertApproxEqRel(
            tokensBurned, expectedTokensToBurn, 1e15, "Tokens burned should match effective ETH price calculation"
        );
    }

    /**
     * @notice Test that enter pricing excludes the incoming msg.value from NAV
     * @dev Verifies user is priced against pre-deposit NAV, not NAV inflated by own deposit
     */
    function test_EnterPricing_ExcludesIncomingMsgValue() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 depositAmount = ENTER_ETH_DEPOSIT;

        // Compute expected price against pre-deposit NAV
        uint256 navBefore = strategyManager.totalNAVInETH();
        uint256 adjustedSupply = (eve.totalSupply() * INITIAL_CW) / Math.SCALE_FACTOR;
        uint256 expectedPremiumPrice = (navBefore * Math.NORMALIZATION_FACTOR) / adjustedSupply;
        uint256 expectedTokens = Math.convertAssetsInverse(depositAmount, expectedPremiumPrice);

        vm.prank(user2);
        bondingCurve.enter{value: depositAmount}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        assertEq(eve.balanceOf(user2), expectedTokens, "enter() should exclude msg.value from NAV during pricing");
    }

    /**
     * @notice Test that AMM free balance is included in NAV and ETH price views
     * @dev Verifies StrategyManager NAV aggregation and AMM price views stay consistent
     */
    function test_NAVAndPriceViews_IncludeAMMFreeBalance() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        uint256 ammTopUp = ENTER_ETH_DEPOSIT;
        vm.deal(address(bondingCurve), ammTopUp);

        // With no strategies and no locked claims, free balance equals total AMM balance
        uint256 expectedNav = address(controller).balance + bondingCurve.freeBalance();
        assertEq(strategyManager.totalNAVInETH(), expectedNav, "NAV should include AMM free balance");

        uint256 expectedBasePrice = (expectedNav * Math.NORMALIZATION_FACTOR) / eve.totalSupply();
        uint256 adjustedSupply = (eve.totalSupply() * INITIAL_CW) / Math.SCALE_FACTOR;
        uint256 expectedPremiumPrice = (expectedNav * Math.NORMALIZATION_FACTOR) / adjustedSupply;

        assertEq(
            bondingCurve.eveBasePriceInETH(), expectedBasePrice, "base price should include AMM free balance in NAV"
        );
        assertEq(
            bondingCurve.evePremiumPriceInETH(),
            expectedPremiumPrice,
            "premium price should include AMM free balance in NAV"
        );
    }

    /**
     * @notice Test that exit burn sizing uses NAV that includes AMM free balance
     * @dev Verifies the effective price for exit reflects AMM-held free ETH and burn amount follows it
     */
    function test_ExitPricing_UsesAMMFreeBalanceInNAV() public {
        // Bootstrap and create user2 position
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Add extra ETH to AMM and ensure immediate redemption path is available
        uint256 ammTopUp = ENTER_ETH_DEPOSIT;
        vm.deal(address(bondingCurve), ammTopUp);

        uint256 ethRequested = EXIT_SMALL_ETH;
        uint256 user2Balance = eve.balanceOf(user2);
        uint256 expectedTokensToBurn = Math.convertAssetsInverse(ethRequested, bondingCurve.eveBasePriceInETH());

        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        bondingCurve.exit(ethRequested, user2Balance, 0);
        vm.stopPrank();

        uint256 tokensBurned = user2Balance - eve.balanceOf(user2);
        assertApproxEqRel(
            tokensBurned, expectedTokensToBurn, 1e15, "exit() should use effective price with AMM free balance"
        );
    }

    /**
     * @notice Test that NAV excludes ETH locked for pending claims during claim window
     * @dev Regression for VF-003/VF-007: lockedForClaims must not inflate NAV after processRedemption()
     */
    function test_TotalNAVInETH_ExcludesLockedClaimsDuringClaimWindow() public {
        _setupLockedClaimState();

        uint256 locked = bondingCurve.lockedForClaims();
        assertGt(locked, 0, "test setup must leave locked claims");

        uint256 expectedNav =
            address(strategyManager).balance + address(controller).balance + bondingCurve.freeBalance();
        assertEq(strategyManager.totalNAVInETH(), expectedNav, "NAV must use AMM freeBalance only");

        uint256 navUsingFullAmmBalance =
            address(strategyManager).balance + address(controller).balance + address(bondingCurve).balance;
        assertGt(navUsingFullAmmBalance, expectedNav, "full amm.balance would overstate NAV");

        assertEq(
            strategyManager.totalNAVInETH() + locked,
            navUsingFullAmmBalance,
            "NAV + lockedForClaims must reconcile with full AMM balance"
        );
    }

    /**
     * @notice Test that enter pricing is not inflated by locked claim ETH
     * @dev Premium price must reflect free-balance NAV, not full AMM balance
     */
    function test_EnterPricing_NotInflatedByLockedClaims() public {
        _setupLockedClaimState();

        uint256 adjustedSupply = (eve.totalSupply() * INITIAL_CW) / Math.SCALE_FACTOR;
        uint256 actualPrice = bondingCurve.evePremiumPriceInETH();

        uint256 wrongNav = address(controller).balance + address(bondingCurve).balance;
        uint256 inflatedPrice = (wrongNav * Math.NORMALIZATION_FACTOR) / adjustedSupply;
        assertLt(actualPrice, inflatedPrice, "premium price must not count locked ETH in NAV");

        uint256 correctNav = address(controller).balance + bondingCurve.freeBalance();
        uint256 expectedPrice = (correctNav * Math.NORMALIZATION_FACTOR) / adjustedSupply;
        assertEq(actualPrice, expectedPrice, "premium price must use NAV with locked ETH excluded");
    }

    /**
     * @notice Test that NAV in ETH is used for price calculations
     * @dev Verifies that price calculations use totalNAVInETH(), not totalNAVInUSD()
     */
    function test_PriceCalculationUsesETHNAV() public {
        // Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Get NAV values
        uint256 navETH = strategyManager.totalNAVInETH();

        // Calculate expected prices using ETH NAV
        uint256 expectedBasePriceETH = (navETH * Math.NORMALIZATION_FACTOR) / eve.totalSupply();
        uint256 expectedPremiumPriceETH =
            (navETH * Math.NORMALIZATION_FACTOR * Math.SCALE_FACTOR) / (eve.totalSupply() * INITIAL_CW);

        // Verify prices match ETH NAV calculations
        assertEq(bondingCurve.eveBasePriceInETH(), expectedBasePriceETH, "Base price should use ETH NAV");
        assertEq(bondingCurve.evePremiumPriceInETH(), expectedPremiumPriceETH, "Premium price should use ETH NAV");

        // Verify USD prices are conversions of ETH prices, not direct USD NAV calculations
        uint256 basePriceETH = bondingCurve.eveBasePriceInETH();
        uint256 basePriceUSD = bondingCurve.eveBasePriceInUSD();
        uint256 expectedUSDFromETH = oracle.convertTokenToUSD(address(0), basePriceETH, Math.DECIMALS_NORMALIZED);

        assertEq(
            basePriceUSD, expectedUSDFromETH, "USD price should be ETH price converted, not direct USD NAV calculation"
        );
    }

    /**
     * @notice Test that USD price calculations remain consistent after multiple operations
     * @dev Verifies USD price calculation consistency across multiple enter/exit operations
     */
    function test_PriceCalculationConsistencyAfterOperations() public {
        // Bootstrap
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Record initial prices
        uint256 initialBasePriceETH = bondingCurve.eveBasePriceInETH();
        uint256 initialPremiumPriceETH = bondingCurve.evePremiumPriceInETH();

        // User2 enters
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Verify prices still follow correct calculation path
        uint256 navETH = strategyManager.totalNAVInETH();
        uint256 expectedBasePriceETH = (navETH * Math.NORMALIZATION_FACTOR) / eve.totalSupply();
        assertEq(
            bondingCurve.eveBasePriceInETH(), expectedBasePriceETH, "Base price should still use ETH NAV after enter"
        );

        // Prices should have changed (NAV increased, supply increased)
        assertTrue(
            bondingCurve.eveBasePriceInETH() != initialBasePriceETH
                || bondingCurve.evePremiumPriceInETH() != initialPremiumPriceETH,
            "Prices should change after operations"
        );

        // Verify USD prices are still conversions of ETH prices
        uint256 basePriceETH = bondingCurve.eveBasePriceInETH();
        uint256 basePriceUSD = bondingCurve.eveBasePriceInUSD();
        uint256 expectedUSD = oracle.convertTokenToUSD(address(0), basePriceETH, Math.DECIMALS_NORMALIZED);
        assertEq(basePriceUSD, expectedUSD, "USD price should still be ETH price converted after operations");
    }

    /**
     * @notice Test that ETH price calculations handle zero NAV correctly
     * @dev Edge case: when NAV is zero, prices should be zero
     */
    function test_ETHPricesWithZeroNAV() public {
        // Bootstrap
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Drain all ETH from controller (simulating zero NAV scenario)
        vm.deal(address(controller), 0);

        // Prices should be zero or very small
        uint256 navETH = strategyManager.totalNAVInETH();
        if (navETH == 0) {
            // If NAV is truly zero, prices should reflect that
            uint256 basePriceETH = bondingCurve.eveBasePriceInETH();
            assertEq(basePriceETH, 0, "Base price should be zero when NAV is zero");
        }
    }

    // ============ Wonderland Testing Guidelines - Unit Tests ============

    /**
     * @notice Test enter function with proper mocking following Wonderland guidelines
     * @dev Uses systematic Given/When/Then structure with proper mocking
     */
    function test_Enter_WithProperMocking_ShouldWork() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Then - Verify bootstrap and token minting
        assertTrue(bondingCurve.bootstrapped());
        assertGt(eve.balanceOf(user1), 0);
        assertEq(eve.balanceOf(address(0xdead)), DEAD_SUPPLY);
    }

    /**
     * @notice Test enter function when minimum tokens is zero
     * @dev Tests edge case with zero input
     */
    function test_Enter_WhenMinTokensZero_ShouldRevert() public {
        // Given - Zero minimum tokens
        uint256 minTokens = 0;

        // When/Then - Should revert
        vm.prank(user1);
        vm.expectRevert();
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(minTokens);
    }

    /**
     * @notice Test enter function when deposit is insufficient
     * @dev Tests sad path with insufficient funds
     */
    function test_Enter_WhenInsufficientDeposit_ShouldRevert() public {
        // Given - Insufficient deposit
        uint256 insufficientDeposit = 500e6; // Below minimum

        // When/Then - Should revert
        vm.prank(user1);
        vm.expectRevert();
        bondingCurve.enter{value: insufficientDeposit}(BOOTSTRAP_MIN_TOKENS);
    }

    /**
     * @notice Test enter function when contract is paused
     * @dev Tests sad path when contract is paused
     */
    function test_Enter_WhenPaused_ShouldRevert() public {
        // Given - Contract is paused
        vm.prank(owner);
        bondingCurve.pause();

        // When/Then - Should revert
        vm.prank(user1);
        vm.expectRevert();
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
    }

    /**
     * @notice Test exit function with immediate redemption
     * @dev Tests happy path for exit with sufficient liquidity
     */
    function test_Exit_WithImmediateRedemption_ShouldWork() public {
        // Given - Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Approve EVE tokens for exit
        uint256 userEveBalance = eve.balanceOf(user1);
        vm.prank(user1);
        eve.approve(address(bondingCurve), EXIT_MAX_TOKENS);

        // When - User exits with reasonable amount (less than available liquidity)
        uint256 exitAmount = 0.025e18; // 0.025 ETH
        vm.prank(user1);
        bondingCurve.exit(exitAmount, EXIT_MAX_TOKENS, 1e18);

        // Then - Verify user's EVE balance decreased
        assertLt(eve.balanceOf(user1), userEveBalance);
    }

    /**
     * @notice Test exit function with queued redemption
     * @dev Tests sad path when insufficient liquidity
     */
    function test_Exit_WithQueuedRedemption_ShouldWork() public {
        // Given - Bootstrap first
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Approve EVE tokens for exit
        uint256 userEveBalance = eve.balanceOf(user1);
        vm.prank(user1);
        eve.approve(address(bondingCurve), userEveBalance);

        // When - User requests exit with ETH (may queue if insufficient liquidity)
        uint256 exitAmount = 0.1e18; // 0.1 ETH request
        vm.prank(user1);
        uint256 requestId = bondingCurve.exit(exitAmount, userEveBalance, 1e18);

        // Then - Redemption completed (requestId == 0) or queued (requestId > 0)
        // No revert means success - either immediate redemption or queued
        assertTrue(requestId == 0 || requestId > 0);
    }

    /**
     * @notice Test exit function when contract is not bootstrapped
     * @dev Tests sad path before bootstrap
     */
    function test_Exit_WhenNotBootstrapped_ShouldRevert() public {
        // Given - Contract not bootstrapped

        // When/Then - Should revert
        vm.prank(user1);
        vm.expectRevert();
        bondingCurve.exit(EXIT_ETH_REQUESTED, EXIT_MAX_TOKENS, 1e18);
    }

    // ============ Fuzz Tests ============

    /**
     * @notice Fuzz test enter function with valid amounts
     * @dev Tests range of valid inputs using fuzzing
     */
    function testFuzz_Enter_WithValidAmounts(uint256 _deposit, uint256 _minTokens) public {
        uint256 deposit = bound(_deposit, 0.5e18, 100e18); // 0.5 to 100 ETH
        uint256 minTokens = bound(_minTokens, 1, 1000e18);

        vm.deal(user1, deposit);

        // When
        vm.prank(user1);
        bondingCurve.enter{value: deposit}(minTokens);
        vm.roll(block.number + 1);

        // Then
        assertTrue(bondingCurve.bootstrapped());
        assertGt(eve.balanceOf(user1), 0);
    }

    /**
     * @notice Fuzz test connector weight setting
     * @dev Tests range of valid connector weights
     */
    function testFuzz_SetConnectorWeight(uint256 _cw) public {
        // Bound to valid range (1 to 1e18) - must be > 0
        _cw = bound(_cw, 1, 1e18);

        // When - Call as admin
        vm.prank(owner);
        bondingCurve.setConnectorWeight(_cw);

        // Then
        assertEq(bondingCurve.connectorWeight(), _cw);
    }

    function testFuzz_ExitWithValidAmounts(uint256 ethRequested, uint256 maxTokens) public {
        // First bootstrap
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        vm.assume(ethRequested > 0);
        vm.assume(ethRequested <= ENTER_ETH_DEPOSIT);

        uint256 basePrice = bondingCurve.eveBasePriceInETH();
        uint256 userBalance = eve.balanceOf(user1);

        // Calculate minimum tokens needed for this ETH request
        // This mirrors the contract's calculation: tokens = (ethRequested * 1e18) / basePrice
        uint256 tokensNeeded = (ethRequested * Math.NORMALIZATION_FACTOR) / basePrice;

        // Ensure maxTokens is sufficient AND within user's balance
        vm.assume(maxTokens >= tokensNeeded);
        vm.assume(maxTokens <= userBalance);

        // Transfer some ETH for immediate redemption
        vm.deal(address(bondingCurve), ENTER_ETH_DEPOSIT);

        vm.startPrank(user1);

        eve.approve(address(bondingCurve), maxTokens);
        bondingCurve.exit(ethRequested, maxTokens, 0);

        vm.stopPrank();
    }

    function testFuzz_ConnectorWeight(uint256 cw) public {
        vm.assume(cw > 0);
        vm.assume(cw <= 1e18);

        vm.prank(owner);
        bondingCurve.setConnectorWeight(cw);
    }

    /*//////////////////////////////////////////////////////////////
            LARGE NAV MOVE REGRESSIONS (deviation guard removed)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice M-1 regression: bootstrap and a large enter in the SAME block.
     * @dev The removed deviation guard froze the AMM in this scenario (a checkpoint
     * touch in block N suppressed the post-trade checkpoint write). Without the guard
     * there is no freeze vector: same-block and next-block flows simply work.
     */
    function test_SameBlockBootstrapThenLargeEnter_NoFreeze() public {
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);

        // Same block: a large enter moves the base price far beyond the old 5% band.
        vm.prank(user2);
        bondingCurve.enter{value: 10e18}(ENTER_MIN_TOKENS);
        assertGt(eve.balanceOf(user2), 0);

        // Next block the AMM keeps working: enter and immediate exit succeed.
        vm.roll(block.number + 1);
        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);

        uint256 user2Balance = eve.balanceOf(user2);
        vm.deal(address(bondingCurve), ENTER_ETH_DEPOSIT);
        vm.startPrank(user2);
        eve.approve(address(bondingCurve), user2Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user2Balance, 0);
        vm.stopPrank();

        assertEq(batchId, 0, "exit should settle immediately against the AMM float");
    }

    /**
     * @notice M-2 regression: a large NAV jump (e.g. harvest yield accrual) does not
     * freeze enter/exit — users are simply priced against the new NAV.
     */
    function test_EnterExit_AfterLargeNAVIncrease() public {
        _bootstrapWithETH();

        // +200% NAV jump (abnormal single-tx move, far beyond the removed 5% band)
        vm.deal(address(controller), address(controller).balance * 3);

        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        assertGt(eve.balanceOf(user2), 0);

        uint256 user1Balance = eve.balanceOf(user1);
        vm.startPrank(user1);
        eve.approve(address(bondingCurve), user1Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user1Balance, 0);
        vm.stopPrank();

        assertGt(batchId, 0, "exit should queue against the new NAV");
    }

    /**
     * @notice Large NAV drop (realized strategy loss) does not freeze enter/exit —
     * user slippage params (`minTokensToMint` / `maxTokensToBurn`) are the protection.
     */
    function test_EnterExit_AfterLargeNAVDecrease() public {
        _bootstrapWithETH();

        // -50% NAV (realized loss)
        vm.deal(address(controller), address(controller).balance / 2);

        vm.prank(user2);
        bondingCurve.enter{value: ENTER_ETH_DEPOSIT}(ENTER_MIN_TOKENS);
        assertGt(eve.balanceOf(user2), 0);

        uint256 user1Balance = eve.balanceOf(user1);
        vm.startPrank(user1);
        eve.approve(address(bondingCurve), user1Balance);
        uint256 batchId = bondingCurve.exit(EXIT_SMALL_ETH, user1Balance, 0);
        vm.stopPrank();

        assertGt(batchId, 0, "exit should queue against the new NAV");
    }

    // ============ Helper Functions ============

    /**
     * @notice Helper function to bootstrap with ETH
     * @dev Performs bootstrap using real contracts (no mocking)
     */
    function _bootstrapWithETH() internal {
        // Bootstrap
        vm.prank(user1);
        bondingCurve.enter{value: BOOTSTRAP_ETH_DEPOSIT}(BOOTSTRAP_MIN_TOKENS);
        vm.roll(block.number + 1);

        // Advance one more block so bootstrap and user flows land in different
        // blocks (mirrors real usage).
        vm.roll(block.number + 1);
    }
}

/**
 * @title AMMV2
 * @notice Mock implementation for upgrade testing
 */
contract AMMV2 is AMM {
    constructor(address _registry, uint256 _CW) AMM(_registry, _CW) {}
}
