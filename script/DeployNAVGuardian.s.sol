// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {NAVGuardian} from "../src/contracts/automation/NAVGuardian.sol";

import {Auth} from "../src/libraries/Auth.sol";

/**
 * @title DeployNAVGuardian
 * @notice Deploys the CRE NAVGuardian in report-only mode.
 * @dev Does NOT grant SECURITY_ROLE. After a false-positive bake-in period, schedule a
 *      timelocked SECURITY_ROLE grant and flip `setReportOnly(false)`.
 *
 *      Env: PRIVATE_KEY, REGISTRY_ADDRESS, KEYSTONE_FORWARDER, CHAIN_SELECTOR, MAX_REPORT_AGE
 */
contract DeployNAVGuardian is Script {
    function run() external returns (NAVGuardian guardian) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address forwarder = vm.envAddress("KEYSTONE_FORWARDER");
        uint64 chainSelector = uint64(vm.envUint("CHAIN_SELECTOR"));
        uint64 maxReportAge = uint64(vm.envUint("MAX_REPORT_AGE"));

        console.log("Registry:", registryAddress);
        console.log("KEYSTONE_FORWARDER:", forwarder);

        vm.startBroadcast(deployerPrivateKey);
        guardian = new NAVGuardian(registryAddress, forwarder, chainSelector, maxReportAge);
        vm.stopBroadcast();

        require(guardian.reportOnly(), "CRITICAL: guardian must deploy in reportOnly");
        require(!guardian.disabled(), "CRITICAL: guardian unexpectedly disabled");
        require(address(guardian.registry()) == registryAddress, "CRITICAL: guardian registry mismatch");
        // SECURITY_ROLE must NOT be granted at deploy time.
        require(
            !Registry(registryAddress).hasRole(Auth.SECURITY_ROLE, address(guardian)),
            "CRITICAL: guardian must not hold SECURITY_ROLE at deploy"
        );

        console.log("NAVGuardian:", address(guardian));
        console.log("Deployed in reportOnly=true. Bind workflow identity; bake in; then grant SECURITY_ROLE.");
    }
}
