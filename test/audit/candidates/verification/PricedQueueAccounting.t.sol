// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AMM} from "../../../../src/contracts/AMM.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {ExitQueue} from "../../../../src/contracts/ExitQueue.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {Whitelist} from "../../../../src/contracts/Whitelist.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";

contract PricedQueueAccountingTest is ProtocolTestBase {
    uint256 internal constant INITIAL_NAV = 100 ether;
    uint256 internal constant INITIAL_SUPPLY = 100_000e18;
    uint256 internal constant QUEUED_SHARES = 80_000e18;
    uint256 internal constant QUEUED_LIABILITY = 80 ether;
    uint256 internal constant POST_PRICE_GAIN = 80 ether;
    uint256 internal constant EXITING_ACTIVE_SHARES = 10_000e18;
    uint256 internal constant ENTRY_DEPOSIT = 10 ether;

    AMM internal amm;
    Controller internal controller;
    EVE internal eve;
    ExitQueue internal exitQueue;
    Oracle internal oracle;
    StrategyManager internal strategyManager;
    Whitelist internal whitelist;

    address internal holder;
    address internal queuedUser;
    address internal activeExiter;
    address internal entrant;
    address internal gainSource;

    function setUp() public {
        holder = makeAddr("remainingActiveHolder");
        queuedUser = makeAddr("pricedQueuedUser");
        activeExiter = makeAddr("activeExiter");
        entrant = makeAddr("postPriceEntrant");
        gainSource = makeAddr("postPriceGainSource");

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

        oracle.updateUsdFeedInfo(address(0), address(new MockPriceFeed(8, 1_000e8)), 1 hours);

        address[] memory users = new address[](2);
        users[0] = holder;
        users[1] = entrant;
        whitelist.addToWhitelist(users);

        vm.deal(holder, INITIAL_NAV);
        vm.deal(entrant, ENTRY_DEPOSIT);
        vm.deal(gainSource, POST_PRICE_GAIN);
    }

    function test_PostPriceGainIsMisallocatedAcrossQueuedActiveAndEnteringCohorts() public {
        vm.prank(holder);
        amm.enter{value: INITIAL_NAV}(INITIAL_SUPPLY - 1e18);

        vm.startPrank(holder);
        eve.transfer(queuedUser, QUEUED_SHARES);
        eve.transfer(activeExiter, EXITING_ACTIVE_SHARES);
        vm.stopPrank();

        vm.startPrank(queuedUser);
        eve.approve(address(amm), type(uint256).max);
        uint256 batchId = amm.exit(QUEUED_LIABILITY, QUEUED_SHARES, 1e18);
        vm.stopPrank();
        assertEq(batchId, 1);

        controller.priceBatch();
        (, uint256 fixedPrice,,,) = exitQueue.batchInfo(batchId);

        assertEq(fixedPrice, 1e15);
        assertEq(eve.totalSupply(), INITIAL_SUPPLY, "pricing does not burn escrowed queue shares");
        assertEq(eve.balanceOf(address(amm)), QUEUED_SHARES);
        assertEq(strategyManager.totalNAVInETH(), INITIAL_NAV, "priced liability backing remains in NAV");
        assertEq(QUEUED_SHARES * fixedPrice / 1e18, QUEUED_LIABILITY);

        vm.prank(gainSource);
        (bool gained,) = address(amm).call{value: POST_PRICE_GAIN}("");
        assertTrue(gained);

        uint256 rawBasePrice = amm.eveBasePriceInETH();
        uint256 activeResidualPrice =
            (strategyManager.totalNAVInETH() - QUEUED_LIABILITY) * 1e18 / (eve.totalSupply() - QUEUED_SHARES);
        assertEq(rawBasePrice, 1.8e15, "AMM spreads gain over fixed queued shares");
        assertEq(activeResidualPrice, 5e15, "gain belongs to active shares after reserving liability");

        vm.startPrank(activeExiter);
        eve.approve(address(amm), type(uint256).max);
        uint256 exitBatchId = amm.exit(18 ether, EXITING_ACTIVE_SHARES, 0);
        vm.stopPrank();
        assertEq(exitBatchId, 0);
        assertEq(activeExiter.balance, 18 ether);
        assertEq(EXITING_ACTIVE_SHARES * activeResidualPrice / 1e18, 50 ether);

        vm.prank(entrant);
        amm.enter{value: ENTRY_DEPOSIT}(1);
        assertEq(eve.balanceOf(entrant), 2_777_777777777777777777, "entrant mints at raw 3.6e-3 premium price");

        controller.processRequest(batchId, queuedUser);
        vm.prank(queuedUser);
        amm.claim();

        assertEq(queuedUser.balance, QUEUED_LIABILITY, "priced cohort receives its fixed liability");
        assertEq(strategyManager.totalNAVInETH(), 92 ether);
        assertEq(eve.totalSupply(), 12_777_777777777777777777);

        uint256 finalBasePrice = amm.eveBasePriceInETH();
        uint256 entrantClaim = eve.balanceOf(entrant) * finalBasePrice / 1e18;
        uint256 incumbentCohortClaim = strategyManager.totalNAVInETH() - entrantClaim;
        assertApproxEqAbs(finalBasePrice, 7.2e15, 1);
        assertApproxEqAbs(entrantClaim, 20 ether, 2);
        assertApproxEqAbs(incumbentCohortClaim, 72 ether, 2);
        assertGt(entrantClaim, ENTRY_DEPOSIT, "entrant captures pre-entry active-cohort gain");

        uint256 conserved = queuedUser.balance + activeExiter.balance + strategyManager.totalNAVInETH();
        assertEq(conserved, INITIAL_NAV + POST_PRICE_GAIN + ENTRY_DEPOSIT);
    }
}
