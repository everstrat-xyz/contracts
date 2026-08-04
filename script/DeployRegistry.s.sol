// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployRegistry
 * @notice First step of the modular deploy: deploys the 48h admin TimelockController
 *         (PL-003) and the protocol Registry with the timelock as its designated admin.
 * @dev The Registry `_admin` must differ from the deployer (ADMIN_ROLE is
 *      self-administered), so it must be the admin timelock — never an EOA and never the
 *      DAO multisig directly. The DAO (`DAO_ADDRESS`) is the timelock's proposer (and
 *      canceller) and the security (`SECURITY_ADDRESS`) its canceller, mirroring DeployAll.
 *      The security multisig also receives SECURITY_ROLE here (direct, no timelock — emergency
 *      pause must be instant), mirroring DeployAll's `_grantTieredProtocolRoles`.
 *
 *      The deployer keeps a temporary bootstrap ADMIN_ROLE (granted by the Registry
 *      constructor to msg.sender) to run the remaining modular deploy steps; run
 *      FinalizeProtocolDeploy as the last step to renounce it.
 *
 *      Env (required): PRIVATE_KEY, DAO_ADDRESS, SECURITY_ADDRESS — no deployer fallbacks;
 *      a missing value reverts the deploy. Optional: TIMELOCK_ADMIN_DELAY (default 48h).
 *      Export the logged Registry address as REGISTRY_ADDRESS and the logged timelock
 *      address as TIMELOCK_ADDRESS for the subsequent modular scripts.
 */
contract DeployRegistry is ProtocolDeployBase {
    function run() external returns (address registryAddress, address adminTimelockAddress) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address dao = _protocolDao();
        address security = _protocolSecurity();

        console.log("Deploying Registry with deployer:", deployer);
        console.log("DAO (timelock proposer):", dao);
        console.log("Emergency security (timelock canceller):", security);

        vm.startBroadcast(deployerPrivateKey);

        ProtocolTimelocks memory timelocks = _deployTimelocks(deployer, dao, security);
        Registry registry = _deployRegistry(address(timelocks.adminTimelock));

        // SECURITY_ROLE is held directly by the security multisig (no timelock — emergency
        // pause must be instant), mirroring DeployAll's _grantTieredProtocolRoles. The grant
        // runs under the deployer's TEMPORARY bootstrap ADMIN grant.
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.stopBroadcast();

        registryAddress = address(registry);
        adminTimelockAddress = address(timelocks.adminTimelock);

        require(registry.hasRole(Auth.ADMIN_ROLE, adminTimelockAddress), "CRITICAL: admin timelock missing ADMIN_ROLE");
        require(registry.hasRole(Auth.ADMIN_ROLE, deployer), "CRITICAL: deployer missing bootstrap ADMIN_ROLE");
        require(registry.hasRole(Auth.SECURITY_ROLE, security), "CRITICAL: security missing SECURITY_ROLE");
        _verifyTimelockRoles(timelocks.adminTimelock, deployer, dao, security);

        console.log("Registry deployed at:", registryAddress);
        console.log("Admin timelock (48h) deployed at:", adminTimelockAddress);
        console.log("Export REGISTRY_ADDRESS and TIMELOCK_ADDRESS for the remaining modular deploy steps");
        console.log("NOTE: deployer holds a bootstrap ADMIN_ROLE; run FinalizeProtocolDeploy as the last deploy step");

        return (registryAddress, adminTimelockAddress);
    }
}
