// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {StrategyManager} from "../src/contracts/StrategyManager.sol";
import {UniCLStrat} from "../src/contracts/strategies/UniCLStrat.sol";
import {IUniCLStrat} from "../src/interfaces/strategies/IUniCLStrat.sol";
import {Auth} from "../src/libraries/Auth.sol";

/**
 * @title DeployUniCLStrat
 * @notice Deploys UniCLStrat and registers it with StrategyManager (address from Registry).
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
 *        2. The DEX adapter (e.g. UniswapV3ConverterAdapter) must be whitelisted
 *           in the Converter via `setAllowedAdapter(adapter, true)`.
 *
 *      Deploying in any other order produces a confusing deep revert.
 *
 *      Expected Registry state at deployment time:
 *        - Auth.CONVERTER  → Converter proxy address
 *        - Auth.STRATEGY_MANAGER → StrategyManager proxy address
 *        - Converter has adapter(s) configured via setAllowedAdapter
 */
contract DeployUniCLStrat is Script {
    // Mirrors of UniCLStrat.MIN_TWAP_INTERVAL / MIN_SHORT_TWAP_INTERVAL (contract constants
    // are not accessible via the type from outside the inheritance tree).
    uint32 internal constant MIN_TWAP_INTERVAL = 1800;
    uint32 internal constant MIN_SHORT_TWAP_INTERVAL = 60;

    function run() external returns (UniCLStrat uniCLStrat) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        IUniCLStrat.DeploymentConfig memory config = _deploymentConfig();
        Registry registry = Registry(config.addresses.registry);
        address strategyManagerAddress = Auth.strategyManager(registry);

        console.log("Deploying UniCLStrat with deployer:", deployer);
        console.log("Registry:", config.addresses.registry);
        console.log("StrategyManager (from Registry):", strategyManagerAddress);

        vm.startBroadcast(deployerPrivateKey);

        // addStrategy() is ADMIN_ROLE (48h timelock)-gated in production. During the initial
        // modular deploy the broadcaster is the deployer using its TEMPORARY bootstrap
        // Registry ADMIN grant (renounced afterwards by FinalizeProtocolDeploy) — the
        // intended bootstrap pattern. Adding a strategy to a LIVE protocol cannot go through
        // this script: it must be scheduled on the admin timelock by the DAO proposer.

        uniCLStrat = new UniCLStrat(config);
        StrategyManager(payable(strategyManagerAddress)).addStrategy(
            address(uniCLStrat), uint8(vm.envUint("DEPOSIT_WEIGHT")), uint8(vm.envUint("WITHDRAWAL_WEIGHT"))
        );

        vm.stopBroadcast();

        require(address(uniCLStrat.registry()) == config.addresses.registry, "CRITICAL: UniCLStrat registry() mismatch");
        require(
            uniCLStrat.MIN_TWAP_INTERVAL() == MIN_TWAP_INTERVAL
                && uniCLStrat.MIN_SHORT_TWAP_INTERVAL() == MIN_SHORT_TWAP_INTERVAL,
            "CRITICAL: script TWAP floor mirrors drifted from UniCLStrat constants"
        );
        require(
            Auth.strategyManager(registry) == strategyManagerAddress, "CRITICAL: Registry STRATEGY_MANAGER mismatch"
        );

        console.log("UniCLStrat deployed at:", address(uniCLStrat));
    }

    function _deploymentConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        uint32 twapInterval = uint32(vm.envUint("TWAP_INTERVAL"));
        uint32 shortTwapInterval = uint32(vm.envUint("SHORT_TWAP_INTERVAL"));
        // The constructor enforces the same floors; checking here surfaces a clear error
        // instead of a deep constructor revert. NOTE: the target pool's observation
        // cardinality must cover TWAP_INTERVAL or navInETH() reverts until the
        // observation buffer fills (see pool.increaseObservationCardinalityNext).
        require(twapInterval >= MIN_TWAP_INTERVAL, "TWAP_INTERVAL below MIN_TWAP_INTERVAL");
        require(shortTwapInterval >= MIN_SHORT_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL below MIN_SHORT_TWAP_INTERVAL");

        return IUniCLStrat.DeploymentConfig({
            addresses: IUniCLStrat.AddressConfig({
                registry: vm.envAddress("REGISTRY_ADDRESS"),
                weth: vm.envAddress("WETH_ADDRESS"),
                pool: vm.envAddress("POOL_ADDRESS")
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
}
