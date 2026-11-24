// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Registry} from "registry/Registry.sol";
import {AeroCLStrat} from "../src/contracts/strategies/AeroCLStrat.sol";
import {IUniCLStrat} from "../src/interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {ICLFactory} from "../src/interfaces/integrations/aero/ICLFactory.sol";
import {ICLPool} from "../src/interfaces/integrations/aero/ICLPool.sol";
import {IDynamicSwapFeeHook} from "../src/interfaces/integrations/aero/IDynamicSwapFeeHook.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {IStrategyManager} from "../src/interfaces/IStrategyManager.sol";
import {Auth} from "../src/libraries/Auth.sol";

/**
 * @title DeployAeroCLStrat
 * @notice Deploys AeroCLStrat bytecode only. Does **not** call `StrategyManager.addStrategy`.
 *
 * @dev Same prerequisites and go-live flow as `DeployUniCLStrat` (read its NatSpec): the
 *      constructor resolves the Converter from the Registry and validates the route, so the
 *      Converter must be registered and the swap adapter allowlisted (timelocked
 *      `Converter.setAllowedAdapter`) BEFORE this script; `addStrategy` is scheduled on the admin
 *      timelock AFTER it. No Registry role is needed — only a funded deployer key.
 *
 *      Routing: inventory swaps go through the configured Converter route, normally the existing
 *      UniswapV3ConverterAdapter on a deep Uniswap pool (e.g. WETH/USDT 0.05%) — not through the
 *      Aero pool. No Slipstream adapter is needed.
 *
 *      Pre-broadcast probes (fail closed with a readable error instead of a constructor revert):
 *        - provenance: `CLFactory.isPool(pool)` and `getPool(token0, token1, tickSpacing) == pool`;
 *        - TWAP: `pool.observe([interval, 0])` for both windows;
 *        - in-use `observationCardinality` (6-field Slipstream `slot0`) >= ceil(interval / 12) + 1,
 *          floored at 150 (the constructor applies the same rule);
 *        - the paired token has a working USD feed on the protocol Oracle (`isTokenSupported`);
 *          warns when StrategyManager has not whitelisted it, since emergency inventory would
 *          then drop out of NAV.
 *      Fee cap is a **warning, not a failure** by default: it logs the pool's maximum dynamic fee
 *      (swap-fee hook `feeCap`, or the static `fee()` when no hook is attached) and warns when it
 *      sits at or above `FEE_CAP_BUDGET_BPS` (100 bps, leaving the other half of the 200 bps quote
 *      band for TWAP-vs-Chainlink drift). Only the hook (or static) cap is read; Aero fee modules
 *      that apply on top of it are not modelled. Our inventory swaps route through the configured
 *      Converter route (a Uniswap pool), never through the Aero pool, so the cap only matters if a
 *      route is later pointed at this pool. Aero has already raised the WETH/USDT cap to the 5%
 *      factory default once, which broke the strict check; set `STRICT_FEE_CAP=true` to fail instead.
 *      `STRICT_FEE_CAP` must be unset, `true` or `false`; any other value stops the script. A Converter route through this pool is only allowed
 *      once this check passes under `STRICT_FEE_CAP=true` (docs/STRATEGY_GUARDRAILS.md §1.1.2).
 *      Also logs the pool's `unstakedFee` — the share of swap fees unstaked LPs (this strategy)
 *      forgo; 0 on Ethereum mainnet at launch, governance-adjustable.
 *
 *      Size `MAX_TOTAL_NAV` against the pool's depth: Aero pools are far thinner than their
 *      Uniswap counterparts (issue #55: start at ~10-20 ETH, not the 500 ETH UniCLStrat size).
 *      The script logs the pool's WETH balance and warns when `MAX_TOTAL_NAV` exceeds
 *      `MAX_NAV_POOL_WETH_SHARE_BPS` (15%) of it. 20 ETH against ~170 WETH at launch is ~12%.
 *
 *      Env: PRIVATE_KEY, REGISTRY_ADDRESS, WETH_ADDRESS, POOL_ADDRESS (Aero CL pool),
 *      AERO_CL_FACTORY, SWAP_ADAPTER_ADDRESS, WETH_TO_PAIRED_TOKEN_PATH, PAIRED_TOKEN_TO_WETH_PATH,
 *      EXIT_ROUTE_FEE_PIPS (estimated paired-token to WETH route fee in parts per million, 500 for a
 *      0.05% fee; marks the paired-token share of NAV down by the expected exit cost), POSITION_WIDTH, REBALANCE_TICK_THRESHOLD, MAX_TICK_DEVIATION, TWAP_INTERVAL,
 *      SHORT_TWAP_INTERVAL, MAX_TOTAL_NAV. Integer env values are range-checked before narrowing.
 *
 *      After deployment, record the linked library addresses (`CLStratLib`, `CLRangeLib`,
 *      `CLPositionLib`) from the broadcast file's `libraries` entry and verify them alongside the
 *      strategy; a second deployment from the same forge setup reuses them.
 */
contract DeployAeroCLStrat is Script {
    // Mirrors of AeroCLStrat constants (checked against the deployed contract below).
    uint32 internal constant MIN_TWAP_INTERVAL = 1800;
    uint32 internal constant MIN_SHORT_TWAP_INTERVAL = 60;
    uint32 internal constant MAX_BLOCK_SECONDS = 12;
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 150;
    uint32 internal constant MAX_TWAP_INTERVAL = uint32(type(uint16).max) * MAX_BLOCK_SECONDS;
    uint256 internal constant MAX_QUOTE_DEVIATION_BPS = 200;
    /// @dev Fee-cap budget inside the quote band: the other 100 bps is left for oracle drift.
    uint256 internal constant FEE_CAP_BUDGET_BPS = 100;
    /// @dev Pool fees are in pips (1e-6): 1 bps = 100 pips.
    uint256 internal constant PIPS_PER_BPS = 100;
    uint256 internal constant BASIS_POINTS = 10_000;
    /// @dev Warn when MAX_TOTAL_NAV exceeds this share of the pool's WETH balance.
    uint256 internal constant MAX_NAV_POOL_WETH_SHARE_BPS = 1_500;

    function run() external returns (AeroCLStrat aeroCLStrat) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        IUniCLStrat.DeploymentConfig memory config = _deploymentConfig();
        Registry registry = Registry(config.addresses.registry);
        address strategyManagerAddress = Auth.strategyManager(registry);

        console.log("Deploying AeroCLStrat with deployer:", deployer);
        console.log("Registry:", config.addresses.registry);
        console.log("StrategyManager (from Registry):", strategyManagerAddress);
        console.log("Aero pool:", config.addresses.pool);
        console.log("NOTE: this script does not call addStrategy; schedule registration on the admin timelock");

        vm.startBroadcast(deployerPrivateKey);

        aeroCLStrat = new AeroCLStrat(config);

        vm.stopBroadcast();

        require(
            address(aeroCLStrat.registry()) == config.addresses.registry, "CRITICAL: AeroCLStrat registry() mismatch"
        );
        require(
            aeroCLStrat.MIN_TWAP_INTERVAL() == MIN_TWAP_INTERVAL
                && aeroCLStrat.MIN_SHORT_TWAP_INTERVAL() == MIN_SHORT_TWAP_INTERVAL
                && aeroCLStrat.MAX_BLOCK_SECONDS() == MAX_BLOCK_SECONDS
                && aeroCLStrat.MIN_OBSERVATION_CARDINALITY() == MIN_OBSERVATION_CARDINALITY
                && aeroCLStrat.MAX_TWAP_INTERVAL() == MAX_TWAP_INTERVAL
                && aeroCLStrat.MAX_QUOTE_DEVIATION_BPS() == MAX_QUOTE_DEVIATION_BPS,
            "CRITICAL: script mirrors drifted from AeroCLStrat constants"
        );
        require(
            Auth.strategyManager(registry) == strategyManagerAddress, "CRITICAL: Registry STRATEGY_MANAGER mismatch"
        );
        _requireDeployedConfig(aeroCLStrat, config);

        console.log("AeroCLStrat deployed at:", address(aeroCLStrat));
        console.log("Next: schedule StrategyManager.addStrategy on the admin TimelockController");
        console.log("(paired-token feed / addSupportedERC20 usually share the prior allowlist batch).");
    }

    function _deploymentConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        uint32 twapInterval = _envUint32("TWAP_INTERVAL");
        uint32 shortTwapInterval = _envUint32("SHORT_TWAP_INTERVAL");
        address pool = vm.envAddress("POOL_ADDRESS");
        address factory = vm.envAddress("AERO_CL_FACTORY");
        address registry = vm.envAddress("REGISTRY_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");

        require(twapInterval >= MIN_TWAP_INTERVAL, "TWAP_INTERVAL below MIN_TWAP_INTERVAL");
        require(twapInterval <= MAX_TWAP_INTERVAL, "TWAP_INTERVAL above MAX_TWAP_INTERVAL");
        require(shortTwapInterval >= MIN_SHORT_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL below MIN_SHORT_TWAP_INTERVAL");
        require(shortTwapInterval <= MAX_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL above MAX_TWAP_INTERVAL");
        require(shortTwapInterval < twapInterval, "SHORT_TWAP_INTERVAL must be below TWAP_INTERVAL");
        _requireAeroProvenance(factory, pool);
        _requirePoolCanServeTwap(pool, twapInterval, "TWAP_INTERVAL");
        _requirePoolCanServeTwap(pool, shortTwapInterval, "SHORT_TWAP_INTERVAL");
        _requirePoolObservationCardinality(pool, twapInterval);
        _requirePoolObservationCardinality(pool, shortTwapInterval);
        _checkFeeCapWithinQuoteBudget(factory, pool, _strictFeeCap());
        console.log("Aero pool unstakedFee (pips):", ICLFactory(factory).getUnstakedFee(pool));
        console.log("Aero pool in-range liquidity:", ICLPool(pool).liquidity());
        _warnIfMaxNavLargeVsPoolDepth(pool, weth, vm.envUint("MAX_TOTAL_NAV"));
        _requirePairedTokenPriced(registry, pool, weth);

        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: registry,
                weth: weth,
                pool: pool,
                factory: factory
            }),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: vm.envAddress("SWAP_ADAPTER_ADDRESS"),
                wethToPairedTokenPath: vm.envBytes("WETH_TO_PAIRED_TOKEN_PATH"),
                pairedTokenToWethPath: vm.envBytes("PAIRED_TOKEN_TO_WETH_PATH"),
                exitRouteFeePips: vm.envUint("EXIT_ROUTE_FEE_PIPS")
            }),
            strategy: IUniCLStrat.StrategyConfig({
                positionWidth: _envInt24("POSITION_WIDTH"),
                rebalanceTickThreshold: _envInt24("REBALANCE_TICK_THRESHOLD"),
                maxTickDeviation: int56(_envInt24("MAX_TICK_DEVIATION")),
                twapInterval: twapInterval,
                shortTwapInterval: shortTwapInterval,
                maxTotalNAV: vm.envUint("MAX_TOTAL_NAV")
            })
        });
    }

    /// @dev Same check the constructor makes (tick-spacing-keyed `getPool`), plus `isPool`.
    function _requireAeroProvenance(address factory, address pool) internal view {
        require(ICLFactory(factory).isPool(pool), "POOL_ADDRESS is not an Aero CLFactory pool");
        ICLPool clPool = ICLPool(pool);
        require(
            ICLFactory(factory).getPool(clPool.token0(), clPool.token1(), clPool.tickSpacing()) == pool,
            "CLFactory.getPool(token0, token1, tickSpacing) != POOL_ADDRESS"
        );
    }

    function _requirePoolCanServeTwap(address pool, uint32 interval, string memory label) internal view {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = interval;
        secondsAgos[1] = 0;
        // `observe` is ABI-identical to Uniswap V3, so it goes through `IUniswapV3Pool` like the strategy.
        try IUniswapV3Pool(pool).observe(secondsAgos) returns (int56[] memory, uint160[] memory) {}
        catch {
            revert(
                string.concat(
                    "pool.observe cannot serve ",
                    label,
                    "; grow observation cardinality and wait for fill before deploy"
                )
            );
        }
    }

    /// @dev In-use `observationCardinality` (6-field Slipstream `slot0`, not Next).
    function _requirePoolObservationCardinality(address pool, uint32 interval) internal view {
        (,,, uint16 cardinality,,) = ICLPool(pool).slot0();
        uint256 required = (uint256(interval) + MAX_BLOCK_SECONDS - 1) / MAX_BLOCK_SECONDS + 1;
        if (required < MIN_OBSERVATION_CARDINALITY) required = MIN_OBSERVATION_CARDINALITY;
        require(required <= type(uint16).max, "TWAP window exceeds uint16 observation ring");
        require(
            cardinality >= uint16(required),
            "pool observationCardinality below ceil(interval/MAX_BLOCK_SECONDS) + 1; grow and wait for fill"
        );
    }

    /// @dev Logs the pool's maximum dynamic fee and warns when it does not fit the quote budget.
    ///      Failure only under `STRICT_FEE_CAP=true`: inventory swaps route through the Converter (a
    ///      Uniswap pool), so a wide Aero cap is harmless unless a route is pointed at this pool.
    function _checkFeeCapWithinQuoteBudget(address factory, address pool, bool strict) internal view {
        address hook = ICLFactory(factory).getPoolSwapHook(pool);
        uint256 feeCap;
        if (hook == address(0)) {
            feeCap = ICLPool(pool).fee();
        } else {
            (, uint24 cap,,,) = IDynamicSwapFeeHook(hook).dynamicFeeConfig(pool);
            feeCap = cap;
        }
        console.log("Aero pool max swap fee (pips):", feeCap);

        uint256 budget = FEE_CAP_BUDGET_BPS * PIPS_PER_BPS;
        if (feeCap < budget) return;

        if (strict) revert("Aero pool fee cap does not fit inside FEE_CAP_BUDGET_BPS");

        console.log("WARNING: pool fee cap (pips) >= quote budget; fine while routes skip this pool, but");
        console.log("set STRICT_FEE_CAP=true to enforce, or keep routes off this pool.");
    }

    /// @dev Warning only: a thin pool makes every re-center and withdrawal move the price more, and
    ///      a cap that is a large share of the pool's WETH side means the strategy is most of the
    ///      in-range liquidity. Size against `IERC20(weth).balanceOf(pool)` at deploy time.
    function _warnIfMaxNavLargeVsPoolDepth(address pool, address weth, uint256 maxTotalNAV)
        internal
        view
        returns (bool warned)
    {
        uint256 poolWeth = IERC20(weth).balanceOf(pool);
        console.log("Aero pool WETH balance (wei):", poolWeth);
        console.log("MAX_TOTAL_NAV (wei):", maxTotalNAV);

        // Divide rather than multiply MAX_TOTAL_NAV, so a huge value cannot overflow the check.
        if (maxTotalNAV <= poolWeth / BASIS_POINTS * MAX_NAV_POOL_WETH_SHARE_BPS) return false;

        console.log("WARNING: MAX_TOTAL_NAV is above 15% of the pool's WETH balance (bps of pool WETH):");
        console.log(poolWeth < BASIS_POINTS ? type(uint256).max : maxTotalNAV / (poolWeth / BASIS_POINTS));
        console.log("Aero pools are thin; start at ~10-20 ETH (docs/STRATEGY_GUARDRAILS.md section 1.1.2).");
        return true;
    }

    /// @dev The strategy prices its paired token through the Oracle on every NAV read, so a missing
    ///      feed would brick NAV after registration. StrategyManager whitelisting is optional but keeps
    ///      emergency-exit inventory in NAV and recoverable, so its absence is logged.
    function _requirePairedTokenPriced(address registry, address pool, address weth) internal view {
        address token0 = ICLPool(pool).token0();
        address paired = token0 == weth ? ICLPool(pool).token1() : token0;
        IOracle oracle = IOracle(Auth.oracle(Registry(registry)));
        require(oracle.isTokenSupported(paired), "paired token has no USD feed on the Oracle");
        if (!IStrategyManager(Auth.strategyManager(Registry(registry))).isSupportedERC20(paired)) {
            console.log("WARNING: paired token is not a StrategyManager supported ERC-20; schedule addSupportedERC20");
        }
    }

    /// @dev Reads back every constructor parameter from the deployed strategy.
    function _requireDeployedConfig(AeroCLStrat strategy, IUniCLStrat.DeploymentConfig memory config) internal view {
        require(address(strategy.weth()) == config.addresses.weth, "CRITICAL: weth mismatch");
        require(address(strategy.pool()) == config.addresses.pool, "CRITICAL: pool mismatch");
        require(strategy.factory() == config.addresses.factory, "CRITICAL: factory mismatch");
        require(strategy.swapAdapter() == config.routes.swapAdapter, "CRITICAL: swapAdapter mismatch");
        require(
            keccak256(strategy.wethToPairedTokenPath()) == keccak256(config.routes.wethToPairedTokenPath),
            "CRITICAL: wethToPairedTokenPath mismatch"
        );
        require(
            keccak256(strategy.pairedTokenToWethPath()) == keccak256(config.routes.pairedTokenToWethPath),
            "CRITICAL: pairedTokenToWethPath mismatch"
        );
        require(strategy.exitRouteFeePips() == config.routes.exitRouteFeePips, "CRITICAL: exitRouteFeePips mismatch");
        require(strategy.positionWidth() == config.strategy.positionWidth, "CRITICAL: positionWidth mismatch");
        require(
            strategy.rebalanceTickThreshold() == config.strategy.rebalanceTickThreshold,
            "CRITICAL: rebalanceTickThreshold mismatch"
        );
        require(strategy.maxTickDeviation() == config.strategy.maxTickDeviation, "CRITICAL: maxTickDeviation mismatch");
        require(strategy.twapInterval() == config.strategy.twapInterval, "CRITICAL: twapInterval mismatch");
        require(
            strategy.shortTwapInterval() == config.strategy.shortTwapInterval, "CRITICAL: shortTwapInterval mismatch"
        );
        require(strategy.maxTotalNAV() == config.strategy.maxTotalNAV, "CRITICAL: maxTotalNAV mismatch");
    }

    /// @dev Only `true`, `false` or unset (false) are accepted.
    function _strictFeeCap() internal view returns (bool) {
        string memory value = vm.envOr("STRICT_FEE_CAP", string("false"));
        bytes32 hash = keccak256(bytes(value));
        if (hash == keccak256("true")) return true;
        require(hash == keccak256("false"), "STRICT_FEE_CAP must be true or false");
        return false;
    }

    function _envUint32(string memory name) internal view returns (uint32) {
        uint256 value = vm.envUint(name);
        require(value <= type(uint32).max, string.concat(name, " does not fit uint32"));
        return uint32(value);
    }

    function _envInt24(string memory name) internal view returns (int24) {
        int256 value = vm.envInt(name);
        require(value >= type(int24).min && value <= type(int24).max, string.concat(name, " does not fit int24"));
        return int24(value);
    }
}
