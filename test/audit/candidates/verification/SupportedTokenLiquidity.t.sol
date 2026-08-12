// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AMM} from "../../../../src/contracts/AMM.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {ExitQueue} from "../../../../src/contracts/ExitQueue.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {Whitelist} from "../../../../src/contracts/Whitelist.sol";

import {IController} from "../../../../src/interfaces/IController.sol";
import {IStrategyManager} from "../../../../src/interfaces/IStrategyManager.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";

contract SupportedTokenLiquidityTest is ProtocolTestBase {
    uint256 internal constant NATIVE_BACKING = 5 ether;
    uint256 internal constant TOKEN_BACKING = 20_000e18; // $20,000 = 5 ETH at $4,000/ETH
    uint256 internal constant BOOTSTRAP_SUPPLY = 20_000e18;

    AMM internal amm;
    Controller internal controller;
    EVE internal eve;
    ExitQueue internal exitQueue;
    Oracle internal oracle;
    StrategyManager internal strategyManager;
    Whitelist internal whitelist;
    MockERC20 internal supportedToken;

    address internal holder;
    address internal earlyExiter;

    function setUp() public {
        holder = makeAddr("laterHolder");
        earlyExiter = makeAddr("earlyExiter");

        ProtocolContracts memory deployed = _deployProtocolInstances(address(this), DEFAULT_CONNECTOR_WEIGHT);
        _registerProtocolContracts(deployed.registry, deployed, address(this), true);
        _grantProtocolRoles(deployed.registry, deployed, address(this), address(this));

        amm = deployed.amm;
        controller = deployed.controller;
        eve = deployed.token;
        exitQueue = deployed.exitQueue;
        oracle = deployed.oracle;
        strategyManager = deployed.strategyManager;
        whitelist = deployed.whitelist;

        oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, 4_000e8)), 1 hours);

        supportedToken = new MockERC20("Emergency Paired Token", "EPT", 18);
        oracle.updateUsdFeedInfo(address(supportedToken), address(new MockPriceFeed(8, 1e8)), 1 hours);
        strategyManager.addSupportedERC20(address(supportedToken));

        address[] memory users = new address[](1);
        users[0] = holder;
        whitelist.addToWhitelist(users);
        vm.deal(holder, NATIVE_BACKING);
    }

    function test_EarlyExitConsumesNativeWhileLaterHolderIsStrandedAgainstTokenNAV() public {
        vm.prank(holder);
        amm.enter{value: NATIVE_BACKING}(BOOTSTRAP_SUPPLY - 1e18);
        assertEq(eve.totalSupply(), BOOTSTRAP_SUPPLY);

        supportedToken.mint(address(strategyManager), TOKEN_BACKING);
        assertEq(strategyManager.totalNAVInETH(), 10 ether, "supported token raises redeemable NAV by 5 ETH");

        controller.provideExitLiquidity(NATIVE_BACKING);
        assertEq(amm.freeBalance(), NATIVE_BACKING);
        assertEq(address(controller).balance, 0);

        vm.prank(holder);
        eve.transfer(earlyExiter, 10_000e18);

        vm.startPrank(earlyExiter);
        eve.approve(address(amm), type(uint256).max);
        uint256 earlyBatchId = amm.exit(5 ether, 10_000e18, 0);
        vm.stopPrank();

        assertEq(earlyBatchId, 0, "first holder receives all native liquidity immediately");
        assertEq(earlyExiter.balance, 5 ether);
        assertEq(amm.freeBalance(), 0);
        assertEq(address(controller).balance, 0);
        assertEq(strategyManager.totalNAVInETH(), 5 ether, "remaining NAV is entirely the supported token");
        assertEq(eve.totalSupply(), 10_000e18);

        vm.startPrank(holder);
        eve.approve(address(amm), type(uint256).max);
        uint256 lateBatchId = amm.exit(4.999 ether, eve.balanceOf(holder), 0);
        vm.stopPrank();

        assertEq(lateBatchId, 1, "later holder is queued despite 5 ETH reported NAV");
        assertEq(strategyManager.totalNAVInETH(), 5 ether);
        assertEq(address(controller).balance + amm.freeBalance() + address(strategyManager).balance, 0);

        controller.priceBatch();
        (,,, uint256 tokensToBurn,) = exitQueue.requestInfo(lateBatchId, holder);
        assertEq(tokensToBurn, 9_998e18);

        vm.expectRevert(IController.ControllerInsufficientBalance.selector);
        controller.processRequest(lateBatchId, holder);

        vm.expectRevert(IStrategyManager.StrategyManagerNoBalanceToRecover.selector);
        strategyManager.emergencyWithdrawToController();

        uint256 strandedTokens = supportedToken.balanceOf(address(strategyManager));
        strategyManager.removeSupportedERC20(address(supportedToken));

        assertEq(supportedToken.balanceOf(address(strategyManager)), strandedTokens, "removal does not recover custody");
        assertEq(strategyManager.totalNAVInETH(), 0, "removal only drops the stranded asset from NAV");
    }
}
