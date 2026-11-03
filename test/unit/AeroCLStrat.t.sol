// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
// solhint-disable gas-small-strings
pragma solidity ^0.8.30;

import {AeroCLStrat} from "../../src/contracts/strategies/AeroCLStrat.sol";
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {UniCLStratTestBase} from "../helpers/UniCLStratTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAeroCLPool, MockAeroCLFactory} from "../mocks/AeroCLStratMocks.sol";

/**
 * @title AeroCLStratTest
 * @notice Unit tests for AeroCLStrat. Strategy mechanics are shared with UniCLStrat (same
 *         `UniCLStratLib`) and covered exhaustively by `UniCLStrat.t.sol`; this suite targets the
 *         Aero-specific surface — the 6-field Slipstream `slot0`, tick-spacing-keyed factory
 *         provenance, and the locally inlined observation-cardinality gate — and smoke-tests each
 *         strategy action through that `slot0` path.
 * @dev Reuses `UniCLStratTestBase` for registry / oracle / converter / token wiring; the Aero pool
 *      and factory are deployed alongside, on the same WETH / paired-token pair.
 */
contract AeroCLStratTest is UniCLStratTestBase {
    int24 public constant OTHER_TICK_SPACING = 100;
    uint32 public constant UPDATED_TWAP_INTERVAL = 3600;
    uint16 public constant CARDINALITY_BELOW_UPDATED_WINDOW = 200; // < ceil(3600 / 12) = 300
    uint256 public constant ACCRUED_FEE_WETH = 0.1 ether;
    uint256 public constant ACCRUED_FEE_PAIRED = 0.05 ether;
    uint256 public constant WITHDRAW_NAV_REL_TOLERANCE = 1e16; // 1%

    MockAeroCLPool public aeroPool;
    MockAeroCLFactory public aeroFactory;
    AeroCLStrat public aeroStrategy;

    function setUp() public override {
        super.setUp();

        aeroPool = new MockAeroCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        aeroFactory = new MockAeroCLFactory();
        aeroFactory.setPool(address(weth), address(pairedToken), TICK_SPACING, address(aeroPool));
        aeroStrategy = new AeroCLStrat(_aeroConfig());
    }

    // ============ Constructor ============

    function test_Constructor_SetsInitialState() public view {
        assertEq(aeroStrategy.name(), "Aero Concentrated Liquidity Strategy");
        assertEq(aeroStrategy.version(), "1.0.0");
        assertEq(address(aeroStrategy.pool()), address(aeroPool));
        assertEq(address(aeroStrategy.factory()), address(aeroFactory));
        assertEq(address(aeroStrategy.weth()), address(weth));
        assertEq(address(aeroStrategy.pairedToken()), address(pairedToken));
        assertEq(aeroStrategy.tickSpacing(), TICK_SPACING);
        assertEq(aeroStrategy.twapInterval(), TWAP_INTERVAL);
        assertEq(aeroStrategy.shortTwapInterval(), SHORT_TWAP_INTERVAL);
        assertEq(aeroStrategy.maxTotalNAV(), MAX_TOTAL_NAV);
        assertEq(aeroStrategy.navInETH(), 0);
        assertFalse(aeroStrategy.initTicks());
        assertEq(address(aeroStrategy.registry()), address(registry));
    }

    function test_Constructor_RevertsWithZeroFactory() public {
        IUniCLStrat.DeploymentConfig memory config = _aeroConfig();
        config.addresses.factory = address(0);

        vm.expectRevert(IUniCLStrat.UniCLStratZeroAddress.selector);
        new AeroCLStrat(config);
    }

    function test_Constructor_RevertsWithNonWethPool() public {
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER", PAIRED_TOKEN_DECIMALS);
        MockAeroCLPool invalidPool =
            new MockAeroCLPool(address(otherToken), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        aeroFactory.setPool(address(otherToken), address(pairedToken), TICK_SPACING, address(invalidPool));
        IUniCLStrat.DeploymentConfig memory config = _aeroConfig();
        config.addresses.pool = address(invalidPool);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new AeroCLStrat(config);
    }

    function test_Constructor_RevertsWhenPoolNotRegisteredInFactory() public {
        MockAeroCLPool unregisteredPool =
            new MockAeroCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        IUniCLStrat.DeploymentConfig memory config = _aeroConfig();
        config.addresses.pool = address(unregisteredPool);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new AeroCLStrat(config);
    }

    function test_Constructor_RevertsWhenFactoryReturnsDifferentPool() public {
        MockAeroCLPool otherPool = new MockAeroCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        aeroFactory.setPool(address(weth), address(pairedToken), TICK_SPACING, address(otherPool));

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new AeroCLStrat(_aeroConfig());
    }

    /// @dev Provenance is keyed by the pool's own tick spacing: a pool registered only under a
    ///      different spacing is not trusted.
    function test_Constructor_RevertsWhenPoolRegisteredUnderOtherTickSpacing() public {
        MockAeroCLPool pool2 = new MockAeroCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        aeroFactory.setPool(address(weth), address(pairedToken), OTHER_TICK_SPACING, address(pool2));
        IUniCLStrat.DeploymentConfig memory config = _aeroConfig();
        config.addresses.pool = address(pool2);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new AeroCLStrat(config);
    }

    /// @dev Why AeroCLStrat exists: UniCLStrat's 7-field `slot0` decode of a 6-word Slipstream
    ///      reply reverts (returndata too short), even when provenance passes. (The reverse is
    ///      benign — trailing returndata is ignored — so no symmetric test.)
    function test_UniCLStrat_RevertsWithSlipstreamLayoutPool() public {
        factory.setPool(address(weth), address(pairedToken), aeroPool.fee(), address(aeroPool));
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.addresses.pool = address(aeroPool);

        vm.expectRevert();
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWhenPoolCannotServeTwapInterval() public {
        aeroPool.setMaxObserveSecondsAgo(TWAP_INTERVAL - 1);

        vm.expectRevert(IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector);
        new AeroCLStrat(_aeroConfig());
    }

    /// @dev Proves the 6-field decode reads the in-use cardinality field.
    function test_Constructor_RevertsWhenObservationCardinalityBelowMinimum() public {
        uint16 required = aeroStrategy.MIN_OBSERVATION_CARDINALITY();
        aeroPool.setObservationCardinality(required - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUniCLStrat.UniCLStratInsufficientObservationCardinality.selector, required - 1, required
            )
        );
        new AeroCLStrat(_aeroConfig());
    }

    function test_Constructor_SucceedsAtMinimumObservationCardinality() public {
        aeroPool.setObservationCardinality(aeroStrategy.MIN_OBSERVATION_CARDINALITY());

        AeroCLStrat deployed = new AeroCLStrat(_aeroConfig());

        assertEq(address(deployed.pool()), address(aeroPool));
    }

    function test_Constructor_RevertsWhenTwapIntervalExceedsMax() public {
        IUniCLStrat.DeploymentConfig memory config = _aeroConfig();
        config.strategy.twapInterval = aeroStrategy.MAX_TWAP_INTERVAL() + 1;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new AeroCLStrat(config);
    }

    // ============ TWAP setters (cardinality gate) ============

    function test_SetTwapInterval_RevertsWhenCardinalityCannotCoverWindow() public {
        aeroPool.setObservationCardinality(CARDINALITY_BELOW_UPDATED_WINDOW);
        uint16 required = uint16(UPDATED_TWAP_INTERVAL / aeroStrategy.MAX_BLOCK_SECONDS());

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniCLStrat.UniCLStratInsufficientObservationCardinality.selector,
                CARDINALITY_BELOW_UPDATED_WINDOW,
                required
            )
        );
        aeroStrategy.setTwapInterval(UPDATED_TWAP_INTERVAL);
    }

    function test_SetTwapInterval_UpdatesWhenCardinalityCoversWindow() public {
        vm.prank(admin);
        aeroStrategy.setTwapInterval(UPDATED_TWAP_INTERVAL);

        assertEq(aeroStrategy.twapInterval(), UPDATED_TWAP_INTERVAL);
    }

    function test_SetShortTwapInterval_RevertsWhenPoolCannotServeWindow() public {
        aeroPool.setObservationCardinality(type(uint16).max);
        aeroPool.setMaxObserveSecondsAgo(TWAP_INTERVAL);

        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector);
        aeroStrategy.setShortTwapInterval(TWAP_INTERVAL + 1);
    }

    // ============ Strategy actions through the Slipstream slot0 path ============

    function test_Deposit_MintsLiquidityIntoAeroPool() public {
        _aeroDeposit(DEPOSIT_AMOUNT);

        (uint128 liquidity,,,,) = aeroPool.positions(_mainPositionKey());
        assertGt(liquidity, 0);
        assertTrue(aeroStrategy.initTicks());
        assertEq(aeroStrategy.totalDeposited(), DEPOSIT_AMOUNT);
        assertApproxEqRel(aeroStrategy.navInETH(), DEPOSIT_AMOUNT, WITHDRAW_NAV_REL_TOLERANCE);
        assertTrue(aeroStrategy.isHealthy());
    }

    function test_Deposit_RevertsWhenPoolIsNotCalm() public {
        aeroPool.setCurrentTickWithoutTwap(NOT_CALM_TICK);
        vm.deal(strategyManager, DEPOSIT_AMOUNT);

        assertEq(aeroStrategy.maxDeposit(), 0);
        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratNotCalm.selector);
        aeroStrategy.deposit{value: DEPOSIT_AMOUNT}();
    }

    function test_MaxDeposit_ReturnsRemainingCapacity() public {
        _aeroDeposit(DEPOSIT_AMOUNT);

        assertEq(aeroStrategy.maxDeposit(), MAX_TOTAL_NAV - aeroStrategy.navInETH());
    }

    function test_NavInETH_UsesTwapForPoolBalances() public {
        _aeroDeposit(DEPOSIT_AMOUNT);
        uint256 navBeforeSpotMove = aeroStrategy.navInETH();

        aeroPool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        assertApproxEqAbs(aeroStrategy.navInETH(), navBeforeSpotMove, 10 wei);
    }

    function test_IsHealthy_FalseWhenSpotDriftsOutsideThreshold() public {
        _aeroDeposit(DEPOSIT_AMOUNT);

        aeroPool.setCurrentTick(UNHEALTHY_TICK);

        assertFalse(aeroStrategy.isHealthy());
    }

    function test_Rebalance_RecentersAroundCurrentTick() public {
        _aeroDeposit(DEPOSIT_AMOUNT);
        aeroPool.setCurrentTick(UNHEALTHY_TICK);

        vm.prank(strategyManager);
        aeroStrategy.rebalance();

        assertTrue(aeroStrategy.isHealthy());
        (int24 tickLower, int24 tickUpper) = aeroStrategy.positionMain();
        assertLt(tickLower, UNHEALTHY_TICK);
        assertGt(tickUpper, UNHEALTHY_TICK);
    }

    function test_Rebalance_RevertsWhenHealthy() public {
        _aeroDeposit(DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyIsHealthy.selector);
        aeroStrategy.rebalance();
    }

    function test_Withdraw_SendsETHWhenPoolIsNotCalm() public {
        _aeroDeposit(DEPOSIT_AMOUNT);
        uint256 navBefore = aeroStrategy.navInETH();
        aeroPool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        vm.prank(strategyManager);
        uint256 withdrawn = aeroStrategy.withdraw(receiver, WITHDRAW_AMOUNT);

        assertEq(withdrawn, WITHDRAW_AMOUNT);
        assertEq(receiver.balance, WITHDRAW_AMOUNT);
        assertApproxEqRel(aeroStrategy.navInETH(), navBefore - WITHDRAW_AMOUNT, WITHDRAW_NAV_REL_TOLERANCE);
    }

    function test_Sync_PokesAccruedFeesIntoPendingPerformanceFee() public {
        _aeroDeposit(DEPOSIT_AMOUNT);
        (int24 tickLower, int24 tickUpper) = aeroStrategy.positionMain();
        aeroPool.accrueFees(
            address(aeroStrategy), tickLower, tickUpper, uint128(ACCRUED_FEE_WETH), uint128(ACCRUED_FEE_PAIRED)
        );
        uint256 navBefore = aeroStrategy.navInETH();

        vm.prank(strategyManager);
        aeroStrategy.sync();

        assertGt(aeroStrategy.navInETH(), navBefore);
        assertGt(aeroStrategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    function test_EmergencyExit_SweepsHoldingsAfterPause() public {
        _aeroDeposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        aeroStrategy.pause();
        (uint128 liquidity,,,,) = aeroPool.positions(_mainPositionKey());
        assertEq(liquidity, 0, "pause should unwind the Aero position");

        uint256 pairedBefore = pairedToken.balanceOf(address(aeroStrategy));
        uint256 expectedEth = weth.balanceOf(address(aeroStrategy)) + address(aeroStrategy).balance;

        vm.prank(admin);
        aeroStrategy.emergencyExit();

        assertEq(strategyManager.balance, expectedEth);
        assertEq(pairedToken.balanceOf(strategyManager), pairedBefore);
        assertEq(aeroStrategy.navInETH(), 0);
    }

    // ============ Helpers ============

    function _aeroConfig() internal view returns (IUniCLStrat.DeploymentConfig memory config) {
        config = _defaultConfig();
        config.addresses.pool = address(aeroPool);
        config.addresses.factory = address(aeroFactory);
    }

    function _aeroDeposit(uint256 _amount) internal {
        vm.deal(strategyManager, _amount);
        vm.prank(strategyManager);
        aeroStrategy.deposit{value: _amount}();
    }

    function _mainPositionKey() internal view returns (bytes32) {
        (int24 tickLower, int24 tickUpper) = aeroStrategy.positionMain();
        return keccak256(abi.encodePacked(address(aeroStrategy), tickLower, tickUpper));
    }
}
