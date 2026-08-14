// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {CREQueueExecutor} from "../src/contracts/automation/CREQueueExecutor.sol";
import {CREStrategyExecutor} from "../src/contracts/automation/CREStrategyExecutor.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployCREExecutors
 * @notice Modular deploy step: deploys both CRE keeper executors, registers them on the
 *         Registry address book, and optionally grants KEEPER_ROLE.
 *
 * @dev Shared implementation lives in {ProtocolDeployBase-_deployCREExecutors}; DeployAll
 *      calls the same helper. Run this after core Registry wiring and before
 *      FinalizeProtocolDeploy (the deployer must still hold ADMIN_ROLE), or schedule
 *      registration / role grants through the 48h admin timelock in production.
 *
 *      Env vars:
 *        - PRIVATE_KEY: deployer key (must hold ADMIN_ROLE on the Registry for bootstrap
 *          registration, optional role grants, and policy-knob setters).
 *        - REGISTRY_ADDRESS: the protocol Registry.
 *        - KEYSTONE_FORWARDER: Chainlink-managed KeystoneForwarder (immutable on executors).
 *        - CHAIN_SELECTOR: CCIP chain selector for this deployment (uint64).
 *        - MAX_REPORT_AGE: max report `observedAt` age in seconds (uint64, > 0).
 *        - EXIT_LIQUIDITY_TARGET_ETH: required. AMM free-balance target in wei for the
 *          ProvideExitLiquidity action (0 = disabled — valid explicit choice).
 *        - CONTROLLER_RESERVE_ETH: required. ETH (wei) kept idle on the Controller, not
 *          deposited to strategies (0 = no reserve — valid explicit choice).
 *        - GRANT_KEEPER_ROLE: required bool. `true` grants KEEPER_ROLE to both executors
 *          from the deployer; `false` when grants must be timelocked (finalize only after
 *          those grants have executed).
 *
 *      Post-deployment (per executor):
 *        1. Deploy CRE workflows (queue-keeper / strategy-keeper).
 *        2. Bind workflow identity (ADMIN), per ReceiverTemplate:
 *           `setExpectedAuthor`, then `setExpectedWorkflowName`, then pin
 *           `setExpectedWorkflowId`.
 *        3. Enable workflow `writeReport`.
 *        4. Before granting KEEPER_ROLE to anything new: set `strategyDepositCooldown` > 0.
 *
 *      SECURITY: never grant KEEPER_ROLE to Chainlink infra or a deployer EOA in
 *      production. This script grants it to the two executor contracts and to nothing
 *      else. A manual break-glass keeper multisig is NOT deployed here and is NOT a
 *      default: it is an opt-in governance decision with its own timelocked proposal —
 *      read `docs/FREEZE_RUNBOOK.md` §0.1 (rationale, risk surface, containment via
 *      `Controller.pause()`, signer policy) before proposing it.
 *      Executors reject reports until workflow identity is bound.
 */
contract DeployCREExecutors is ProtocolDeployBase {
    function run() external returns (CREQueueExecutor queueExecutor, CREStrategyExecutor strategyExecutor) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        bool grantKeeperRole = vm.envBool("GRANT_KEEPER_ROLE");

        Registry registry = Registry(registryAddress);

        console.log("Deployer:", deployer);
        console.log("Registry:", registryAddress);
        console.log("GRANT_KEEPER_ROLE:", grantKeeperRole);
        console.log("KEYSTONE_FORWARDER:", vm.envAddress("KEYSTONE_FORWARDER"));
        console.log("CHAIN_SELECTOR:", vm.envUint("CHAIN_SELECTOR"));
        console.log("MAX_REPORT_AGE:", vm.envUint("MAX_REPORT_AGE"));

        vm.startBroadcast(deployerPrivateKey);

        CREExecutors memory executors = _deployCREExecutors(registry, grantKeeperRole);

        vm.stopBroadcast();

        _verifyCREExecutors(registry, executors, grantKeeperRole);

        queueExecutor = executors.queueExecutor;
        strategyExecutor = executors.strategyExecutor;

        console.log("CREQueueExecutor:", address(queueExecutor));
        console.log("CREStrategyExecutor:", address(strategyExecutor));
        console.log("Next steps: bind workflow identity on each executor, then enable writeReport.");
    }
}
