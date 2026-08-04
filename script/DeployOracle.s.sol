// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Oracle} from "../src/contracts/Oracle.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployOracle
 * @notice Deploys the Oracle proxy and registers it on an existing Registry.
 * @dev `updateUsdFeedInfo` registers the initial ETH Token / USD feed. That call is
 *      ADMIN_ROLE (48h timelock)-gated in production; here it runs under the deployer's
 *      TEMPORARY bootstrap ADMIN grant (renounced by FinalizeProtocolDeploy) — the intended
 *      bootstrap pattern. Registering the ETH USD feed is what makes ETH "supported"
 *      (`isTokenSupported(address(0))`). Any feed change after finalization must be
 *      scheduled through the admin timelock.
 *      Env (required): PRIVATE_KEY, REGISTRY_ADDRESS, PRICE_FEED, TIMELOCK_ADDRESS.
 */
contract DeployOracle is ProtocolDeployBase {
    uint256 public constant STALENESS_INTERVAL = 3600;

    function run() external returns (address proxy, address implementation) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address priceFeed = vm.envAddress("PRICE_FEED");
        address deployer = vm.addr(deployerPrivateKey);
        address adminTimelock = _protocolAdminTimelock();

        console.log("Deploying Oracle with deployer:", deployer);
        console.log("Registry:", registryAddress);

        _assertUsdQuotedFeed(priceFeed);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        Oracle oracle;
        (implementation, oracle) = _deployOracle(registry);
        proxy = address(oracle);

        _registerAndVerify(registry, Auth.ORACLE, proxy);

        oracle.updateUsdFeedInfo(address(0), priceFeed, STALENESS_INTERVAL);

        vm.stopBroadcast();

        require(address(oracle.registry()) == registryAddress, "CRITICAL: Oracle registry() mismatch");
        require(registry.getContractByKey(Auth.ORACLE) == proxy, "CRITICAL: Registry ORACLE mismatch");
        require(oracle.isTokenSupported(address(0)), "CRITICAL: Oracle missing ETH feed");
        require(
            registry.hasRole(Auth.ADMIN_ROLE, adminTimelock), "CRITICAL: admin timelock missing ADMIN_ROLE on Registry"
        );

        console.log("Oracle proxy:", proxy);
        console.log("Oracle implementation:", implementation);

        return (proxy, implementation);
    }
}
