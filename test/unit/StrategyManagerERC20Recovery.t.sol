// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

import {Registry} from "registry/Registry.sol";
import {StrategyManager} from "contracts/StrategyManager.sol";
import {Controller} from "contracts/Controller.sol";
import {Converter} from "contracts/Converter.sol";
import {Oracle} from "contracts/Oracle.sol";
import {AMM} from "contracts/AMM.sol";
import {EVE} from "contracts/EVE.sol";
import {IStrategyManager} from "interfaces/IStrategyManager.sol";
import {IConverter} from "interfaces/IConverter.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {Auth} from "libraries/Auth.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockPriceFeed} from "test/mocks/MockPriceFeed.sol";
import {MockConverterAdapter} from "test/mocks/MockConverterAdapter.sol";
import {MockStrategy} from "test/mocks/MockStrategy.sol";
import {MockWETH} from "test/mocks/UniCLStratMocks.sol";
import {ProtocolTestBase} from "test/helpers/ProtocolTestBase.sol";

/**
 * @title StrategyManager stranded-ERC-20 recovery tests (audit finding G4)
 * @notice After `IStrategy.emergencyExit()` the strategy's paired token sits on the
 *         StrategyManager and is priced into NAV. `convertSupportedERC20ToETH` sells it for ETH
 *         delivered to the Controller, so that value can actually be paid to redeemers.
 */
contract StrategyManagerERC20RecoveryTest is ProtocolTestBase {
    uint256 internal constant ETH_PRICE = 4000e8;
    uint256 internal constant USDC_PRICE = 1e8;
    uint256 internal constant STALENESS_INTERVAL = 3600;
    uint256 internal constant BOOTSTRAP_ETH = 1 ether;

    /// @dev $500 of USDC at $4000/ETH = 0.125 ETH.
    uint256 internal constant STRANDED_USDC = 500e6;
    uint256 internal constant STRANDED_USDC_VALUE_ETH = 0.125 ether;

    /// @dev MockConverterAdapter output = amountIn * multiplier / 1e18 in raw units. USDC (6 dp)
    ///      to WETH (18 dp) at $1 / $4000: 1e12 / 4000 = 2.5e8 wei per USDC unit.
    uint256 internal constant ORACLE_RATE_MULTIPLIER = 2.5e26;
    uint256 internal constant BPS = 10_000;

    Registry internal registry;
    StrategyManager internal strategyManager;
    Controller internal controller;
    Converter internal converter;
    Oracle internal oracle;
    AMM internal amm;
    EVE internal eve;
    MockWETH internal weth;
    MockERC20 internal usdc;
    MockConverterAdapter internal adapter;

    address internal admin;
    address internal security = makeAddr("security");
    address internal stranger = makeAddr("stranger");

    bytes internal usdcToWethPath;

    function setUp() public {
        admin = address(this);
        ProtocolContracts memory contracts = _deployProtocol(admin, 5e17);
        registry = contracts.registry;
        strategyManager = contracts.strategyManager;
        controller = contracts.controller;
        converter = contracts.converter;
        oracle = contracts.oracle;
        amm = contracts.amm;
        eve = contracts.token;
        weth = contracts.weth;

        oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, int256(ETH_PRICE))), STALENESS_INTERVAL);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle.updateUsdFeedInfo(address(usdc), address(new MockPriceFeed(8, int256(USDC_PRICE))), STALENESS_INTERVAL);
        strategyManager.addSupportedERC20(address(usdc));

        adapter = new MockConverterAdapter(weth, usdc);
        adapter.setOutputMultiplier(ORACLE_RATE_MULTIPLIER);
        converter.setAllowedAdapter(address(adapter), true);
        // The mock adapter mints WETH; back it with ETH so the Converter can unwrap it.
        vm.deal(address(weth), 100 ether);

        usdcToWethPath = abi.encodePacked(address(usdc), uint24(500), address(weth));

        registry.grantRole(Auth.SECURITY_ROLE, security);

        amm.enter{value: BOOTSTRAP_ETH}(1);

        // As left by UniCLStrat.emergencyExit(): the paired token sits on the StrategyManager.
        usdc.mint(address(strategyManager), STRANDED_USDC);
    }

    function _convert(uint256 _amountIn, uint256 _minETHOut) internal returns (uint256) {
        return strategyManager.convertSupportedERC20ToETH(
            address(usdc), address(adapter), usdcToWethPath, _amountIn, _minETHOut
        );
    }

    // ============ Happy path ============

    function test_Convert_SendsETHToControllerAndKeepsNAV() public {
        uint256 navBefore = strategyManager.totalNAVInETH();
        uint256 controllerBefore = address(controller).balance;
        assertEq(navBefore, BOOTSTRAP_ETH + STRANDED_USDC_VALUE_ETH);

        vm.expectEmit(true, false, false, true, address(strategyManager));
        emit IStrategyManager.SupportedERC20Converted(address(usdc), STRANDED_USDC, STRANDED_USDC_VALUE_ETH);
        uint256 ethOut = _convert(STRANDED_USDC, 0);

        assertEq(ethOut, STRANDED_USDC_VALUE_ETH);
        assertEq(address(controller).balance - controllerBefore, STRANDED_USDC_VALUE_ETH);
        assertEq(usdc.balanceOf(address(strategyManager)), 0);
        // Value moved from an unpayable token into payable ETH at the Oracle price: NAV unchanged.
        assertEq(strategyManager.totalNAVInETH(), navBefore);

        // Nothing is left behind on the StrategyManager or the Converter.
        assertEq(weth.balanceOf(address(strategyManager)), 0);
        assertEq(weth.balanceOf(address(converter)), 0);
        assertEq(usdc.allowance(address(strategyManager), address(converter)), 0);
        assertEq(weth.allowance(address(strategyManager), address(converter)), 0);
    }

    function test_Convert_GrantsItselfConverterCallerRoleOnce() public {
        assertFalse(converter.isCaller(address(strategyManager)));

        _convert(STRANDED_USDC / 2, 0);
        assertTrue(converter.isCaller(address(strategyManager)));

        // Second call reuses the role.
        _convert(STRANDED_USDC / 2, 0);
        assertEq(usdc.balanceOf(address(strategyManager)), 0);
    }

    function test_Convert_PartialAmountLeavesRestPricedIn() public {
        uint256 navBefore = strategyManager.totalNAVInETH();

        _convert(STRANDED_USDC / 4, 0);

        assertEq(usdc.balanceOf(address(strategyManager)), STRANDED_USDC * 3 / 4);
        assertEq(strategyManager.totalNAVInETH(), navBefore);
    }

    function test_Convert_AcceptsSlippageWithinOracleBand() public {
        uint256 maxSlippage = strategyManager.MAX_ERC20_RECOVERY_SLIPPAGE_BPS();
        adapter.setOutputMultiplier(ORACLE_RATE_MULTIPLIER * (BPS - maxSlippage) / BPS);
        uint256 navBefore = strategyManager.totalNAVInETH();

        uint256 ethOut = _convert(STRANDED_USDC, 0);

        uint256 floor = STRANDED_USDC_VALUE_ETH * (BPS - maxSlippage) / BPS;
        assertEq(ethOut, floor);
        // NAV drops by exactly the realised swap loss.
        assertEq(navBefore - strategyManager.totalNAVInETH(), STRANDED_USDC_VALUE_ETH - floor);
    }

    // ============ Price protection ============

    function test_Convert_RevertsBelowOracleFloorEvenWithZeroCallerMinimum() public {
        uint256 maxSlippage = strategyManager.MAX_ERC20_RECOVERY_SLIPPAGE_BPS();
        adapter.setOutputMultiplier(ORACLE_RATE_MULTIPLIER * (BPS - maxSlippage - 1) / BPS);

        vm.expectRevert(IConverter.ConverterInsufficientOutput.selector);
        _convert(STRANDED_USDC, 0);
    }

    function test_Convert_RevertsBelowCallerMinimum() public {
        vm.expectRevert(IConverter.ConverterInsufficientOutput.selector);
        _convert(STRANDED_USDC, STRANDED_USDC_VALUE_ETH + 1);
    }

    function test_Convert_RevertsWhenReportedOutputIsNotReceived() public {
        weth.mint(address(strategyManager), STRANDED_USDC_VALUE_ETH);
        vm.mockCall(
            address(converter),
            abi.encodeWithSelector(IConverter.executeSwapExactAmountIn.selector),
            abi.encode(STRANDED_USDC_VALUE_ETH)
        );

        vm.expectRevert(IConverter.ConverterInsufficientOutput.selector);
        _convert(STRANDED_USDC, STRANDED_USDC_VALUE_ETH);
    }

    function test_Convert_RevertsWhenOracleFeedIsStale() public {
        vm.warp(block.timestamp + STALENESS_INTERVAL + 1);
        vm.expectRevert();
        _convert(STRANDED_USDC, 0);
    }

    // ============ Validation ============

    function test_Convert_RevertsForUnsupportedToken() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(strategyManager), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IStrategyManager.StrategyManagerERC20NotSupported.selector, address(other))
        );
        strategyManager.convertSupportedERC20ToETH(
            address(other), address(adapter), abi.encodePacked(address(other), uint24(500), address(weth)), 1 ether, 0
        );
    }

    function test_Convert_RevertsForZeroAmount() public {
        vm.expectRevert(IStrategyManager.StrategyManagerNoBalanceToRecover.selector);
        _convert(0, 0);
    }

    function test_Convert_RevertsWhenRouteDoesNotSellTheTokenForWETH() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);

        bytes[3] memory badPaths = [
            abi.encodePacked(address(weth), uint24(500), address(usdc)),
            abi.encodePacked(address(usdc), uint24(500), address(other)),
            abi.encodePacked(address(other), uint24(500), address(weth))
        ];
        for (uint256 i; i < badPaths.length; ++i) {
            vm.expectRevert(IStrategyManager.StrategyManagerInvalidRecoveryRoute.selector);
            strategyManager.convertSupportedERC20ToETH(address(usdc), address(adapter), badPaths[i], STRANDED_USDC, 0);
        }
    }

    function test_Convert_RevertsForAdapterNotAllowedOnConverter() public {
        MockConverterAdapter rogue = new MockConverterAdapter(weth, usdc);

        vm.expectRevert(IConverter.ConverterAdapterNotAllowed.selector);
        strategyManager.convertSupportedERC20ToETH(address(usdc), address(rogue), usdcToWethPath, STRANDED_USDC, 0);
    }

    function test_Convert_RevertsWhenAmountExceedsBalance() public {
        vm.expectRevert();
        _convert(STRANDED_USDC + 1, 0);
    }

    // ============ Access & pause ============

    function test_Convert_SecurityRoleCanConvert() public {
        vm.prank(security);
        uint256 ethOut = _convert(STRANDED_USDC, 0);
        assertEq(ethOut, STRANDED_USDC_VALUE_ETH);
    }

    function test_Convert_RevertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRegistryClient.RegistryClientCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE
            )
        );
        _convert(STRANDED_USDC, 0);
    }

    /// @dev Emergency exits happen while paused; recovery must not require unpausing.
    function test_Convert_WorksWhileStrategyManagerPaused() public {
        strategyManager.pause();
        assertTrue(strategyManager.paused());

        uint256 ethOut = _convert(STRANDED_USDC, 0);
        assertEq(ethOut, STRANDED_USDC_VALUE_ETH);
    }

    // ============ The audit scenario ============

    /// @dev G4: an emergency exit leaves part of NAV in a token the protocol cannot pay out.
    ///      Once converted, that value is ETH on the Controller and redeemable like any other.
    function test_EmergencyExitedPairedToken_BecomesPayableETH() public {
        MockStrategy strategy = new MockStrategy("Exited", address(controller), address(strategyManager));
        strategyManager.addStrategy(address(strategy), 80, 70);

        // The strategy has already swept its paired token here and reports no NAV.
        strategy.setNavInETH(0);
        uint256 payableBefore = address(controller).balance + address(strategyManager).balance;
        uint256 navBefore = strategyManager.totalNAVInETH();
        assertGt(navBefore, payableBefore);

        _convert(STRANDED_USDC, 0);

        uint256 payableAfter = address(controller).balance + address(strategyManager).balance;
        assertEq(payableAfter, navBefore - amm.freeBalance());
        assertEq(strategyManager.totalNAVInETH(), navBefore);
    }
}
