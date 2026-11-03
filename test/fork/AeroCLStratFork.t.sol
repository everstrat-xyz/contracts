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
import {DeployAeroCLStrat} from "../../script/DeployAeroCLStrat.s.sol";

/// @dev Exposes the deploy script's pre-broadcast probes so they run against the real pool.
///      `forge test` may run tests concurrently, so the `STRICT_FEE_CAP` mode is passed in
///      explicitly (the env var is only read in the script's `run`) and the tests stay
///      order-independent.
contract DeployAeroCLStratProbeHarness is DeployAeroCLStrat {
    function probe(address _factory, address _pool, uint32 _twapInterval, uint32 _shortTwapInterval)
        external
        view
    {
        _probe(_factory, _pool, _twapInterval, _shortTwapInterval, false);
    }

    function probeStrict(address _factory, address _pool, uint32 _twapInterval, uint32 _shortTwapInterval)
        external
        view
    {
        _probe(_factory, _pool, _twapInterval, _shortTwapInterval, true);
    }

    function _probe(
        address _factory,
        address _pool,
        uint32 _twapInterval,
        uint32 _shortTwapInterval,
        bool _strict
    ) private view {
        _requireAeroProvenance(_factory, _pool);
        _requirePoolCanServeTwap(_pool, _twapInterval, "TWAP_INTERVAL");
        _requirePoolCanServeTwap(_pool, _shortTwapInterval, "SHORT_TWAP_INTERVAL");
        _requirePoolObservationCardinality(_pool, _twapInterval);
        _requirePoolObservationCardinality(_pool, _shortTwapInterval);
        _checkFeeCapWithinQuoteBudget(_factory, _pool, _strict);
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
    uint256 internal constant POOL_DETUNE_BPS = 10_050;
    int24 internal constant NOT_CALM_TICK_OFFSET = 350;
    /// @dev Between REBALANCE_TICK_THRESHOLD and MAX_TICK_DEVIATION: unhealthy but still calm.
    int24 internal constant REBALANCE_TICK_OFFSET = 180;
    uint256 internal constant NAV_TOLERANCE = 0.03e18; // 3%
    uint256 internal constant WITHDRAW_TOLERANCE = 0.04e18; // 4%
    uint256 internal constant SWAP_USDT_BUDGET = 100_000_000_000e6;
    uint256 internal constant SWAP_WETH_BUDGET = 30_000_000e18;
    uint256 internal constant FEE_SWAP_USDT_AMOUNT = 20_000e6;

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
        uint256 forkBlock = vm.envUint("MAINNET_FORK_BLOCK");
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

    /// @dev Aero raised this pool's dynamic fee cap to the 5% factory default after Phase 1 was
    ///      written, so the probe must not fail the deploy by default. The cap is logged instead;
    ///      our inventory swaps route through a Uniswap pool, not this one. Asserts the live cap
    ///      really is over budget, so this test fails loudly if Aero ever lowers it again.
    function test_Fork_DeployProbes_FeeCapAboveBudget_StillDeploysByDefault() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();
        harness.probe(AERO_CL_FACTORY, AERO_WETH_USDT_POOL, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);

        (, uint24 feeCap,,,) =
            IDynamicSwapFeeHook(ICLFactory(AERO_CL_FACTORY).getPoolSwapHook(AERO_WETH_USDT_POOL)).dynamicFeeConfig(
                AERO_WETH_USDT_POOL
            );
        assertGe(
            feeCap,
            harness.feeBudgetPips(),
            "live cap should still exceed the quote budget; if not, the warning path is dead code"
        );
    }

    /// @dev `STRICT_FEE_CAP=true` restores the hard gate for operators who route through this pool.
    function test_Fork_DeployProbes_StrictFeeCap_RejectsWideCap() public onlyFork {
        DeployAeroCLStratProbeHarness harness = new DeployAeroCLStratProbeHarness();

        vm.expectRevert(bytes("Aero pool fee cap does not fit inside MAX_QUOTE_DEVIATION_BPS"));
        harness.probeStrict(AERO_CL_FACTORY, AERO_WETH_USDT_POOL, TWAP_INTERVAL, SHORT_TWAP_INTERVAL);
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

        _movePoolTickBy(NOT_CALM_TICK_OFFSET);

        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, PARTIAL_WITHDRAW_AMOUNT);

        assertEq(withdrawn, PARTIAL_WITHDRAW_AMOUNT, "partial withdrawal should be exact");
        assertEq(receiver.balance, PARTIAL_WITHDRAW_AMOUNT, "receiver should get native ETH");
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

        assertGe(withdrawn, amount * 95 / 100, "full withdrawal should recover ~all NAV");
        assertEq(receiver.balance, withdrawn);
        assertLt(strategy.navInETH(), DEPOSIT_AMOUNT * 5 / 100, "only dust should remain");
    }

    // ============ Sync (real unstaked swap fees) ============

    /// @dev Proves unstaked Slipstream positions accrue swap fees into `tokensOwed` (the pool's
    ///      `unstakedFee` is 0 on mainnet) and that `burn(..., 0)` pokes work on Slipstream.
    function test_Fork_Sync_PokesRealUnstakedSwapFeesIntoTokensOwed() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        (, uint128 owed0Before, uint128 owed1Before) = _mainPositionState();

        // Round-trip in-range volume through the Aero pool.
        (int256 amount0, int256 amount1) = _swapExactIn(!wethIsToken0, FEE_SWAP_USDT_AMOUNT);
        uint256 wethOut = uint256(-(wethIsToken0 ? amount0 : amount1));
        _swapExactIn(wethIsToken0, wethOut);

        vm.prank(strategyManager);
        strategy.sync();

        (, uint128 owed0After, uint128 owed1After) = _mainPositionState();
        assertGt(uint256(owed0After) + owed1After, uint256(owed0Before) + owed1Before, "sync should poke fees");
        assertGt(strategy.pendingPerformanceFeeInETH(1_000), 0, "pending fee should reflect real LP fees");
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

        // Opposite the detune so the Uni-routed rebalance swap stays inside the oracle band.
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

    function test_Fork_EmergencyExit_UnwindsRealPositionWhilePaused() public onlyFork {
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

    function _prepareCalmAlignedPool() internal {
        uint256 oracleEthPrice = oracle.convert(address(0), USDT, 1 ether, 18, USDT_DECIMALS);
        _movePoolSqrtPriceTo(_sqrtPriceX96ForEthPrice(oracleEthPrice * POOL_DETUNE_BPS / BPS));
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

    function _deposit(uint256 _amount) internal {
        vm.deal(strategyManager, _amount);
        vm.prank(strategyManager);
        strategy.deposit{value: _amount}();
    }
}
