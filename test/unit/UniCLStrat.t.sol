// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
// solhint-disable gas-small-strings
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {IConverter} from "../../src/interfaces/IConverter.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {UniCLStratTestBase} from "../helpers/UniCLStratTestBase.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockConverterAdapter} from "../mocks/MockConverterAdapter.sol";
import {MockUniCLPool} from "../mocks/UniCLStratMocks.sol";

contract RejectingTreasury {
    receive() external payable {
        revert("REJECT_ETH");
    }
}

contract UniCLStratTest is UniCLStratTestBase {
    uint256 public constant EXCESS_DEPOSIT_AMOUNT = MAX_TOTAL_NAV + 1 ether;
    uint256 public constant EXCESS_WITHDRAW_AMOUNT = DEPOSIT_AMOUNT + 1 ether;
    uint256 public constant PERFORMANCE_PROFIT = 1 ether;
    uint256 public constant LARGE_PERFORMANCE_PROFIT = 200 ether;
    uint256 public constant NAV_BALANCE_AMOUNT = 2 ether;
    uint256 public constant PERFORMANCE_FEE_NAV_REL_TOLERANCE = 1e16; // 1%
    uint256 public constant EXCESS_PERFORMANCE_FEE_BPS = 2_001;
    uint256 public constant EXCESS_SWAP_SLIPPAGE_BPS = 501;
    uint256 public constant NAV_TOLERANCE = 10 wei;
    uint256 public constant UPDATED_MAX_TOTAL_NAV = 200 ether;
    uint256 public constant UPDATED_SWAP_SLIPPAGE_BPS = 150;
    int56 public constant UPDATED_MAX_TICK_DEVIATION = 20;
    int24 public constant UPDATED_POSITION_WIDTH = 3;
    int24 public constant UPDATED_REBALANCE_TICK_THRESHOLD = 60;
    int24 public constant OUT_OF_RANGE_TICK = 180;
    uint32 public constant UPDATED_TWAP_INTERVAL = 3600;
    uint32 public constant UPDATED_SHORT_TWAP_INTERVAL = 120;
    uint32 public constant INVALID_TWAP_INTERVAL = 1799; // MIN_TWAP_INTERVAL - 1
    uint32 public constant INVALID_SHORT_TWAP_INTERVAL = 59; // MIN_SHORT_TWAP_INTERVAL - 1
    uint256 public constant ACCRUED_FEE_WETH = 0.1 ether;
    uint256 public constant ACCRUED_FEE_PAIRED = 0.05 ether;
    uint256 public constant IDLE_ETH_DONATION = 3 ether;

    function test_Constructor_SetsInitialState() public view {
        assertEq(strategy.name(), "Uniswap Concentrated Liquidity Strategy");
        assertEq(strategy.version(), "1.0.0");
        assertEq(strategy.genesisTimestamp(), INITIAL_TIMESTAMP);
        assertEq(address(strategy.weth()), address(weth));
        assertEq(address(strategy.pairedToken()), address(pairedToken));
        assertEq(address(strategy.pool()), address(pool));
        assertEq(address(strategy.factory()), address(factory));
        assertEq(address(strategy.swapAdapter()), address(swapAdapter));
        assertEq(strategy.swapSlippageBps(), strategy.DEFAULT_SWAP_SLIPPAGE_BPS());
        assertEq(registry.getContractByKey(Auth.ORACLE), address(oracle));
        assertEq(registry.getContractByKey(Auth.CONVERTER), address(converter));
        assertEq(strategy.tickSpacing(), TICK_SPACING);
        assertEq(strategy.positionWidth(), POSITION_WIDTH);
        assertEq(strategy.rebalanceTickThreshold(), REBALANCE_TICK_THRESHOLD);
        assertEq(strategy.maxTickDeviation(), MAX_TICK_DEVIATION);
        assertEq(strategy.twapInterval(), TWAP_INTERVAL);
        assertEq(strategy.shortTwapInterval(), SHORT_TWAP_INTERVAL);
        assertEq(strategy.MIN_OBSERVATION_CARDINALITY() * strategy.MAX_BLOCK_SECONDS(), strategy.MIN_TWAP_INTERVAL());
        assertEq(strategy.MAX_TWAP_INTERVAL(), uint32(type(uint16).max) * strategy.MAX_BLOCK_SECONDS());
        assertEq(strategy.maxTotalNAV(), MAX_TOTAL_NAV);
        assertEq(strategy.totalDeposited(), 0);
        assertEq(strategy.totalWithdrawn(), 0);
        assertEq(strategy.navInETH(), 0);
        assertFalse(strategy.initTicks());
        assertEq(address(strategy.registry()), address(registry));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, admin));
        assertEq(registry.getContractByKey(Auth.STRATEGY_MANAGER), strategyManager);
    }

    function test_Constructor_RevertsWithZeroRegistry() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.addresses.registry = address(0);

        vm.expectRevert(IRegistryClient.RegistryClientZeroRegistry.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWithZeroFactory() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.addresses.factory = address(0);

        vm.expectRevert(IUniCLStrat.UniCLStratZeroAddress.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWithInvalidPool() public {
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER", PAIRED_TOKEN_DECIMALS);
        MockUniCLPool invalidPool =
            new MockUniCLPool(address(otherToken), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.addresses.pool = address(invalidPool);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWhenPoolNotRegisteredInFactory() public {
        MockUniCLPool unregisteredPool =
            new MockUniCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.addresses.pool = address(unregisteredPool);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWhenFactoryReturnsDifferentPool() public {
        MockUniCLPool otherPool = new MockUniCLPool(address(weth), address(pairedToken), TICK_SPACING, INITIAL_TICK);
        // Rebind the fee tier to a different pool address so provenance fails.
        factory.setPool(address(weth), address(pairedToken), pool.fee(), address(otherPool));

        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWithInvalidConfig() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.positionWidth = 0;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWithInvalidRebalanceTickThreshold() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.rebalanceTickThreshold = 0;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWithInvalidMaxTickDeviation() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.maxTickDeviation = 0;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWithInvalidTwapInterval() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.twapInterval = INVALID_TWAP_INTERVAL;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWithInvalidShortTwapInterval() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.shortTwapInterval = INVALID_SHORT_TWAP_INTERVAL;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWhenTwapIntervalExceedsMax() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.twapInterval = strategy.MAX_TWAP_INTERVAL() + 1;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWhenShortTwapIntervalExceedsMax() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.shortTwapInterval = strategy.MAX_TWAP_INTERVAL() + 1;

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWhenPoolCannotServeTwapInterval() public {
        pool.setMaxObserveSecondsAgo(TWAP_INTERVAL - 1);

        vm.expectRevert(IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector);
        new UniCLStrat(_defaultConfig());
    }

    function test_Constructor_RevertsWhenPoolCannotServeShortTwapInterval() public {
        // Long window still fits; short is raised above the mock's lookback cap.
        pool.setMaxObserveSecondsAgo(TWAP_INTERVAL);
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.strategy.shortTwapInterval = TWAP_INTERVAL + 1;

        vm.expectRevert(IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector);
        new UniCLStrat(config);
    }

    function test_Constructor_RevertsWhenObservationCardinalityBelowMinimum() public {
        uint16 required = strategy.MIN_OBSERVATION_CARDINALITY();
        pool.setObservationCardinality(required - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUniCLStrat.UniCLStratInsufficientObservationCardinality.selector, required - 1, required
            )
        );
        new UniCLStrat(_defaultConfig());
    }

    function test_Constructor_RevertsWithInvalidRouteConfig() public {
        IUniCLStrat.DeploymentConfig memory config = _defaultConfig();
        config.routes.wethToPairedTokenPath = abi.encodePacked(address(pairedToken), uint24(500), address(weth));

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidRouteConfig.selector);
        new UniCLStrat(config);
    }

    function test_NavInETH_IncludesNativeETH() public {
        vm.deal(address(strategy), NAV_BALANCE_AMOUNT);

        assertEq(strategy.navInETH(), NAV_BALANCE_AMOUNT);
    }

    function test_Receive_AcceptsNativeETHAndIncreasesNAV() public {
        vm.deal(user, NAV_BALANCE_AMOUNT);

        vm.prank(user);
        (bool success,) = address(strategy).call{value: NAV_BALANCE_AMOUNT}("");

        assertTrue(success);
        assertEq(address(strategy).balance, NAV_BALANCE_AMOUNT);
        assertEq(strategy.navInETH(), NAV_BALANCE_AMOUNT);
    }

    function test_NavInETH_IncludesWETH() public {
        weth.mint(address(strategy), NAV_BALANCE_AMOUNT);

        assertEq(strategy.navInETH(), NAV_BALANCE_AMOUNT);
    }

    function test_NavInETH_IncludesPairedToken() public {
        pairedToken.mint(address(strategy), NAV_BALANCE_AMOUNT);

        assertEq(strategy.navInETH(), NAV_BALANCE_AMOUNT);
    }

    function test_NavInETH_UsesTwapForPoolBalances() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 navBeforeSpotMove = strategy.navInETH();

        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        assertApproxEqAbs(strategy.navInETH(), navBeforeSpotMove, NAV_TOLERANCE);
    }

    function test_Deposit_SucceedsWhenSpotDivergesFromTwapWithinCalmBand() public {
        pool.setCurrentTick(INITIAL_TICK);
        pool.setCurrentTickWithoutTwap(INITIAL_TICK + 1);

        _deposit(DEPOSIT_AMOUNT);

        assertGt(strategy.navInETH(), 0);
        assertTrue(strategy.isHealthy());
    }

    function test_Rebalance_SucceedsWhenSpotDivergesFromTwapWithinCalmBand() public {
        _deposit(DEPOSIT_AMOUNT);
        pool.setCurrentTick(UNHEALTHY_TICK);
        assertFalse(strategy.isHealthy());
        pool.setCurrentTickWithoutTwap(UNHEALTHY_TICK + 1);

        vm.prank(strategyManager);
        strategy.rebalance();

        assertTrue(strategy.isHealthy());
    }

    function test_MaxDeposit_ReturnsRemainingCapacity() public {
        _deposit(DEPOSIT_AMOUNT);

        assertEq(strategy.maxDeposit(), MAX_TOTAL_NAV - strategy.navInETH());
    }

    function test_MaxDeposit_ReturnsZeroWhenPoolIsNotCalm() public {
        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        assertEq(strategy.maxDeposit(), 0);
    }

    function test_MaxDeposit_ReturnsZeroWhenPaused() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        assertEq(strategy.maxDeposit(), 0);
    }

    function test_MaxWithdrawal_ReturnsNAV() public {
        _deposit(DEPOSIT_AMOUNT);

        assertEq(strategy.maxWithdrawal(), strategy.navInETH());
    }

    function test_MaxWithdrawal_ReturnsZeroWhenPaused() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        assertEq(strategy.maxWithdrawal(), 0);
    }

    function test_IsHealthy_ReturnsTrueBeforeTicksAreInitialized() public view {
        assertTrue(strategy.isHealthy());
    }

    function test_IsHealthy_ReturnsFalseWhenPoolIsNotCalm() public {
        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        assertFalse(strategy.isHealthy());
    }

    function test_IsHealthy_ReturnsFalseWhenShortTwapObservationIsUnavailable() public {
        pool.setObserveShouldRevert(true);

        assertFalse(strategy.isHealthy());
        assertEq(strategy.maxDeposit(), 0);
    }

    function test_IsHealthy_ReturnsFalseWhenCurrentTickIsOutsideMainPosition() public {
        _deposit(DEPOSIT_AMOUNT);
        pool.setCurrentTick(OUT_OF_RANGE_TICK);

        assertFalse(strategy.isHealthy());
    }

    function test_IsHealthy_ReturnsFalseWhenCurrentTickExceedsRebalanceThreshold() public {
        _deposit(DEPOSIT_AMOUNT);
        pool.setCurrentTick(UNHEALTHY_TICK);

        assertFalse(strategy.isHealthy());
    }

    function test_Deposit() public {
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.FundsDeposited(DEPOSIT_AMOUNT);

        _deposit(DEPOSIT_AMOUNT);

        assertEq(strategy.totalDeposited(), DEPOSIT_AMOUNT);
        assertTrue(strategy.initTicks());
        assertTrue(strategy.isHealthy());
        assertLe(strategy.navInETH(), DEPOSIT_AMOUNT);
        assertApproxEqAbs(strategy.navInETH(), DEPOSIT_AMOUNT, NAV_TOLERANCE);
        assertEq(address(strategy).balance, 0);
        assertLe(weth.balanceOf(address(strategy)), NAV_TOLERANCE);
        assertLe(pairedToken.balanceOf(address(strategy)), NAV_TOLERANCE);

        IUniCLStrat.Position memory mainPosition = _mainPosition();
        assertEq(mainPosition.tickLower, -POSITION_WIDTH * TICK_SPACING);
        assertEq(mainPosition.tickUpper, POSITION_WIDTH * TICK_SPACING);
    }

    function test_InvestIdleETH() public {
        _donate(DEPOSIT_AMOUNT);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.FundsInvested(DEPOSIT_AMOUNT);
        vm.prank(admin);
        uint256 invested = strategy.investIdleETH();

        assertEq(invested, DEPOSIT_AMOUNT);
        assertEq(address(strategy).balance, 0);
        assertTrue(strategy.initTicks());
        assertTrue(strategy.isHealthy());
        assertApproxEqAbs(strategy.navInETH(), DEPOSIT_AMOUNT, NAV_TOLERANCE);

        IUniCLStrat.Position memory mainPosition = _mainPosition();
        assertEq(mainPosition.tickLower, -POSITION_WIDTH * TICK_SPACING);
        assertEq(mainPosition.tickUpper, POSITION_WIDTH * TICK_SPACING);
    }

    function test_InvestIdleETH_CapsAtMaxDeposit() public {
        // Idle ETH already counts in NAV, so the remaining capacity is maxTotalNAV - idle.
        // When idle exceeds that capacity, only the capacity is deployed; the rest stays native.
        uint256 idle = 60 ether;
        uint256 expectedInvested = MAX_TOTAL_NAV - idle; // 40 ether
        _donate(idle);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.FundsInvested(expectedInvested);
        vm.prank(admin);
        uint256 invested = strategy.investIdleETH();

        assertEq(invested, expectedInvested);
        // Idle ETH beyond the cap remains as native ETH (still counted in NAV).
        assertEq(address(strategy).balance, idle - expectedInvested);
        assertApproxEqAbs(strategy.navInETH(), idle, NAV_TOLERANCE);
    }

    function test_InvestIdleETH_RevertsWhenPoolIsNotCalm() public {
        _donate(DEPOSIT_AMOUNT);
        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratNotCalm.selector);
        strategy.investIdleETH();
    }

    function test_InvestIdleETH_RevertsWhenCallerLacksRole() public {
        _donate(DEPOSIT_AMOUNT);

        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(user);
        strategy.investIdleETH();
    }

    function test_InvestIdleETH_RevertsWhenPaused() public {
        _donate(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        vm.prank(admin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        strategy.investIdleETH();
    }

    function test_InvestIdleETH_ReturnsZeroWhenNoIdleETH() public {
        vm.recordLogs();
        vm.prank(admin);
        uint256 invested = strategy.investIdleETH();

        assertEq(invested, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(strategy.initTicks());
    }

    function test_InvestIdleETH_DeploysDonation() public {
        // investIdleETH() deploys idle native ETH and keeps it NAV-neutral.
        _deposit(DEPOSIT_AMOUNT);
        _donate(NAV_BALANCE_AMOUNT);

        vm.prank(admin);
        uint256 invested = strategy.investIdleETH();

        assertEq(invested, NAV_BALANCE_AMOUNT);
        assertEq(address(strategy).balance, 0);
        assertApproxEqAbs(strategy.navInETH(), DEPOSIT_AMOUNT + NAV_BALANCE_AMOUNT, NAV_TOLERANCE);
    }

    function test_DonationRemainsIdleUntilInvest() public {
        _donate(DEPOSIT_AMOUNT);

        assertEq(address(strategy).balance, DEPOSIT_AMOUNT);
        assertFalse(strategy.initTicks());

        vm.prank(admin);
        strategy.investIdleETH();

        assertEq(address(strategy).balance, 0);
        assertTrue(strategy.initTicks());
    }

    function test_Deposit_RevertsWhenCallerLacksRole() public {
        vm.deal(user, DEPOSIT_AMOUNT);

        _expectInvalidCaller(Auth.STRATEGY_MANAGER);
        vm.prank(user);
        strategy.deposit{value: DEPOSIT_AMOUNT}();
    }

    function test_Deposit_RevertsWithZeroAmount() public {
        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyZeroDeposit.selector);
        strategy.deposit();
    }

    function test_Deposit_RevertsWhenAmountExceedsMaxDeposit() public {
        vm.deal(strategyManager, EXCESS_DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyMaxDepositExceeded.selector);
        strategy.deposit{value: EXCESS_DEPOSIT_AMOUNT}();
    }

    function test_Deposit_AllowsFullHeadroom() public {
        // Regression: comparing msg.value against _maxDeposit() double-counted in-flight
        // ETH (already in navInETH via address(this).balance) and rejected D > H/2.
        _deposit(MAX_TOTAL_NAV);

        assertEq(strategy.totalDeposited(), MAX_TOTAL_NAV);
        assertApproxEqAbs(strategy.navInETH(), MAX_TOTAL_NAV, NAV_TOLERANCE);
    }

    function test_Deposit_AllowsRemainingHeadroom() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 headroom = strategy.maxDeposit();
        assertGt(headroom, 0);

        _deposit(headroom);

        assertEq(strategy.totalDeposited(), DEPOSIT_AMOUNT + headroom);
        assertEq(strategy.maxDeposit(), 0);
    }

    function test_Deposit_RevertsWhenPoolIsNotCalm() public {
        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);
        vm.deal(strategyManager, DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratNotCalm.selector);
        strategy.deposit{value: DEPOSIT_AMOUNT}();
    }

    function test_Deposit_RevertsWhenQuoteFails() public {
        converter.setQuoteShouldRevert(true);
        vm.deal(strategyManager, DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratQuoteFailed.selector);
        strategy.deposit{value: DEPOSIT_AMOUNT}();
    }

    function test_Withdraw() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 navBeforeWithdrawal = strategy.navInETH();

        vm.prank(strategyManager);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.FundsWithdrawn(WITHDRAW_AMOUNT);
        strategy.withdraw(receiver, WITHDRAW_AMOUNT);

        assertEq(receiver.balance, WITHDRAW_AMOUNT);
        assertEq(strategy.totalWithdrawn(), WITHDRAW_AMOUNT);
        assertTrue(strategy.isHealthy());
        assertApproxEqAbs(strategy.navInETH(), navBeforeWithdrawal - WITHDRAW_AMOUNT, NAV_TOLERANCE);
    }

    function test_Withdraw_UsesExactOutputSwapForMissingWeth() public {
        _deposit(DEPOSIT_AMOUNT);

        // After removing liquidity the strategy holds ~50/50 WETH/paired (~5/5 ETH).
        // Withdrawing 6 ETH leaves ~1 ETH of WETH missing — affordable within the
        // slippage-padded paired balance, so the exact-output path is taken.
        uint256 withdrawAmount = 6 ether;

        vm.prank(strategyManager);
        strategy.withdraw(receiver, withdrawAmount);

        assertEq(converter.lastExecuteSwapExactAmountOutCall(), 1);
        assertEq(receiver.balance, withdrawAmount);
        assertEq(strategy.totalWithdrawn(), withdrawAmount);
    }

    function test_Withdraw_FallsBackToExactInputWhenPairedBalanceInsufficient() public {
        _deposit(DEPOSIT_AMOUNT);

        // Withdrawing the full NAV needs ~5 ETH of WETH topped up, but the
        // slippage-padded exact-output maximum exceeds the ~5 ETH paired balance,
        // so the strategy falls back to a best-effort exact-input swap of the
        // whole paired balance (no exact-output call is made).
        uint256 withdrawAmount = strategy.navInETH();

        vm.prank(strategyManager);
        strategy.withdraw(receiver, withdrawAmount);

        assertEq(converter.lastExecuteSwapExactAmountOutCall(), 0);
        assertApproxEqAbs(receiver.balance, withdrawAmount, NAV_TOLERANCE);
        assertApproxEqAbs(strategy.navInETH(), 0, NAV_TOLERANCE);
    }

    function test_Withdraw_FulfilledEntirelyFromIdleNativeETH() public {
        // Idle native ETH is counted in navInETH() / maxWithdrawal(), so withdraw()
        // must be able to deliver it even with no LP position or WETH.
        _donate(IDLE_ETH_DONATION);
        assertEq(strategy.maxWithdrawal(), IDLE_ETH_DONATION);

        vm.prank(strategyManager);
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.FundsWithdrawn(IDLE_ETH_DONATION);
        uint256 withdrawn = strategy.withdraw(receiver, IDLE_ETH_DONATION);

        assertEq(withdrawn, IDLE_ETH_DONATION);
        assertEq(receiver.balance, IDLE_ETH_DONATION);
        assertEq(address(strategy).balance, 0);
        assertEq(strategy.totalWithdrawn(), IDLE_ETH_DONATION);
        assertEq(strategy.navInETH(), 0);
    }

    function test_Withdraw_SendsIdleETHDirectlyWithoutWrappingWhenItCoversRequest() public {
        // When idle native ETH covers the requested amount, the payout is sent straight
        // from the native balance: no wrap/unwrap round-trip through the Converter, no
        // swaps, and the LP position stays untouched.
        _deposit(DEPOSIT_AMOUNT);
        _donate(IDLE_ETH_DONATION);

        uint256 withdrawAmount = IDLE_ETH_DONATION - 1 ether;
        uint256 wethBalanceBefore = weth.balanceOf(address(strategy));
        uint256 pairedBalanceBefore = pairedToken.balanceOf(address(strategy));

        vm.expectCall(address(converter), abi.encodeWithSelector(IConverter.wrapETH.selector), 0);
        vm.expectCall(address(converter), abi.encodeWithSelector(IConverter.unwrapWETH.selector), 0);
        vm.expectCall(address(converter), abi.encodeWithSelector(IConverter.executeSwapExactAmountIn.selector), 0);
        vm.expectCall(address(converter), abi.encodeWithSelector(IConverter.executeSwapExactAmountOut.selector), 0);
        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, withdrawAmount);

        assertEq(withdrawn, withdrawAmount);
        assertEq(receiver.balance, withdrawAmount);
        assertEq(address(strategy).balance, IDLE_ETH_DONATION - withdrawAmount);
        assertEq(weth.balanceOf(address(strategy)), wethBalanceBefore);
        assertEq(pairedToken.balanceOf(address(strategy)), pairedBalanceBefore);
        assertEq(strategy.totalWithdrawn(), withdrawAmount);
        assertTrue(strategy.isHealthy());
        assertApproxEqAbs(strategy.navInETH(), DEPOSIT_AMOUNT + IDLE_ETH_DONATION - withdrawAmount, NAV_TOLERANCE);
    }

    function test_Withdraw_UsesIdleNativeETHForFullNAVWithdrawal() public {
        // Withdrawing the full maxWithdrawal() (which includes an idle native ETH
        // donation) must deliver the promised amount: the idle ETH is paid out natively
        // and only the rest is sourced from the LP position and paired-token swaps.
        _deposit(DEPOSIT_AMOUNT);
        _donate(IDLE_ETH_DONATION);

        uint256 withdrawAmount = strategy.maxWithdrawal();
        assertApproxEqAbs(withdrawAmount, DEPOSIT_AMOUNT + IDLE_ETH_DONATION, NAV_TOLERANCE);

        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, withdrawAmount);

        assertApproxEqAbs(withdrawn, withdrawAmount, NAV_TOLERANCE);
        assertApproxEqAbs(receiver.balance, withdrawAmount, NAV_TOLERANCE);
        assertApproxEqAbs(strategy.navInETH(), 0, NAV_TOLERANCE);
    }

    function test_Withdraw_UnwrapsOnlyRemainderWhenIdleETHFallsShort() public {
        // Idle ETH (3) falls short of the request (6): all idle ETH goes toward the
        // payout natively and only the 3 ETH remainder is unwrapped from the WETH
        // collected by removing liquidity (~5/5 WETH/paired) — no wrapping and no
        // fee-incurring exact-output swap.
        _deposit(DEPOSIT_AMOUNT);
        _donate(IDLE_ETH_DONATION);

        uint256 withdrawAmount = IDLE_ETH_DONATION + 3 ether;

        vm.expectCall(address(converter), abi.encodeWithSelector(IConverter.wrapETH.selector), 0);
        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, withdrawAmount);

        assertEq(converter.lastExecuteSwapExactAmountOutCall(), 0);
        assertEq(withdrawn, withdrawAmount);
        assertEq(receiver.balance, withdrawAmount);
        // All idle native ETH was consumed by the payout
        assertEq(address(strategy).balance, 0);
        assertApproxEqAbs(strategy.navInETH(), DEPOSIT_AMOUNT + IDLE_ETH_DONATION - withdrawAmount, NAV_TOLERANCE);
    }

    function test_Withdraw_RevertsWhenExactOutputQuoteFails() public {
        _deposit(DEPOSIT_AMOUNT);
        converter.setQuoteShouldRevert(true);

        // 6 ETH requires a paired -> WETH top-up, whose exact-output quote now reverts
        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratQuoteFailed.selector);
        strategy.withdraw(receiver, 6 ether);
    }

    function test_Withdraw_RevertsWhenExactOutputQuoteExceedsOracleCeiling() public {
        _deposit(DEPOSIT_AMOUNT);

        // 80% multiplier inflates the exact-output quote (requires 1.25x input),
        // breaching the +2% oracle ceiling on the required input.
        converter.setQuoteMultiplierBps(8_000);

        vm.prank(strategyManager);
        vm.expectPartialRevert(IUniCLStrat.UniCLStratQuoteExceedsOracleCeiling.selector);
        strategy.withdraw(receiver, 6 ether);
    }

    function test_Withdraw_RevertsWhenExactOutputQuoteBelowOracleFloor() public {
        _deposit(DEPOSIT_AMOUNT);

        // 120% multiplier deflates the exact-output quote (requires ~0.83x input),
        // breaching the -2% oracle floor on the required input.
        converter.setQuoteMultiplierBps(12_000);

        vm.prank(strategyManager);
        vm.expectPartialRevert(IUniCLStrat.UniCLStratQuoteBelowOracleFloor.selector);
        strategy.withdraw(receiver, 6 ether);
    }

    function test_Withdraw_RevertsWithZeroReceiver() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratZeroAddress.selector);
        strategy.withdraw(address(0), WITHDRAW_AMOUNT);
    }

    function test_Withdraw_RevertsWithZeroAmount() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyZeroWithdrawal.selector);
        strategy.withdraw(receiver, 0);
    }

    function test_Withdraw_RevertsWhenAmountExceedsNAV() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyMaxWithdrawalExceeded.selector);
        strategy.withdraw(receiver, EXCESS_WITHDRAW_AMOUNT);
    }

    function test_Withdraw_RevertsWhenCallerLacksRole() public {
        _deposit(DEPOSIT_AMOUNT);

        _expectInvalidCaller(Auth.STRATEGY_MANAGER);
        vm.prank(user);
        strategy.withdraw(receiver, WITHDRAW_AMOUNT);
    }

    function test_Withdraw_WhenPoolIsNotCalm() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 navBefore = strategy.navInETH();

        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);
        assertFalse(strategy.isHealthy());

        vm.prank(strategyManager);
        strategy.withdraw(receiver, WITHDRAW_AMOUNT);

        assertEq(receiver.balance, WITHDRAW_AMOUNT);
        assertApproxEqRel(strategy.navInETH(), navBefore - WITHDRAW_AMOUNT, PERFORMANCE_FEE_NAV_REL_TOLERANCE);
        assertFalse(strategy.isHealthy());
    }

    function test_Rebalance_RevertsWhenHealthy() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyIsHealthy.selector);
        strategy.rebalance();
    }

    function test_Rebalance_RevertsWhenPoolIsNotCalm() public {
        _deposit(DEPOSIT_AMOUNT);
        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratNotCalm.selector);
        strategy.rebalance();
    }

    function test_Rebalance_WhenUnhealthy() public {
        _deposit(DEPOSIT_AMOUNT);
        pool.setCurrentTick(UNHEALTHY_TICK);
        assertFalse(strategy.isHealthy());

        vm.prank(strategyManager);
        strategy.rebalance();

        assertTrue(strategy.isHealthy());
        IUniCLStrat.Position memory mainPosition = _mainPosition();
        assertLt(mainPosition.tickLower, UNHEALTHY_TICK);
        assertGt(mainPosition.tickUpper, UNHEALTHY_TICK);
    }

    function test_Rebalance_WhenUnhealthy_RestoresHealth() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.deal(address(strategy), PERFORMANCE_PROFIT);
        pool.setCurrentTick(UNHEALTHY_TICK);
        assertFalse(strategy.isHealthy());

        vm.prank(strategyManager);
        strategy.rebalance();

        assertTrue(strategy.isHealthy());
        IUniCLStrat.Position memory mainPosition = _mainPosition();
        assertLt(mainPosition.tickLower, UNHEALTHY_TICK);
        assertGt(mainPosition.tickUpper, UNHEALTHY_TICK);
    }

    function test_Rebalance_RevertsWhenCallerLacksRole() public {
        _expectInvalidCaller(Auth.STRATEGY_MANAGER);
        vm.prank(user);
        strategy.rebalance();
    }

    function test_Sync_PokesAccruedFeesIntoPosition() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        uint256 navBefore = strategy.navInETH();
        uint256 wethBefore = weth.balanceOf(address(strategy));
        uint256 pairedBefore = pairedToken.balanceOf(address(strategy));

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.Synced();

        vm.prank(strategyManager);
        strategy.sync();

        // Poke-only: NAV and pending update from tokensOwed; no durable counter flush needed.
        assertGt(strategy.navInETH(), navBefore);
        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
        assertEq(weth.balanceOf(address(strategy)), wethBefore);
        assertEq(pairedToken.balanceOf(address(strategy)), pairedBefore);
    }

    function test_Sync_PokesWhenPoolIsNotCalm() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(address(strategy), mainPosition.tickLower, mainPosition.tickUpper, uint128(ACCRUED_FEE_WETH), 0);
        pool.setCurrentTickWithoutTwap(NOT_CALM_TICK);

        uint256 navBefore = strategy.navInETH();

        vm.prank(strategyManager);
        strategy.sync();

        assertGt(strategy.navInETH(), navBefore);
    }

    function test_Withdraw_MaterializesAccruedFeesWithoutSync() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();
        bytes32 positionKey =
            keccak256(abi.encodePacked(address(strategy), mainPosition.tickLower, mainPosition.tickUpper));

        pool.accrueFees(address(strategy), mainPosition.tickLower, mainPosition.tickUpper, uint128(ACCRUED_FEE_WETH), 0);

        (,,, uint128 pendingOwed0, uint128 pendingOwed1) = pool.positionStates(positionKey);
        assertGt(pendingOwed0, 0);
        assertEq(pendingOwed1, 0);

        vm.prank(strategyManager);
        strategy.withdraw(receiver, WITHDRAW_AMOUNT);

        (,,, pendingOwed0, pendingOwed1) = pool.positionStates(positionKey);
        assertEq(pendingOwed0, 0);
        assertEq(pendingOwed1, 0);
        assertEq(receiver.balance, WITHDRAW_AMOUNT);
    }

    function test_Withdraw_AccruesPendingLpFeesWithoutSync() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        // Pending fee growth is not yet in tokensOwed, so the view reads zero until a poke.
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        strategy.withdraw(receiver, WITHDRAW_AMOUNT);

        // Remove path pokes before accruing so collected fees enter the performance-fee base.
        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    function test_SettlePerformanceFee_DoesNotPokeUnmaterializedFees() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        // Settle matches the pending view — neither includes unpoked fee growth.
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        strategy.sync();
        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    /// @dev L-4: feeBaseETH * bps / 10_000 == 0 must not advance charged counters, or the dust
    ///      becomes permanently unfeeable. At PERFORMANCE_FEE_BPS = 1000, feeETH floors to 0 for
    ///      any fee base < 10 wei.
    function test_SettlePerformanceFee_DoesNotChargeWhenFeeRoundsToZero() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        uint128 dustFeeWeth = 5; // feeBaseETH = 5 → feeETH = 5 * 1000 / 10000 = 0
        pool.accrueFees(address(strategy), mainPosition.tickLower, mainPosition.tickUpper, dustFeeWeth, 0);

        vm.prank(strategyManager);
        strategy.sync();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);

        // Another 5 wei of WETH fees: combined base = 10 → feeETH = 1 only if dust was preserved.
        pool.accrueFees(address(strategy), mainPosition.tickLower, mainPosition.tickUpper, dustFeeWeth, 0);

        vm.prank(strategyManager);
        strategy.sync();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 1);
        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 1);
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    function test_Sync_RevertsWhenPaused() public {
        vm.prank(admin);
        strategy.pause();

        vm.prank(strategyManager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        strategy.sync();
    }

    function test_Sync_RevertsWhenCallerLacksRole() public {
        _expectInvalidCaller(Auth.STRATEGY_MANAGER);
        vm.prank(user);
        strategy.sync();
    }

    function test_PendingPerformanceFeeInETH_AccruesOnNewLpFees() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    function test_PendingPerformanceFeeInETH_ReturnsZeroWhenPaused() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(admin);
        strategy.pause();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    function test_SettlePerformanceFee_ReturnsZeroWhenPaused() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        vm.prank(admin);
        strategy.pause();

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);

        vm.prank(admin);
        strategy.unpause();
        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    function test_PendingPerformanceFeeInETH_RestoredAfterUnpause() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        uint256 pendingBeforePause = strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS);
        assertGt(pendingBeforePause, 0);

        vm.prank(admin);
        strategy.pause();
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(admin);
        strategy.unpause();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), pendingBeforePause);
    }

    function test_LpFee_OracleReprice_DoesNotAccruePhantomFeeBase() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy), mainPosition.tickLower, mainPosition.tickUpper, 0, uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS);

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        address ethFeed = address(oracle.getUsdFeedInfo(address(0)).priceFeed);
        MockPriceFeed(ethFeed).setPrice(int256(TOKEN_PRICE / 2));

        vm.prank(strategyManager);
        strategy.sync();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);
    }

    function test_AdminConfigurationSetters() public {
        vm.startPrank(admin);
        strategy.setPositionWidth(UPDATED_POSITION_WIDTH);
        strategy.setRebalanceTickThreshold(UPDATED_REBALANCE_TICK_THRESHOLD);
        strategy.setMaxTickDeviation(UPDATED_MAX_TICK_DEVIATION);
        strategy.setTwapInterval(UPDATED_TWAP_INTERVAL);
        strategy.setShortTwapInterval(UPDATED_SHORT_TWAP_INTERVAL);
        strategy.setMaxTotalNAV(UPDATED_MAX_TOTAL_NAV);
        strategy.setSwapSlippageBps(UPDATED_SWAP_SLIPPAGE_BPS);
        vm.stopPrank();

        assertEq(strategy.positionWidth(), UPDATED_POSITION_WIDTH);
        assertEq(strategy.rebalanceTickThreshold(), UPDATED_REBALANCE_TICK_THRESHOLD);
        assertEq(strategy.maxTickDeviation(), UPDATED_MAX_TICK_DEVIATION);
        assertEq(strategy.twapInterval(), UPDATED_TWAP_INTERVAL);
        assertEq(strategy.shortTwapInterval(), UPDATED_SHORT_TWAP_INTERVAL);
        assertEq(strategy.maxTotalNAV(), UPDATED_MAX_TOTAL_NAV);
        assertEq(strategy.swapSlippageBps(), UPDATED_SWAP_SLIPPAGE_BPS);
    }

    function test_AdminConfigurationSetters_RevertWhenCallerLacksRole() public {
        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(user);
        strategy.setPositionWidth(UPDATED_POSITION_WIDTH);
    }

    function test_AdminConfigurationSetters_RevertWithInvalidConfig() public {
        vm.startPrank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        strategy.setPositionWidth(0);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        strategy.setTwapInterval(INVALID_TWAP_INTERVAL);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        strategy.setShortTwapInterval(INVALID_SHORT_TWAP_INTERVAL);

        // Hoist the getter: `vm.expectRevert` would otherwise be consumed by
        // `MAX_TWAP_INTERVAL()` itself, which does not revert.
        uint32 tooLong = strategy.MAX_TWAP_INTERVAL() + 1;
        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        strategy.setTwapInterval(tooLong);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        strategy.setShortTwapInterval(tooLong);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        strategy.setSwapSlippageBps(EXCESS_SWAP_SLIPPAGE_BPS);
        vm.stopPrank();
    }

    function test_SetTwapInterval_RevertsWhenPoolCannotServeNewWindow() public {
        pool.setMaxObserveSecondsAgo(TWAP_INTERVAL);

        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector);
        strategy.setTwapInterval(UPDATED_TWAP_INTERVAL);

        assertEq(strategy.twapInterval(), TWAP_INTERVAL);
    }

    function test_SetShortTwapInterval_RevertsWhenPoolCannotServeNewWindow() public {
        pool.setMaxObserveSecondsAgo(TWAP_INTERVAL);

        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector);
        strategy.setShortTwapInterval(TWAP_INTERVAL + 1);

        assertEq(strategy.shortTwapInterval(), SHORT_TWAP_INTERVAL);
    }

    function test_SetTwapInterval_RevertsWhenObservationCardinalityInsufficient() public {
        uint32 blockSeconds = strategy.MAX_BLOCK_SECONDS();
        uint16 required = uint16((uint256(UPDATED_TWAP_INTERVAL) + blockSeconds - 1) / blockSeconds);
        pool.setObservationCardinality(required - 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniCLStrat.UniCLStratInsufficientObservationCardinality.selector, required - 1, required
            )
        );
        strategy.setTwapInterval(UPDATED_TWAP_INTERVAL);

        assertEq(strategy.twapInterval(), TWAP_INTERVAL);
    }

    function test_Pause_SecurityCanPauseImmediately() public {
        address security = makeAddr("security");
        vm.prank(admin);
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        strategy.pause();

        assertTrue(strategy.paused());

        // Security cannot unpause — recovery stays with ADMIN_ROLE (timelocked in production)
        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(security);
        strategy.unpause();
    }

    function test_PauseAndUnpause() public {
        vm.prank(admin);
        strategy.pause();

        assertTrue(strategy.paused());
        assertFalse(strategy.isHealthy());
        assertEq(strategy.maxDeposit(), 0);

        vm.prank(admin);
        strategy.unpause();

        assertFalse(strategy.paused());
        assertTrue(strategy.isHealthy());
    }

    function test_Pause_RemovesLiquidityAndRevokesConverterAllowances() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        assertTrue(strategy.paused());
        // Pool liquidity was unwound and collected back onto the strategy
        assertGt(weth.balanceOf(address(strategy)) + pairedToken.balanceOf(address(strategy)), 0);
        // Converter allowances were revoked
        assertEq(weth.allowance(address(strategy), address(converter)), 0);
        assertEq(pairedToken.allowance(address(strategy), address(converter)), 0);
    }

    function test_Pause_SucceedsWhenPoolIsDegraded() public {
        _deposit(DEPOSIT_AMOUNT);

        pool.setPoolShouldRevert(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IUniCLStrat.LiquidityUnwindSkipped();
        vm.prank(admin);
        strategy.pause();

        assertTrue(strategy.paused());
        // The independent allowance revocation still executed
        assertEq(weth.allowance(address(strategy), address(converter)), 0);
        assertEq(pairedToken.allowance(address(strategy), address(converter)), 0);
    }

    function test_Pause_SecurityCanPauseWhenPoolIsDegraded() public {
        address security = makeAddr("security");
        vm.prank(admin);
        registry.grantRole(Auth.SECURITY_ROLE, security);

        _deposit(DEPOSIT_AMOUNT);

        pool.setPoolShouldRevert(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IUniCLStrat.LiquidityUnwindSkipped();
        vm.prank(security);
        strategy.pause();

        assertTrue(strategy.paused());
        // The allowance revocation still executed
        assertEq(weth.allowance(address(strategy), address(converter)), 0);
        assertEq(pairedToken.allowance(address(strategy), address(converter)), 0);
    }

    function test_SelfRemoveLiquidityAndCollect_RevertsWhenCallerIsNotSelf() public {
        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratCallerNotSelf.selector);
        strategy.selfRemoveLiquidityAndCollect();
    }

    function test_Pause_SucceedsWhenPairedTokenRejectsZeroApproval() public {
        _deposit(DEPOSIT_AMOUNT);

        uint256 _pairedAllowanceBefore = pairedToken.allowance(address(strategy), address(converter));
        assertGt(_pairedAllowanceBefore, 0);

        pairedToken.setRevertApprove(true);

        vm.expectEmit(true, false, false, true, address(strategy));
        emit IUniCLStrat.ConverterAllowanceRevocationSkipped(address(pairedToken));
        vm.prank(admin);
        strategy.pause();

        assertTrue(strategy.paused());
        // WETH revoke is strict and independent of the paired-token try/catch
        assertEq(weth.allowance(address(strategy), address(converter)), 0);
        assertEq(pairedToken.allowance(address(strategy), address(converter)), _pairedAllowanceBefore);
    }

    function test_Pause_RevertsWhenWethRejectsZeroApproval() public {
        _deposit(DEPOSIT_AMOUNT);

        weth.setRevertApprove(true);

        vm.prank(admin);
        vm.expectRevert();
        strategy.pause();

        assertFalse(strategy.paused());
    }

    function test_Pause_SkippedAllowanceRevocation_DoesNotBlockEmergencyExit() public {
        _deposit(DEPOSIT_AMOUNT);

        pairedToken.setRevertApprove(true);

        vm.prank(admin);
        strategy.pause();

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertGt(strategyManager.balance, 0);
    }

    function test_SelfRevokePairedTokenConverterAllowance_RevertsWhenCallerIsNotSelf() public {
        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratCallerNotSelf.selector);
        strategy.selfRevokePairedTokenConverterAllowance();
    }

    // ============ EmergencyExit ============

    function test_EmergencyExit_ClearsPendingLpFees() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(admin);
        strategy.pause();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);
    }

    function test_EmergencyExit() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        uint256 wethBefore = weth.balanceOf(address(strategy));
        uint256 pairedBefore = pairedToken.balanceOf(address(strategy));
        uint256 nativeEthBefore = address(strategy).balance;
        uint256 expectedEthToStrategyManager = wethBefore + nativeEthBefore;

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.EmergencyExited(expectedEthToStrategyManager);
        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(pairedToken.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertEq(strategyManager.balance, expectedEthToStrategyManager);
        assertEq(pairedToken.balanceOf(address(strategyManager)), pairedBefore);
        assertEq(strategy.navInETH(), 0);
    }

    /// @dev L-6: a reverting paired-token transfer must not hostage the WETH/ETH sweep.
    function test_EmergencyExit_SweepsETHWhenPairedTokenTransferReverts() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        uint256 wethBefore = weth.balanceOf(address(strategy));
        uint256 pairedBefore = pairedToken.balanceOf(address(strategy));
        uint256 nativeEthBefore = address(strategy).balance;
        uint256 expectedEthToStrategyManager = wethBefore + nativeEthBefore;
        assertGt(pairedBefore, 0);

        pairedToken.setRevertTransfer(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IUniCLStrat.PairedTokenTransferSkipped();
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.EmergencyExited(expectedEthToStrategyManager);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertEq(strategyManager.balance, expectedEthToStrategyManager);
        // Paired inventory stays on the strategy until the token is transferable again.
        assertEq(pairedToken.balanceOf(address(strategy)), pairedBefore);
        assertEq(pairedToken.balanceOf(address(strategyManager)), 0);

        pairedToken.setRevertTransfer(false);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(pairedToken.balanceOf(address(strategy)), 0);
        assertEq(pairedToken.balanceOf(address(strategyManager)), pairedBefore);
    }

    /// @dev A reverting paired-token `balanceOf` must not hostage the WETH/ETH sweep.
    function test_EmergencyExit_SweepsETHWhenPairedTokenBalanceOfReverts() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        uint256 wethBefore = weth.balanceOf(address(strategy));
        uint256 pairedBefore = pairedToken.balanceOf(address(strategy));
        uint256 nativeEthBefore = address(strategy).balance;
        uint256 expectedEthToStrategyManager = wethBefore + nativeEthBefore;
        assertGt(pairedBefore, 0);

        pairedToken.setRevertBalanceOf(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IUniCLStrat.PairedTokenTransferSkipped();
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.EmergencyExited(expectedEthToStrategyManager);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertEq(strategyManager.balance, expectedEthToStrategyManager);

        pairedToken.setRevertBalanceOf(false);
        assertEq(pairedToken.balanceOf(address(strategy)), pairedBefore);
        assertEq(pairedToken.balanceOf(address(strategyManager)), 0);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(pairedToken.balanceOf(address(strategy)), 0);
        assertEq(pairedToken.balanceOf(address(strategyManager)), pairedBefore);
    }

    /// @dev L-6: USDT-style empty returndata must not hostage the ETH sweep; trySafeTransfer
    ///      treats empty returndata + code as success and completes the paired transfer.
    function test_EmergencyExit_TransfersPairedTokenWithNoReturnData() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        uint256 wethBefore = weth.balanceOf(address(strategy));
        uint256 pairedBefore = pairedToken.balanceOf(address(strategy));
        uint256 nativeEthBefore = address(strategy).balance;
        uint256 expectedEthToStrategyManager = wethBefore + nativeEthBefore;
        assertGt(pairedBefore, 0);

        pairedToken.setNoReturnTransfer(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.EmergencyExited(expectedEthToStrategyManager);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertEq(strategyManager.balance, expectedEthToStrategyManager);
        assertEq(pairedToken.balanceOf(address(strategy)), 0);
        assertEq(pairedToken.balanceOf(address(strategyManager)), pairedBefore);
    }

    /// @dev L-6: a false-returning paired-token transfer must not hostage the ETH sweep.
    function test_EmergencyExit_SweepsETHWhenPairedTokenTransferReturnsFalse() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        uint256 wethBefore = weth.balanceOf(address(strategy));
        uint256 pairedBefore = pairedToken.balanceOf(address(strategy));
        uint256 nativeEthBefore = address(strategy).balance;
        uint256 expectedEthToStrategyManager = wethBefore + nativeEthBefore;
        assertGt(pairedBefore, 0);

        pairedToken.setReturnFalseTransfer(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IUniCLStrat.PairedTokenTransferSkipped();
        vm.expectEmit(false, false, false, true, address(strategy));
        emit IStrategy.EmergencyExited(expectedEthToStrategyManager);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertEq(strategyManager.balance, expectedEthToStrategyManager);
        assertEq(pairedToken.balanceOf(address(strategy)), pairedBefore);
        assertEq(pairedToken.balanceOf(address(strategyManager)), 0);
    }

    function test_EmergencyExit_RevertsWhenNotPaused() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratNotPaused.selector);
        strategy.emergencyExit();
    }

    function test_EmergencyExit_RevertsWhenCallerLacksRole() public {
        vm.prank(admin);
        strategy.pause();

        _expectCallerHasNoneOfRoles(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE);
        vm.prank(user);
        strategy.emergencyExit();
    }

    function test_EmergencyExit_RevertsWhenCallerIsStrategyManager() public {
        vm.prank(admin);
        strategy.pause();

        _expectCallerHasNoneOfRoles(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE);
        vm.prank(strategyManager);
        strategy.emergencyExit();
    }

    function test_EmergencyExit_WithNoBalances() public {
        vm.prank(admin);
        strategy.pause();

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(pairedToken.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
    }

    function test_EmergencyExit_CombinesWETHAndNativeETH() public {
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        uint256 wethBefore = weth.balanceOf(address(strategy));
        vm.deal(address(strategy), NAV_BALANCE_AMOUNT);

        uint256 expectedEthToSend = wethBefore + NAV_BALANCE_AMOUNT;

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(strategyManager.balance, expectedEthToSend);
        assertEq(address(strategy).balance, 0);
        assertEq(weth.balanceOf(address(strategy)), 0);
    }

    function test_EmergencyExit_SucceedsWhenPoolIsStillDegraded() public {
        _deposit(DEPOSIT_AMOUNT);

        pool.setPoolShouldRevert(true);

        vm.prank(admin);
        strategy.pause();

        // On-contract native ETH must remain recoverable even with a bricked pool
        vm.deal(address(strategy), NAV_BALANCE_AMOUNT);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(address(strategy).balance, 0);
        assertApproxEqAbs(strategyManager.balance, NAV_BALANCE_AMOUNT, NAV_TOLERANCE);
    }

    function test_EmergencyExit_DoesNotTouchPoolAfterSkippedUnwind() public {
        _deposit(DEPOSIT_AMOUNT);

        pool.setPoolShouldRevert(true);

        vm.prank(admin);
        strategy.pause();

        // The pause-time unwind was skipped: liquidity is still in the pool
        assertLe(weth.balanceOf(address(strategy)) + pairedToken.balanceOf(address(strategy)), NAV_TOLERANCE);

        // Pool recovers, but emergencyExit only sweeps held balances — it never touches the pool
        pool.setPoolShouldRevert(false);

        vm.prank(admin);
        strategy.emergencyExit();

        // The LP position is untouched and still attributed to the strategy
        assertGt(strategy.navInETH(), 0);
        assertLe(strategyManager.balance, NAV_TOLERANCE);
        assertLe(pairedToken.balanceOf(strategyManager), NAV_TOLERANCE);
    }

    function test_UnpauseAndRepause_RecoverPoolLiquidityAfterDegradedPause() public {
        _deposit(DEPOSIT_AMOUNT);

        pool.setPoolShouldRevert(true);

        vm.prank(admin);
        strategy.pause();

        // The pause-time unwind was skipped: liquidity is still in the pool
        assertLe(weth.balanceOf(address(strategy)) + pairedToken.balanceOf(address(strategy)), NAV_TOLERANCE);

        // Pool recovers: admin unpauses and re-runs the circuit breaker, which unwinds the LP
        pool.setPoolShouldRevert(false);

        vm.prank(admin);
        strategy.unpause();
        vm.prank(admin);
        strategy.pause();

        assertGt(weth.balanceOf(address(strategy)) + pairedToken.balanceOf(address(strategy)), 0);

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(weth.balanceOf(address(strategy)), 0);
        assertEq(pairedToken.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);
        assertGt(strategyManager.balance + pairedToken.balanceOf(strategyManager), 0);
        assertEq(strategy.navInETH(), 0);
    }

    // ============ EmergencyExit LP-Fee Accounting Reset (#231 H-1) ============

    function test_EmergencyExit_SkippedUnwind_DoesNotDoubleChargeSettledFeesOnResume() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        // Settle charges the accrued fees, but the fee tokens stay in the pool as tokensOwed.
        vm.prank(strategyManager);
        assertGt(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        // Bricked pool: the pause-time unwind is skipped, so the already-charged fee
        // tokens remain in the pool across the emergency exit.
        pool.setPoolShouldRevert(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IUniCLStrat.LiquidityUnwindSkipped();
        vm.prank(admin);
        strategy.pause();

        // The pool recovers before the exit; the reset accrues then sets charged = earned
        // so in-pool already-charged fees are written off and not feeable again on resume.
        pool.setPoolShouldRevert(false);

        vm.prank(admin);
        strategy.emergencyExit();

        // Documented resume flow: the already-charged fees must not become feeable again.
        vm.prank(admin);
        strategy.unpause();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);
    }

    function test_EmergencyExit_PoolStillDegraded_DoesNotDoubleChargeSettledFeesOnResume() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        vm.prank(strategyManager);
        assertGt(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        pool.setPoolShouldRevert(true);

        vm.expectEmit(false, false, false, true, address(strategy));
        emit IUniCLStrat.LiquidityUnwindSkipped();
        vm.prank(admin);
        strategy.pause();

        // The pool is still bricked at exit: accrue falls back to the snapshot (no-op),
        // then charged = earned. Leaving already-charged in-pool fees bracketed so resume
        // cannot re-charge them (zeroing would).
        vm.prank(admin);
        strategy.emergencyExit();

        pool.setPoolShouldRevert(false);

        vm.prank(admin);
        strategy.unpause();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);
    }

    function test_EmergencyExit_SkippedUnwind_ChargesOnlyPostResetGrowthOnResume() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        vm.prank(strategyManager);
        assertGt(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);

        pool.setPoolShouldRevert(true);
        vm.prank(admin);
        strategy.pause();
        pool.setPoolShouldRevert(false);

        vm.prank(admin);
        strategy.emergencyExit();
        vm.prank(admin);
        strategy.unpause();

        // Fee growth after the reset stays feeable — and only that growth.
        uint256 _newFeeWeth = 0.02 ether;
        uint256 _newFeePaired = 0.01 ether;
        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(_newFeeWeth),
            uint128(_newFeePaired)
        );

        vm.prank(strategyManager);
        strategy.sync();

        // Mock feeds price pairedToken 1:1 with ETH, so the ETH fee base is the sum.
        uint256 _expectedFee = (_newFeeWeth + _newFeePaired) * PERFORMANCE_FEE_BPS / 10_000;
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), _expectedFee);

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), _expectedFee);

        // Charged exactly once: a second settle finds nothing new.
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);
    }

    function test_EmergencyExit_SuccessfulUnwind_SweptFeesAreNotFeeableOnResume() public {
        _deposit(DEPOSIT_AMOUNT);
        IUniCLStrat.Position memory mainPosition = _mainPosition();

        pool.accrueFees(
            address(strategy),
            mainPosition.tickLower,
            mainPosition.tickUpper,
            uint128(ACCRUED_FEE_WETH),
            uint128(ACCRUED_FEE_PAIRED)
        );

        vm.prank(strategyManager);
        strategy.sync();

        assertGt(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        // No settle: the pause-time unwind succeeds and collects the accrued-uncharged
        // fee tokens onto the strategy alongside principal.
        vm.prank(admin);
        strategy.pause();

        uint256 wethBeforeExit = weth.balanceOf(address(strategy));
        uint256 pairedBeforeExit = pairedToken.balanceOf(address(strategy));
        assertGt(pairedBeforeExit, 0);

        vm.prank(admin);
        strategy.emergencyExit();

        // The uncharged fee tokens were swept to the StrategyManager as wind-down value.
        assertEq(strategy.navInETH(), 0);
        assertEq(strategyManager.balance, wethBeforeExit);
        assertEq(pairedToken.balanceOf(strategyManager), pairedBeforeExit);

        // On resume the swept fees do not resurrect as feeable — nothing is charged.
        vm.prank(admin);
        strategy.unpause();

        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0);

        vm.prank(strategyManager);
        assertEq(strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS), 0);
    }

    function test_UniswapV3MintCallback_RevertsWhenCallerIsNotPool() public {
        vm.expectRevert(IUniCLStrat.UniCLStratCallerNotPool.selector);
        strategy.uniswapV3MintCallback(0, 0, "");
    }

    function test_UniswapV3MintCallback_RevertsWhenNotMinting() public {
        vm.prank(address(pool));
        vm.expectRevert(IUniCLStrat.UniCLStratInvalidMintCallback.selector);
        strategy.uniswapV3MintCallback(0, 0, "");
    }

    function test_UniswapV3MintCallback_SucceedsDuringDepositMint() public {
        _deposit(DEPOSIT_AMOUNT);

        IUniCLStrat.Position memory mainPosition = _mainPosition();
        (uint128 liquidity,,,,) = pool.positions(
            keccak256(abi.encodePacked(address(strategy), mainPosition.tickLower, mainPosition.tickUpper))
        );

        assertGt(liquidity, 0);
    }

    // ============ Oracle Deviation Tests ============

    function test_Swap_RevertsWhenQuoteBelowOracleFloor() public {
        converter.setQuoteMultiplierBps(8_000); // 80% of 1:1 → below 98% floor
        vm.deal(strategyManager, DEPOSIT_AMOUNT);
        vm.prank(strategyManager);
        vm.expectRevert(abi.encodeWithSelector(IUniCLStrat.UniCLStratQuoteBelowOracleFloor.selector, 4e18, 5e18));
        strategy.deposit{value: DEPOSIT_AMOUNT}();
    }

    function test_Swap_RevertsWhenQuoteExceedsOracleCeiling() public {
        converter.setQuoteMultiplierBps(12_000); // 120% of 1:1 → above 102% ceiling
        vm.deal(strategyManager, DEPOSIT_AMOUNT);
        vm.prank(strategyManager);
        vm.expectRevert(abi.encodeWithSelector(IUniCLStrat.UniCLStratQuoteExceedsOracleCeiling.selector, 6e18, 5e18));
        strategy.deposit{value: DEPOSIT_AMOUNT}();
    }

    // ============ setRouteConfig Runtime Setter Tests ============

    function test_SetRouteConfig_UpdatesAdapterAndPaths() public {
        MockConverterAdapter newAdapter = new MockConverterAdapter(weth, pairedToken);
        converter.setAllowedAdapter(address(newAdapter), true);
        bytes memory newWethPath = abi.encodePacked(address(weth), uint24(500), address(pairedToken));
        bytes memory newPairedPath = abi.encodePacked(address(pairedToken), uint24(500), address(weth));

        vm.prank(admin);
        strategy.setRouteConfig(address(newAdapter), newWethPath, newPairedPath);

        assertEq(address(strategy.swapAdapter()), address(newAdapter));
        assertEq(strategy.wethToPairedTokenPath(), newWethPath);
        assertEq(strategy.pairedTokenToWethPath(), newPairedPath);
    }

    function test_SetRouteConfig_RevertsWhenCallerLacksRole() public {
        bytes memory _wethPath = abi.encodePacked(address(weth), uint24(3000), address(pairedToken));
        bytes memory _pairedPath = abi.encodePacked(address(pairedToken), uint24(3000), address(weth));
        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(user);
        strategy.setRouteConfig(address(swapAdapter), _wethPath, _pairedPath);
    }

    function test_SetRouteConfig_RevertsWithZeroAdapter() public {
        bytes memory _wethPath = abi.encodePacked(address(weth), uint24(3000), address(pairedToken));
        bytes memory _pairedPath = abi.encodePacked(address(pairedToken), uint24(3000), address(weth));
        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratInvalidRouteConfig.selector);
        strategy.setRouteConfig(address(0), _wethPath, _pairedPath);
    }

    function test_SetRouteConfig_RevertsWithWrongDirectionPath() public {
        bytes memory _pairedPath = abi.encodePacked(address(pairedToken), uint24(3000), address(weth));
        bytes memory _wrongPath = abi.encodePacked(address(pairedToken), uint24(3000), address(weth));
        // Pass the pairedToken→WETH path as the WETH→pairedToken path
        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratInvalidRouteConfig.selector);
        strategy.setRouteConfig(address(swapAdapter), _wrongPath, _pairedPath);
    }

    // ============ Wrap/Unwrap/Converter-Failure Tests ============

    function test_Deposit_RevertsWhenWrapFails() public {
        converter.setWrapShouldRevert(true);
        vm.deal(strategyManager, DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert("CONVERTER_WRAP_FAILED");
        strategy.deposit{value: DEPOSIT_AMOUNT}();
    }

    function test_Withdraw_RevertsWhenUnwrapFails() public {
        _deposit(DEPOSIT_AMOUNT);
        converter.setUnwrapShouldRevert(true);

        vm.prank(strategyManager);
        vm.expectRevert("CONVERTER_UNWRAP_FAILED");
        strategy.withdraw(receiver, WITHDRAW_AMOUNT);
    }

    // ============ EmergencyExit Under Converter-Paused Conditions ============

    function test_EmergencyExit_SucceedsWhenConverterIsPaused() public {
        _deposit(DEPOSIT_AMOUNT);
        vm.deal(address(strategy), NAV_BALANCE_AMOUNT);

        vm.prank(admin);
        strategy.pause();

        // Pause the Converter — emergencyExit must bypass it via direct weth.withdraw()
        converter.pause();

        uint256 wethBefore = weth.balanceOf(address(strategy));
        uint256 nativeEthBefore = address(strategy).balance;
        uint256 expectedEthToSM = wethBefore + nativeEthBefore;

        vm.prank(admin);
        strategy.emergencyExit();

        assertEq(strategyManager.balance, expectedEthToSM);
        assertEq(address(strategy).balance, 0);
        assertEq(weth.balanceOf(address(strategy)), 0);
    }

    // ============ setSwapSlippageBps Edge Cases ============

    function test_SetSwapSlippageBps_RevertsWhenZero() public {
        vm.prank(admin);
        vm.expectRevert(IUniCLStrat.UniCLStratInvalidConfig.selector);
        strategy.setSwapSlippageBps(0);
    }
}
