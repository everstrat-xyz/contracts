// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AMM} from "../../../../src/contracts/AMM.sol";
import {Controller} from "../../../../src/contracts/Controller.sol";
import {Converter} from "../../../../src/contracts/Converter.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {UniCLStrat} from "../../../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../../../src/interfaces/strategies/IUniCLStrat.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockConverterAdapter} from "../../../mocks/MockConverterAdapter.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";
import {MockUniCLPool, MockWETH} from "../../../mocks/UniCLStratMocks.sol";

contract UnpokedFeeNAVTest is ProtocolTestBase {
    uint256 private constant SCALE = 1e18;
    uint256 private constant INITIAL_TIMESTAMP = 1_700_000_000;
    uint256 private constant BOOTSTRAP_ETH = 80 ether;
    uint256 private constant INITIAL_STRATEGY_DEPOSIT = 40 ether;
    uint256 private constant MAX_TOTAL_NAV = 60 ether;
    uint256 private constant UNPOKED_WETH_FEES = 5 ether;
    uint256 private constant ENTRANT_DEPOSIT = 10 ether;
    uint256 private constant ETH_USD_PRICE = 4000e8;
    uint256 private constant NAV_TOLERANCE = 100 wei;

    AMM private amm;
    Controller private controller;
    Converter private converter;
    EVE private eve;
    Oracle private oracle;
    StrategyManager private manager;
    MockWETH private weth;
    MockERC20 private pairedToken;
    MockUniCLPool private pool;
    UniCLStrat private strategy;

    address private incumbent;
    address private entrant;

    function setUp() public {
        vm.warp(INITIAL_TIMESTAMP);
        incumbent = makeAddr("incumbent cohort");
        entrant = makeAddr("entrant at stale NAV");

        ProtocolContracts memory deployed = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        amm = deployed.amm;
        controller = deployed.controller;
        converter = deployed.converter;
        eve = deployed.token;
        oracle = deployed.oracle;
        manager = deployed.strategyManager;
        weth = deployed.weth;

        MockPriceFeed ethFeed = new MockPriceFeed(8, int256(ETH_USD_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethFeed), 1 days);

        pairedToken = new MockERC20("Paired Token", "PAIR", 18);
        MockPriceFeed pairedFeed = new MockPriceFeed(8, int256(ETH_USD_PRICE));
        oracle.updateUsdFeedInfo(address(pairedToken), address(pairedFeed), 1 days);

        pool = new MockUniCLPool(address(weth), address(pairedToken), 60, 0);
        MockConverterAdapter adapter = new MockConverterAdapter(weth, pairedToken);
        converter.setAllowedAdapter(address(adapter), true);

        strategy = new UniCLStrat(
            IUniCLStrat.DeploymentConfig({
                addresses: IUniCLStrat.AddressConfig({
                    registry: address(deployed.registry),
                    weth: address(weth),
                    pool: address(pool)
                }),
                routes: IUniCLStrat.RouteConfig({
                    swapAdapter: address(adapter),
                    wethToPairedTokenPath: abi.encodePacked(address(weth), uint24(3000), address(pairedToken)),
                    pairedTokenToWethPath: abi.encodePacked(address(pairedToken), uint24(3000), address(weth))
                }),
                strategy: IUniCLStrat.StrategyConfig({
                    positionWidth: 2,
                    rebalanceTickThreshold: 30,
                    maxTickDeviation: 10,
                    twapInterval: 1800,
                    shortTwapInterval: 60,
                    maxTotalNAV: MAX_TOTAL_NAV
                })
            })
        );
        manager.addStrategy(address(strategy), 1, 1);

        vm.deal(incumbent, BOOTSTRAP_ETH);
        vm.prank(incumbent);
        amm.enter{value: BOOTSTRAP_ETH}(1);
        controller.depositToStrategy(address(strategy), INITIAL_STRATEGY_DEPOSIT);
    }

    function test_UnpokedFeesUnderstateNAVMispriceEntryAndPermitCapOverrun() public {
        uint256 reportedStrategyNAV = strategy.navInETH();
        uint256 reportedProtocolNAV = manager.totalNAVInETH();
        uint256 staleHeadroom = strategy.maxDeposit();
        assertEq(staleHeadroom, MAX_TOTAL_NAV - reportedStrategyNAV);

        (int24 tickLower, int24 tickUpper) = strategy.positionMain();
        bytes32 positionKey = keccak256(abi.encodePacked(address(strategy), tickLower, tickUpper));
        pool.accrueFees(address(strategy), tickLower, tickUpper, uint128(UNPOKED_WETH_FEES), 0);

        (uint128 liquidity, uint128 owed0,, uint128 pending0,) = pool.positionStates(positionKey);
        assertGt(liquidity, 0);
        assertEq(owed0, 0);
        assertEq(pending0, UNPOKED_WETH_FEES);
        assertEq(strategy.navInETH(), reportedStrategyNAV);
        assertEq(manager.totalNAVInETH(), reportedProtocolNAV);
        assertEq(strategy.maxDeposit(), staleHeadroom);

        uint256 snapshot = vm.snapshotState();

        // Branch A: AMM entry prices against reportedProtocolNAV, not NAV + hidden fees.
        uint256 supplyBefore = eve.totalSupply();
        uint256 adjustedSupply = supplyBefore * amm.connectorWeight() / SCALE;
        uint256 stalePremiumPrice = reportedProtocolNAV * SCALE / adjustedSupply;
        uint256 fairPremiumPrice = (reportedProtocolNAV + UNPOKED_WETH_FEES) * SCALE / adjustedSupply;
        uint256 staleExpectedMint = ENTRANT_DEPOSIT * SCALE / stalePremiumPrice;
        uint256 fairExpectedMint = ENTRANT_DEPOSIT * SCALE / fairPremiumPrice;

        vm.deal(entrant, ENTRANT_DEPOSIT);
        vm.prank(entrant);
        amm.enter{value: ENTRANT_DEPOSIT}(1);

        uint256 actualMint = eve.balanceOf(entrant);
        assertEq(actualMint, staleExpectedMint);
        assertGt(actualMint, fairExpectedMint);

        uint256 navBeforePoke = manager.totalNAVInETH();
        assertEq(navBeforePoke, reportedProtocolNAV + ENTRANT_DEPOSIT);
        controller.syncStrategy(address(strategy));
        assertEq(manager.totalNAVInETH() - navBeforePoke, UNPOKED_WETH_FEES);

        uint256 incumbentActualShare = eve.balanceOf(incumbent) * SCALE / eve.totalSupply();
        uint256 incumbentFairShare = eve.balanceOf(incumbent) * SCALE / (supplyBefore + fairExpectedMint);
        assertLt(incumbentActualShare, incumbentFairShare);

        assertTrue(vm.revertToState(snapshot));

        // Branch B: the advertised full headroom passes before deposit pokes the hidden fees.
        controller.depositToStrategy(address(strategy), staleHeadroom);
        uint256 navAfterDeposit = strategy.navInETH();
        assertGt(navAfterDeposit, MAX_TOTAL_NAV);
        assertApproxEqAbs(navAfterDeposit - MAX_TOTAL_NAV, UNPOKED_WETH_FEES, NAV_TOLERANCE);
        assertEq(strategy.maxDeposit(), 0);

        (,,, pending0,) = pool.positionStates(positionKey);
        assertEq(pending0, 0);
    }
}
