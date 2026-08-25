// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Registry} from "registry/Registry.sol";
import {QueueKeeperExecutor} from "../src/contracts/automation/QueueKeeperExecutor.sol";
import {StrategyKeeperExecutor} from "../src/contracts/automation/StrategyKeeperExecutor.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployKeeperExecutors
 * @notice Modular deploy step: deploys both keeper executors, registers them
 *         on the Registry address book, and optionally grants KEEPER_ROLE.
 *
 * @dev Shared implementation lives in {ProtocolDeployBase-_deployKeeperExecutors};
 *      DeployAll calls the same helper. Run this after core Registry wiring and
 *      before FinalizeProtocolDeploy (the deployer must still hold ADMIN_ROLE), or
 *      schedule registration / role grants through the 48h admin timelock in production.
 *
 *      Env vars:
 *        - PRIVATE_KEY: deployer key (must hold ADMIN_ROLE on the Registry for bootstrap
 *          registration, optional role grants, and policy-knob setters).
 *        - REGISTRY_ADDRESS: the protocol Registry.
 *        - EXIT_LIQUIDITY_TARGET_ETH: required. AMM free-balance target in wei for the
 *          ProvideExitLiquidity action (0 = disabled — valid explicit choice).
 *        - CONTROLLER_RESERVE_ETH: required. ETH (wei) kept idle on the Controller, not
 *          deposited to strategies (0 = no reserve — valid explicit choice).
 *        - GRANT_KEEPER_ROLE: required bool. `true` grants KEEPER_ROLE to both executors
 *          from the deployer; `false` when grants must be timelocked (finalize only after
 *          those grants have executed).
 *
 *      Post-deployment (per executor):
 *        1. Deploy the Mimic functions (see the keepers repo, mimic-functions/):
 *           - W2: reads StrategyKeeperExecutor.checker() via oracle and relays
 *             execPayload verbatim as an EvmCall intent.
 *           - W1: queue-keeper deep-scan function building perform calldata
 *             off-chain.
 *        2. Create triggers (cron) for each function in the Mimic explorer;
 *           note the operator's smart account address (per chain).
 *        3. Bind it: ADMIN `allowExecutorCaller(smartAccount)`. Executors are
 *           inert until this lands (perform reverts KeeperExecutorNoAllowedCallers).
 *        4. Fund Mimic credits for executions.
 *        5. Before granting KEEPER_ROLE to anything new: set `strategyDepositCooldown` > 0.
 *
 *      SECURITY: never grant KEEPER_ROLE to automation infrastructure or a deployer EOA in
 *      production. This script grants it to the two executor contracts and to nothing
 *      else. A manual break-glass keeper multisig is NOT deployed here and is NOT a
 *      default: it is an opt-in governance decision with its own timelocked proposal —
 *      read `docs/FREEZE_RUNBOOK.md` §0.1 (rationale, risk surface, containment via
 *      `Controller.pause()`, signer policy) before proposing it.
 *      Executors reject perform calls until a caller is allowlisted.
 */
contract DeployKeeperExecutors is ProtocolDeployBase {
    function run() external returns (QueueKeeperExecutor queueExecutor, StrategyKeeperExecutor strategyExecutor) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");
        bool grantKeeperRole = vm.envBool("GRANT_KEEPER_ROLE");

        Registry registry = Registry(registryAddress);

        console.log("Deployer:", deployer);
        console.log("Registry:", registryAddress);
        console.log("GRANT_KEEPER_ROLE:", grantKeeperRole);

        vm.startBroadcast(deployerPrivateKey);

        KeeperExecutors memory executors = _deployKeeperExecutors(registry, grantKeeperRole);

        vm.stopBroadcast();

        _verifyKeeperExecutors(registry, executors, grantKeeperRole);

        queueExecutor = executors.queueExecutor;
        strategyExecutor = executors.strategyExecutor;

        console.log("QueueKeeperExecutor:", address(queueExecutor));
        console.log("StrategyKeeperExecutor:", address(strategyExecutor));
        console.log("Next steps: create Gelato tasks, then allowExecutorCaller(dedicatedMsgSender)");
        console.log("on each executor via ADMIN (timelocked in production).");
    }
}
