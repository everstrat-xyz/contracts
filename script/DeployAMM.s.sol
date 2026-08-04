// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {AMM} from "../src/contracts/AMM.sol";
import {StrategyManager} from "../src/contracts/StrategyManager.sol";
import {Registry} from "registry/Registry.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployAMM
 * @notice Deploys StrategyManager and AMM, registers them on an existing Registry, and
 *         grants MINTER_ROLE to both (AMM for enter/exit mints, StrategyManager for
 *         performance-fee mints).
 * @dev Env (required): PRIVATE_KEY, REGISTRY_ADDRESS, DAO_TREASURY_ADDRESS — the fee
 *      treasury is never defaulted; a missing value reverts the deploy.
 *      Optional: PERFORMANCE_FEE_BPS (default 0 = fees disabled).
 */
contract DeployAMM is ProtocolDeployBase {
    function run() external returns (address strategyManagerProxy, address ammAddress) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying StrategyManager and AMM with deployer:", deployer);
        console.log("Registry:", registryAddress);

        Registry registry = Registry(registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        address smImplementation;
        StrategyManager strategyManager;
        address daoTreasury = _protocolDaoTreasury();
        (smImplementation, strategyManager) = _deployStrategyManager(registry, _protocolFeeConfig(daoTreasury));
        AMM amm = new AMM(registryAddress, DEFAULT_CONNECTOR_WEIGHT);

        strategyManagerProxy = address(strategyManager);
        ammAddress = address(amm);

        _registerAndVerify(registry, Auth.STRATEGY_MANAGER, strategyManagerProxy);
        _registerAndVerify(registry, Auth.AMM, ammAddress);

        // MINTER_ROLE goes to BOTH the AMM (EVE mint/burn on enter/exit) and the
        // StrategyManager (performance-fee EVE mints to the DAO treasury). Missing the
        // StrategyManager grant silently breaks every harvest and strategy withdrawal once
        // fees are enabled, and repairing it needs a 48h-timelocked grant.
        bytes32[] memory roles = new bytes32[](2);
        address[] memory accounts = new address[](2);
        roles[0] = Auth.MINTER_ROLE;
        accounts[0] = ammAddress;
        roles[1] = Auth.MINTER_ROLE;
        accounts[1] = strategyManagerProxy;
        registry.grantRoles(roles, accounts);

        // Deployer keeps its bootstrap Registry ADMIN_ROLE for any remaining modular steps
        // (e.g. DeployUniCLStrat + addStrategy). Renounce explicitly at the end via
        // FinalizeProtocolDeploy — the single, unconditional PL-003 finalization step.

        vm.stopBroadcast();

        require(address(strategyManager.registry()) == registryAddress, "CRITICAL: SM registry() mismatch");
        require(address(amm.registry()) == registryAddress, "CRITICAL: AMM registry() mismatch");
        require(
            registry.getContractByKey(Auth.STRATEGY_MANAGER) == strategyManagerProxy,
            "CRITICAL: Registry STRATEGY_MANAGER mismatch"
        );
        require(registry.getContractByKey(Auth.AMM) == ammAddress, "CRITICAL: Registry AMM mismatch");
        require(registry.hasRole(Auth.MINTER_ROLE, ammAddress), "CRITICAL: AMM missing MINTER_ROLE");
        require(
            registry.hasRole(Auth.MINTER_ROLE, strategyManagerProxy), "CRITICAL: StrategyManager missing MINTER_ROLE"
        );

        console.log("StrategyManager proxy:", strategyManagerProxy);
        console.log("StrategyManager implementation:", smImplementation);
        console.log("AMM:", ammAddress);

        return (strategyManagerProxy, ammAddress);
    }
}
