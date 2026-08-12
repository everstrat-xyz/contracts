// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AMM} from "../../../../src/contracts/AMM.sol";
import {Converter} from "../../../../src/contracts/Converter.sol";
import {EVE} from "../../../../src/contracts/EVE.sol";
import {Oracle} from "../../../../src/contracts/Oracle.sol";
import {StrategyManager} from "../../../../src/contracts/StrategyManager.sol";
import {UniCLStrat} from "../../../../src/contracts/strategies/UniCLStrat.sol";
import {IUniswapV3Pool} from "../../../../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {IUniCLStrat} from "../../../../src/interfaces/strategies/IUniCLStrat.sol";

import {ProtocolTestBase} from "../../../helpers/ProtocolTestBase.sol";
import {MockConverterAdapter} from "../../../mocks/MockConverterAdapter.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {MockPriceFeed} from "../../../mocks/MockPriceFeed.sol";
import {MockWETH} from "../../../mocks/UniCLStratMocks.sol";

contract HistoryLimitedPool is IUniswapV3Pool {
    address public immutable override token0;
    address public immutable override token1;
    uint24 public constant override fee = 3000;
    int24 public constant override tickSpacing = 60;

    uint32 public availableHistory;

    constructor(address _token0, address _token1, uint32 _availableHistory) {
        token0 = _token0;
        token1 = _token1;
        availableHistory = _availableHistory;
    }

    function setAvailableHistory(uint32 _availableHistory) external {
        availableHistory = _availableHistory;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1) << 96, 0, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata _secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](_secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](_secondsAgos.length);
        for (uint256 i; i < _secondsAgos.length; ++i) {
            if (_secondsAgos[i] > availableHistory) revert("OLD");
        }
    }

    function positions(bytes32) external pure returns (uint128, uint256, uint256, uint128, uint128) {
        return (0, 0, 0, 0, 0);
    }

    function mint(address, int24, int24, uint128, bytes calldata) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function burn(int24, int24, uint128) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function collect(address, int24, int24, uint128, uint128) external pure returns (uint128, uint128) {
        return (0, 0);
    }
}

contract TwapAvailabilityTest is ProtocolTestBase {
    uint32 private constant MIN_LONG_WINDOW = 1800;
    uint32 private constant LONGER_WINDOW = 3600;
    uint256 private constant BOOTSTRAP_ETH = 80 ether;
    uint256 private constant ETH_USD_PRICE = 4000e8;

    AMM private amm;
    Converter private converter;
    EVE private eve;
    Oracle private oracle;
    StrategyManager private manager;
    UniCLStrat private strategy;
    HistoryLimitedPool private pool;

    address private incumbent;
    address private entrant;

    function setUp() public {
        incumbent = makeAddr("incumbent");
        entrant = makeAddr("entrant");

        ProtocolContracts memory deployed = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        amm = deployed.amm;
        converter = deployed.converter;
        eve = deployed.token;
        oracle = deployed.oracle;
        manager = deployed.strategyManager;
        MockWETH weth = deployed.weth;

        MockPriceFeed ethFeed = new MockPriceFeed(8, int256(ETH_USD_PRICE));
        oracle.updateUsdFeedInfo(address(0), address(ethFeed), 1 days);

        vm.deal(incumbent, BOOTSTRAP_ETH);
        vm.prank(incumbent);
        amm.enter{value: BOOTSTRAP_ETH}(1);

        MockERC20 pairedToken = new MockERC20("Paired Token", "PAIR", 18);
        MockPriceFeed pairedFeed = new MockPriceFeed(8, int256(ETH_USD_PRICE));
        oracle.updateUsdFeedInfo(address(pairedToken), address(pairedFeed), 1 days);

        // One second short of the constructor's accepted long window.
        pool = new HistoryLimitedPool(address(weth), address(pairedToken), MIN_LONG_WINDOW - 1);
        MockConverterAdapter adapter = new MockConverterAdapter(weth, pairedToken);
        converter.setAllowedAdapter(address(adapter), true);

        // Constructor performs no observation-availability check and succeeds.
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
                    twapInterval: MIN_LONG_WINDOW,
                    shortTwapInterval: 60,
                    maxTotalNAV: 100 ether
                })
            })
        );

        // Registration also performs no NAV/observe preflight and succeeds.
        manager.addStrategy(address(strategy), 1, 1);
    }

    function test_InsufficientHistoryFreezesPricingAndAllRecoveryPathsWork() public {
        bytes4 unavailable = IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector;

        assertFalse(strategy.isHealthy());
        assertEq(strategy.maxDeposit(), 0);
        vm.expectRevert(unavailable);
        strategy.navInETH();
        vm.expectRevert(unavailable);
        manager.totalNAVInETH();

        // Cold-start recovery: once the pool can serve the minimum, NAV is live.
        pool.setAvailableHistory(MIN_LONG_WINDOW);
        assertEq(strategy.navInETH(), 0);
        assertEq(manager.totalNAVInETH(), BOOTSTRAP_ETH);

        // The setter accepts a longer unavailable window without probing observe().
        strategy.setTwapInterval(LONGER_WINDOW);
        assertEq(strategy.twapInterval(), LONGER_WINDOW);
        vm.expectRevert(unavailable);
        amm.eveBasePriceInETH();

        vm.deal(entrant, 1 ether);
        vm.prank(entrant);
        vm.expectRevert(unavailable);
        amm.enter{value: 1 ether}(1);

        vm.startPrank(incumbent);
        eve.approve(address(amm), type(uint256).max);
        uint256 incumbentTokens = eve.balanceOf(incumbent);
        vm.expectRevert(unavailable);
        amm.exit(1 ether, incumbentTokens, 0);
        vm.stopPrank();

        // Clean removal reads NAV and is therefore unavailable too.
        vm.expectRevert(unavailable);
        manager.removeStrategy(address(strategy));

        uint256 historyRecovery = vm.snapshotState();
        pool.setAvailableHistory(LONGER_WINDOW);
        assertEq(manager.totalNAVInETH(), BOOTSTRAP_ETH);
        assertTrue(vm.revertToState(historyRecovery));

        uint256 configRecovery = vm.snapshotState();
        strategy.setTwapInterval(MIN_LONG_WINDOW);
        assertEq(manager.totalNAVInETH(), BOOTSTRAP_ETH);
        vm.prank(entrant);
        amm.enter{value: 1 ether}(1);
        assertGt(eve.balanceOf(entrant), 0);
        assertTrue(vm.revertToState(configRecovery));

        // forceRemove catches the failed NAV read and restores protocol pricing.
        manager.forceRemoveStrategy(address(strategy));
        assertEq(manager.strategyCount(), 0);
        assertEq(manager.totalNAVInETH(), BOOTSTRAP_ETH);
        vm.prank(entrant);
        amm.enter{value: 1 ether}(1);
        assertGt(eve.balanceOf(entrant), 0);
    }
}
