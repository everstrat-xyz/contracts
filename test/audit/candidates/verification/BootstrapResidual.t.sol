// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AMM} from "../../../../src/contracts/AMM.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {Whitelist} from "../../../../src/contracts/Whitelist.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";

contract BootstrapResidualTest is ProtocolTestBase {
    uint256 internal constant BOOTSTRAP_DEPOSIT = 0.25 ether;
    uint256 internal constant RESIDUAL = 10 ether;
    uint256 internal constant EXPECTED_SUPPLY = 1_000e18;

    AMM internal amm;
    Controller internal controller;
    EVE internal eve;
    Oracle internal oracle;
    StrategyManager internal strategyManager;
    Whitelist internal whitelist;

    address internal attacker;
    address internal donor;

    function setUp() public {
        attacker = makeAddr("firstWhitelistedDepositor");
        donor = makeAddr("residualDonor");

        ProtocolContracts memory deployed = _deployProtocolInstances(address(this), DEFAULT_CONNECTOR_WEIGHT);
        _registerProtocolContracts(deployed.registry, deployed, address(this), true);
        _grantProtocolRoles(deployed.registry, deployed, address(this), address(this));

        amm = deployed.amm;
        controller = deployed.controller;
        eve = deployed.token;
        oracle = deployed.oracle;
        strategyManager = deployed.strategyManager;
        whitelist = deployed.whitelist;

        oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, 4_000e8)), 1 hours);

        address[] memory users = new address[](1);
        users[0] = attacker;
        whitelist.addToWhitelist(users);

        vm.deal(attacker, 1 ether);
        vm.deal(donor, 100 ether);
    }

    function test_FirstWhitelistedDepositorCapturesPreBootstrapAMMResidual() public {
        vm.prank(donor);
        (bool donated,) = address(amm).call{value: RESIDUAL}("");
        assertTrue(donated);

        assertFalse(amm.bootstrapped());
        assertEq(eve.totalSupply(), 0);
        assertEq(strategyManager.totalNAVInETH(), RESIDUAL);

        uint256 attackerETHBefore = attacker.balance;
        vm.prank(attacker);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(EXPECTED_SUPPLY - 1e18);

        assertTrue(amm.bootstrapped());
        assertEq(eve.totalSupply(), EXPECTED_SUPPLY, "supply is sized only from msg.value in USD");
        assertEq(eve.balanceOf(attacker), EXPECTED_SUPPLY - 1e18);
        assertEq(strategyManager.totalNAVInETH(), RESIDUAL + BOOTSTRAP_DEPOSIT);
        assertEq(address(amm).balance, RESIDUAL);
        assertEq(address(controller).balance, BOOTSTRAP_DEPOSIT);

        uint256 tokensBeforeExit = eve.balanceOf(attacker);
        vm.prank(attacker);
        eve.approve(address(amm), tokensBeforeExit);
        vm.prank(attacker);
        uint256 batchId = amm.exit(RESIDUAL, tokensBeforeExit, 0);

        assertEq(batchId, 0, "residual is paid as an immediate redemption");
        assertGe(attacker.balance, attackerETHBefore - BOOTSTRAP_DEPOSIT + RESIDUAL - 1);
        assertGt(attacker.balance, attackerETHBefore, "first depositor realizes immediate profit");
        assertLt(eve.balanceOf(attacker), tokensBeforeExit);
        assertLe(amm.freeBalance(), 1);
    }

    function test_AllCoreNativeCustodyBalancesCountBeforeBootstrap() public {
        _sendFromDonor(address(amm), 1 ether);
        _sendFromDonor(address(controller), 2 ether);
        _sendFromDonor(address(strategyManager), 3 ether);

        assertFalse(amm.bootstrapped());
        assertEq(eve.totalSupply(), 0);
        assertEq(amm.freeBalance(), 1 ether);
        assertEq(address(controller).balance, 2 ether);
        assertEq(address(strategyManager).balance, 3 ether);
        assertEq(strategyManager.totalNAVInETH(), 6 ether);

        vm.prank(attacker);
        amm.enter{value: BOOTSTRAP_DEPOSIT}(EXPECTED_SUPPLY - 1e18);

        assertEq(eve.totalSupply(), EXPECTED_SUPPLY);
        assertEq(strategyManager.totalNAVInETH(), 6 ether + BOOTSTRAP_DEPOSIT);
    }

    function _sendFromDonor(address recipient, uint256 amount) internal {
        vm.prank(donor);
        (bool success,) = payable(recipient).call{value: amount}("");
        assertTrue(success);
    }
}
