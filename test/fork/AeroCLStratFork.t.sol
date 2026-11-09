// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
// solhint-disable gas-small-strings, max-states-count
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Registry} from "registry/Registry.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {Converter} from "../../src/contracts/Converter.sol";
import {UniswapV3ConverterAdapter} from "../../src/contracts/adapters/UniswapV3ConverterAdapter.sol";
import {AeroCLStrat} from "../../src/contracts/strategies/AeroCLStrat.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {ICLPool} from "../../src/interfaces/integrations/aero/ICLPool.sol";
import {ICLFactory} from "../../src/interfaces/integrations/aero/ICLFactory.sol";
import {IDynamicSwapFeeHook} from "../../src/interfaces/integrations/aero/IDynamicSwapFeeHook.sol";
import {FullMath} from "../../src/libraries/integrations/uniswap/FullMath.sol";
import {TickMath} from "../../src/libraries/integrations/uniswap/TickMath.sol";
import {TickUtils} from "../../src/libraries/integrations/uniswap/TickUtils.sol";

import {MockStrategyManagerStub} from "../mocks/MockStrategyManagerStub.sol";
import {IAeroCLFactoryForkAdmin, IAeroCustomUnstakedFeeModule} from "./helpers/AeroForkHelpers.sol";
import {DeployAeroCLStrat} from "../../script/DeployAeroCLStrat.s.sol";

/// @dev Exposes the deploy script's pre-broadcast probes so they run against the real pool.
///      `forge test` may run tests concurrently, so the `STRICT_FEE_CAP` mode is passed in
///      explicitly (the env var is only read in the script's `run`) and the tests stay
///      order-independent.
contract DeployAeroCLStratProbeHarness is DeployAeroCLStrat {
    function probe(address _factory, address _pool, uint32 _twapInterval, uint32 _shortTwapInterval) external view {
        _probe(_factory, _pool, _twapInterval, _shortTwapInterval, false);
    }

    function probeStrict(address _factory, address _pool, uint32 _twapInterval, uint32 _shortTwapInterval)
        external
        view
    {
        _probe(_factory, _pool, _twapInterval, _shortTwapInterval, true);
    }

    function _probe(address _factory, address _pool, uint32 _twapInterval, uint32 _shortTwapInterval, bool _strict)
        private
        view
    {
        _requireAeroProvenance(_factory, _pool);
        _requirePoolCanServeTwap(_pool, _twapInterval, "TWAP_INTERVAL");
        _requirePoolCanServeTwap(_pool, _shortTwapInterval, "SHORT_TWAP_INTERVAL");
        _requirePoolObservationCardinality(_pool, _twapInterval);
        _requirePoolObservationCardinality(_pool, _shortTwapInterval);
        _checkFeeCapWithinQuoteBudget(_factory, _pool, _strict);
    }

    function maxNavLargeVsPoolDepth(address _pool, address _weth, uint256 _maxTotalNAV) external view returns (bool) {
        return _warnIfMaxNavLargeVsPoolDepth(_pool, _weth, _maxTotalNAV);
    }

    /// @dev The budget constant is `internal`, so expose it for assertions.
    function feeBudgetPips() external pure returns (uint256) {
        return MAX_QUOTE_DEVIATION_BPS * PIPS_PER_BPS;
    }
}

/**
 * @title AeroCLStratForkTest
 * @notice Ethereum mainnet fork tests for AeroCLStrat against the REAL Aero (Slipstream)
 *         WETH/USDT pool (tick spacing 50, 6-field `slot0`, dynamic swap fee), the real
 *         CLFactory, real Chainlink ETH/USD + USDT/USD feeds and the real USDT token.
 *         Inventory swaps route through the shared Converter + UniswapV3ConverterAdapter on the
 *         much deeper Uniswap V3 WETH/USDT 0.05% pool, exactly as `DeployAeroCLStrat` configures.
 *
 * @dev Aero (Ethereum) launched 2026-10-22, so the fork must be pinned to a later block, e.g.
 *        MAINNET_RPC_URL=... MAINNET_FORK_BLOCK=26256000 forge test --match-path 'test/fork/*'
 *      (verified at 26256000; a pinned historical block needs an archive RPC — non-archive public
 *      nodes only serve recent state, so use `MAINNET_FORK_BLOCK=0` with them).
 *      `MAINNET_FORK_BLOCK=0` means tip (latest). When `MAINNET_RPC_URL` is unset, tests skip.
 *      The Aero pool's price is moved with direct `pool.swap` calls (this contract implements
 *      `uniswapV3SwapCallback`), so the suite has no dependency on Aero's periphery routers.
 */
contract AeroCLStratForkTest is Test {
    using SafeERC20 for IERC20;

    // ============ Mainnet addresses ============

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant AERO_CL_FACTORY = 0xF4Fd2E6c5B60c5b365cd1B96DD6245E6D60414c2;
    address internal constant AERO_WETH_USDT_POOL = 0xBa9abfDFB7c28E232d853d85c619e4248971AA31;
    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant UNIV3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant UNIV3_WETH_USDT_POOL_005 = 0x11b815efB8f581194ae79006d24E0d814B7697F6;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CHAINLINK_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    uint24 internal constant ROUTE_POOL_FEE = 500;
    uint8 internal constant USDT_DECIMALS = 6;

    // ============ Strategy configuration ============

    /// @dev The Aero pool holds ~170 WETH; size well below that (issue #55: start at 10-20 ETH).
    uint256 internal constant MAX_TOTAL_NAV = 15 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 0.5 ether;
    uint256 internal constant PARTIAL_WITHDRAW_AMOUNT = 0.15 ether;
    /// @dev Tick spacing is 50: width 8 => 400-tick half-width. The threshold stays >= one
    ///      spacing bucket so a tick-math boundary wobble can never read as unhealthy.
    int24 internal constant POSITION_WIDTH = 8;
    int24 internal constant REBALANCE_TICK_THRESHOLD = 100;
    int56 internal constant MAX_TICK_DEVIATION = 300;
    uint32 internal constant TWAP_INTERVAL = 1800;
    uint32 internal constant SHORT_TWAP_INTERVAL = 60;
    uint256 internal constant STALENESS_INTERVAL = 30 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_NAV_POOL_WETH_SHARE_BPS = 1_500; // mirrors DeployAeroCLStrat
    int24 internal constant NOT_CALM_TICK_OFFSET = 350;
    /// @dev Between REBALANCE_TICK_THRESHOLD and MAX_TICK_DEVIATION: unhealthy but still calm.
    int24 internal constant REBALANCE_TICK_OFFSET = 180;
    // Tolerances sit at ~2-5x the deviations measured at block 26256000 and at tip (Nov 2026):
    // deposit NAV 0.02-0.10%, invest-idle 0.01-0.04%, partial withdraw at a dislocated spot
    // 0.32-0.46%, full-withdraw residual 0.75%. A 1-2% mispricing would now fail.
    uint256 internal constant NAV_TOLERANCE = 0.005e18; // 0.5%
    uint256 internal constant WITHDRAW_TOLERANCE = 0.01e18; // 1%
    uint256 internal constant FULL_WITHDRAW_MIN_PAYOUT_BPS = 9_950; // 99.5% of maxWithdrawal
    uint256 internal constant FULL_WITHDRAW_MAX_RESIDUAL_BPS = 150; // 1.5% of the deposit
    uint256 internal constant SWAP_USDT_BUDGET = 100_000_000_000e6;
    uint256 internal constant SWAP_WETH_BUDGET = 30_000_000e18;
    uint256 internal constant FEE_SWAP_USDT_AMOUNT = 20_000e6;
    uint256 internal constant PERFORMANCE_FEE_BPS = 1_000; // 10%
    /// @dev Pending fee is an independent oracle re-valuation of tokensOwed: only rounding differs.
    uint256 internal constant FEE_VALUATION_TOLERANCE = 1e12; // 1e-6 relative
    uint256 internal constant INVEST_IDLE_AMOUNT = 0.3 ether;
    /// @dev 25% of unstaked LP fees diverted (pips); well below the module's MAX_FEE.
    uint24 internal constant TEST_UNSTAKED_FEE = 250_000;
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant UNSTAKED_FEE_RATIO_TOLERANCE = 0.01e18; // 1%
    /// @dev An enabled CLFactory tick spacing with no WETH/USDT pool, for fresh-pool tests.
    int24 internal constant FRESH_POOL_TICK_SPACING = 100;
    uint16 internal constant FRESH_POOL_CARDINALITY = 1;

    // ============ Actors ============

    address internal admin = makeAddr("admin");
    address internal security = makeAddr("security");
    address internal receiver = makeAddr("receiver");

    // ============ State ============

    bool internal forkAvailable;
    address internal strategyManager;
    Registry internal registry;
    Oracle internal oracle;
    Converter internal converter;
    UniswapV3ConverterAdapter internal adapter;
    AeroCLStrat internal strategy;
    ICLPool internal aeroPool = ICLPool(AERO_WETH_USDT_POOL);
    bytes internal wethToUsdtPath;
    bytes internal usdtToWethPath;
    bool internal wethIsToken0;

    modifier onlyFork() {
        if (!forkAvailable) vm.skip(true);
        _;
    }

    receive() external payable {}

    function setUp() public {
        if (!vm.envExists("MAINNET_RPC_URL")) return;

        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }
        // Aero is not deployed at pre-launch blocks: skip instead of failing.
        if (AERO_WETH_USDT_POOL.code.length == 0) return;
        forkAvailable = true;

        wethIsToken0 = aeroPool.token0() == WETH;
        _deployProtocolWiring();
    }

    function _deployProtocolWiring() internal {
        registry = new Registry(admin);
        strategyManager = address(new MockStrategyManagerStub());

        Oracle oracleImpl = new Oracle();
        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(oracleImpl), abi.encodeWithSelector(Oracle.initialize.selector, address(registry))
                )
            )
        );

        Converter converterImpl = new Converter();
        converter = Converter(
            payable(
                new ERC1967Proxy(
                    address(converterImpl),
                    abi.encodeWithSelector(Converter.initialize.selector, address(registry), WETH)
                )
            )
        );

        adapter = new UniswapV3ConverterAdapter(UNIV3_SWAP_ROUTER, UNIV3_FACTORY, address(oracle), WETH, TWAP_INTERVAL);

        wethToUsdtPath = abi.encodePacked(WETH, ROUTE_POOL_FEE, USDT);
        usdtToWethPath = abi.encodePacked(USDT, ROUTE_POOL_FEE, WETH);

        vm.startPrank(admin);
        bytes32[] memory keys = new bytes32[](3);
        address[] memory addresses = new address[](3);
        keys[0] = Auth.ORACLE;
        addresses[0] = address(oracle);
        keys[1] = Auth.CONVERTER;
        addresses[1] = address(converter);
        keys[2] = Auth.STRATEGY_MANAGER;
        addresses[2] = strategyManager;
        registry.registerContracts(keys, addresses);
        registry.grantRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, address(converter));
        registry.grantRole(Auth.SECURITY_ROLE, security);
        oracle.updateUsdFeedInfo(address(0), CHAINLINK_ETH_USD, STALENESS_INTERVAL);
        oracle.updateUsdFeedInfo(USDT, CHAINLINK_USDT_USD, STALENESS_INTERVAL);
        converter.setAllowedAdapter(address(adapter), true);
        vm.stopPrank();

        strategy = new AeroCLStrat(_deploymentConfig(AERO_WETH_USDT_POOL));

        vm.prank(strategyManager);
        converter.grantCallerRole(address(strategy));

        vm.prank(admin);
        strategy.setSwapSlippageBps(strategy.MAX_SWAP_SLIPPAGE_BPS());
    }

    function _deploymentConfig(address _pool) internal view returns (IUniCLStrat.DeploymentConfig memory) {
        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: address(registry),
                weth: WETH,
                pool: _pool,
                factory: AERO_CL_FACTORY
            }),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: address(adapter),
                wethToPairedTokenPath: wethToUsdtPath,
                pairedTokenToWethPath: usdtToWethPath
            }),
            strategy: IUniCLStrat.StrategyConfig({
                positionWidth: POSITION_WIDTH,
                rebalanceTickThreshold: REBALANCE_TICK_THRESHOLD,
                maxTickDeviation: MAX_TICK_DEVIATION,
                twapInterval: TWAP_INTERVAL,
                shortTwapInterval: SHORT_TWAP_INTERVAL,
                maxTotalNAV: MAX_TOTAL_NAV
            })
        });
    }

    // ============ Constructor (real CLFactory provenance + 6-field slot0) ============

    function test_Fork_Constructor_BindsRealAeroPool() public onlyFork {
        assertEq(address(strategy.pool()), AERO_WETH_USDT_POOL);
        assertEq(address(strategy.factory()), AERO_CL_FACTORY);
        assertEq(strategy.tickSpacing(), aeroPool.tickSpacing());
        assertEq(address(strategy.pairedToken()), USDT);
    }

    /// @dev A Uniswap pool is not an Aero pool: real CLFactory provenance rejects it.
    function test_Fork_Constructor_RevertsForNonAeroPool() public onlyFork {
        IUniCLStrat.DeploymentConfig memory config = _deploymentConfig(UNIV3_WETH_USDT_POOL_005);

        vm.expectRevert(IUniCLStrat.UniCLStratInvalidPool.selector);
        new AeroCLStrat(config);
    }

    // ============ Deploy-script probes ============

    function test_Fork_DeployProbes_PassForRealAeroPool() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();

        harness.probe(AERO_CL_FACTORY, AERO_WETH_USDT_POOL, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    function test_Fork_DeployProbes_RejectNonAeroPool() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();

        vm.expectRevert(bytes("POOL_ADDRESS is not an Aero CLFactory pool"));
        harness.probe(AERO_CL_FACTORY, UNIV3_WETH_USDT_POOL_005, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    /// @dev Sizing is a warning, keyed on the pool's live WETH balance (15% share threshold).
    function test_Fork_DeployProbes_WarnsWhenMaxNavIsLargeVsPoolDepth() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();
        uint256 poolWeth = IERC20(WETH).balanceOf(AERO_WETH_USDT_POOL);
        uint256 threshold = (poolWeth * MAX_NAV_POOL_WETH_SHARE_BPS) / BPS;

        assertFalse(harness.maxNavLargeVsPoolDepth(AERO_WETH_USDT_POOL, WETH, threshold), "at threshold");
        assertTrue(harness.maxNavLargeVsPoolDepth(AERO_WETH_USDT_POOL, WETH, threshold + 1), "above threshold");
    }

    // Fee-cap branches use a mocked hook config: the live cap is Aero governance state (it was
    // raised to the 5% factory default after launch), and a test pinned to it would fail on a
    // governance change rather than on a code change. Everything else in the probe stays real.

    /// @dev At the budget counts as over it: the default mode only warns.
    function test_Fork_DeployProbes_FeeCapAtBudget_WarnsByDefault() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();
        _mockPoolFeeCap(harness.feeBudgetPips());

        harness.probe(AERO_CL_FACTORY, AERO_WETH_USDT_POOL, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    /// @dev `STRICT_FEE_CAP=true` restores the hard gate for operators who route through this pool.
    function test_Fork_DeployProbes_StrictFeeCap_RejectsCapAtBudget() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();
        _mockPoolFeeCap(harness.feeBudgetPips());

        vm.expectRevert(bytes("Aero pool fee cap does not fit inside MAX_QUOTE_DEVIATION_BPS"));
        harness.probeStrict(AERO_CL_FACTORY, AERO_WETH_USDT_POOL, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    function test_Fork_DeployProbes_StrictFeeCap_AcceptsCapBelowBudget() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();
        _mockPoolFeeCap(harness.feeBudgetPips() - 1);

        harness.probeStrict(AERO_CL_FACTORY, AERO_WETH_USDT_POOL, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    /// @dev Without a swap-fee hook the static `fee()` is the cap.
    function test_Fork_DeployProbes_StrictFeeCap_UsesStaticFeeWithoutHook() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();
        vm.mockCall(
            AERO_CL_FACTORY, abi.encodeCall(ICLFactory.getPoolSwapHook, (AERO_WETH_USDT_POOL)), abi.encode(address(0))
        );
        vm.mockCall(AERO_WETH_USDT_POOL, abi.encodeCall(ICLPool.fee, ()), abi.encode(uint24(harness.feeBudgetPips())));

        vm.expectRevert(bytes("Aero pool fee cap does not fit inside MAX_QUOTE_DEVIATION_BPS"));
        harness.probeStrict(AERO_CL_FACTORY, AERO_WETH_USDT_POOL, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    /// @dev A freshly created pool has one observation, written at creation: `observe` cannot
    ///      look back a full window yet.
    function test_Fork_DeployProbes_RejectFreshPool() public onlyFork {
        address fresh = _createFreshAeroPool();
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();

        string memory expected = string.concat(
            "pool.observe cannot serve TWAP_INTERVAL", "; grow observation cardinality and wait for fill before deploy"
        );
        vm.expectRevert(bytes(expected));
        harness.probe(AERO_CL_FACTORY, fresh, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    /// @dev Once a window has passed, a cardinality-1 pool serves `observe` by extrapolating its
    ///      single observation (a spot price, not a TWAP); only the cardinality probe catches it.
    function test_Fork_DeployProbes_RejectAgedLowCardinalityPool() public onlyFork {
        address fresh = _createFreshAeroPool();
        vm.warp(block.timestamp + TWAP_INTERVAL + 1);
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();

        vm.expectRevert(
            bytes("pool observationCardinality below ceil(interval/MAX_BLOCK_SECONDS); grow and wait for fill")
        );
        harness.probe(AERO_CL_FACTORY, fresh, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
    }

    // ============ Constructor (real fresh pool: TWAP / cardinality gates) ============

    function test_Fork_Constructor_RevertsForFreshPool() public onlyFork {
        IUniCLStrat.DeploymentConfig memory config = _deploymentConfig(_createFreshAeroPool());

        vm.expectRevert(IUniCLStrat.UniCLStratPoolTWAPNotAvailable.selector);
        new AeroCLStrat(config);
    }

    function test_Fork_Constructor_RevertsForAgedLowCardinalityPool() public onlyFork {
        IUniCLStrat.DeploymentConfig memory config = _deploymentConfig(_createFreshAeroPool());
        vm.warp(block.timestamp + TWAP_INTERVAL + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUniCLStrat.UniCLStratInsufficientObservationCardinality.selector,
                FRESH_POOL_CARDINALITY,
                strategy.MIN_OBSERVATION_CARDINALITY()
            )
        );
        new AeroCLStrat(config);
    }

    // ============ Deposit ============

    function test_Fork_Deposit_ProvidesLiquidityToRealAeroPool() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        (uint128 liquidity,,) = _mainPositionState();
        assertGt(liquidity, 0, "main position should hold real Aero pool liquidity");
        assertTrue(strategy.initTicks(), "ticks should be initialised");
        assertEq(strategy.totalDeposited(), DEPOSIT_AMOUNT);
        assertTrue(strategy.isHealthy(), "freshly minted position should be healthy");
        assertApproxEqRel(strategy.navInETH(), DEPOSIT_AMOUNT, NAV_TOLERANCE, "NAV should track deposited ETH");
    }

    function test_Fork_Deposit_RevertsAboveMaxDeposit() public onlyFork {
        _prepareCalmAlignedPool();
        uint256 excessive = MAX_TOTAL_NAV + 1 ether;
        vm.deal(strategyManager, excessive);
        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyMaxDepositExceeded.selector);
        strategy.deposit{value: excessive}();
    }

    function test_Fork_Deposit_RevertsWhenPaused() public onlyFork {
        _prepareCalmAlignedPool();
        vm.prank(security);
        strategy.pause();

        assertEq(strategy.maxDeposit(), 0);
        vm.deal(strategyManager, 1 ether);
        vm.prank(strategyManager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        strategy.deposit{value: 1 ether}();
    }

    // ============ Withdraw ============

    function test_Fork_Withdraw_PartialSendsExactETHToReceiver() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        uint256 navBefore = strategy.navInETH();
        (uint128 liquidityBefore,,) = _mainPositionState();

        _movePoolTickBy(NOT_CALM_TICK_OFFSET);

        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, PARTIAL_WITHDRAW_AMOUNT);

        assertEq(withdrawn, PARTIAL_WITHDRAW_AMOUNT, "partial withdrawal should be exact");
        assertEq(receiver.balance, PARTIAL_WITHDRAW_AMOUNT, "receiver should get native ETH");
        // Partial burn, not a full unwind: the pool is not calm, so nothing is re-added, and any
        // liquidity left on the main range must therefore have survived the withdrawal.
        (uint128 liquidityAfter,,) = _mainPositionState();
        assertGt(liquidityAfter, 0, "main range should keep liquidity (partial burn)");
        assertLt(liquidityAfter, liquidityBefore, "main range should be partially burned");
        assertApproxEqRel(
            strategy.navInETH(), navBefore - PARTIAL_WITHDRAW_AMOUNT, WITHDRAW_TOLERANCE, "NAV should shrink by payout"
        );
    }

    function test_Fork_Withdraw_FullRoundTripEmptiesStrategy() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        _movePoolTickBy(-NOT_CALM_TICK_OFFSET);

        uint256 amount = strategy.maxWithdrawal();
        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, amount);

        assertGe(withdrawn, amount * FULL_WITHDRAW_MIN_PAYOUT_BPS / BPS, "full withdrawal should pay out ~all NAV");
        assertEq(receiver.balance, withdrawn);
        // The burn happens at the moved spot while NAV was marked at the (lagging) TWAP, so a
        // small surplus can remain after paying out the full TWAP-marked NAV.
        assertLt(strategy.navInETH(), DEPOSIT_AMOUNT * FULL_WITHDRAW_MAX_RESIDUAL_BPS / BPS, "only a residual remains");
    }

    // ============ Sync (real unstaked swap fees) ============

    /// @dev Proves unstaked Slipstream positions accrue swap fees into `tokensOwed` (the pool's
    ///      `unstakedFee` is 0 on mainnet) and that `burn(..., 0)` pokes work on Slipstream.
    function test_Fork_Sync_PokesRealUnstakedSwapFeesIntoTokensOwed() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        (uint256 owedWethBefore, uint256 owedUsdtBefore) = _owedByToken();

        _roundTripFeeVolume();
        vm.prank(strategyManager);
        strategy.sync();

        (uint256 owedWethAfter, uint256 owedUsdtAfter) = _owedByToken();
        assertGt(owedUsdtAfter, owedUsdtBefore, "USDT-in leg should accrue USDT fees");
        assertGt(owedWethAfter, owedWethBefore, "WETH-in leg should accrue WETH fees");

        // The strategy's view must equal an independent oracle valuation of the poked fees.
        uint256 feeBaseETH = _valueInETH(owedWethAfter - owedWethBefore, owedUsdtAfter - owedUsdtBefore);
        assertApproxEqRel(
            strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS),
            feeBaseETH * PERFORMANCE_FEE_BPS / BPS,
            FEE_VALUATION_TOLERANCE,
            "pending fee should be bps of the oracle value of the poked tokensOwed"
        );
    }

    function test_Fork_SettlePerformanceFee_ChargesPendingAndResets() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        _roundTripFeeVolume();
        vm.prank(strategyManager);
        strategy.sync();
        uint256 pending = strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS);
        assertGt(pending, 0, "precondition: real fees pending");

        vm.prank(strategyManager);
        uint256 settled = strategy.settlePerformanceFee(PERFORMANCE_FEE_BPS);

        assertEq(settled, pending, "settlement should charge exactly the pending view");
        assertEq(strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS), 0, "nothing left to charge");
    }

    /// @dev Unstaked LPs keep their pro-rata swap fees net of `CLFactory.getUnstakedFee(pool)`.
    ///      Raising it through the real fee module (as its manager) must shrink the accrued
    ///      `tokensOwed` by exactly that share, and the pending fee must follow the net amount —
    ///      the claim FREEZE_RUNBOOK §6.4 relies on ("on-chain accounting stays correct").
    function test_Fork_Sync_UnstakedFeeReducesAccruedFeesProRata() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        (uint256 owedWeth0, uint256 owedUsdt0) = _owedByToken();
        uint256 snapshot = vm.snapshotState();

        // Baseline: the mainnet default (no diversion).
        assertEq(ICLFactory(AERO_CL_FACTORY).getUnstakedFee(AERO_WETH_USDT_POOL), 0, "precondition: default is 0");
        _roundTripFeeVolume();
        vm.prank(strategyManager);
        strategy.sync();
        (uint256 grossWeth, uint256 grossUsdt) = _owedByToken();
        grossWeth -= owedWeth0;
        grossUsdt -= owedUsdt0;

        // Same state and volume, with a quarter of unstaked LP fees diverted.
        vm.revertToState(snapshot);
        _setUnstakedFee(TEST_UNSTAKED_FEE);
        assertEq(ICLFactory(AERO_CL_FACTORY).getUnstakedFee(AERO_WETH_USDT_POOL), TEST_UNSTAKED_FEE);
        _roundTripFeeVolume();
        vm.prank(strategyManager);
        strategy.sync();
        (uint256 netWeth, uint256 netUsdt) = _owedByToken();
        netWeth -= owedWeth0;
        netUsdt -= owedUsdt0;

        uint256 keptShare = (PIPS - TEST_UNSTAKED_FEE) * 1e18 / PIPS;
        assertApproxEqRel(netUsdt * 1e18 / grossUsdt, keptShare, UNSTAKED_FEE_RATIO_TOLERANCE, "USDT fees net");
        assertApproxEqRel(netWeth * 1e18 / grossWeth, keptShare, UNSTAKED_FEE_RATIO_TOLERANCE, "WETH fees net");
        assertApproxEqRel(
            strategy.pendingPerformanceFeeInETH(PERFORMANCE_FEE_BPS),
            _valueInETH(netWeth, netUsdt) * PERFORMANCE_FEE_BPS / BPS,
            FEE_VALUATION_TOLERANCE,
            "pending fee should follow tokensOwed net of the unstaked fee"
        );
    }

    // ============ Invest idle ETH ============

    function test_Fork_InvestIdleETH_DeploysDonationIntoAeroPool() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        (uint128 liquidityBefore,,) = _mainPositionState();
        uint256 navBefore = strategy.navInETH();
        vm.deal(address(strategy), INVEST_IDLE_AMOUNT);

        vm.prank(admin);
        uint256 invested = strategy.investIdleETH();

        assertEq(invested, INVEST_IDLE_AMOUNT, "all idle ETH fits under maxTotalNAV");
        assertEq(address(strategy).balance, 0, "no native ETH left idle");
        (uint128 liquidityAfter,,) = _mainPositionState();
        assertGt(liquidityAfter, liquidityBefore, "main range should grow");
        assertApproxEqRel(
            strategy.navInETH(), navBefore + INVEST_IDLE_AMOUNT, NAV_TOLERANCE, "NAV should grow by the donation"
        );
    }

    // ============ Rebalance ============

    function test_Fork_Rebalance_RevertsWhenHealthy() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyIsHealthy.selector);
        strategy.rebalance();
    }

    function test_Fork_Rebalance_RecentersPositionAfterPriceMove() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        (int24 lowerBefore, int24 upperBefore) = strategy.positionMain();

        // Past rebalanceTickThreshold but inside maxTickDeviation: unhealthy yet still calm.
        _movePoolTickBy(-REBALANCE_TICK_OFFSET);
        _alignPoolToTickBoundaryAndSettle();

        assertFalse(strategy.isHealthy(), "drifted position should be unhealthy");
        assertGt(strategy.maxDeposit(), 0, "pool should still be calm");

        vm.prank(strategyManager);
        strategy.rebalance();

        (int24 lowerAfter, int24 upperAfter) = strategy.positionMain();
        assertTrue(lowerAfter != lowerBefore || upperAfter != upperBefore, "main position should move");
        (uint128 liquidity,,) = _mainPositionState();
        assertGt(liquidity, 0, "recentered position should hold liquidity");
        assertTrue(strategy.isHealthy(), "strategy should be healthy after rebalance");
    }

    function test_Fork_Rebalance_RevertsWhenPoolNotCalm() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        _movePoolTickBy(NOT_CALM_TICK_OFFSET);

        assertEq(strategy.maxDeposit(), 0, "capacity should be zero while not calm");
        assertTrue(strategy.isHealthy(), "not-calm pool should report healthy (no action possible)");

        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratNotCalm.selector);
        strategy.rebalance();
    }

    // ============ Pause / emergency exit ============

    function test_Fork_PauseUnpause_RestoresRealUsdtConverterAllowance() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(security);
        strategy.pause();
        assertEq(IERC20(USDT).allowance(address(strategy), address(converter)), 0, "pause should revoke");
        (uint128 liquidity,,) = _mainPositionState();
        assertEq(liquidity, 0, "pause should unwind the Aero position");

        vm.prank(admin);
        strategy.unpause();
        assertEq(IERC20(USDT).allowance(address(strategy), address(converter)), type(uint256).max);
    }

    /// @dev `pause()` unwinds the position; `emergencyExit()` only sweeps what the strategy holds.
    function test_Fork_PauseThenEmergencyExit_SweepsUnwoundPosition() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        uint256 navBefore = strategy.navInETH();

        vm.prank(security);
        strategy.pause();
        vm.prank(security);
        strategy.emergencyExit();

        uint256 ethOut = strategyManager.balance;
        uint256 usdtOut = IERC20(USDT).balanceOf(strategyManager);
        assertGt(ethOut, 0, "emergency exit should forward unwrapped ETH");

        uint256 totalOutInETH = ethOut + oracle.convert(USDT, address(0), usdtOut, USDT_DECIMALS, 18);
        assertApproxEqRel(totalOutInETH, navBefore, NAV_TOLERANCE, "recovered value should match NAV");
        assertLe(strategy.navInETH(), 1e12, "strategy should hold only dust after exit");
    }

    // ============ Pool manipulation helpers ============

    /// @dev Pays the Aero pool for direct `swap` calls made by this test.
    function uniswapV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata) external {
        require(msg.sender == AERO_WETH_USDT_POOL, "unexpected swap callback");
        if (_amount0Delta > 0) IERC20(aeroPool.token0()).safeTransfer(msg.sender, uint256(_amount0Delta));
        if (_amount1Delta > 0) IERC20(aeroPool.token1()).safeTransfer(msg.sender, uint256(_amount1Delta));
    }

    /// @dev Puts the Aero pool on the Chainlink price. Inventory swaps route through the untouched
    ///      Uniswap pool, so (unlike the UniCLStrat USDT suite) no detune is needed for them.
    function _prepareCalmAlignedPool() internal {
        uint256 oracleEthPrice = oracle.convert(address(0), USDT, 1 ether, 18, USDT_DECIMALS);
        _movePoolSqrtPriceTo(_sqrtPriceX96ForEthPrice(oracleEthPrice));
        _alignPoolToTickBoundaryAndSettle();
    }

    /// @dev Mid-bucket target (see the UniCLStrat fork suites) so a +/-1 tick-math wobble can
    ///      never cross a spacing boundary; then let both TWAPs catch up.
    function _alignPoolToTickBoundaryAndSettle() internal {
        int24 spacing = aeroPool.tickSpacing();
        int24 target = TickUtils.floor(_currentTick(), spacing) + spacing / 2;
        _movePoolSqrtPriceTo(TickMath.getSqrtRatioAtTick(target));
        vm.warp(block.timestamp + TWAP_INTERVAL + 1);
    }

    function _movePoolTickBy(int24 _tickOffset) internal {
        _movePoolSqrtPriceTo(TickMath.getSqrtRatioAtTick(_currentTick() + _tickOffset));
    }

    function _movePoolSqrtPriceTo(uint160 _targetSqrtPriceX96) internal {
        uint160 current = _currentSqrtPrice();
        if (current == _targetSqrtPriceX96) return;

        // price = token1/token0: token0 in (zeroForOne) lowers it, token1 in raises it.
        bool zeroForOne = _targetSqrtPriceX96 < current;
        bool token0IsWeth = wethIsToken0;
        uint256 budget = (zeroForOne == token0IsWeth) ? SWAP_WETH_BUDGET : SWAP_USDT_BUDGET;
        deal(zeroForOne ? aeroPool.token0() : aeroPool.token1(), address(this), budget);
        aeroPool.swap(address(this), zeroForOne, int256(budget), _targetSqrtPriceX96, "");

        assertEq(_currentSqrtPrice(), _targetSqrtPriceX96, "pool should land exactly on the target price");
    }

    function _swapExactIn(bool _zeroForOne, uint256 _amountIn) internal returns (int256 amount0, int256 amount1) {
        deal(_zeroForOne ? aeroPool.token0() : aeroPool.token1(), address(this), _amountIn);
        uint160 limit = _zeroForOne
            ? TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK) + 1
            : TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK) - 1;
        (amount0, amount1) = aeroPool.swap(address(this), _zeroForOne, int256(_amountIn), limit, "");
    }

    function _sqrtPriceX96ForEthPrice(uint256 _ethPriceInUsdtUnits) internal view returns (uint160) {
        return wethIsToken0
            ? uint160(Math.sqrt(FullMath.mulDiv(_ethPriceInUsdtUnits, 1 << 192, 1e18)))
            : uint160(Math.sqrt(FullMath.mulDiv(1e18, 1 << 192, _ethPriceInUsdtUnits)));
    }

    function _currentSqrtPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,) = aeroPool.slot0();
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,,,) = aeroPool.slot0();
    }

    function _mainPositionState() internal view returns (uint128 liquidity, uint128 owed0, uint128 owed1) {
        (int24 tickLower, int24 tickUpper) = strategy.positionMain();
        bytes32 key = keccak256(abi.encodePacked(address(strategy), tickLower, tickUpper));
        (liquidity,,, owed0, owed1) = IUniswapV3Pool(AERO_WETH_USDT_POOL).positions(key);
    }

    /// @dev `tokensOwed` summed over main and alt (the strategy's fee base), split by token.
    function _owedByToken() internal view returns (uint256 owedWeth, uint256 owedUsdt) {
        (int24 mainLower, int24 mainUpper) = strategy.positionMain();
        (int24 altLower, int24 altUpper) = strategy.positionAlt();
        (uint256 owed0Main, uint256 owed1Main) = _owed(mainLower, mainUpper);
        (uint256 owed0Alt, uint256 owed1Alt) = _owed(altLower, altUpper);
        uint256 owed0 = owed0Main + owed0Alt;
        uint256 owed1 = owed1Main + owed1Alt;
        (owedWeth, owedUsdt) = wethIsToken0 ? (owed0, owed1) : (owed1, owed0);
    }

    function _owed(int24 _tickLower, int24 _tickUpper) internal view returns (uint256 owed0, uint256 owed1) {
        bytes32 key = keccak256(abi.encodePacked(address(strategy), _tickLower, _tickUpper));
        (,,, uint128 tokensOwed0, uint128 tokensOwed1) = IUniswapV3Pool(AERO_WETH_USDT_POOL).positions(key);
        (owed0, owed1) = (tokensOwed0, tokensOwed1);
    }

    /// @dev Independent valuation: WETH at par, USDT through the Oracle (as the strategy does).
    function _valueInETH(uint256 _weth, uint256 _usdt) internal view returns (uint256) {
        return _weth + oracle.convert(USDT, address(0), _usdt, USDT_DECIMALS, 18);
    }

    /// @dev Swaps USDT -> WETH and back through the Aero pool, so both tokens accrue LP fees.
    function _roundTripFeeVolume() internal {
        (int256 amount0, int256 amount1) = _swapExactIn(!wethIsToken0, FEE_SWAP_USDT_AMOUNT);
        uint256 wethOut = uint256(-(wethIsToken0 ? amount0 : amount1));
        _swapExactIn(wethIsToken0, wethOut);
    }

    /// @dev Sets the pool's unstaked fee through the real module, as the factory's fee manager.
    function _setUnstakedFee(uint24 _fee) internal {
        IAeroCLFactoryForkAdmin factoryAdmin = IAeroCLFactoryForkAdmin(AERO_CL_FACTORY);
        IAeroCustomUnstakedFeeModule feeModule = IAeroCustomUnstakedFeeModule(factoryAdmin.unstakedFeeModule());
        vm.prank(factoryAdmin.unstakedFeeManager());
        feeModule.setCustomFee(AERO_WETH_USDT_POOL, _fee);
    }

    /// @dev Creates a real WETH/USDT pool through the CLFactory (permissionless) at the live
    ///      price. It is factory-provenanced but has a single observation (cardinality 1).
    function _createFreshAeroPool() internal returns (address fresh) {
        IAeroCLFactoryForkAdmin factoryAdmin = IAeroCLFactoryForkAdmin(AERO_CL_FACTORY);
        fresh = factoryAdmin.createPool(WETH, USDT, FRESH_POOL_TICK_SPACING, _currentSqrtPrice());
        (,,, uint16 cardinality,,) = ICLPool(fresh).slot0();
        assertEq(cardinality, FRESH_POOL_CARDINALITY, "precondition: a fresh pool has one observation");
    }

    /// @dev Points the factory at a stub swap-fee hook reporting `_feeCap` for the real pool.
    function _mockPoolFeeCap(uint256 _feeCap) internal {
        address hook = makeAddr("mockSwapFeeHook");
        vm.etch(hook, hex"00");
        vm.mockCall(
            AERO_CL_FACTORY, abi.encodeCall(ICLFactory.getPoolSwapHook, (AERO_WETH_USDT_POOL)), abi.encode(hook)
        );
        vm.mockCall(
            hook,
            abi.encodeCall(IDynamicSwapFeeHook.dynamicFeeConfig, (AERO_WETH_USDT_POOL)),
            abi.encode(uint24(0), uint24(_feeCap), uint64(0), false, uint24(0))
        );
    }

    function _deposit(uint256 _amount) internal {
        vm.deal(strategyManager, _amount);
        vm.prank(strategyManager);
        strategy.deposit{value: _amount}();
    }
}
