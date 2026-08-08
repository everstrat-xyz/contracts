// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {UniswapV3ConverterAdapter} from "../src/contracts/adapters/UniswapV3ConverterAdapter.sol";
import {Auth} from "../src/libraries/Auth.sol";

/**
 * @title DeployUniswapV3ConverterAdapter
 * @notice Deploys UniswapV3ConverterAdapter bytecode only. Does **not** call
 *         `Converter.setAllowedAdapter` — always schedule that on the 48h admin timelock
 *         after FinalizeProtocolDeploy / DeployAll (same gate as strategy registration).
 *
 * @dev Prerequisites:
 *        1. Oracle must be deployed and registered under Auth.ORACLE (DeployOracle /
 *           DeployAll) — the adapter constructor takes the Oracle address and uses it for
 *           TWAP ↔ Chainlink quote cross-checks.
 *
 *      This script needs no Registry ADMIN_ROLE — only a funded deployer key. It is
 *      intentionally outside `DeployAll` (core protocol only); run it when bringing up
 *      UniCL / Converter DEX routing on a network (before or after finalize).
 *
 *      Env (required):
 *        - PRIVATE_KEY
 *        - REGISTRY_ADDRESS — resolve Oracle
 *        - WETH_ADDRESS
 *        - UNIV3_SWAP_ROUTER — Uniswap V3 SwapRouter
 *        - UNIV3_FACTORY — Uniswap V3 Factory
 *        - ADAPTER_TWAP_INTERVAL — quote TWAP window (seconds; >= MIN_TWAP_INTERVAL = 60)
 *
 *      After this script: export `SWAP_ADAPTER_ADDRESS=<deployed>`, then on the admin
 *      timelock schedule `Converter.setAllowedAdapter(adapter, true)` (required before
 *      `DeployUniCLStrat`, whose constructor validates routes against the allowlist).
 */
contract DeployUniswapV3ConverterAdapter is Script {
    // Mirror of UniswapV3ConverterAdapter.MIN_TWAP_INTERVAL (not accessible via the type
    // from outside the inheritance tree without an instance).
    uint32 internal constant MIN_TWAP_INTERVAL = 60;

    function run() external returns (UniswapV3ConverterAdapter adapter) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address router = vm.envAddress("UNIV3_SWAP_ROUTER");
        address factory = vm.envAddress("UNIV3_FACTORY");
        uint32 twapInterval = uint32(vm.envUint("ADAPTER_TWAP_INTERVAL"));

        Registry registry = Registry(registryAddress);
        address oracle = Auth.oracle(registry);

        require(twapInterval >= MIN_TWAP_INTERVAL, "ADAPTER_TWAP_INTERVAL below MIN_TWAP_INTERVAL");
        require(oracle != address(0), "CRITICAL: Registry ORACLE not set");
        require(weth != address(0), "CRITICAL: WETH_ADDRESS is zero");
        require(router != address(0), "CRITICAL: UNIV3_SWAP_ROUTER is zero");
        require(factory != address(0), "CRITICAL: UNIV3_FACTORY is zero");

        console.log("Deploying UniswapV3ConverterAdapter with deployer:", deployer);
        console.log("Registry:", registryAddress);
        console.log("Oracle (from Registry):", oracle);
        console.log("WETH:", weth);
        console.log("SwapRouter:", router);
        console.log("Factory:", factory);
        console.log("TWAP interval:", twapInterval);
        console.log("NOTE: this script does not whitelist the adapter;");
        console.log("schedule Converter.setAllowedAdapter on the admin timelock after finalize");

        vm.startBroadcast(deployerPrivateKey);

        adapter = new UniswapV3ConverterAdapter(router, factory, oracle, weth, twapInterval);

        vm.stopBroadcast();

        require(address(adapter.oracle()) == oracle, "CRITICAL: adapter oracle() mismatch");
        require(adapter.weth() == weth, "CRITICAL: adapter weth() mismatch");
        require(address(adapter.router()) == router, "CRITICAL: adapter router() mismatch");
        require(address(adapter.factory()) == factory, "CRITICAL: adapter factory() mismatch");
        require(adapter.twapInterval() == twapInterval, "CRITICAL: adapter twapInterval() mismatch");
        require(
            adapter.MIN_TWAP_INTERVAL() == MIN_TWAP_INTERVAL,
            "CRITICAL: script TWAP floor mirror drifted from UniswapV3ConverterAdapter"
        );

        console.log("UniswapV3ConverterAdapter deployed at:", address(adapter));
        console.log("Next: export SWAP_ADAPTER_ADDRESS=", address(adapter));
        console.log("Then timelock setAllowedAdapter before DeployUniCLStrat.");
    }
}
