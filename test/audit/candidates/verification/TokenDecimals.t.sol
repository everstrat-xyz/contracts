// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";
import {MockUniCLPool} from "../../../mocks/UniCLStratMocks.sol";
import {MockConverterAdapter} from "../../../mocks/MockConverterAdapter.sol";
import {UniCLStrat} from "../../../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../../../src/interfaces/strategies/IUniCLStrat.sol";
import {Math} from "../../../../src/libraries/Math.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";

contract TokenDecimalsVerificationTest is ProtocolTestBase {
    uint256 private constant STALENESS = 1 hours;
    address private attacker = makeAddr("attacker");
    address private security = makeAddr("security");

    ProtocolContracts private protocol;
    MockERC20 private highDecimalToken;

    function setUp() public {
        vm.warp(1_700_000_000);
        protocol = _deployProtocol(address(this), 5e17);

        MockPriceFeed ethFeed = new MockPriceFeed(8, 4_000e8);
        MockPriceFeed tokenFeed = new MockPriceFeed(8, 1e8);
        highDecimalToken = new MockERC20("High Decimal", "HIGH", 19);
        protocol.oracle.updateUsdFeedInfo(address(0), address(ethFeed), STALENESS);
        protocol.oracle.updateUsdFeedInfo(address(highDecimalToken), address(tokenFeed), STALENESS);
        protocol.registry.grantRole(Auth.SECURITY_ROLE, security);

        protocol.amm.enter{value: 1 ether}(1);
    }

    function test_SupportedERC20_DustFreezesNAVAndPricingUntilSecurityRemovesIt() public {
        protocol.strategyManager.addSupportedERC20(address(highDecimalToken));
        assertTrue(protocol.strategyManager.isSupportedERC20(address(highDecimalToken)));
        assertGt(protocol.strategyManager.totalNAVInETH(), 0);
        assertGt(protocol.amm.eveBasePriceInETH(), 0);

        _donateOneUnit(address(protocol.strategyManager));

        vm.expectRevert(Math.MathDecimalsTooHigh.selector);
        protocol.strategyManager.totalNAVInETH();
        vm.expectRevert(Math.MathDecimalsTooHigh.selector);
        protocol.amm.eveBasePriceInETH();

        vm.prank(security);
        protocol.strategyManager.removeSupportedERC20(address(highDecimalToken));
        assertGt(protocol.strategyManager.totalNAVInETH(), 0);
        assertGt(protocol.amm.eveBasePriceInETH(), 0);
        assertEq(highDecimalToken.balanceOf(address(protocol.strategyManager)), 1);
    }

    function test_UniCLConstructorAcceptsHighDecimalsThenDustFreezesProtocolNAV() public {
        MockConverterAdapter adapter = new MockConverterAdapter(protocol.weth, highDecimalToken);
        MockUniCLPool pool = new MockUniCLPool(address(protocol.weth), address(highDecimalToken), 60, 0);
        protocol.converter.setAllowedAdapter(address(adapter), true);

        bytes memory wethToPaired = abi.encodePacked(address(protocol.weth), uint24(3_000), address(highDecimalToken));
        bytes memory pairedToWeth = abi.encodePacked(address(highDecimalToken), uint24(3_000), address(protocol.weth));
        IUniCLStrat.DeploymentConfig memory config = IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: address(protocol.registry),
                weth: address(protocol.weth),
                pool: address(pool)
            }),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: address(adapter),
                wethToPairedTokenPath: wethToPaired,
                pairedTokenToWethPath: pairedToWeth
            }),
            strategy: IUniCLStrat.StrategyConfig({
                positionWidth: 2,
                rebalanceTickThreshold: 30,
                maxTickDeviation: 10,
                twapInterval: 1_800,
                shortTwapInterval: 60,
                maxTotalNAV: 100 ether
            })
        });

        UniCLStrat strategy = new UniCLStrat(config);
        assertEq(strategy.pairedToken().decimals(), 19);
        protocol.strategyManager.addStrategy(address(strategy), 0, 100);
        assertGt(protocol.strategyManager.totalNAVInETH(), 0);

        _donateOneUnit(address(strategy));

        vm.expectRevert(Math.MathDecimalsTooHigh.selector);
        strategy.navInETH();
        vm.expectRevert(Math.MathDecimalsTooHigh.selector);
        protocol.strategyManager.totalNAVInETH();
        vm.expectRevert(Math.MathDecimalsTooHigh.selector);
        protocol.amm.eveBasePriceInETH();

        // The security path can evacuate a standard paired token without pricing it.
        vm.startPrank(security);
        strategy.pause();
        strategy.emergencyExit();
        vm.stopPrank();
        assertEq(highDecimalToken.balanceOf(address(strategy)), 0);
        assertEq(highDecimalToken.balanceOf(address(protocol.strategyManager)), 1);
        assertGt(protocol.strategyManager.totalNAVInETH(), 0);
        assertGt(protocol.amm.eveBasePriceInETH(), 0);
    }

    function _donateOneUnit(address recipient) private {
        highDecimalToken.mint(attacker, 1);
        vm.prank(attacker);
        highDecimalToken.transfer(recipient, 1);
    }
}
