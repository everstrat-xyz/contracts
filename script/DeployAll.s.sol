// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {Oracle} from "../src/contracts/Oracle.sol";
import {Whitelist} from "../src/contracts/Whitelist.sol";
import {Auth} from "../src/libraries/Auth.sol";

import {ProtocolDeployBase} from "./ProtocolDeployBase.sol";

/**
 * @title DeployAll
 * @notice Full protocol deployment via the Registry-centric wiring pattern with
 *         PL-003 timelock governance.
 * @dev End state of a run:
 *        - ADMIN_ROLE          -> 48h TimelockController (config, registry, roles, oracle
 *                                 feeds, unpause, UUPS upgrades — schedule upgrades with a
 *                                 longer delay by policy)
 *        - SECURITY_ROLE       -> security multisig (immediate pause + timelock canceller)
 *        - KEEPER_ROLE         -> CREQueueExecutor + CREStrategyExecutor only
 *        - DAO multisig        -> proposer/canceller on the timelock; NO direct roles
 *        - deployer            -> all bootstrap roles renounced
 *      During the run the deployer wires the protocol (contract registration, role grants,
 *      the initial Oracle feed, keeper executors) through its TEMPORARY Registry ADMIN_ROLE
 *      bootstrap grant — those same calls are ADMIN_ROLE (48h timelock)-gated in production,
 *      and the grant is renounced before the script ends, so this is the intended bootstrap
 *      pattern.
 *      Env (required): PRIVATE_KEY, PRICE_FEED, WETH_ADDRESS, DAO_ADDRESS, SECURITY_ADDRESS,
 *      DAO_TREASURY_ADDRESS, EXIT_LIQUIDITY_TARGET_ETH, CONTROLLER_RESERVE_ETH,
 *      WHITELIST_SIGNER_ADDRESS — critical addresses and CREStrategyExecutor policy knobs
 *      (wei) are never defaulted (in particular never to the deployer key / silent 0); a
 *      missing value reverts the deploy. Setting either policy knob to 0 is a valid explicit
 *      choice (immediate exits disabled / no Controller float). Set WHITELIST_SIGNER_ADDRESS
 *      to the zero address to postpone invite-signer seeding (add later via timelocked
 *      `addSigner()`). Required: PERFORMANCE_FEE_BPS (`0` disables fees). Optional:
 *      TIMELOCK_ADMIN_DELAY (defaults to 48h — sole deploy-script envOr exception).
 *
 *      Core-only: does **not** deploy DEX adapters (e.g. UniswapV3ConverterAdapter) or
 *      strategies. Those are modular follow-ups — see `DeployUniswapV3ConverterAdapter` /
 *      `DeployUniCLStrat` — with `setAllowedAdapter` / `addStrategy` always scheduled on the
 *      48h admin timelock after this script.
 *
 *      Post-deployment: bind CRE workflow identity on each executor
 *      (`setExpectedAuthor` / name / id), then enable workflow `writeReport`.
 */
contract DeployAll is ProtocolDeployBase {
    struct DeploymentResult {
        address registryProxy;
        address tokenAddress;
        address controllerProxy;
        address controllerImplementation;
        address strategyManagerProxy;
        address strategyManagerImplementation;
        address bondingCurveAddress;
        address oracleProxy;
        address oracleImplementation;
        address exitQueueProxy;
        address exitQueueImplementation;
        address converterProxy;
        address converterImplementation;
        address adminTimelock;
        address queueKeeperExecutor;
        address strategyKeeperExecutor;
        address whitelist;
    }

    uint256 public constant STALENESS_INTERVAL = 3600;

    function run() external returns (DeploymentResult memory result) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address priceFeed = vm.envAddress("PRICE_FEED");
        address weth = vm.envAddress("WETH_ADDRESS");
        address deployer = vm.addr(deployerPrivateKey);
        address dao = _protocolDao();
        address security = _protocolSecurity();

        console.log("Deploying all contracts with deployer:", deployer);
        console.log("DAO (timelock proposer):", dao);
        console.log("Emergency security:", security);

        _assertUsdQuotedFeed(priceFeed);

        vm.startBroadcast(deployerPrivateKey);

        // Timelocks first: the Registry is constructed with the 48h admin timelock as its
        // designated ADMIN_ROLE holder (the deployer keeps a bootstrap ADMIN grant from the
        // Registry constructor, renounced below).
        ProtocolTimelocks memory timelocks = _deployTimelocks(deployer, dao, security);

        address daoTreasury = _protocolDaoTreasury();
        ProtocolContracts memory protocol = _deployProtocolInstances(
            address(timelocks.adminTimelock), weth, DEFAULT_CONNECTOR_WEIGHT, _protocolFeeConfig(daoTreasury)
        );
        _registerProtocolContracts(protocol.registry, protocol, true);
        _grantTieredProtocolRoles(protocol.registry, protocol, timelocks, security);

        // Keepers are a dedicated step: deploy CRE receivers, register on the Registry
        // address book, and grant KEEPER_ROLE. Executors reject reports until workflow
        // identity is ADMIN-bound.
        KeeperExecutors memory keepers = _deployKeeperExecutors(protocol.registry, true);

        Oracle(protocol.oracle).updateUsdFeedInfo(address(0), priceFeed, STALENESS_INTERVAL);

        // Seed the initial invite signer while the deployer still holds its temporary
        // bootstrap ADMIN_ROLE grant — adding a signer afterwards requires the 48h admin
        // timelock. Zero address is an explicit "postpone seeding" choice (required env;
        // never silently omitted).
        address whitelistSigner = _protocolWhitelistSigner();
        if (whitelistSigner != address(0)) {
            Whitelist(protocol.whitelist).addSigner(whitelistSigner);
        }

        _finalizeDeployerTieredAccess(protocol.registry, deployer);

        vm.stopBroadcast();

        result = _toDeploymentResult(protocol, timelocks, keepers);
        _verifyDeployment(result, protocol, timelocks, keepers, deployer, dao, security, priceFeed);

        return result;
    }

    function _toDeploymentResult(
        ProtocolContracts memory _protocol,
        ProtocolTimelocks memory _timelocks,
        KeeperExecutors memory _keepers
    ) internal view returns (DeploymentResult memory result) {
        // The Registry is static (deployed directly, never behind an ERC1967 proxy), so it
        // has no implementation slot to read — see ProtocolDeployBase._deployRegistry().
        result.registryProxy = address(_protocol.registry);
        result.tokenAddress = address(_protocol.token);
        result.controllerProxy = address(_protocol.controller);
        result.controllerImplementation = _implementationAddress(result.controllerProxy);
        result.strategyManagerProxy = address(_protocol.strategyManager);
        result.strategyManagerImplementation = _implementationAddress(result.strategyManagerProxy);
        result.bondingCurveAddress = address(_protocol.amm);
        result.oracleProxy = address(_protocol.oracle);
        result.oracleImplementation = _implementationAddress(result.oracleProxy);
        result.exitQueueProxy = address(_protocol.exitQueue);
        result.exitQueueImplementation = _implementationAddress(result.exitQueueProxy);
        result.converterProxy = address(_protocol.converter);
        result.converterImplementation = _implementationAddress(result.converterProxy);
        result.adminTimelock = address(_timelocks.adminTimelock);
        result.queueKeeperExecutor = address(_keepers.queueExecutor);
        result.strategyKeeperExecutor = address(_keepers.strategyExecutor);
        result.whitelist = address(_protocol.whitelist);
    }

    function _verifyDeployment(
        DeploymentResult memory result,
        ProtocolContracts memory protocol,
        ProtocolTimelocks memory timelocks,
        KeeperExecutors memory keepers,
        address deployer,
        address dao,
        address security,
        address priceFeed
    ) internal view {
        console.log("\n=== Verification ===");
        console.log("Registry proxy:", result.registryProxy);
        console.log("EVE:", result.tokenAddress);
        console.log("Controller proxy:", result.controllerProxy);
        console.log("StrategyManager proxy:", result.strategyManagerProxy);
        console.log("Oracle proxy:", result.oracleProxy);
        console.log("ExitQueue proxy:", result.exitQueueProxy);
        console.log("AMM:", result.bondingCurveAddress);
        console.log("Converter proxy:", result.converterProxy);
        console.log("Whitelist:", result.whitelist);
        console.log("Admin timelock (48h):", result.adminTimelock);
        console.log("CREQueueExecutor:", result.queueKeeperExecutor);
        console.log("CREStrategyExecutor:", result.strategyKeeperExecutor);

        _verifyRegistryWiring(protocol.registry, protocol);
        _verifyModuleRegistryBackpointers(protocol, result.registryProxy);
        _verifyTimelockWiring(protocol.registry, timelocks, deployer, dao, security);
        _verifyKeeperExecutors(protocol.registry, keepers, true);

        // Protocol role grants (SECURITY is a direct multisig grant — not timelock wiring).
        // Modular Finalize uses _verifyCriticalRoleGrants for the full skipped-step surface;
        // DeployAll only needs the grants this script itself makes.
        require(protocol.registry.hasRole(Auth.SECURITY_ROLE, security), "CRITICAL: security missing SECURITY_ROLE");
        require(
            protocol.registry.hasRole(Auth.MINTER_ROLE, address(protocol.amm)),
            "CRITICAL: AMM missing MINTER_ROLE on Registry"
        );
        require(
            protocol.registry.hasRole(Auth.MINTER_ROLE, address(protocol.strategyManager)),
            "CRITICAL: StrategyManager missing MINTER_ROLE on Registry"
        );
        require(
            protocol.registry.hasRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, address(protocol.converter)),
            "CRITICAL: Converter missing CONVERTER_CALLER_MANAGER_ROLE on Registry"
        );

        require(Oracle(result.oracleProxy).isTokenSupported(address(0)), "CRITICAL: Oracle missing ETH feed");

        console.log("ETH price feed:", priceFeed);
        console.log("All deployment checks passed");
        console.log("Next steps: bind CRE workflow identity on each executor,");
        console.log("then enable writeReport. Keep a manual multisig KEEPER_ROLE.");
    }

    /// @dev Every module resolves the protocol Registry; verify each back-pointer so a
    ///      misconfigured proxy cannot slip through (matches the per-module checks the
    ///      modular deploy scripts perform individually).
    function _verifyModuleRegistryBackpointers(ProtocolContracts memory protocol, address registryProxy)
        internal
        view
    {
        require(address(protocol.token.registry()) == registryProxy, "CRITICAL: EVE registry() mismatch");
        require(address(protocol.controller.registry()) == registryProxy, "CRITICAL: Controller registry() mismatch");
        require(
            address(protocol.strategyManager.registry()) == registryProxy,
            "CRITICAL: StrategyManager registry() mismatch"
        );
        require(address(protocol.oracle.registry()) == registryProxy, "CRITICAL: Oracle registry() mismatch");
        require(address(protocol.exitQueue.registry()) == registryProxy, "CRITICAL: ExitQueue registry() mismatch");
        require(address(protocol.amm.registry()) == registryProxy, "CRITICAL: AMM registry() mismatch");
        require(address(protocol.converter.registry()) == registryProxy, "CRITICAL: Converter registry() mismatch");
        require(address(protocol.whitelist.registry()) == registryProxy, "CRITICAL: Whitelist registry() mismatch");
    }
}
