// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {ExitQueue} from "../src/contracts/ExitQueue.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployExitQueue
 * @notice Deploys the ExitQueue proxy and registers it on an existing Registry.
 */
contract DeployExitQueue is ProtocolDeployBase {
    function run() external returns (address proxy, address implementation) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying ExitQueue with deployer:", deployer);
        console.log("Registry:", registryAddress);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        ExitQueue exitQueue = _deployExitQueue(registry);
        proxy = address(exitQueue);
        implementation = _implementationAddress(proxy);

        _registerAndVerify(registry, Auth.EXIT_QUEUE, proxy);

        vm.stopBroadcast();

        require(address(exitQueue.registry()) == registryAddress, "CRITICAL: ExitQueue registry() mismatch");
        require(registry.getContractByKey(Auth.EXIT_QUEUE) == proxy, "CRITICAL: Registry EXIT_QUEUE mismatch");

        console.log("ExitQueue proxy:", proxy);
        console.log("ExitQueue implementation:", implementation);

        return (proxy, implementation);
    }
}
