// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Controller} from "../src/contracts/Controller.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployController
 * @notice Deploys the Controller proxy and registers it on an existing Registry.
 */
contract DeployController is ProtocolDeployBase {
    function run() external returns (address proxy, address implementation) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Controller with deployer:", deployer);
        console.log("Registry:", registryAddress);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        Controller controller;
        (implementation, controller) = _deployController(registry);
        proxy = address(controller);

        _registerAndVerify(registry, Auth.CONTROLLER, proxy);

        vm.stopBroadcast();

        require(address(controller.registry()) == registryAddress, "CRITICAL: Controller registry() mismatch");
        require(registry.getContractByKey(Auth.CONTROLLER) == proxy, "CRITICAL: Registry CONTROLLER mismatch");

        console.log("Controller proxy:", proxy);
        console.log("Controller implementation:", implementation);

        return (proxy, implementation);
    }
}
