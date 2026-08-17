// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {ProtocolDeployBase} from "../../script/ProtocolDeployBase.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWETH} from "../mocks/UniCLStratMocks.sol";
import {MockConverterAdapter} from "../mocks/MockConverterAdapter.sol";

import {AMM} from "../../src/contracts/AMM.sol";
import {Converter} from "../../src/contracts/Converter.sol";
import {CREStrategyExecutor} from "../../src/contracts/automation/CREStrategyExecutor.sol";
import {Registry} from "registry/Registry.sol";
import {IRegistry} from "interfaces/IRegistry.sol";

import {Auth} from "../../src/libraries/Auth.sol";

import {DeployAll} from "../../script/DeployAll.s.sol";
import {DeployRegistry} from "../../script/DeployRegistry.s.sol";
import {DeployController} from "../../script/DeployController.s.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {DeployExitQueue} from "../../script/DeployExitQueue.s.sol";
import {DeployEVE} from "../../script/DeployEVE.sol";
import {DeployAMM} from "../../script/DeployAMM.s.sol";
import {DeployConverter} from "../../script/DeployConverter.s.sol";
import {DeployWhitelist} from "../../script/DeployWhitelist.s.sol";
import {DeployCREExecutors} from "../../script/DeployCREExecutors.s.sol";
import {FinalizeProtocolDeploy} from "../../script/FinalizeProtocolDeploy.s.sol";

/**
 * @title DeploymentTest
 * @notice Verifies Registry-centric deployment wiring (roles and contract registration).
 */
contract DeploymentTest is ProtocolTestBase {
    function test_DeploymentWithProperRoleGrants() public {
        address deployer = address(this);
        ProtocolContracts memory contracts = _deployProtocol(deployer, DEFAULT_CONNECTOR_WEIGHT);

        Registry registry = contracts.registry;

        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, deployer));
        assertTrue(registry.hasRole(Auth.KEEPER_ROLE, deployer));
        assertTrue(registry.hasRole(Auth.MINTER_ROLE, address(contracts.amm)));

        assertEq(registry.getContractByKey(Auth.CONTROLLER), address(contracts.controller));
        assertEq(registry.getContractByKey(Auth.AMM), address(contracts.amm));
        assertEq(registry.getContractByKey(Auth.STRATEGY_MANAGER), address(contracts.strategyManager));
        assertEq(registry.getContractByKey(Auth.EXIT_QUEUE), address(contracts.exitQueue));
        assertEq(registry.getContractByKey(Auth.ORACLE), address(contracts.oracle));
        assertEq(registry.getContractByKey(Auth.EVE), address(contracts.token));

        assertFalse(contracts.strategyManager.isStrategyRegistered(address(contracts.amm)));
    }

    function test_DeploymentFailsIfAMMNotRegistered() public {
        address deployer = address(this);
        ProtocolContracts memory contracts = _deployProtocolWithoutAmm(deployer, DEFAULT_CONNECTOR_WEIGHT);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        contracts.strategyManager.totalNAVInETH();
    }

    function test_RegistryCanUpdateContractAddress() public {
        address deployer = address(this);
        ProtocolContracts memory contracts = _deployProtocol(deployer, DEFAULT_CONNECTOR_WEIGHT);

        AMM newAmm = new AMM(address(contracts.registry), DEFAULT_CONNECTOR_WEIGHT);

        vm.prank(deployer);
        contracts.registry.registerContract(Auth.AMM, address(newAmm));

        assertEq(contracts.registry.getContractByKey(Auth.AMM), address(newAmm));
    }
}

/**
 * @title DeployScriptsTest
 * @notice Runs the ACTUAL deploy scripts and verifies the PL-003 wiring they must produce:
 *         the Registry's designated ADMIN_ROLE holder is the admin TimelockController (never
 *         the DAO multisig or the deployer key directly), the DAO is the timelock's
 *         proposer, all critical addresses come from explicit env configuration, and the
 *         modular flow ends with the deployer's bootstrap ADMIN_ROLE renounced.
 * @dev `vm.setEnv` is process-global and forge runs tests in parallel, so every test writes
 *      IDENTICAL values for the shared env keys (mocks are etched at fixed addresses via
 *      `deployCodeTo`). Typed casts after etch keep each mock in this contract's type graph so
 *      Foundry can resolve `File.sol:Contract` artifact paths for `vm.getCode`.
 */
contract DeployScriptsTest is Test {
    uint256 internal constant DEPLOYER_PK = 0xD3B10;
    uint256 internal constant ADMIN_TIMELOCK_DELAY = 48 hours;
    int256 internal constant FEED_PRICE = 2000e8;
    uint8 internal constant FEED_DECIMALS = 8;

    address internal constant FEED_ADDRESS = address(0xFEED);
    address internal constant WETH_ADDRESS = address(0xF00D);
    address internal constant PAIRED_TOKEN_ADDRESS = address(0xBEEF);
    address internal constant SWAP_ADAPTER_ADDRESS = address(0xAD0B);

    address internal deployer;
    address internal dao;
    address internal security;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_PK);
        dao = makeAddr("dao");
        security = makeAddr("security");

        deployCodeTo("MockPriceFeed.sol:MockPriceFeed", abi.encode(FEED_DECIMALS, FEED_PRICE), FEED_ADDRESS);
        deployCodeTo("UniCLStratMocks.sol:MockWETH", "", WETH_ADDRESS);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Paired", "PAIRED", uint8(18)), PAIRED_TOKEN_ADDRESS);
        deployCodeTo(
            "MockConverterAdapter.sol:MockConverterAdapter",
            abi.encode(WETH_ADDRESS, PAIRED_TOKEN_ADDRESS),
            SWAP_ADAPTER_ADDRESS
        );

        // Typed casts keep mocks in the compilation graph for `deployCodeTo` / `vm.getCode`.
        // The feed also needs a USD-quoted description (issue #194); the mock default is not.
        MockPriceFeed(FEED_ADDRESS).setDescription("ETH / USD");
        assertEq(MockWETH(payable(WETH_ADDRESS)).symbol(), "WETH");
        assertEq(MockERC20(PAIRED_TOKEN_ADDRESS).symbol(), "PAIRED");
        assertEq(MockConverterAdapter(SWAP_ADAPTER_ADDRESS).name(), "MockConverterAdapter");

        // Critical addresses are REQUIRED env for the scripts — configured explicitly here,
        // exactly as an operator would; the scripts revert when any of them is missing.
        vm.setEnv("PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        vm.setEnv("PRICE_FEED", vm.toString(FEED_ADDRESS));
        vm.setEnv("WETH_ADDRESS", vm.toString(WETH_ADDRESS));
        vm.setEnv("DAO_ADDRESS", vm.toString(dao));
        vm.setEnv("SECURITY_ADDRESS", vm.toString(security));
        vm.setEnv("DAO_TREASURY_ADDRESS", vm.toString(makeAddr("treasury")));
        // Explicit zero postpones invite-signer seeding (required env; never silently omitted).
        vm.setEnv("WHITELIST_SIGNER_ADDRESS", vm.toString(address(0)));
        vm.setEnv("PERFORMANCE_FEE_BPS", "0");
        // Explicit CREStrategyExecutor policy knobs (wei) — required by deploy scripts;
        // 0 is a valid bootstrap choice (immediate exits disabled / no Controller float).
        vm.setEnv("EXIT_LIQUIDITY_TARGET_ETH", "0");
        vm.setEnv("CONTROLLER_RESERVE_ETH", "0");
        vm.setEnv("TIMELOCK_ADMIN_DELAY", vm.toString(ADMIN_TIMELOCK_DELAY));
        vm.setEnv("GRANT_KEEPER_ROLE", "true");
        // CRE / Keystone constructor immutables (Sepolia forwarder used as a stand-in).
        vm.setEnv("KEYSTONE_FORWARDER", vm.toString(makeAddr("keystoneForwarder")));
        vm.setEnv("CHAIN_SELECTOR", "16015286601757825753"); // Ethereum Sepolia
        vm.setEnv("MAX_REPORT_AGE", "3600");
    }

    function test_DeployAll_RegistryAdminIsTimelockWithDaoProposer() public {
        DeployAll.DeploymentResult memory result = new DeployAll().run();
        Registry registry = Registry(result.registryProxy);

        // The Registry's designated admin is the timelock CONTRACT — not the DAO directly.
        assertEq(registry.getRoleMemberCount(Auth.ADMIN_ROLE), 1, "ADMIN_ROLE must be held by the timelock alone");
        assertEq(registry.getRoleMember(Auth.ADMIN_ROLE, 0), result.adminTimelock);

        // PL-003: DAO proposes/cancels on the timelock, security cancels, execution is open.
        TimelockController timelock = TimelockController(payable(result.adminTimelock));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), dao), "DAO missing PROPOSER_ROLE");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), security), "security missing CANCELLER_ROLE");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "execution not open");
        assertEq(timelock.getMinDelay(), ADMIN_TIMELOCK_DELAY);

        // Operational roles: security from env; KEEPER_ROLE only on the two executors.
        assertTrue(registry.hasRole(Auth.SECURITY_ROLE, security), "security missing SECURITY_ROLE");
        assertTrue(registry.hasRole(Auth.MINTER_ROLE, result.bondingCurveAddress), "AMM missing MINTER_ROLE");
        assertTrue(
            registry.hasRole(Auth.MINTER_ROLE, result.strategyManagerProxy), "StrategyManager missing MINTER_ROLE"
        );
        assertTrue(
            registry.hasRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, result.converterProxy),
            "Converter missing CONVERTER_CALLER_MANAGER_ROLE"
        );
        assertTrue(
            registry.hasRole(Auth.KEEPER_ROLE, result.queueKeeperExecutor), "CREQueueExecutor missing KEEPER_ROLE"
        );
        assertTrue(
            registry.hasRole(Auth.KEEPER_ROLE, result.strategyKeeperExecutor), "CREStrategyExecutor missing KEEPER_ROLE"
        );
        assertEq(registry.getContractByKey(Auth.QUEUE_KEEPER_EXECUTOR), result.queueKeeperExecutor);
        assertEq(registry.getContractByKey(Auth.STRATEGY_KEEPER_EXECUTOR), result.strategyKeeperExecutor);

        // Policy knobs applied from required env (explicit 0 in setUp = bootstrap choice).
        CREStrategyExecutor strategyExecutor = CREStrategyExecutor(result.strategyKeeperExecutor);
        assertEq(strategyExecutor.exitLiquidityTargetETH(), 0);
        assertEq(strategyExecutor.controllerReserveETH(), 0);
    }

    /**
     * @notice Full modular flow end state + FinalizeProtocolDeploy guards.
     * @dev All modular scenarios live in ONE test function on purpose: `vm.setEnv` is
     *      process-global and forge runs test functions in parallel, so multiple modular
     *      tests would race on REGISTRY_ADDRESS / TIMELOCK_ADDRESS (each modular run
     *      deploys its own Registry). This is the only writer of those env keys.
     */
    function test_ModularFlow_EndToEndGrantsAndFinalizeGuards() public {
        // ============ Happy path: full modular flow produces every critical grant ============
        (address registryAddress, address timelockAddress) = _deployFreshRegistry();
        Registry registry = Registry(registryAddress);

        // The designated Registry admin is the timelock deployed by DeployRegistry (not
        // DAO_ADDRESS); the DAO is its proposer. The deployer holds only its temporary
        // bootstrap grant mid-flow.
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, timelockAddress), "timelock missing ADMIN_ROLE");
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, dao), "DAO must not hold ADMIN_ROLE directly");
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, deployer), "deployer missing bootstrap ADMIN_ROLE");
        assertTrue(registry.hasRole(Auth.SECURITY_ROLE, security), "security missing SECURITY_ROLE");
        TimelockController timelock = TimelockController(payable(timelockAddress));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), dao), "DAO missing PROPOSER_ROLE");

        _runCoreModuleSteps();
        (address converterProxy,) = new DeployConverter().run();
        new DeployWhitelist().run();
        (address strategyManagerProxy,) = new DeployAMM().run();
        (, CREStrategyExecutor strategyExecutor) = new DeployCREExecutors().run();
        assertEq(strategyExecutor.exitLiquidityTargetETH(), 0);
        assertEq(strategyExecutor.controllerReserveETH(), 0);

        new FinalizeProtocolDeploy().run();

        // Finalize renounced the bootstrap grant; the timelock remains the sole admin.
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, deployer), "deployer still holds bootstrap ADMIN_ROLE");
        assertEq(registry.getRoleMemberCount(Auth.ADMIN_ROLE), 1, "ADMIN_ROLE must be held by the timelock alone");
        assertEq(registry.getRoleMember(Auth.ADMIN_ROLE, 0), timelockAddress);

        // Every critical grant the modular flow must produce (H-3: these were silently
        // missing while FinalizeProtocolDeploy verified only ADMIN renunciation).
        assertTrue(registry.hasRole(Auth.MINTER_ROLE, registry.getContractByKey(Auth.AMM)), "AMM missing MINTER_ROLE");
        assertTrue(registry.hasRole(Auth.MINTER_ROLE, strategyManagerProxy), "StrategyManager missing MINTER_ROLE");
        assertTrue(
            registry.hasRole(Auth.CONVERTER_CALLER_MANAGER_ROLE, converterProxy),
            "Converter missing CONVERTER_CALLER_MANAGER_ROLE"
        );
        assertFalse(
            Converter(payable(converterProxy)).isAdapterAllowed(SWAP_ADAPTER_ADDRESS),
            "DeployConverter must not whitelist adapters (timelock-only)"
        );
        assertTrue(
            registry.hasRole(Auth.KEEPER_ROLE, registry.getContractByKey(Auth.QUEUE_KEEPER_EXECUTOR)),
            "CREQueueExecutor missing KEEPER_ROLE"
        );
        assertTrue(
            registry.hasRole(Auth.KEEPER_ROLE, registry.getContractByKey(Auth.STRATEGY_KEEPER_EXECUTOR)),
            "CREStrategyExecutor missing KEEPER_ROLE"
        );
        assertTrue(registry.getContractByKey(Auth.WHITELIST) != address(0), "WHITELIST not registered");

        // NOTE: `new FinalizeProtocolDeploy().run()` would make the CREATE the "next call"
        // for expectRevert — the reverting scenarios below split creation from the call.

        // ============ A skipped DeployConverter step fails finalization loudly ============
        (registryAddress,) = _deployFreshRegistry();
        registry = Registry(registryAddress);
        _runCoreModuleSteps();
        new DeployWhitelist().run();
        new DeployAMM().run();
        new DeployCREExecutors().run();
        // DeployConverter intentionally skipped.

        FinalizeProtocolDeploy finalize = new FinalizeProtocolDeploy();
        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.CONVERTER));
        finalize.run();

        // ============ A skipped DeployWhitelist step fails finalization loudly ============
        (registryAddress,) = _deployFreshRegistry();
        registry = Registry(registryAddress);
        _runCoreModuleSteps();
        new DeployConverter().run();
        new DeployAMM().run();
        new DeployCREExecutors().run();
        // DeployWhitelist intentionally skipped.

        finalize = new FinalizeProtocolDeploy();
        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.WHITELIST));
        finalize.run();

        // ============ A skipped DeployCREExecutors step fails finalization loudly ============
        (registryAddress,) = _deployFreshRegistry();
        registry = Registry(registryAddress);
        _runCoreModuleSteps();
        new DeployConverter().run();
        new DeployWhitelist().run();
        new DeployAMM().run();
        // DeployCREExecutors intentionally skipped.

        finalize = new FinalizeProtocolDeploy();
        vm.expectRevert(
            abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.QUEUE_KEEPER_EXECUTOR)
        );
        finalize.run();

        // ============ A missing grant on a registered module fails finalization loudly ============
        // The exact H-3 failure mode: StrategyManager without MINTER_ROLE.
        (registryAddress,) = _deployFreshRegistry();
        registry = Registry(registryAddress);
        _runCoreModuleSteps();
        new DeployConverter().run();
        new DeployWhitelist().run();
        (strategyManagerProxy,) = new DeployAMM().run();
        new DeployCREExecutors().run();

        // Simulate the pre-fix modular flow: the deployer (still bootstrap ADMIN) revokes
        // the StrategyManager's MINTER_ROLE before finalizing.
        vm.prank(deployer);
        registry.revokeRole(Auth.MINTER_ROLE, strategyManagerProxy);

        finalize = new FinalizeProtocolDeploy();
        vm.expectRevert("CRITICAL: StrategyManager missing MINTER_ROLE");
        finalize.run();
    }

    function _deployFreshRegistry() internal returns (address registryAddress, address timelockAddress) {
        (registryAddress, timelockAddress) = new DeployRegistry().run();
        vm.setEnv("REGISTRY_ADDRESS", vm.toString(registryAddress));
        vm.setEnv("TIMELOCK_ADDRESS", vm.toString(timelockAddress));
    }

    function _runCoreModuleSteps() internal {
        new DeployController().run();
        new DeployOracle().run();
        new DeployExitQueue().run();
        new DeployEVE().run();
    }
}

/**
 * @title UsdQuotedFeedGuardHarness
 * @notice Exposes ProtocolDeployBase._assertUsdQuotedFeed for direct testing.
 */
contract UsdQuotedFeedGuardHarness is ProtocolDeployBase {
    function assertUsdQuotedFeed(address _priceFeed) external view {
        _assertUsdQuotedFeed(_priceFeed);
    }
}

/**
 * @title UsdQuotedFeedGuardTest
 * @notice Verifies the deploy-script assertion that registered price feeds self-describe
 *         as USD-quoted ("<BASE> / USD") — the Oracle's USD-quote invariant (issue #194).
 */
contract UsdQuotedFeedGuardTest is Test {
    uint8 public constant FEED_DECIMALS = 8;
    int256 public constant FEED_PRICE = 2000e8; // $2000 with 8 feed decimals

    string internal constant REVERT_PREFIX = "CRITICAL: price feed description() is not '<BASE> / USD': ";

    UsdQuotedFeedGuardHarness internal harness;
    MockPriceFeed internal feed;

    function setUp() public {
        harness = new UsdQuotedFeedGuardHarness();
        feed = new MockPriceFeed(FEED_DECIMALS, FEED_PRICE);
    }

    function _expectGuardRevert(string memory _description) internal {
        vm.expectRevert(bytes(string.concat(REVERT_PREFIX, _description)));
    }

    function test_AssertUsdQuotedFeed_AcceptsChainlinkUsdDescription() public {
        feed.setDescription("ETH / USD");
        harness.assertUsdQuotedFeed(address(feed));
    }

    function test_AssertUsdQuotedFeed_AcceptsCalculatedUsdDescription() public {
        feed.setDescription("Calculated stETH / USD");
        harness.assertUsdQuotedFeed(address(feed));
    }

    function test_AssertUsdQuotedFeed_RejectsNonUsdQuoteCurrency() public {
        feed.setDescription("ETH / BTC");
        _expectGuardRevert("ETH / BTC");
        harness.assertUsdQuotedFeed(address(feed));
    }

    function test_AssertUsdQuotedFeed_RejectsUsdAsBaseCurrency() public {
        feed.setDescription("USD / ETH");
        _expectGuardRevert("USD / ETH");
        harness.assertUsdQuotedFeed(address(feed));
    }

    function test_AssertUsdQuotedFeed_RejectsUsdQuoteWithoutSeparator() public {
        feed.setDescription("ETH/USD");
        _expectGuardRevert("ETH/USD");
        harness.assertUsdQuotedFeed(address(feed));
    }

    function test_AssertUsdQuotedFeed_RejectsNonConformingDescription() public {
        // MockPriceFeed default description ("Mock Price Feed")
        _expectGuardRevert("Mock Price Feed");
        harness.assertUsdQuotedFeed(address(feed));
    }

    function test_AssertUsdQuotedFeed_RejectsDescriptionShorterThanSuffix() public {
        feed.setDescription("USD");
        _expectGuardRevert("USD");
        harness.assertUsdQuotedFeed(address(feed));
    }
}

/**
 * @title AdminTimelockDelayGuardHarness
 * @notice Exposes ProtocolDeployBase._requireAdminTimelockDelay for direct testing.
 */
contract AdminTimelockDelayGuardHarness is ProtocolDeployBase {
    function requireAdminTimelockDelay(uint256 _minDelay) external pure {
        _requireAdminTimelockDelay(_minDelay);
    }
}

/**
 * @title AdminTimelockDelayGuardTest
 * @notice Verifies the 48h floor applied by {_adminTimelockDelay} (PL-003): a weaker
 *         delay would let ADMIN_ROLE act inside the documented reaction window.
 */
contract AdminTimelockDelayGuardTest is Test {
    uint256 internal constant ADMIN_TIMELOCK_DELAY_FLOOR = 48 hours;
    uint256 internal constant ADMIN_TIMELOCK_DELAY_ABOVE_FLOOR = 72 hours;
    string internal constant REVERT_BELOW_FLOOR = "CRITICAL: TIMELOCK_ADMIN_DELAY below 48h floor";

    AdminTimelockDelayGuardHarness internal harness;

    function setUp() public {
        harness = new AdminTimelockDelayGuardHarness();
    }

    function test_RequireAdminTimelockDelay_AcceptsFloor() public view {
        harness.requireAdminTimelockDelay(ADMIN_TIMELOCK_DELAY_FLOOR);
    }

    function test_RequireAdminTimelockDelay_AcceptsAboveFloor() public view {
        harness.requireAdminTimelockDelay(ADMIN_TIMELOCK_DELAY_ABOVE_FLOOR);
    }

    function test_RequireAdminTimelockDelay_RejectsBelowFloor() public {
        vm.expectRevert(bytes(REVERT_BELOW_FLOOR));
        harness.requireAdminTimelockDelay(ADMIN_TIMELOCK_DELAY_FLOOR - 1);
    }

    function test_RequireAdminTimelockDelay_RejectsZero() public {
        vm.expectRevert(bytes(REVERT_BELOW_FLOOR));
        harness.requireAdminTimelockDelay(0);
    }

    function testFuzz_RequireAdminTimelockDelay_RejectsBelowFloor(uint256 delay) public {
        delay = bound(delay, 0, ADMIN_TIMELOCK_DELAY_FLOOR - 1);
        vm.expectRevert(bytes(REVERT_BELOW_FLOOR));
        harness.requireAdminTimelockDelay(delay);
    }

    function testFuzz_RequireAdminTimelockDelay_AcceptsAtOrAboveFloor(uint256 delay) public view {
        delay = bound(delay, ADMIN_TIMELOCK_DELAY_FLOOR, type(uint256).max);
        harness.requireAdminTimelockDelay(delay);
    }
}

/**
 * @title ProtocolDaoGuardHarness
 * @notice Exposes ProtocolDeployBase._requireNonZeroDao for direct testing.
 */
contract ProtocolDaoGuardHarness is ProtocolDeployBase {
    function requireNonZeroDao(address _dao) external pure {
        _requireNonZeroDao(_dao);
    }
}

/**
 * @title ProtocolDaoGuardTest
 * @notice Verifies the deploy-script rejection of DAO_ADDRESS = address(0) applied by
 *         {_protocolDao} (PL-003): OZ grants PROPOSER_ROLE to the zero address so
 *         membership checks pass, but no account can ever `schedule()`.
 */
contract ProtocolDaoGuardTest is Test {
    string internal constant REVERT_ZERO_DAO = "CRITICAL: DAO_ADDRESS is zero";

    ProtocolDaoGuardHarness internal harness;
    address internal proposer;

    function setUp() public {
        harness = new ProtocolDaoGuardHarness();
        proposer = makeAddr("proposer");
    }

    function test_RequireNonZeroDao_AcceptsNonZero() public view {
        harness.requireNonZeroDao(proposer);
    }

    function test_RequireNonZeroDao_RejectsZero() public {
        vm.expectRevert(bytes(REVERT_ZERO_DAO));
        harness.requireNonZeroDao(address(0));
    }

    function testFuzz_RequireNonZeroDao_AcceptsNonZero(address dao) public view {
        dao = address(uint160(bound(uint256(uint160(dao)), 1, type(uint160).max)));
        harness.requireNonZeroDao(dao);
    }
}
