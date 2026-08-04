// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {EVE} from "../src/contracts/EVE.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployEVE
 * @notice Deploys the EVE token and registers it on an existing Registry.
 */
contract DeployEVE is ProtocolDeployBase {
    function run() external returns (address tokenAddress) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying EVE with deployer:", deployer);
        console.log("Registry:", registryAddress);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        EVE token = new EVE(registryAddress);
        _registerAndVerify(registry, Auth.EVE, address(token));

        vm.stopBroadcast();

        tokenAddress = address(token);

        require(address(token.registry()) == registryAddress, "CRITICAL: EVE registry() mismatch");
        require(registry.getContractByKey(Auth.EVE) == tokenAddress, "CRITICAL: Registry EVE mismatch");

        console.log("EVE deployed at:", tokenAddress);

        return tokenAddress;
    }
}
