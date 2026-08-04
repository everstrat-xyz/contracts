// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Whitelist} from "../src/contracts/Whitelist.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployWhitelist
 * @notice Deploys the Whitelist contract and registers it on an existing Registry.
 * @dev Env (required): PRIVATE_KEY, REGISTRY_ADDRESS, WHITELIST_SIGNER_ADDRESS.
 *      WHITELIST_SIGNER_ADDRESS seeds an initial invite signer while the deployer still
 *      holds its bootstrap ADMIN_ROLE grant; set to the zero address to postpone seeding
 *      (add later via timelocked `addSigner()`).
 *      A redeployed Whitelist starts empty — migrate admitted users via `addToWhitelist`
 *      or open the gate with `disable()`.
 */
contract DeployWhitelist is ProtocolDeployBase {
    function run() external returns (address whitelistAddress) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Whitelist with deployer:", deployer);
        console.log("Registry:", registryAddress);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        Whitelist whitelist = _deployWhitelist(registry);
        whitelistAddress = address(whitelist);

        _registerAndVerify(registry, Auth.WHITELIST, whitelistAddress);

        address whitelistSigner = _protocolWhitelistSigner();
        if (whitelistSigner != address(0)) {
            whitelist.addSigner(whitelistSigner);
        }

        vm.stopBroadcast();

        require(address(whitelist.registry()) == registryAddress, "CRITICAL: Whitelist registry() mismatch");
        require(registry.getContractByKey(Auth.WHITELIST) == whitelistAddress, "CRITICAL: Registry WHITELIST mismatch");
        if (whitelistSigner != address(0)) {
            require(whitelist.isSigner(whitelistSigner), "CRITICAL: initial signer not set");
        }

        console.log("Whitelist:", whitelistAddress);

        return whitelistAddress;
    }
}
