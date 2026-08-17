// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {UniCLStrat} from "../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../src/interfaces/strategies/IUniCLStrat.sol";
import {IUniswapV3Pool} from "../src/interfaces/integrations/uniswap/IUniswapV3Pool.sol";
import {Auth} from "../src/libraries/Auth.sol";

/**
 * @title DeployUniCLStrat
 * @notice Deploys UniCLStrat bytecode only. Does **not** call `StrategyManager.addStrategy`.
 *
 * @dev IMPORTANT DEPLOYMENT ORDER:
 *
 *      The UniCLStrat constructor calls `_validateRouteConfig()`, which reads the
 *      Registry to resolve the Converter address (`_registry.converter()`) and then
 *      calls `converter.validateRoute(...)` and `converter.routeTokens(...)`.
 *      This means the following prerequisites MUST be met BEFORE deploying UniCLStrat:
 *
 *        1. Converter contract must be deployed and registered in the Registry
 *           under the Auth.CONVERTER key.
 *        2. The DEX adapter (e.g. from `DeployUniswapV3ConverterAdapter`) must already
 *           be whitelisted via a timelocked `Converter.setAllowedAdapter(adapter, true)`.
 *
 *      Deploying in any other order produces a confusing deep revert.
 *
 *      Expected Registry state at deployment time:
 *        - Auth.CONVERTER  → Converter proxy address
 *        - Auth.STRATEGY_MANAGER → StrategyManager proxy address (needed later for
 *          registration; verified here so deploy does not target an incomplete stack)
 *        - Converter has adapter(s) configured via setAllowedAdapter
 *
 *      This script needs no Registry ADMIN_ROLE — only a funded deployer key. Because
 *      step 2 is always timelocked after finalize / DeployAll, this script runs only
 *      after that allowlist transaction has executed.
 *
 *      UniCL GO-LIVE (always via the 48h admin timelock — same for modular and DeployAll):
 *
 *        A. After finalize: schedule `Converter.setAllowedAdapter(adapter, true)` (and
 *           typically paired-token Oracle feed + optional `addSupportedERC20` in the same
 *           or a prior batch). ETH (`address(0)`) feed is normally already set by
 *           DeployOracle / DeployAll.
 *        B. Run this script (bytecode only) once the adapter is allowed.
 *           Required env includes `UNIV3_FACTORY` and `POOL_ADDRESS` — the constructor
 *           verifies `factory.getPool(token0, token1, pool.fee()) == pool` so a malicious
 *           interface-compatible pool cannot be trusted as the mint-callback caller, and
 *           probes `pool.observe([twapInterval, 0])` / short window *and* requires
 *           in-use `observationCardinality >= ceil(interval / 12)` (floored at 150)
 *           so a quiet cardinality-1 pool cannot mark at a spot-extrapolated TWAP.
 *           Grow the ring via `increaseObservationCardinalityNext` and wait for fill
 *           *before* this script if either probe would fail.
 *        C. Schedule `StrategyManager.addStrategy(strategy, depositWeight, withdrawalWeight)`.
 *
 *      See `docs/STRATEGY_GUARDRAILS.md`. Do not use the deployer's temporary bootstrap
 *      ADMIN for allowlisting or `addStrategy` — those paths are intentionally removed so
 *      modular and one-shot deploys share one go-live gate.
 */
contract DeployUniCLStrat is Script {
    // Mirrors of UniCLStrat TWAP / observation-cardinality floors and cap (contract
    // constants are not accessible via the type from outside the inheritance tree).
    uint32 internal constant MIN_TWAP_INTERVAL = 1800;
    uint32 internal constant MIN_SHORT_TWAP_INTERVAL = 60;
    uint32 internal constant MAX_BLOCK_SECONDS = 12;
    uint16 internal constant MIN_OBSERVATION_CARDINALITY = 150;
    uint32 internal constant MAX_TWAP_INTERVAL = uint32(type(uint16).max) * MAX_BLOCK_SECONDS;

    function run() external returns (UniCLStrat uniCLStrat) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        IUniCLStrat.DeploymentConfig memory config = _deploymentConfig();
        Registry registry = Registry(config.addresses.registry);
        address strategyManagerAddress = Auth.strategyManager(registry);

        console.log("Deploying UniCLStrat with deployer:", deployer);
        console.log("Registry:", config.addresses.registry);
        console.log("StrategyManager (from Registry):", strategyManagerAddress);
        console.log("NOTE: this script does not call addStrategy; schedule registration on the admin timelock");

        vm.startBroadcast(deployerPrivateKey);

        uniCLStrat = new UniCLStrat(config);

        vm.stopBroadcast();

        require(address(uniCLStrat.registry()) == config.addresses.registry, "CRITICAL: UniCLStrat registry() mismatch");
        require(
            uniCLStrat.MIN_TWAP_INTERVAL() == MIN_TWAP_INTERVAL
                && uniCLStrat.MIN_SHORT_TWAP_INTERVAL() == MIN_SHORT_TWAP_INTERVAL
                && uniCLStrat.MAX_BLOCK_SECONDS() == MAX_BLOCK_SECONDS
                && uniCLStrat.MIN_OBSERVATION_CARDINALITY() == MIN_OBSERVATION_CARDINALITY
                && uniCLStrat.MAX_TWAP_INTERVAL() == MAX_TWAP_INTERVAL,
            "CRITICAL: script TWAP floor/cap mirrors drifted from UniCLStrat constants"
        );
        require(
            Auth.strategyManager(registry) == strategyManagerAddress, "CRITICAL: Registry STRATEGY_MANAGER mismatch"
        );

        console.log("UniCLStrat deployed at:", address(uniCLStrat));
        console.log("Next: schedule StrategyManager.addStrategy on the admin TimelockController");
        console.log("(paired-token feed / addSupportedERC20 usually share the prior allowlist batch).");
    }

    function _deploymentConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        uint32 twapInterval = uint32(vm.envUint("TWAP_INTERVAL"));
        uint32 shortTwapInterval = uint32(vm.envUint("SHORT_TWAP_INTERVAL"));
        address pool = vm.envAddress("POOL_ADDRESS");
        // The constructor enforces the same floors and probes `pool.observe`; checking here
        // surfaces a clear error instead of a deep constructor revert.
        require(twapInterval >= MIN_TWAP_INTERVAL, "TWAP_INTERVAL below MIN_TWAP_INTERVAL");
        require(twapInterval <= MAX_TWAP_INTERVAL, "TWAP_INTERVAL above MAX_TWAP_INTERVAL");
        require(shortTwapInterval >= MIN_SHORT_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL below MIN_SHORT_TWAP_INTERVAL");
        require(shortTwapInterval <= MAX_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL above MAX_TWAP_INTERVAL");
        _requirePoolCanServeTwap(pool, twapInterval, "TWAP_INTERVAL");
        _requirePoolCanServeTwap(pool, shortTwapInterval, "SHORT_TWAP_INTERVAL");
        _requirePoolObservationCardinality(pool, twapInterval);
        _requirePoolObservationCardinality(pool, shortTwapInterval);

        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: vm.envAddress("REGISTRY_ADDRESS"),
                weth: vm.envAddress("WETH_ADDRESS"),
                pool: pool,
                factory: vm.envAddress("UNIV3_FACTORY")
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

    /// @dev `observe([interval, 0])` is what `navInETH` will call (availability).
    function _requirePoolCanServeTwap(address pool, uint32 interval, string memory label) internal view {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = interval;
        secondsAgos[1] = 0;
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

    /// @dev In-use `observationCardinality` (not Next) must cover ceil(interval / 12s),
    ///      floored at MIN_OBSERVATION_CARDINALITY — otherwise a quiet ring can still
    ///      serve observe() by extrapolating a spot-like TWAP.
    function _requirePoolObservationCardinality(address pool, uint32 interval) internal view {
        (,,, uint16 cardinality,,,) = IUniswapV3Pool(pool).slot0();
        uint256 required = (uint256(interval) + MAX_BLOCK_SECONDS - 1) / MAX_BLOCK_SECONDS;
        if (required < MIN_OBSERVATION_CARDINALITY) required = MIN_OBSERVATION_CARDINALITY;
        // Fail closed: truncating to uint16 would accept a window no V3 ring can cover.
        require(required <= type(uint16).max, "TWAP window exceeds uint16 observation ring");
        require(
            cardinality >= uint16(required),
            "pool observationCardinality below ceil(interval/MAX_BLOCK_SECONDS); grow and wait for fill"
        );
    }
}
