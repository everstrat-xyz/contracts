// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Registry} from "registry/Registry.sol";
import {Converter} from "../src/contracts/Converter.sol";
import {Controller} from "../src/contracts/Controller.sol";
import {EVE} from "../src/contracts/EVE.sol";
import {AMM} from "../src/contracts/AMM.sol";
import {StrategyManager} from "../src/contracts/StrategyManager.sol";
import {Oracle} from "../src/contracts/Oracle.sol";
import {ExitQueue} from "../src/contracts/ExitQueue.sol";
import {Whitelist} from "../src/contracts/Whitelist.sol";
import {CREQueueExecutor} from "../src/contracts/automation/CREQueueExecutor.sol";
import {CREStrategyExecutor} from "../src/contracts/automation/CREStrategyExecutor.sol";

import {Auth} from "../src/libraries/Auth.sol";
import {IStrategyManager} from "../src/interfaces/IStrategyManager.sol";

/**
 * @title ProtocolDeployBase
 * @notice Shared Registry-centric deployment helpers for Foundry scripts.
 */
abstract contract ProtocolDeployBase is Script {
    uint256 internal constant DEFAULT_CONNECTOR_WEIGHT = 5e17;

    // ============ Timelock Tier Delays (PL-003) ============
    // The privileged ADMIN_ROLE is held by a TimelockController so the reaction window
    // is enforced on-chain. TIMELOCK_ADMIN_DELAY may be omitted and falls back to the
    // production policy below — the sole envOr exception in deploy scripts (never weaker).

    /// @notice Production policy minimum for admin timelock delay (48h). Used as the
    ///         `TIMELOCK_ADMIN_DELAY` envOr fallback. Upgrades should be scheduled with a
    ///         longer delay (e.g. 72h) by policy — TimelockController enforces only the minimum.
    uint256 internal constant DEFAULT_ADMIN_TIMELOCK_DELAY = 48 hours;

    struct ProtocolContracts {
        Registry registry;
        EVE token;
        Controller controller;
        StrategyManager strategyManager;
        Oracle oracle;
        ExitQueue exitQueue;
        AMM amm;
        Converter converter;
        Whitelist whitelist;
    }

    struct ProtocolTimelocks {
        TimelockController adminTimelock; // 48h — holds ADMIN_ROLE (incl. oracle feeds and UUPS upgrades)
    }

    struct KeeperExecutors {
        CREQueueExecutor queueExecutor;
        CREStrategyExecutor strategyExecutor;
    }

    function _deployRegistry(address _admin) internal returns (Registry registry) {
        registry = new Registry(_admin);
    }

    function _deployExitQueue(Registry _registry) internal returns (ExitQueue exitQueue) {
        ExitQueue exitQueueImpl = new ExitQueue();
        exitQueue = ExitQueue(
            address(
                new ERC1967Proxy(
                    address(exitQueueImpl), abi.encodeWithSelector(ExitQueue.initialize.selector, address(_registry))
                )
            )
        );
    }

    function _deployController(Registry _registry) internal returns (address implementation, Controller controller) {
        implementation = address(new Controller());
        controller = Controller(
            payable(
                new ERC1967Proxy(
                    implementation, abi.encodeWithSelector(Controller.initialize.selector, address(_registry))
                )
            )
        );
    }

    function _deployOracle(Registry _registry) internal returns (address implementation, Oracle oracle) {
        implementation = address(new Oracle());
        oracle = Oracle(
            address(
                new ERC1967Proxy(implementation, abi.encodeWithSelector(Oracle.initialize.selector, address(_registry)))
            )
        );
    }

    function _deployStrategyManager(Registry _registry, IStrategyManager.FeeConfig memory _feeConfig)
        internal
        returns (address implementation, StrategyManager strategyManager)
    {
        implementation = address(new StrategyManager());
        strategyManager = StrategyManager(
            payable(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeWithSelector(StrategyManager.initialize.selector, address(_registry), _feeConfig)
                )
            )
        );
    }

    function _deployConverter(Registry _registry, address _weth)
        internal
        returns (address implementation, Converter converter)
    {
        implementation = address(new Converter());
        converter = Converter(
            payable(
                new ERC1967Proxy(
                    implementation, abi.encodeWithSelector(Converter.initialize.selector, address(_registry), _weth)
                )
            )
        );
    }

    /**
     * @notice Deploys the static Whitelist contract.
     * @param _registry The protocol Registry.
     */
    function _deployWhitelist(Registry _registry) internal returns (Whitelist whitelist) {
        whitelist = new Whitelist(address(_registry));
    }

    function _deployProtocolInstances(
        address _admin,
        address _weth,
        uint256 _connectorWeight,
        IStrategyManager.FeeConfig memory _feeConfig
    ) internal returns (ProtocolContracts memory contracts) {
        contracts.registry = _deployRegistry(_admin);
        contracts.token = new EVE(address(contracts.registry));
        contracts.exitQueue = _deployExitQueue(contracts.registry);

        (, contracts.controller) = _deployController(contracts.registry);
        (, contracts.oracle) = _deployOracle(contracts.registry);
        (, contracts.strategyManager) = _deployStrategyManager(contracts.registry, _feeConfig);
        (, contracts.converter) = _deployConverter(contracts.registry, _weth);
        contracts.whitelist = _deployWhitelist(contracts.registry);

        contracts.amm = new AMM(address(contracts.registry), _connectorWeight);
    }

    /// @notice DAO treasury for performance-fee payouts (StrategyManager EVE fee mint recipient).
    /// @dev REQUIRED env — no default. Fee flows must be wired to an explicitly configured
    ///      address, never silently to the deployer or another implicit fallback.
    function _protocolDaoTreasury() internal view returns (address) {
        return vm.envAddress("DAO_TREASURY_ADDRESS");
    }

    /// @notice Production fee config: DAO treasury + required `PERFORMANCE_FEE_BPS` env.
    /// @dev PERFORMANCE_FEE_BPS must be set explicitly (`0` = fees disabled). No envOr fallback.
    function _protocolFeeConfig(address _daoTreasury) internal view returns (IStrategyManager.FeeConfig memory) {
        return IStrategyManager.FeeConfig({
            daoTreasury: _daoTreasury,
            performanceFeeBps: vm.envUint("PERFORMANCE_FEE_BPS")
        });
    }

    function _registerProtocolContracts(Registry _registry, ProtocolContracts memory _contracts, bool _registerAmm)
        internal
    {
        uint256 count = _registerAmm ? 8 : 7;
        bytes32[] memory keys = new bytes32[](count);
        address[] memory addresses = new address[](count);

        keys[0] = Auth.CONTROLLER;
        addresses[0] = address(_contracts.controller);

        uint256 idx = 1;
        if (_registerAmm) {
            keys[idx] = Auth.AMM;
            addresses[idx] = address(_contracts.amm);
            idx++;
        }

        keys[idx] = Auth.STRATEGY_MANAGER;
        addresses[idx] = address(_contracts.strategyManager);
        idx++;
        keys[idx] = Auth.EXIT_QUEUE;
        addresses[idx] = address(_contracts.exitQueue);
        idx++;
        keys[idx] = Auth.ORACLE;
        addresses[idx] = address(_contracts.oracle);
        idx++;
        keys[idx] = Auth.EVE;
        addresses[idx] = address(_contracts.token);
        idx++;
        keys[idx] = Auth.CONVERTER;
        addresses[idx] = address(_contracts.converter);
        idx++;
        keys[idx] = Auth.WHITELIST;
        addresses[idx] = address(_contracts.whitelist);

        _registry.registerContracts(keys, addresses);
    }

    function _requireUnregistered(Registry _registry, bytes32 _key) internal view {
        try _registry.getContractByKey(_key) returns (address) {
            revert("CRITICAL: key already registered on Registry");
        } catch {}
    }

    function _registerAndVerify(Registry _registry, bytes32 _key, address _address) internal {
        _requireUnregistered(_registry, _key);
        _registry.registerContract(_key, _address);
        require(_registry.getContractByKey(_key) == _address, "CRITICAL: Registry registration failed");
    }

    // ============ Oracle Feed Validation ============

    /// @dev Chainlink aggregator descriptions follow the "<BASE> / <QUOTE>" convention
    ///      (e.g. "ETH / USD", "Calculated stETH / USD").
    string internal constant USD_QUOTE_DESCRIPTION_SUFFIX = " / USD";

    /**
     * @notice Assert that `_priceFeed` self-describes as a USD-quoted Chainlink feed.
     * @dev Deploy-time guard for the Oracle USD-quote assumption (see
     *      {IOracle-updateUsdFeedInfo}). `description()` is advisory — not used as an
     *      on-chain check — but at deployment a nonconforming string usually means the
     *      wrong feed address, so scripts fail closed.
     */
    function _assertUsdQuotedFeed(address _priceFeed) internal view {
        string memory feedDescription = AggregatorV3Interface(_priceFeed).description();
        require(
            _endsWith(feedDescription, USD_QUOTE_DESCRIPTION_SUFFIX),
            string.concat("CRITICAL: price feed description() is not '<BASE> / USD': ", feedDescription)
        );
    }

    function _endsWith(string memory _value, string memory _suffix) internal pure returns (bool) {
        bytes memory valueBytes = bytes(_value);
        bytes memory suffixBytes = bytes(_suffix);
        if (valueBytes.length < suffixBytes.length) return false;

        uint256 offset = valueBytes.length - suffixBytes.length;
        for (uint256 i; i < suffixBytes.length; ++i) {
            if (valueBytes[offset + i] != suffixBytes[i]) return false;
        }
        return true;
    }

    function _implementationAddress(address _proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(_proxy, slot))));
    }

    // ============ Deployment Configuration (env) ============
    // Every address that ends up holding a role (or receiving protocol value) is a REQUIRED
    // env read: `vm.envAddress` reverts loudly when the variable is unset. None of these may
    // ever default to the deployer key — a silent fallback would hand the deployer permanent
    // governance power.

    /// @notice DAO multisig (PL-003): proposer/canceller on the admin timelock. Holds no
    ///         direct protocol role.
    function _protocolDao() internal view returns (address) {
        return vm.envAddress("DAO_ADDRESS");
    }

    /// @notice Emergency security multisig (SECURITY_ROLE: immediate pause + timelock canceller).
    function _protocolSecurity() internal view returns (address) {
        return vm.envAddress("SECURITY_ADDRESS");
    }

    /// @notice Admin TimelockController of an existing deployment — the protocol's designated
    ///         ADMIN_ROLE holder after bootstrap teardown. Used by modular scripts that run
    ///         after DeployRegistry (which deploys the timelock and logs this address for export).
    function _protocolAdminTimelock() internal view returns (address) {
        return vm.envAddress("TIMELOCK_ADDRESS");
    }

    /// @notice Initial Whitelist invite-signer key (the server's KMS-held signing address).
    /// @dev REQUIRED env read (same convention as DAO/SECURITY/treasury). Set to the zero
    ///      address explicitly to postpone seeding — leaving `whitelist()` unusable until an
    ///      admin (48h timelock in production) calls `addSigner()`. Never omitted silently
    ///      and never defaulted to the deployer.
    function _protocolWhitelistSigner() internal view returns (address) {
        return vm.envAddress("WHITELIST_SIGNER_ADDRESS");
    }

    /**
     * @notice Deploys both CRE keeper executors, registers them on the Registry address
     *         book, optionally grants them KEEPER_ROLE, and applies Strategy executor
     *         policy knobs from required env.
     * @dev In the automated trust model the executors are the ONLY KEEPER_ROLE holders —
     *      Chainlink infrastructure never receives a protocol role. The KeystoneForwarder
     *      is immutable at construction; workflow identity is bound afterward via ADMIN
     *      `setExpectedAuthor` / `setExpectedWorkflowName` / `setExpectedWorkflowId`
     *      (ReceiverTemplate setters; Registry ADMIN instead of Ownable).
     *
     *      Required CRE env:
     *        - KEYSTONE_FORWARDER: Chainlink-managed KeystoneForwarder address
     *        - CHAIN_SELECTOR: CCIP chain selector for this deployment (uint64)
     *        - MAX_REPORT_AGE: max report age in seconds (uint64, must be > 0)
     *
     *      Policy knobs (`EXIT_LIQUIDITY_TARGET_ETH`, `CONTROLLER_RESERVE_ETH`) are REQUIRED
     *      env (wei) — `vm.envUint` reverts when unset. Zero is a valid explicit choice.
     * @param _registry The protocol Registry (caller must hold ADMIN_ROLE)
     * @param _grantKeeperRole Whether to grant KEEPER_ROLE to both executors (false in
     *        production when the grant must be scheduled through the 48h admin timelock)
     */
    function _deployKeeperExecutors(Registry _registry, bool _grantKeeperRole)
        internal
        returns (KeeperExecutors memory keepers)
    {
        address forwarder = vm.envAddress("KEYSTONE_FORWARDER");
        uint64 chainSelector = uint64(vm.envUint("CHAIN_SELECTOR"));
        uint64 maxReportAge = uint64(vm.envUint("MAX_REPORT_AGE"));

        keepers.queueExecutor = new CREQueueExecutor(address(_registry), forwarder, chainSelector, maxReportAge);
        keepers.strategyExecutor = new CREStrategyExecutor(address(_registry), forwarder, chainSelector, maxReportAge);

        bytes32[] memory keys = new bytes32[](2);
        address[] memory addresses = new address[](2);
        keys[0] = Auth.QUEUE_KEEPER_EXECUTOR;
        addresses[0] = address(keepers.queueExecutor);
        keys[1] = Auth.STRATEGY_KEEPER_EXECUTOR;
        addresses[1] = address(keepers.strategyExecutor);
        _registry.registerContracts(keys, addresses);

        if (_grantKeeperRole) {
            bytes32[] memory roles = new bytes32[](2);
            address[] memory accounts = new address[](2);
            roles[0] = Auth.KEEPER_ROLE;
            accounts[0] = address(keepers.queueExecutor);
            roles[1] = Auth.KEEPER_ROLE;
            accounts[1] = address(keepers.strategyExecutor);
            _registry.grantRoles(roles, accounts);
        }

        // Explicit policy knobs — required env, zero allowed. Applied while the deployer
        // still holds bootstrap ADMIN_ROLE (last free config window before the 48h timelock).
        uint256 exitLiquidityTarget = vm.envUint("EXIT_LIQUIDITY_TARGET_ETH");
        uint256 controllerReserve = vm.envUint("CONTROLLER_RESERVE_ETH");
        keepers.strategyExecutor.setExitLiquidityTargetETH(exitLiquidityTarget);
        keepers.strategyExecutor.setControllerReserveETH(controllerReserve);
    }

    // ============ Timelock Deployment (PL-003) ============

    /**
     * @notice Deploys the admin TimelockController.
     * @param _deployer Temporary timelock admin used only to grant the security
     *        CANCELLER_ROLE; renounced before this function returns.
     * @param _proposer The DAO multisig — sole proposer (and canceller).
     * @param _security Emergency security — canceller (can kill malicious queued
     *        operations but can never propose or execute).
     * @dev TIMELOCK_ADMIN_DELAY may be omitted: envOr falls back to
     *      {DEFAULT_ADMIN_TIMELOCK_DELAY} (48h) — never a weaker value. This is the only
     *      deploy-script envOr exception; other knobs must be set explicitly.
     */
    function _deployTimelocks(address _deployer, address _proposer, address _security)
        internal
        returns (ProtocolTimelocks memory timelocks)
    {
        timelocks.adminTimelock = _deployTimelock(
            vm.envOr("TIMELOCK_ADMIN_DELAY", DEFAULT_ADMIN_TIMELOCK_DELAY), _deployer, _proposer, _security
        );
    }

    function _deployTimelock(uint256 _minDelay, address _deployer, address _proposer, address _security)
        internal
        returns (TimelockController timelock)
    {
        address[] memory proposers = new address[](1);
        proposers[0] = _proposer; // OZ also grants the proposer CANCELLER_ROLE

        // address(0) executor = open execution: once the delay has passed anyone may
        // execute, so liveness does not depend on a single operator key.
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        // Deployer is a TEMPORARY timelock admin, used only to grant the security
        // CANCELLER_ROLE; the role is renounced immediately so the timelock becomes
        // self-administered (changes to its own roles must pass through itself).
        timelock = new TimelockController(_minDelay, proposers, executors, _deployer);
        timelock.grantRole(timelock.CANCELLER_ROLE(), _security);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), _deployer);
    }

    /**
     * @notice Grants the tiered protocol roles: every privileged role goes to its
     *         timelock, never to an EOA/multisig directly. The security gets the
     *         (pause-only) SECURITY_ROLE. KEEPER_ROLE is granted separately to the
     *         keeper executors via {_deployKeeperExecutors}. The deployer retains its
     *         bootstrap ADMIN_ROLE (from the Registry constructor) to register the
     *         initial Oracle feeds in the same deployment batch — renounced in
     *         {_finalizeDeployerTieredAccess}.
     */
    function _grantTieredProtocolRoles(
        Registry _registry,
        ProtocolContracts memory _contracts,
        ProtocolTimelocks memory _timelocks,
        address _security
    ) internal {
        bytes32[] memory roles = new bytes32[](5);
        address[] memory accounts = new address[](5);

        roles[0] = Auth.ADMIN_ROLE;
        accounts[0] = address(_timelocks.adminTimelock);
        roles[1] = Auth.SECURITY_ROLE;
        accounts[1] = _security;
        roles[2] = Auth.MINTER_ROLE;
        accounts[2] = address(_contracts.amm);
        roles[3] = Auth.CONVERTER_CALLER_MANAGER_ROLE;
        accounts[3] = address(_contracts.converter);
        roles[4] = Auth.MINTER_ROLE;
        accounts[4] = address(_contracts.strategyManager);

        _registry.grantRoles(roles, accounts);
    }

    /**
     * @notice Renounces the deployer's bootstrap ADMIN_ROLE. In the PL-003 timelock model
     *         this ALWAYS renounces — no EOA/multisig may end a deployment holding
     *         ADMIN_ROLE; the role lives exclusively on the admin TimelockController.
     */
    function _finalizeDeployerTieredAccess(Registry _registry, address _deployer) internal {
        if (_registry.hasRole(Auth.ADMIN_ROLE, _deployer)) {
            _registry.renounceRole(Auth.ADMIN_ROLE, _deployer);
        }
    }

    /**
     * @notice Verifies the PL-003 timelock wiring end state: Registry `ADMIN_ROLE` is held
     *         only by the admin TimelockController (not the deployer, DAO, or security), and
     *         the timelock's own governance roles are correctly assigned (DAO proposes,
     *         security cancels, execution is open). Protocol role grants such as
     *         `SECURITY_ROLE` are verified separately via {_verifyCriticalRoleGrants}.
     */
    function _verifyTimelockWiring(
        Registry _registry,
        ProtocolTimelocks memory _timelocks,
        address _deployer,
        address _proposer,
        address _security
    ) internal view {
        TimelockController adminTl = _timelocks.adminTimelock;

        require(_registry.hasRole(Auth.ADMIN_ROLE, address(adminTl)), "CRITICAL: admin timelock missing ADMIN_ROLE");

        // No direct ADMIN_ROLE outside the timelock
        require(!_registry.hasRole(Auth.ADMIN_ROLE, _deployer), "CRITICAL: deployer still holds ADMIN_ROLE");
        require(!_registry.hasRole(Auth.ADMIN_ROLE, _proposer), "CRITICAL: DAO holds direct ADMIN_ROLE");
        require(!_registry.hasRole(Auth.ADMIN_ROLE, _security), "CRITICAL: security holds ADMIN_ROLE");

        _verifyTimelockRoles(adminTl, _deployer, _proposer, _security);
    }

    function _verifyTimelockRoles(TimelockController _timelock, address _deployer, address _proposer, address _security)
        internal
        view
    {
        require(_timelock.hasRole(_timelock.PROPOSER_ROLE(), _proposer), "CRITICAL: DAO missing PROPOSER_ROLE");
        require(_timelock.hasRole(_timelock.CANCELLER_ROLE(), _security), "CRITICAL: security missing CANCELLER_ROLE");
        require(_timelock.hasRole(_timelock.EXECUTOR_ROLE(), address(0)), "CRITICAL: timelock execution not open");
        require(
            !_timelock.hasRole(_timelock.DEFAULT_ADMIN_ROLE(), _deployer), "CRITICAL: deployer still admin on timelock"
        );
        require(!_timelock.hasRole(_timelock.PROPOSER_ROLE(), _security), "CRITICAL: security can propose");
    }

    /**
     * @notice Verifies the PL-003 deployer end state for a modular deploy step: the
     *         configured protocol admin (the admin TimelockController) holds ADMIN_ROLE and
     *         the deployer has fully renounced it. Mirrors the {_verifyTimelockWiring}
     *         deployer checks for scripts that operate on an already-deployed Registry.
     */
    function _verifyDeployerTieredAccess(Registry _registry, address _deployer, address _admin) internal view {
        require(_registry.hasRole(Auth.ADMIN_ROLE, _admin), "CRITICAL: admin missing ADMIN_ROLE on Registry");
        require(!_registry.hasRole(Auth.ADMIN_ROLE, _deployer), "CRITICAL: deployer still holds ADMIN_ROLE on Registry");
    }

    /**
     * @notice Verifies every critical protocol role grant for a completed *modular*
     *         deployment (FinalizeProtocolDeploy). Fails loudly on any misconfiguration —
     *         a missing grant discovered only at runtime costs a 48h-timelocked repair.
     *         Includes `SECURITY_ROLE` on the security multisig (direct grant, not timelock
     *         wiring — see {_verifyTimelockWiring}). DeployAll verifies the same grants
     *         inline rather than calling this helper (no skipped-step surface to catch).
     * @dev Resolving each Registry key reverts when the module was never registered, so a
     *      skipped modular step (e.g. DeployConverter or DeployKeeperExecutors) fails here
     *      with a clear `RegistryContractNotRegistered` before the deployer renounces ADMIN.
     *      KEEPER_ROLE is verified strictly: when DeployKeeperExecutors runs with
     *      GRANT_KEEPER_ROLE=false the grants must land (via the admin timelock) BEFORE
     *      FinalizeProtocolDeploy runs.
     */
    function _verifyCriticalRoleGrants(Registry _registry, address _security) internal view {
        // Core module registrations (revert loudly when a modular step was skipped).
        _registry.getContractByKey(Auth.CONTROLLER);
        _registry.getContractByKey(Auth.EXIT_QUEUE);
        _registry.getContractByKey(Auth.ORACLE);
        _registry.getContractByKey(Auth.EVE);
        address amm = _registry.getContractByKey(Auth.AMM);
        address strategyManager = _registry.getContractByKey(Auth.STRATEGY_MANAGER);
        address converter = _registry.getContractByKey(Auth.CONVERTER);
        address queueExecutor = _registry.getContractByKey(Auth.QUEUE_KEEPER_EXECUTOR);
        address strategyExecutor = _registry.getContractByKey(Auth.STRATEGY_KEEPER_EXECUTOR);

        require(_registry.hasRole(Auth.SECURITY_ROLE, _security), "CRITICAL: security missing SECURITY_ROLE");
        require(_registry.hasRole(Auth.MINTER_ROLE, amm), "CRITICAL: AMM missing MINTER_ROLE");
        require(_registry.hasRole(Auth.MINTER_ROLE, strategyManager), "CRITICAL: StrategyManager missing MINTER_ROLE");
        require(
            _registry.hasRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, converter),
            "CRITICAL: Converter missing CONVERTER_CALLER_MANAGER_ROLE"
        );
        require(_registry.hasRole(Auth.KEEPER_ROLE, queueExecutor), "CRITICAL: CREQueueExecutor missing KEEPER_ROLE");
        require(
            _registry.hasRole(Auth.KEEPER_ROLE, strategyExecutor),
            "CRITICAL: CREStrategyExecutor missing KEEPER_ROLE"
        );
    }

    function _verifyRegistryWiring(Registry _registry, ProtocolContracts memory _contracts) internal view {
        require(
            _registry.getContractByKey(Auth.CONTROLLER) == address(_contracts.controller),
            "CRITICAL: Registry CONTROLLER mismatch"
        );
        require(_registry.getContractByKey(Auth.AMM) == address(_contracts.amm), "CRITICAL: Registry AMM mismatch");
        require(
            _registry.getContractByKey(Auth.STRATEGY_MANAGER) == address(_contracts.strategyManager),
            "CRITICAL: Registry STRATEGY_MANAGER mismatch"
        );
        require(
            _registry.getContractByKey(Auth.EXIT_QUEUE) == address(_contracts.exitQueue),
            "CRITICAL: Registry EXIT_QUEUE mismatch"
        );
        require(
            _registry.getContractByKey(Auth.ORACLE) == address(_contracts.oracle), "CRITICAL: Registry ORACLE mismatch"
        );
        require(_registry.getContractByKey(Auth.EVE) == address(_contracts.token), "CRITICAL: Registry EVE mismatch");
        require(
            _registry.getContractByKey(Auth.CONVERTER) == address(_contracts.converter),
            "CRITICAL: Registry CONVERTER mismatch"
        );
        require(
            _registry.getContractByKey(Auth.WHITELIST) == address(_contracts.whitelist),
            "CRITICAL: Registry WHITELIST mismatch"
        );
    }

    function _verifyKeeperExecutors(Registry _registry, KeeperExecutors memory _keepers, bool _expectKeeperRole)
        internal
        view
    {
        require(
            _registry.getContractByKey(Auth.QUEUE_KEEPER_EXECUTOR) == address(_keepers.queueExecutor),
            "CRITICAL: Registry QUEUE_KEEPER_EXECUTOR mismatch"
        );
        require(
            _registry.getContractByKey(Auth.STRATEGY_KEEPER_EXECUTOR) == address(_keepers.strategyExecutor),
            "CRITICAL: Registry STRATEGY_KEEPER_EXECUTOR mismatch"
        );
        require(
            address(_keepers.queueExecutor.registry()) == address(_registry),
            "CRITICAL: CREQueueExecutor registry() mismatch"
        );
        require(
            address(_keepers.strategyExecutor.registry()) == address(_registry),
            "CRITICAL: CREStrategyExecutor registry() mismatch"
        );
        if (_expectKeeperRole) {
            require(
                _registry.hasRole(Auth.KEEPER_ROLE, address(_keepers.queueExecutor)),
                "CRITICAL: CREQueueExecutor missing KEEPER_ROLE"
            );
            require(
                _registry.hasRole(Auth.KEEPER_ROLE, address(_keepers.strategyExecutor)),
                "CRITICAL: CREStrategyExecutor missing KEEPER_ROLE"
            );
        }

        uint256 exitLiquidityTarget = _keepers.strategyExecutor.exitLiquidityTargetETH();
        uint256 controllerReserve = _keepers.strategyExecutor.controllerReserveETH();
        console.log("exitLiquidityTargetETH (wei):", exitLiquidityTarget);
        console.log("controllerReserveETH (wei):", controllerReserve);
        if (exitLiquidityTarget == 0) {
            console.log("WARNING: exitLiquidityTargetETH is 0 - immediate exits disabled");
        }
        if (controllerReserve == 0) {
            console.log("WARNING: controllerReserveETH is 0 - no idle Controller reserve beyond pending redemptions");
        }
    }
}
