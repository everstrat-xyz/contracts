// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Converter} from "../src/contracts/Converter.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployConverter
 * @notice Deploys the Converter proxy, registers it on an existing Registry, and grants it
 *         CONVERTER_CALLER_MANAGER_ROLE — mirroring DeployAll's `_grantTieredProtocolRoles`.
 * @dev The CONVERTER_CALLER_MANAGER_ROLE grant is what lets the Converter administer
 *      CONVERTER_CALLER_ROLE for strategies: `StrategyManager.addStrategy` calls
 *      `Converter.grantCallerRole`, which reverts loudly without it. Run this BEFORE
 *      `DeployUniCLStrat` (whose constructor also resolves the Converter from the Registry).
 *
 *      The grant and the optional adapter whitelisting run under the deployer's TEMPORARY
 *      bootstrap ADMIN grant (renounced by FinalizeProtocolDeploy) — the intended bootstrap
 *      pattern. Adapter changes after finalization must be scheduled through the admin
 *      timelock.
 *
 *      Env (required): PRIVATE_KEY, REGISTRY_ADDRESS, WETH_ADDRESS.
 *      Optional: SWAP_ADAPTER_ADDRESS — when set (and non-zero), the adapter is whitelisted
 *      via `setAllowedAdapter(adapter, true)` so DeployUniCLStrat's route validation can
 *      succeed; the same env var feeds DeployUniCLStrat's `swapAdapter` route config.
 */
contract DeployConverter is ProtocolDeployBase {
    function run() external returns (address proxy, address implementation) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address swapAdapter = vm.envOr("SWAP_ADAPTER_ADDRESS", address(0));
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Converter with deployer:", deployer);
        console.log("Registry:", registryAddress);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        Converter converter;
        (implementation, converter) = _deployConverter(registry, weth);
        proxy = address(converter);

        _registerAndVerify(registry, Auth.CONVERTER, proxy);

        registry.grantRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, proxy);

        if (swapAdapter != address(0)) {
            converter.setAllowedAdapter(swapAdapter, true);
        }

        vm.stopBroadcast();

        require(address(converter.registry()) == registryAddress, "CRITICAL: Converter registry() mismatch");
        require(registry.getContractByKey(Auth.CONVERTER) == proxy, "CRITICAL: Registry CONVERTER mismatch");
        require(
            registry.hasRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, proxy),
            "CRITICAL: Converter missing CONVERTER_CALLER_MANAGER_ROLE"
        );
        if (swapAdapter != address(0)) {
            require(converter.isAdapterAllowed(swapAdapter), "CRITICAL: swap adapter not whitelisted on Converter");
        }

        console.log("Converter proxy:", proxy);
        console.log("Converter implementation:", implementation);
        if (swapAdapter != address(0)) {
            console.log("Whitelisted swap adapter:", swapAdapter);
        }

        return (proxy, implementation);
    }
}
