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
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {FullMath} from "../../src/libraries/integrations/uniswap/FullMath.sol";
import {TickMath} from "../../src/libraries/integrations/uniswap/TickMath.sol";
import {TickUtils} from "../../src/libraries/integrations/uniswap/TickUtils.sol";

import {MockStrategyManagerStub} from "../mocks/MockStrategyManagerStub.sol";
import {ICanonicalSwapRouter} from "./helpers/UniswapV3ForkHelpers.sol";

/**
 * @title UniCLStratUSDTForkTest
 * @notice Ethereum mainnet fork tests for UniCLStrat and its Converter /
 *         UniswapV3ConverterAdapter path against the REAL Uniswap V3 WETH/USDT 0.3% pool,
 *         real Chainlink ETH/USD + USDT/USD feeds, and the real (non-standard) USDT token.
 *
 * @dev Companion to `UniCLStratFork.t.sol` (WETH/USDC). Real mainnet USDT does not return a
 *      bool from `transfer`/`transferFrom`/`approve`, and its `approve` reverts when changing
 *      a non-zero allowance directly to another non-zero value (the classic "approve race"
 *      guard). `test/unit/UniCLStrat.t.sol` simulates these quirks with `MockERC20` flags, but
 *      only the real token bytecode proves the strategy's `forceApprove`/`safeTransfer` usage
 *      (via OZ `SafeERC20`) actually tolerates it end-to-end. Every deposit/withdraw/pause/
 *      unpause/emergencyExit below round-trips through the real USDT contract.
 *
 *      Unlike the WETH/USDC pool, USDT sorts ABOVE WETH by address, so this pool has the
 *      OPPOSITE token0/token1 order (token0 = WETH, token1 = USDT). All price-direction math
 *      below is derived from `pool.token0()`/`token1()` at runtime rather than hard-coded, so
 *      it stays correct regardless of ordering.
 *
 *      Run:
 *        MAINNET_RPC_URL=... MAINNET_FORK_BLOCK=<n> forge test --match-path 'test/fork/*'
 *      `MAINNET_FORK_BLOCK=0` means tip (latest). When `MAINNET_RPC_URL` is unset
 *      (`vm.envExists` is false), tests skip so offline `forge test` stays green — no envOr.
 */
contract UniCLStratUSDTForkTest is Test {
    using SafeERC20 for IERC20;

    // ============ Mainnet addresses ============

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant UNIV3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant WETH_USDT_POOL_030 = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CHAINLINK_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    uint24 internal constant POOL_FEE = 3000;
    uint8 internal constant USDT_DECIMALS = 6;

    // ============ Strategy configuration ============

    uint256 internal constant MAX_TOTAL_NAV = 100 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 0.5 ether;
    uint256 internal constant PARTIAL_WITHDRAW_AMOUNT = 0.15 ether;
    // The WETH/USDC 0.05% pool used by the sibling fork test is far deeper than this
    // WETH/USDT 0.3% pool, so a tight rebalance threshold there (10 ticks) is unrealistic
    // here: even a routine deposit-time inventory-balancing swap moves this pool's spot
    // tick past that. `REBALANCE_TICK_THRESHOLD` is sized to (a) comfortably absorb that
    // routine deposit-time drift, (b) stay >= tickSpacing (60) so it can never be smaller
    // than a single `floor()` bucket step (see `_alignPoolToTickBoundaryAndSettle`'s
    // NatSpec: a threshold below tickSpacing can never absorb a tick-math boundary wobble),
    // and (c) still leave room under `MAX_TICK_DEVIATION` for `REBALANCE_TICK_OFFSET` to
    // land in an "unhealthy but still calm" zone the rebalance-recenter test needs.
    int24 internal constant POSITION_WIDTH = 30;
    int24 internal constant REBALANCE_TICK_THRESHOLD = 120;
    int56 internal constant MAX_TICK_DEVIATION = 300;
    uint32 internal constant TWAP_INTERVAL = 1800;
    uint32 internal constant SHORT_TWAP_INTERVAL = 60;
    uint256 internal constant STALENESS_INTERVAL = 30 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant POOL_DETUNE_BPS = 10_050;
    int24 internal constant NOT_CALM_TICK_OFFSET = 350;
    /// @dev Between REBALANCE_TICK_THRESHOLD and MAX_TICK_DEVIATION: far enough from center
    ///      to be unhealthy, but not far enough to also trip the calm check.
    int24 internal constant REBALANCE_TICK_OFFSET = 180;
    uint256 internal constant NAV_TOLERANCE = 0.03e18; // 3%
    uint256 internal constant WITHDRAW_TOLERANCE = 0.04e18; // 4%
    uint256 internal constant TRADER_USDT_BUDGET = 100_000_000_000e6;
    uint256 internal constant TRADER_WETH_BUDGET = 30_000_000e18;
    uint256 internal constant FEE_SWAP_USDT_AMOUNT = 200_000e6;

    // ============ Actors ============

    address internal admin = makeAddr("admin");
    address internal security = makeAddr("security");
    address internal receiver = makeAddr("receiver");
    address internal trader = makeAddr("trader");

    // ============ State ============

    bool internal forkAvailable;
    address internal strategyManager;
    Registry internal registry;
    Oracle internal oracle;
    Converter internal converter;
    UniswapV3ConverterAdapter internal adapter;
    UniCLStrat internal strategy;
    IUniswapV3Pool internal pool = IUniswapV3Pool(WETH_USDT_POOL_030);
    bytes internal wethToUsdtPath;
    bytes internal usdtToWethPath;
    bool internal wethIsToken0;

    modifier onlyFork() {
        if (!forkAvailable) vm.skip(true);
        _;
    }

    receive() external payable {}

    function setUp() public {
        // Skip offline without envOr: absence is explicit, not a silent empty-string fallback.
        if (!vm.envExists("MAINNET_RPC_URL")) return;

        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        // Required when forking: 0 = tip. Omitting the var reverts (no silent tip fallback).
        uint256 forkBlock = vm.envUint("MAINNET_FORK_BLOCK");
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }
        forkAvailable = true;

        wethIsToken0 = pool.token0() == WETH;
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

        wethToUsdtPath = abi.encodePacked(WETH, POOL_FEE, USDT);
        usdtToWethPath = abi.encodePacked(USDT, POOL_FEE, WETH);

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

        strategy = new UniCLStrat(_deploymentConfig());

        vm.prank(strategyManager);
        converter.grantCallerRole(address(strategy));

        vm.prank(admin);
        strategy.setSwapSlippageBps(strategy.MAX_SWAP_SLIPPAGE_BPS());
    }

    function _deploymentConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: address(registry),
                weth: WETH,
                pool: WETH_USDT_POOL_030,
                factory: UNIV3_FACTORY
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

    // ============ Deposit ============

    function test_Fork_Deposit_ProvidesLiquidityToRealPool() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        (uint128 liquidity,,) = _mainPositionState();
        assertGt(liquidity, 0, "main position should hold real pool liquidity");
        assertTrue(strategy.initTicks(), "ticks should be initialised");
        assertEq(strategy.totalDeposited(), DEPOSIT_AMOUNT, "totalDeposited should track the deposit");
        assertTrue(strategy.isHealthy(), "freshly minted position should be healthy");
    }

    function test_Fork_NavInETH_ReflectsDepositedValue() public onlyFork {
        _prepareCalmAlignedPool();
        assertEq(strategy.navInETH(), 0, "empty strategy should have zero NAV");

        _deposit(DEPOSIT_AMOUNT);

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

        assertEq(strategy.maxDeposit(), 0, "paused strategy should advertise zero capacity");
        assertEq(strategy.maxWithdrawal(), 0, "paused strategy should advertise zero withdrawal");

        vm.deal(strategyManager, 1 ether);
        vm.prank(strategyManager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        strategy.deposit{value: 1 ether}();
    }

    /// @dev Seeds real USDT inventory on the strategy before a deposit, forcing the deposit
    ///      path to balance inventory via a real `approve`/`transfer` round-trip on USDT
    ///      (the classic non-standard-ERC20 surface) rather than only ever touching WETH.
    function test_Fork_Deposit_SucceedsWhenSpotDriftsBelowTwap() public onlyFork {
        _prepareCalmAlignedPool();

        uint256 usdtSeed = oracle.convert(address(0), USDT, DEPOSIT_AMOUNT * 12 / 10, 18, USDT_DECIMALS);
        deal(USDT, address(strategy), usdtSeed);

        _deposit(DEPOSIT_AMOUNT);

        (uint128 liquidity,,) = _mainPositionState();
        assertGt(liquidity, 0, "deposit should mint liquidity after inventory swap moves spot");
        assertTrue(strategy.isHealthy());
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
        assertEq(strategy.totalWithdrawn(), PARTIAL_WITHDRAW_AMOUNT, "totalWithdrawn should track");
        assertApproxEqRel(
            strategy.navInETH(), navBefore - PARTIAL_WITHDRAW_AMOUNT, WITHDRAW_TOLERANCE, "NAV should shrink by payout"
        );
    }

    function test_Fork_Withdraw_FullRoundTripEmptiesStrategy() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        _movePoolTickBy(-NOT_CALM_TICK_OFFSET);

        uint256 amount = strategy.maxWithdrawal();
        assertGt(amount, 0, "maxWithdrawal should expose the full NAV");

        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, amount);

        assertGe(withdrawn, amount * 95 / 100, "full withdrawal should recover ~all NAV");
        assertEq(receiver.balance, withdrawn, "receiver should get the withdrawn ETH");
        assertLt(strategy.navInETH(), DEPOSIT_AMOUNT * 5 / 100, "only dust should remain");
    }

    // ============ Sync ============

    function test_Fork_Sync_PokesRealPoolFeesIntoTokensOwed() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        (, uint128 owed0Before, uint128 owed1Before) = _mainPositionState();

        uint256 wethOut = _traderSwap(USDT, WETH, FEE_SWAP_USDT_AMOUNT, 0);
        _traderSwap(WETH, USDT, wethOut, 0);

        vm.prank(strategyManager);
        strategy.sync();

        (, uint128 owed0After, uint128 owed1After) = _mainPositionState();
        assertGt(
            uint256(owed0After) + owed1After,
            uint256(owed0Before) + owed1Before,
            "sync should poke accrued swap fees into tokensOwed"
        );
    }

    // ============ Rebalance ============

    function test_Fork_Rebalance_RevertsWhenHealthy() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        assertTrue(strategy.isHealthy());

        vm.prank(strategyManager);
        vm.expectRevert(IStrategy.StrategyIsHealthy.selector);
        strategy.rebalance();
    }

    /**
     * @notice Uses `_alignPoolToTickBoundaryAndSettle()` after the tick move (not just
     *         `_movePoolTickBy`) so the long AND short TWAP fully catch up to the new spot
     *         price before the health check: that makes the pool calm again (deviation ~0
     *         regardless of `MAX_TICK_DEVIATION`), isolating this test to the
     *         `rebalanceTickThreshold` branch of `isHealthy()` — an "unhealthy but calm"
     *         position, the state `rebalance()` exists to fix.
     */
    function test_Fork_Rebalance_RecentersPositionAfterPriceMove() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        (int24 lowerBefore, int24 upperBefore) = strategy.positionMain();
        assertTrue(strategy.isHealthy(), "freshly minted position should be healthy");

        // Move OPPOSITE the `POOL_DETUNE_BPS` detune applied by `_prepareCalmAlignedPool`
        // (which pushed price ~0.5% above the real Chainlink price) rather than stacking on
        // top of it: rebalance's inventory-balancing swap is cross-checked against Chainlink
        // (`UniswapV3ConverterAdapter.MAX_ORACLE_DEVIATION_BPS = 200`, i.e. 2%), and stacking
        // both moves in the same direction pushes the pool >2% from Chainlink, reverting the
        // swap with `UniCLStratQuoteFailed`. Moving the other way partially cancels the
        // detune, keeping the net deviation from Chainlink comfortably under the cap.
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
        assertFalse(strategy.isHealthy(), "not-calm pool should report unhealthy");

        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratNotCalm.selector);
        strategy.rebalance();

        vm.deal(strategyManager, 1 ether);
        vm.prank(strategyManager);
        vm.expectRevert(IUniCLStrat.UniCLStratNotCalm.selector);
        strategy.deposit{value: 1 ether}();
    }

    // ============ Pause / unpause (real USDT approve-race guard) ============

    /**
     * @notice Real USDT's `approve` reverts when moving a non-zero allowance directly to
     *         another non-zero value; only `approve(0)` first, then `approve(newValue)`, is
     *         safe. `forceApprove` (OZ SafeERC20) implements exactly that pattern. This test
     *         proves a pause -> unpause -> pause -> unpause cycle against the REAL USDT
     *         contract never reverts and always leaves the Converter allowance at either 0
     *         (paused) or `type(uint256).max` (unpaused), then that a withdrawal still works.
     */
    function test_Fork_PauseUnpause_RestoresRealUsdtConverterAllowance() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        assertEq(
            IERC20(USDT).allowance(address(strategy), address(converter)),
            type(uint256).max,
            "deploy-time allowance should be max"
        );

        vm.prank(security);
        strategy.pause();
        assertEq(IERC20(USDT).allowance(address(strategy), address(converter)), 0, "pause should revoke USDT allowance");

        vm.prank(admin);
        strategy.unpause();
        assertEq(
            IERC20(USDT).allowance(address(strategy), address(converter)),
            type(uint256).max,
            "unpause should restore max USDT allowance"
        );

        // Second cycle: forceApprove must reset 0 -> max again without USDT's race guard reverting.
        vm.prank(security);
        strategy.pause();
        vm.prank(admin);
        strategy.unpause();
        assertEq(
            IERC20(USDT).allowance(address(strategy), address(converter)),
            type(uint256).max,
            "repeated pause/unpause should keep restoring max USDT allowance"
        );

        _movePoolTickBy(-NOT_CALM_TICK_OFFSET);
        uint256 amount = strategy.maxWithdrawal();
        vm.prank(strategyManager);
        uint256 withdrawn = strategy.withdraw(receiver, amount);
        assertGt(withdrawn, 0, "strategy should still be able to withdraw after repeated pause/unpause");
    }

    // ============ Emergency exit ============

    function test_Fork_EmergencyExit_RevertsWhenNotPaused() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(security);
        vm.expectRevert(IUniCLStrat.UniCLStratNotPaused.selector);
        strategy.emergencyExit();
    }

    /// @dev Exercises the real USDT `transfer` call (no bool return value) via
    ///      `SafeERC20.safeTransfer` inside `emergencyExit()` — the mock-based unit tests can
    ///      only simulate this surface with `MockERC20.setNoReturnTransfer`.
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
        assertGt(usdtOut, 0, "emergency exit should forward the paired token");

        uint256 totalOutInETH = ethOut + oracle.convert(USDT, address(0), usdtOut, USDT_DECIMALS, 18);
        assertApproxEqRel(totalOutInETH, navBefore, NAV_TOLERANCE, "recovered value should match NAV");
        assertLe(strategy.navInETH(), 1e12, "strategy should hold only dust after exit");
    }

    // ============ Converter / adapter path ============

    function test_Fork_Converter_ExactOutputSwapExecutesOnRealPool() public onlyFork {
        _prepareCalmAlignedPool();

        address swapCaller = makeAddr("swapCaller");
        vm.prank(strategyManager);
        converter.grantCallerRole(swapCaller);

        uint256 amountOut = 1_000e6;
        deal(WETH, swapCaller, 2 ether);

        vm.startPrank(swapCaller);
        IERC20(WETH).approve(address(converter), 2 ether);
        uint256 quotedIn = converter.quoteSwapExactAmountOut(address(adapter), wethToUsdtPath, amountOut);
        uint256 spent = converter.executeSwapExactAmountOut(
            address(adapter), wethToUsdtPath, amountOut, quotedIn * 102 / 100, block.timestamp + 15 minutes
        );
        vm.stopPrank();

        assertEq(IERC20(USDT).balanceOf(swapCaller), amountOut, "exact-output should deliver the precise amount");
        assertEq(IERC20(WETH).balanceOf(swapCaller), 2 ether - spent, "unspent input should be refunded");
        assertApproxEqRel(spent, quotedIn, 0.02e18, "spent input should track the TWAP quote");
    }

    // ============ Pool manipulation helpers ============
    //
    // Unlike WETH/USDC (token0 = USDC, token1 = WETH), the WETH/USDT pool sorts WETH BELOW
    // USDT, so token0 = WETH and token1 = USDT. Price (token1/token0) direction and the
    // sqrtPriceX96 conversion are derived from `wethIsToken0` at runtime instead of assuming
    // a fixed ordering, so this file stays correct however a given pool happens to sort.

    function _prepareCalmAlignedPool() internal {
        uint256 oracleEthPrice = oracle.convert(address(0), USDT, 1 ether, 18, USDT_DECIMALS);
        _movePoolSqrtPriceTo(_sqrtPriceX96ForEthPrice(oracleEthPrice * POOL_DETUNE_BPS / BPS));
        _alignPoolToTickBoundaryAndSettle();
    }

    /// @dev Targets the MIDDLE of a tickSpacing bucket rather than its lower edge. Uniswap's
    ///      `getSqrtRatioAtTick`/`getTickAtSqrtRatio` are not exact inverses at a tick's exact
    ///      lower-bound price (a well-known +/-1 rounding ambiguity there): landing precisely
    ///      on a spacing boundary can read back as the bucket one below, which then flips
    ///      which spacing-multiple `floor()` centers the deposited position on. A mid-bucket
    ///      target has slack on both sides, so that +/-1 wobble can never cross a bucket edge.
    function _alignPoolToTickBoundaryAndSettle() internal {
        int24 spacing = pool.tickSpacing();
        int24 target = TickUtils.floor(_currentTick(), spacing) + spacing / 2;
        _movePoolSqrtPriceTo(TickMath.getSqrtRatioAtTick(target));
        vm.warp(block.timestamp + TWAP_INTERVAL + 1);
    }

    function _movePoolTickBy(int24 _tickOffset) internal {
        _movePoolSqrtPriceTo(TickMath.getSqrtRatioAtTick(_currentTick() + _tickOffset));
    }

    function _movePoolSqrtPriceTo(uint160 _targetSqrtPriceX96) internal {
        (uint160 currentSqrtPrice,,,,,,) = pool.slot0();
        if (currentSqrtPrice == _targetSqrtPriceX96) return;

        // price = token1/token0: swapping token0 in decreases price, token1 in increases it.
        if (_targetSqrtPriceX96 < currentSqrtPrice) {
            _swapToken0In(_targetSqrtPriceX96);
        } else {
            _swapToken1In(_targetSqrtPriceX96);
        }

        (currentSqrtPrice,,,,,,) = pool.slot0();
        assertEq(currentSqrtPrice, _targetSqrtPriceX96, "pool should land exactly on the target price");
    }

    function _swapToken0In(uint160 _targetSqrtPriceX96) internal {
        if (wethIsToken0) {
            _traderSwap(WETH, USDT, TRADER_WETH_BUDGET, _targetSqrtPriceX96);
        } else {
            _traderSwap(USDT, WETH, TRADER_USDT_BUDGET, _targetSqrtPriceX96);
        }
    }

    function _swapToken1In(uint160 _targetSqrtPriceX96) internal {
        if (wethIsToken0) {
            _traderSwap(USDT, WETH, TRADER_USDT_BUDGET, _targetSqrtPriceX96);
        } else {
            _traderSwap(WETH, USDT, TRADER_WETH_BUDGET, _targetSqrtPriceX96);
        }
    }

    /// @dev Uses `forceApprove` (not a plain interface `.approve()` call) because real USDT
    ///      returns no data at all from `approve`/`transfer` — decoding the declared `bool`
    ///      return of a direct interface call reverts even though the underlying call
    ///      succeeded. `forceApprove` also resets to 0 before setting a new non-zero value,
    ///      which real USDT requires (its approve-race guard rejects a direct non-zero ->
    ///      non-zero change); `trader`'s allowance to the router may still be non-zero
    ///      (partially consumed) from an earlier swap in the same test.
    function _traderSwap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint160 _sqrtPriceLimitX96)
        internal
        returns (uint256 amountOut)
    {
        deal(_tokenIn, trader, _amountIn);
        vm.startPrank(trader);
        IERC20(_tokenIn).forceApprove(UNIV3_SWAP_ROUTER, _amountIn);
        amountOut = ICanonicalSwapRouter(UNIV3_SWAP_ROUTER).exactInputSingle(
            ICanonicalSwapRouter.ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: POOL_FEE,
                recipient: trader,
                deadline: block.timestamp + 15 minutes,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: _sqrtPriceLimitX96
            })
        );
        vm.stopPrank();
    }

    /// @dev sqrtPriceX96 for a target ETH price expressed in raw paired-token units per 1
    ///      ether, honouring whichever token happens to be token0 in this pool.
    function _sqrtPriceX96ForEthPrice(uint256 _ethPriceInUsdtUnits) internal view returns (uint160) {
        return wethIsToken0
            ? uint160(Math.sqrt(FullMath.mulDiv(_ethPriceInUsdtUnits, 1 << 192, 1e18)))
            : uint160(Math.sqrt(FullMath.mulDiv(1e18, 1 << 192, _ethPriceInUsdtUnits)));
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,,,,) = pool.slot0();
    }

    function _mainPositionState() internal view returns (uint128 liquidity, uint128 owed0, uint128 owed1) {
        (int24 tickLower, int24 tickUpper) = strategy.positionMain();
        bytes32 key = keccak256(abi.encodePacked(address(strategy), tickLower, tickUpper));
        (liquidity,,, owed0, owed1) = pool.positions(key);
    }

    function _deposit(uint256 _amount) internal {
        vm.deal(strategyManager, _amount);
        vm.prank(strategyManager);
        strategy.deposit{value: _amount}();
    }
}
