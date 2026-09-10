// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
// solhint-disable gas-small-strings, max-states-count
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Registry} from "registry/Registry.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {Converter} from "../../src/contracts/Converter.sol";
import {UniswapV3ConverterAdapter} from "../../src/contracts/adapters/UniswapV3ConverterAdapter.sol";
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {TickUtils} from "../../src/libraries/integrations/uniswap/TickUtils.sol";

import {MockStrategyManagerStub} from "../mocks/MockStrategyManagerStub.sol";

/**
 * @title UniCLStratBootstrapParamsTest
 * @notice Validates the mainnet bootstrap parameter set documented in
 *         `docs/reports/2026-09-09-uniclstrat-bootstrap-parameters.md` against real
 *         mainnet pool state, so a bad parameter set fails in CI rather than at deploy.
 *
 * @dev Covers, for each candidate pool:
 *        - constructor acceptance (WETH in pair, factory provenance, TWAP availability,
 *          observation cardinality floor) at the documented TWAP windows;
 *        - the tick brackets the strategy will actually mint, which are
 *          `TickUtils.baseTicks(floor(tick, spacing) +/- positionWidth * spacing)` and are
 *          therefore always tickSpacing-aligned — a raw `tick +/- width` bracket is not;
 *        - the deployment prerequisite that the paired token is Oracle-priceable, which
 *          both `navInETH()` and `StrategyManager.addSupportedERC20()` depend on.
 *
 *      Run:
 *        MAINNET_RPC_URL=... MAINNET_FORK_BLOCK=<n> forge test --match-path 'test/fork/*'
 *      Skips when MAINNET_RPC_URL is unset so offline `forge test` stays green.
 */
contract UniCLStratBootstrapParamsTest is Test {
    // ============ Mainnet addresses ============

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant UNIV3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Candidate LP pools (report section 3)
    address internal constant POOL_A_WETH_USDT_030 = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36;
    address internal constant POOL_B_USDC_WETH_030 = 0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8;
    address internal constant POOL_C_USDC_WETH_001 = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;

    // Swap-route pools (report section 5)
    uint24 internal constant ROUTE_FEE = 500;

    address internal constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant CHAINLINK_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    // ============ Documented parameters ============

    int56 internal constant MAX_TICK_DEVIATION = 100;
    uint32 internal constant TWAP_INTERVAL = 1800;
    uint32 internal constant SHORT_TWAP_INTERVAL = 60;
    uint256 internal constant STALENESS_INTERVAL = 30 days;

    /// @dev Target half-width in ticks: ln(1.20)/ln(1.0001) ~= 1823.
    int24 internal constant TARGET_HALF_WIDTH_TICKS = 1823;
    /// @dev Rounding `positionWidth` to whole tickSpacings costs at most one spacing.
    int24 internal constant WIDTH_TOLERANCE_TICKS = 60;

    // ============ State ============

    Registry internal registry;
    Oracle internal oracle;
    Converter internal converter;
    UniswapV3ConverterAdapter internal adapter;
    address internal strategyManager;
    address internal admin = makeAddr("admin");

    bool internal forkAvailable;

    modifier onlyFork() {
        if (!forkAvailable) return;
        _;
    }

    function setUp() public {
        if (!vm.envExists("MAINNET_RPC_URL")) return;

        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        uint256 forkBlock = vm.envUint("MAINNET_FORK_BLOCK");
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

        oracle = Oracle(
            address(
                new ERC1967Proxy(
                    address(new Oracle()), abi.encodeWithSelector(Oracle.initialize.selector, address(registry))
                )
            )
        );

        converter = Converter(
            payable(
                new ERC1967Proxy(
                    address(new Converter()),
                    abi.encodeWithSelector(Converter.initialize.selector, address(registry), WETH)
                )
            )
        );

        adapter = new UniswapV3ConverterAdapter(UNIV3_SWAP_ROUTER, UNIV3_FACTORY, address(oracle), WETH, TWAP_INTERVAL);

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

        // Deployment prerequisite: every leg the strategies price must be USD-supported.
        oracle.updateUsdFeedInfo(address(0), CHAINLINK_ETH_USD, STALENESS_INTERVAL);
        oracle.updateUsdFeedInfo(USDC, CHAINLINK_USDC_USD, STALENESS_INTERVAL);
        oracle.updateUsdFeedInfo(USDT, CHAINLINK_USDT_USD, STALENESS_INTERVAL);
        converter.setAllowedAdapter(address(adapter), true);
        vm.stopPrank();
    }

    // ============ Helpers ============

    function _config(address _pool, address _paired, int24 _positionWidth, int24 _rebalanceTickThreshold)
        internal
        view
        returns (IUniCLStrat.DeploymentConfig memory)
    {
        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: address(registry),
                weth: WETH,
                pool: _pool,
                factory: UNIV3_FACTORY
            }),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: address(adapter),
                wethToPairedTokenPath: abi.encodePacked(WETH, ROUTE_FEE, _paired),
                pairedTokenToWethPath: abi.encodePacked(_paired, ROUTE_FEE, WETH)
            }),
            strategy: IUniCLStrat.StrategyConfig({
                positionWidth: _positionWidth,
                rebalanceTickThreshold: _rebalanceTickThreshold,
                maxTickDeviation: MAX_TICK_DEVIATION,
                twapInterval: TWAP_INTERVAL,
                shortTwapInterval: SHORT_TWAP_INTERVAL,
                maxTotalNAV: 1_000 ether
            })
        });
    }

    /// @dev Asserts one documented parameter row deploys and brackets as documented.
    function _assertParameterSet(address _pool, address _paired, int24 _positionWidth, int24 _rebalanceTickThreshold)
        internal
    {
        IUniswapV3Pool pool = IUniswapV3Pool(_pool);
        int24 spacing = pool.tickSpacing();

        // Constructor enforces WETH-in-pair, factory provenance, TWAP availability and
        // the observation-cardinality floor. A revert here is a rejected parameter set.
        UniCLStrat strategy = new UniCLStrat(_config(_pool, _paired, _positionWidth, _rebalanceTickThreshold));

        assertEq(strategy.positionWidth(), _positionWidth, "positionWidth");
        assertEq(strategy.rebalanceTickThreshold(), _rebalanceTickThreshold, "rebalanceTickThreshold");
        assertEq(strategy.tickSpacing(), spacing, "tickSpacing");

        // positionWidth is a MULTIPLIER of tickSpacing, so the realised half-width must
        // land within one spacing of the intended target.
        int24 halfWidth = _positionWidth * spacing;
        int24 delta = halfWidth > TARGET_HALF_WIDTH_TICKS
            ? halfWidth - TARGET_HALF_WIDTH_TICKS
            : TARGET_HALF_WIDTH_TICKS - halfWidth;
        assertLe(uint256(uint24(delta)), uint256(uint24(WIDTH_TOLERANCE_TICKS)), "half-width off target");

        // The bracket the strategy will mint is centred on the FLOORED tick, so both
        // bounds are tickSpacing-aligned. `tick +/- halfWidth` generally is not.
        (, int24 tick,,,,,) = pool.slot0();
        (int24 tickLower, int24 tickUpper) = TickUtils.baseTicks(tick, halfWidth, spacing);

        assertEq(tickLower % spacing, 0, "tickLower not spacing-aligned");
        assertEq(tickUpper % spacing, 0, "tickUpper not spacing-aligned");
        assertEq(tickUpper - tickLower, 2 * halfWidth, "bracket width");
        assertEq((tickLower + tickUpper) / 2, TickUtils.floor(tick, spacing), "bracket not centred on floored tick");
        assertLe(tickLower, tick, "tick below bracket");
        assertLe(tick, tickUpper, "tick above bracket");

        // Prerequisite for navInETH() and StrategyManager.addSupportedERC20().
        assertTrue(oracle.isTokenSupported(_paired), "paired token not Oracle-priceable");

        // NAV must compute at deploy time (fail-closed on a missing TWAP or feed).
        assertEq(strategy.navInETH(), 0, "fresh strategy NAV");
    }

    // ============ Strategy A - WETH/USDT 0.3% ============

    function test_Fork_BootstrapParams_StrategyA_WethUsdt030() public onlyFork {
        _assertParameterSet(POOL_A_WETH_USDT_030, USDT, 30, 900);
    }

    // ============ Strategy B - USDC/WETH 0.3% ============

    function test_Fork_BootstrapParams_StrategyB_UsdcWeth030() public onlyFork {
        _assertParameterSet(POOL_B_USDC_WETH_030, USDC, 30, 900);
    }

    // ============ Strategy C - USDC/WETH 0.01% ============

    function test_Fork_BootstrapParams_StrategyC_UsdcWeth001() public onlyFork {
        _assertParameterSet(POOL_C_USDC_WETH_001, USDC, 1823, 911);
    }

    // ============ Regression: the report's original bracket arithmetic ============

    /**
     * @notice A raw `tick +/- width` bracket is not mintable on a 60-spacing pool.
     * @dev Guards the documentation error this test suite was written to catch: the
     *      first revision of the bootstrap report published `tick +/- width` brackets
     *      for the two 0.3% pools, which Uniswap V3 would reject.
     */
    function test_Fork_BootstrapParams_RawTickBracketIsNotSpacingAligned() public onlyFork {
        int24[2] memory widths = [int24(1800), int24(1800)];
        address[2] memory pools = [POOL_A_WETH_USDT_030, POOL_B_USDC_WETH_030];

        for (uint256 i; i < pools.length; ++i) {
            IUniswapV3Pool pool = IUniswapV3Pool(pools[i]);
            int24 spacing = pool.tickSpacing();
            (, int24 tick,,,,,) = pool.slot0();

            // Only aligned by coincidence when tick is already a multiple of spacing.
            if (tick % spacing != 0) {
                assertTrue((tick - widths[i]) % spacing != 0, "raw lower unexpectedly aligned");
            }

            (int24 tickLower, int24 tickUpper) = TickUtils.baseTicks(tick, widths[i], spacing);
            assertEq(tickLower % spacing, 0, "library lower aligned");
            assertEq(tickUpper % spacing, 0, "library upper aligned");
        }
    }
}
