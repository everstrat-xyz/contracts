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
 *      The grant runs under the deployer's TEMPORARY bootstrap ADMIN grant (renounced by
 *      FinalizeProtocolDeploy) — the intended bootstrap pattern.
 *
 *      This script does **not** call `setAllowedAdapter`. DEX adapter allowlisting is always
 *      scheduled on the 48h admin timelock after finalize / DeployAll (same gate as
 *      `addStrategy`) — see `DeployUniswapV3ConverterAdapter` and `DeployUniCLStrat` NatSpec.
 *      `DeployUniCLStrat` requires the adapter to already be allowed (constructor route
 *      validation), so whitelist must execute before that script.
 *
 *      Env (required): PRIVATE_KEY, REGISTRY_ADDRESS, WETH_ADDRESS.
 */
contract DeployConverter is ProtocolDeployBase {
    function run() external returns (address proxy, address implementation) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
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

        vm.stopBroadcast();

        require(address(converter.registry()) == registryAddress, "CRITICAL: Converter registry() mismatch");
        require(registry.getContractByKey(Auth.CONVERTER) == proxy, "CRITICAL: Registry CONVERTER mismatch");
        require(
            registry.hasRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, proxy),
            "CRITICAL: Converter missing CONVERTER_CALLER_MANAGER_ROLE"
        );

        console.log("Converter proxy:", proxy);
        console.log("Converter implementation:", implementation);
        console.log("NOTE: setAllowedAdapter is not called here; schedule it on the admin timelock");

        return (proxy, implementation);
    }
}
