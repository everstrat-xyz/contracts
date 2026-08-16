// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title FinalizeProtocolDeploy
 * @notice Renounces the deployer's bootstrap Registry ADMIN_ROLE. Under the PL-003 timelock
 *         model this always renounces — ADMIN_ROLE must end the deployment held only by the
 *         admin TimelockController.
 * @dev Run as the last step of a modular deploy after all contracts are registered and roles
 *      are granted. Beyond the ADMIN checks, this script VERIFIES every critical protocol
 *      grant ({ProtocolDeployBase-_verifyCriticalRoleGrants}): SECURITY_ROLE on the security
 *      multisig, MINTER_ROLE on the AMM and StrategyManager, CONVERTER_CALLER_MANAGER_ROLE on
 *      the Converter, KEEPER_ROLE on both keeper executors, and every core Registry key
 *      including `WHITELIST` — so a skipped or mis-granted modular step fails the deployment
 *      loudly instead of surfacing as a runtime revert that needs a 48h-timelocked repair.
 *      Env (required): PRIVATE_KEY, REGISTRY_ADDRESS, TIMELOCK_ADDRESS (the admin
 *      TimelockController deployed by DeployRegistry), SECURITY_ADDRESS (the security
 *      multisig that must hold SECURITY_ROLE).
 */
contract FinalizeProtocolDeploy is ProtocolDeployBase {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);
        address adminTimelock = _protocolAdminTimelock();
        address security = _protocolSecurity();

        console.log("Finalizing deployer admin access with deployer:", deployer);
        console.log("Admin timelock:", adminTimelock);
        console.log("Registry:", registryAddress);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        _finalizeDeployerTieredAccess(registry, deployer);

        vm.stopBroadcast();

        _verifyDeployerTieredAccess(registry, deployer, adminTimelock);
        _verifyCriticalRoleGrants(registry, security);

        console.log("Deployer admin access finalized");
        console.log("All critical protocol role grants verified");
    }
}
