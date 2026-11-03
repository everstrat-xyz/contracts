// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {AeroCLStrat} from "../src/contracts/strategies/AeroCLStrat.sol";
import {IUniCLStrat} from "../src/interfaces/strategies/IUniCLStrat.sol";
import {ICLFactory} from "../src/interfaces/integrations/aero/ICLFactory.sol";
import {ICLPool} from "../src/interfaces/integrations/aero/ICLPool.sol";
import {IDynamicSwapFeeHook} from "../src/interfaces/integrations/aero/IDynamicSwapFeeHook.sol";
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
 *        - in-use `observationCardinality` (6-field Slipstream `slot0`) >= ceil(interval / 12),
 *          floored at 150.
 *      Fee cap is a **warning, not a failure** by default: it logs the pool's maximum dynamic fee
 *      (swap-fee hook `feeCap`, or the static `fee()` when no hook is attached) and warns when it
 *      sits at or above `MAX_QUOTE_DEVIATION_BPS`. Our inventory swaps route through the configured
 *      Converter route (a Uniswap pool), never through the Aero pool, so the cap only matters if a
 *      route is later pointed at this pool. Aero has already raised the WETH/USDT cap to the 5%
 *      factory default once, which broke the strict check; set `STRICT_FEE_CAP=true` to fail instead.
 *      (`vm.envOr` parses `true`/`false` case-insensitively, plus `1`/`0`; any other value, e.g.
 *      `yes`, silently falls back to `false`.) A Converter route through this pool is only allowed
 *      once this check passes under `STRICT_FEE_CAP=true` (docs/STRATEGY_GUARDRAILS.md §1.1.2).
 *      Also logs the pool's `unstakedFee` — the share of swap fees unstaked LPs (this strategy)
 *      forgo; 0 on Ethereum mainnet at launch, governance-adjustable.
 *
 *      Size `MAX_TOTAL_NAV` against the pool's depth: Aero pools are far thinner than their
 *      Uniswap counterparts (issue #55: start at ~10-20 ETH, not the 500 ETH UniCLStrat size).
 *
 *      Env: PRIVATE_KEY, REGISTRY_ADDRESS, WETH_ADDRESS, POOL_ADDRESS (Aero CL pool),
 *      AERO_CL_FACTORY, SWAP_ADAPTER_ADDRESS, WETH_TO_PAIRED_TOKEN_PATH, PAIRED_TOKEN_TO_WETH_PATH,
 *      POSITION_WIDTH, REBALANCE_TICK_THRESHOLD, MAX_TICK_DEVIATION, TWAP_INTERVAL,
 *      SHORT_TWAP_INTERVAL, MAX_TOTAL_NAV.
 */
contract DeployAeroCLStrat is Script {
    // Mirrors of AeroCLStrat constants (checked against the deployed contract below).
    uint32 internal constant MIN_TWAP_INTERVAL = 1800;
    uint32 internal constant MIN_SHORT_TWAP_INTERVAL = 60;
    uint32 internal constant MAX_BLOCK_SECONDS = 12;
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 150;
    uint32 internal constant MAX_TWAP_INTERVAL = uint32(type(uint16).max) * MAX_BLOCK_SECONDS;
    uint256 internal constant MAX_QUOTE_DEVIATION_BPS = 200;
    /// @dev Pool fees are in pips (1e-6): 1 bps = 100 pips.
    uint256 internal constant PIPS_PER_BPS = 100;

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

        console.log("AeroCLStrat deployed at:", address(aeroCLStrat));
        console.log("Next: schedule StrategyManager.addStrategy on the admin TimelockController");
        console.log("(paired-token feed / addSupportedERC20 usually share the prior allowlist batch).");
    }

    function _deploymentConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        uint32 twapInterval = uint32(vm.envUint("TWAP_INTERVAL"));
        uint32 shortTwapInterval = uint32(vm.envUint("SHORT_TWAP_INTERVAL"));
        address pool = vm.envAddress("POOL_ADDRESS");
        address factory = vm.envAddress("AERO_CL_FACTORY");

        require(twapInterval >= MIN_TWAP_INTERVAL, "TWAP_INTERVAL below MIN_TWAP_INTERVAL");
        require(twapInterval <= MAX_TWAP_INTERVAL, "TWAP_INTERVAL above MAX_TWAP_INTERVAL");
        require(shortTwapInterval >= MIN_SHORT_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL below MIN_SHORT_TWAP_INTERVAL");
        require(shortTwapInterval <= MAX_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL above MAX_TWAP_INTERVAL");
        _requireAeroProvenance(factory, pool);
        _requirePoolCanServeTwap(pool, twapInterval, "TWAP_INTERVAL");
        _requirePoolCanServeTwap(pool, shortTwapInterval, "SHORT_TWAP_INTERVAL");
        _requirePoolObservationCardinality(pool, twapInterval);
        _requirePoolObservationCardinality(pool, shortTwapInterval);
        _checkFeeCapWithinQuoteBudget(factory, pool, vm.envOr("STRICT_FEE_CAP", false));
        console.log("Aero pool unstakedFee (pips):", ICLFactory(factory).getUnstakedFee(pool));

        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: vm.envAddress("REGISTRY_ADDRESS"),
                weth: vm.envAddress("WETH_ADDRESS"),
                pool: pool,
                factory: factory
            }),
            routes: IUniCLStrat.RouteConfig({
                swapAdapter: vm.envAddress("SWAP_ADAPTER_ADDRESS"),
                wethToPairedTokenPath: vm.envBytes("WETH_TO_PAIRED_TOKEN_PATH"),
                pairedTokenToWethPath: vm.envBytes("PAIRED_TOKEN_TO_WETH_PATH")
            }),
            strategy: IUniCLStrat.StrategyConfig({
                positionWidth: int24(vm.envInt("POSITION_WIDTH")),
                rebalanceTickThreshold: int24(vm.envInt("REBALANCE_TICK_THRESHOLD")),
                maxTickDeviation: int56(vm.envInt("MAX_TICK_DEVIATION")),
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
        // `observe` is ABI-identical to Uniswap V3; declared here to keep ICLPool minimal.
        (bool ok,) = pool.staticcall(abi.encodeWithSignature("observe(uint32[])", secondsAgos));
        require(
            ok,
            string.concat(
                "pool.observe cannot serve ", label, "; grow observation cardinality and wait for fill before deploy"
            )
        );
    }

    /// @dev In-use `observationCardinality` (6-field Slipstream `slot0`, not Next).
    function _requirePoolObservationCardinality(address pool, uint32 interval) internal view {
        (,,, uint16 cardinality,,) = ICLPool(pool).slot0();
        uint256 required = (uint256(interval) + MAX_BLOCK_SECONDS - 1) / MAX_BLOCK_SECONDS;
        if (required < MIN_OBSERVATION_CARDINALITY) required = MIN_OBSERVATION_CARDINALITY;
        require(required <= type(uint16).max, "TWAP window exceeds uint16 observation ring");
        require(
            cardinality >= uint16(required),
            "pool observationCardinality below ceil(interval/MAX_BLOCK_SECONDS); grow and wait for fill"
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

        uint256 budget = MAX_QUOTE_DEVIATION_BPS * PIPS_PER_BPS;
        if (feeCap < budget) return;

        if (strict) {
            require(feeCap < budget, "Aero pool fee cap does not fit inside MAX_QUOTE_DEVIATION_BPS");
        } else {
            console.log(
                "WARNING: pool fee cap (pips) >= quote budget; fine while routes skip this pool, but"
            );
            console.log("set STRICT_FEE_CAP=true to enforce, or keep routes off this pool.");
        }
    }
}
