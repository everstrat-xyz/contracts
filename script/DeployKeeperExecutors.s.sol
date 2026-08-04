// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {QueueKeeperExecutor} from "../src/contracts/automation/QueueKeeperExecutor.sol";
import {StrategyKeeperExecutor} from "../src/contracts/automation/StrategyKeeperExecutor.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployKeeperExecutors
 * @notice Modular deploy step: deploys both Chainlink Automation keeper executors,
 *         registers them on the Registry address book, and optionally grants KEEPER_ROLE.
 *
 * @dev Shared implementation lives in {ProtocolDeployBase-_deployKeeperExecutors}; DeployAll
 *      calls the same helper. Run this after core Registry wiring and before
 *      FinalizeProtocolDeploy (the deployer must still hold ADMIN_ROLE), or schedule
 *      registration / role grants through the 48h admin timelock in production.
 *
 *      Env vars:
 *        - PRIVATE_KEY: deployer key (must hold ADMIN_ROLE on the Registry for bootstrap
 *          registration, optional role grants, and policy-knob setters).
 *        - REGISTRY_ADDRESS: the protocol Registry.
 *        - EXIT_LIQUIDITY_TARGET_ETH: required. AMM free-balance target in wei for the
 *          ProvideExitLiquidity action (0 = disabled — valid explicit choice).
 *        - CONTROLLER_RESERVE_ETH: required. ETH (wei) kept idle on the Controller, not
 *          deposited to strategies (0 = no reserve — valid explicit choice).
 *        - GRANT_KEEPER_ROLE (optional, default true): grant KEEPER_ROLE to both
 *          executors from the deployer. Set false when grants must be timelocked.
 *
 *      Post-deployment (per executor):
 *        1. Register the upkeep in Chainlink Automation (UI or registrar),
 *           targeting the executor with empty checkData.
 *        2. Read the upkeep's Forwarder address from the Automation registry.
 *        3. Call `setForwarder(forwarder)` on the executor (ADMIN_ROLE).
 *
 *      SECURITY: never grant KEEPER_ROLE to the Chainlink registry/registrar or
 *      a deployer EOA in production — only to the executor contracts. The
 *      executors stay inert until their Forwarder is set.
 */
contract DeployKeeperExecutors is ProtocolDeployBase {
    function run() external returns (QueueKeeperExecutor queueExecutor, StrategyKeeperExecutor strategyExecutor) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        bool grantKeeperRole = vm.envOr("GRANT_KEEPER_ROLE", true);

        Registry registry = Registry(registryAddress);

        console.log("Deployer:", deployer);
        console.log("Registry:", registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        KeeperExecutors memory keepers = _deployKeeperExecutors(registry, grantKeeperRole);

        vm.stopBroadcast();

        _verifyKeeperExecutors(registry, keepers, grantKeeperRole);

        queueExecutor = keepers.queueExecutor;
        strategyExecutor = keepers.strategyExecutor;

        console.log("QueueKeeperExecutor:", address(queueExecutor));
        console.log("StrategyKeeperExecutor:", address(strategyExecutor));
        console.log("Next steps: register upkeeps in Chainlink Automation,");
        console.log("then call setForwarder(<forwarder>) on each executor.");
    }
}
