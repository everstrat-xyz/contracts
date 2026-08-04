// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
// solhint-disable gas-small-strings, max-states-count
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {IUniswapV3Router} from "../../src/interfaces/integrations/uniswap/IUniswapV3Router.sol";
import {FullMath} from "../../src/libraries/integrations/uniswap/FullMath.sol";
import {TickMath} from "../../src/libraries/integrations/uniswap/TickMath.sol";
import {TickUtils} from "../../src/libraries/integrations/uniswap/TickUtils.sol";

import {MockStrategyManagerStub} from "../mocks/MockStrategyManagerStub.sol";
import {ICanonicalSwapRouter} from "./helpers/UniswapV3ForkHelpers.sol";

/**
 * @title UniCLStratForkTest
 * @notice Ethereum mainnet fork tests for UniCLStrat and its Converter /
 *         UniswapV3ConverterAdapter path against the real Uniswap V3 WETH/USDC 0.05% pool
 *         and real Chainlink ETH/USD + USDC/USD feeds.
 *
 * @dev Run: MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path 'test/fork/*'
 *      Optionally pin a block: MAINNET_FORK_BLOCK=<number>
 *      When MAINNET_RPC_URL is unset, tests skip so offline `forge test` stays green.
 */
contract UniCLStratForkTest is Test {
    // ============ Mainnet addresses ============

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant UNIV3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant WETH_USDC_POOL_005 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    uint24 internal constant POOL_FEE = 500;
    uint8 internal constant USDC_DECIMALS = 6;

    // ============ Strategy configuration ============

    uint256 internal constant MAX_TOTAL_NAV = 100 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 0.5 ether;
    uint256 internal constant PARTIAL_WITHDRAW_AMOUNT = 0.15 ether;
    int24 internal constant POSITION_WIDTH = 40;
    int24 internal constant REBALANCE_TICK_THRESHOLD = 10;
    int56 internal constant MAX_TICK_DEVIATION = 60;
    uint32 internal constant TWAP_INTERVAL = 1800;
    uint32 internal constant SHORT_TWAP_INTERVAL = 60;
    uint256 internal constant STALENESS_INTERVAL = 30 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant POOL_DETUNE_BPS = 10_050;
    int24 internal constant NOT_CALM_TICK_OFFSET = 70;
    int24 internal constant REBALANCE_TICK_OFFSET = 25;
    uint256 internal constant NAV_TOLERANCE = 0.03e18; // 3%
    uint256 internal constant WITHDRAW_TOLERANCE = 0.04e18; // 4%
    uint256 internal constant TRADER_USDC_BUDGET = 100_000_000_000e6;
    uint256 internal constant TRADER_WETH_BUDGET = 30_000_000e18;
    uint256 internal constant FEE_SWAP_USDC_AMOUNT = 200_000e6;

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
    IUniswapV3Pool internal pool = IUniswapV3Pool(WETH_USDC_POOL_005);
    bytes internal wethToUsdcPath;
    bytes internal usdcToWethPath;

    modifier onlyFork() {
        if (!forkAvailable) vm.skip(true);
        _;
    }

    receive() external payable {}

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }
        forkAvailable = true;

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

        wethToUsdcPath = abi.encodePacked(WETH, POOL_FEE, USDC);
        usdcToWethPath = abi.encodePacked(USDC, POOL_FEE, WETH);

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
        oracle.updateUsdFeedInfo(USDC, CHAINLINK_USDC_USD, STALENESS_INTERVAL);
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
            addresses: IUniCLStrat.AddressConfig({registry: address(registry), weth: WETH, pool: WETH_USDC_POOL_005}),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: address(adapter),
                wethToPairedTokenPath: wethToUsdcPath,
                pairedTokenToWethPath: usdcToWethPath
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

    function test_Fork_Deposit_SucceedsWhenSpotDriftsBelowTwap() public onlyFork {
        _prepareCalmAlignedPool();

        uint256 usdcSeed = oracle.convert(address(0), USDC, DEPOSIT_AMOUNT * 12 / 10, 18, USDC_DECIMALS);
        deal(USDC, address(strategy), usdcSeed);

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

        uint256 wethOut = _traderSwap(USDC, WETH, FEE_SWAP_USDC_AMOUNT, 0);
        _traderSwap(WETH, USDC, wethOut, 0);

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

    function test_Fork_Rebalance_RecentersPositionAfterPriceMove() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);
        (int24 lowerBefore, int24 tickUpperBefore) = strategy.positionMain();

        _movePoolTickBy(REBALANCE_TICK_OFFSET);
        _alignPoolToTickBoundaryAndSettle();

        assertFalse(strategy.isHealthy(), "drifted position should be unhealthy");
        assertGt(strategy.maxDeposit(), 0, "pool should still be calm");

        vm.prank(strategyManager);
        strategy.rebalance();

        (int24 lowerAfter, int24 upperAfter) = strategy.positionMain();
        assertTrue(lowerAfter != lowerBefore || upperAfter != tickUpperBefore, "main position should move");
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

    // ============ Emergency exit ============

    function test_Fork_EmergencyExit_RevertsWhenNotPaused() public onlyFork {
        _prepareCalmAlignedPool();
        _deposit(DEPOSIT_AMOUNT);

        vm.prank(security);
        vm.expectRevert(IUniCLStrat.UniCLStratNotPaused.selector);
        strategy.emergencyExit();
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
        uint256 usdcOut = IERC20(USDC).balanceOf(strategyManager);
        assertGt(ethOut, 0, "emergency exit should forward unwrapped ETH");
        assertGt(usdcOut, 0, "emergency exit should forward the paired token");

        uint256 totalOutInETH = ethOut + oracle.convert(USDC, address(0), usdcOut, USDC_DECIMALS, 18);
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
        uint256 quotedIn = converter.quoteSwapExactAmountOut(address(adapter), wethToUsdcPath, amountOut);
        uint256 spent = converter.executeSwapExactAmountOut(
            address(adapter), wethToUsdcPath, amountOut, quotedIn * 102 / 100, block.timestamp + 15 minutes
        );
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(swapCaller), amountOut, "exact-output should deliver the precise amount");
        assertEq(IERC20(WETH).balanceOf(swapCaller), 2 ether - spent, "unspent input should be refunded");
        assertApproxEqRel(spent, quotedIn, 0.02e18, "spent input should track the TWAP quote");
    }

    function test_Fork_ProtocolRouterInterfaceMatchesCanonicalRouter() public onlyFork {
        deal(WETH, trader, 2 ether);

        vm.startPrank(trader);
        IERC20(WETH).approve(UNIV3_SWAP_ROUTER, 2 ether);

        uint256 amountOut = IUniswapV3Router(UNIV3_SWAP_ROUTER).exactInput(
            IUniswapV3Router.ExactInputParams({
                path: wethToUsdcPath,
                recipient: trader,
                deadline: block.timestamp + 15 minutes,
                amountIn: 1 ether,
                amountOutMinimum: 0
            })
        );
        assertGt(amountOut, 0, "protocol router interface should swap on mainnet");
        vm.stopPrank();
    }

    // ============ Pool manipulation helpers ============

    function _prepareCalmAlignedPool() internal {
        uint256 oracleEthPrice = oracle.convert(address(0), USDC, 1 ether, 18, USDC_DECIMALS);
        _movePoolSqrtPriceTo(_sqrtPriceX96ForEthPrice(oracleEthPrice * POOL_DETUNE_BPS / BPS));
        _alignPoolToTickBoundaryAndSettle();
    }

    function _alignPoolToTickBoundaryAndSettle() internal {
        _movePoolSqrtPriceTo(TickMath.getSqrtRatioAtTick(TickUtils.floor(_currentTick(), pool.tickSpacing())));
        vm.warp(block.timestamp + TWAP_INTERVAL + 1);
    }

    function _movePoolTickBy(int24 _tickOffset) internal {
        _movePoolSqrtPriceTo(TickMath.getSqrtRatioAtTick(_currentTick() + _tickOffset));
    }

    function _movePoolSqrtPriceTo(uint160 _targetSqrtPriceX96) internal {
        (uint160 currentSqrtPrice,,,,,,) = pool.slot0();
        if (currentSqrtPrice == _targetSqrtPriceX96) return;

        if (_targetSqrtPriceX96 < currentSqrtPrice) {
            _traderSwap(USDC, WETH, TRADER_USDC_BUDGET, _targetSqrtPriceX96);
        } else {
            _traderSwap(WETH, USDC, TRADER_WETH_BUDGET, _targetSqrtPriceX96);
        }

        (currentSqrtPrice,,,,,,) = pool.slot0();
        assertEq(currentSqrtPrice, _targetSqrtPriceX96, "pool should land exactly on the target price");
    }

    function _traderSwap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint160 _sqrtPriceLimitX96)
        internal
        returns (uint256 amountOut)
    {
        deal(_tokenIn, trader, _amountIn);
        vm.startPrank(trader);
        IERC20(_tokenIn).approve(UNIV3_SWAP_ROUTER, _amountIn);
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

    function _sqrtPriceX96ForEthPrice(uint256 _ethPriceInUsdcUnits) internal pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(1e18, 1 << 192, _ethPriceInUsdcUnits)));
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
