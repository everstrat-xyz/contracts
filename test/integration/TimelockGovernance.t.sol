// SPDX-License-Identifier: MIT
// solhint-disable compiler-version, import-path-check, use-natspec, ordering, func-name-mixedcase
pragma solidity ^0.8.13;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin-upgradeable/utils/PausableUpgradeable.sol";

import {Registry} from "registry/Registry.sol";
import {Controller} from "../../src/contracts/Controller.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {UniCLStrat} from "../../src/contracts/strategies/UniCLStrat.sol";
import {Auth} from "../../src/libraries/Auth.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {IUniCLStrat} from "../../src/interfaces/strategies/IUniCLStrat.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUniCLPool, MockWETH} from "../mocks/UniCLStratMocks.sol";
import {MockConverterAdapter} from "../mocks/MockConverterAdapter.sol";

/**
 * @title TimelockGovernanceTest
 * @notice PL-003 integration tests: the privileged ADMIN_ROLE is held exclusively by the
 *         admin TimelockController, the security can only pause (immediately) and cancel
 *         queued operations, and no EOA/multisig can act on the protocol directly.
 * @dev Mirrors the DeployAll wiring:
 *        ADMIN_ROLE    -> 48h admin timelock (config, registry, roles, oracle feeds, unpause, upgrades)
 *        SECURITY_ROLE -> security (pause only; canceller on the timelock)
 *        DAO           -> proposer on the timelock; no direct protocol roles
 */
contract TimelockGovernanceTest is ProtocolTestBase {
    uint256 public constant ADMIN_TIMELOCK_DELAY = 48 hours;
    uint256 public constant STALENESS_INTERVAL = 3600;
    uint256 public constant NEW_CONNECTOR_WEIGHT = 6e17;
    int256 public constant FEED_PRICE = 2000e8;
    uint8 public constant FEED_DECIMALS = 8;
    bytes32 public constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes4 public constant REGISTRY_CLIENT_MISSING_ROLE_SELECTOR =
        bytes4(keccak256("RegistryClientMissingRole(bytes32)"));

    address public dao = makeAddr("dao");
    address public security = makeAddr("security");
    address public keeper = makeAddr("keeper");

    TimelockController public adminTimelock;
    ProtocolContracts public protocol;
    MockPriceFeed public ethPriceFeed;
    UniCLStrat public strategy;

    function setUp() public {
        // Deploy the admin timelock: DAO proposes, execution is open, the security can
        // cancel, and the deployer's temporary timelock admin access is renounced.
        adminTimelock = _deployTimelock(ADMIN_TIMELOCK_DELAY);

        // Registry is constructed with the admin timelock as its designated ADMIN_ROLE
        // holder; this test contract keeps a bootstrap ADMIN grant (renounced below).
        protocol = _deployProtocolInstances(address(adminTimelock), DEFAULT_CONNECTOR_WEIGHT);
        _registerProtocolContracts(protocol.registry, protocol, address(this), true);

        bytes32[] memory roles = new bytes32[](3);
        address[] memory accounts = new address[](3);
        roles[0] = Auth.SECURITY_ROLE;
        accounts[0] = security;
        roles[1] = Auth.KEEPER_ROLE;
        accounts[1] = keeper;
        roles[2] = Auth.MINTER_ROLE;
        accounts[2] = address(protocol.amm);
        protocol.registry.grantRoles(roles, accounts);

        // Bootstrap the ETH feed via the deployer's ADMIN_ROLE, then drop it.
        ethPriceFeed = new MockPriceFeed(FEED_DECIMALS, FEED_PRICE);
        protocol.oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), STALENESS_INTERVAL);
        strategy = _deployUniCLStrat();
        protocol.registry.renounceRole(Auth.ADMIN_ROLE, address(this));
    }

    /// @dev Minimal mock-backed UniCLStrat so the security pause sweep covers the strategy
    ///      pause gate too (parameters mirror UniCLStratTestBase defaults).
    function _deployUniCLStrat() internal returns (UniCLStrat) {
        MockWETH weth = new MockWETH();
        MockERC20 pairedToken = new MockERC20("Paired Token", "PAIR", 18);
        MockUniCLPool pool = new MockUniCLPool(address(weth), address(pairedToken), 60, 0);
        MockConverterAdapter swapAdapter = new MockConverterAdapter(weth, pairedToken);
        // Allowlist the adapter on the protocol Converter so the strategy's route
        // validation passes (this test contract still holds ADMIN_ROLE during setUp).
        protocol.converter.setAllowedAdapter(address(swapAdapter), true);

        return new UniCLStrat(
            IUniCLStrat.DeploymentConfig({
                addresses: IUniCLStrat.AddressConfig({
                    registry: address(protocol.registry),
                    weth: address(weth),
                    pool: address(pool)
                }),
                routes: IUniCLStrat.RouteConfig({
                    swapAdapter: address(swapAdapter),
                    wethToPairedTokenPath: abi.encodePacked(address(weth), uint24(3000), address(pairedToken)),
                    pairedTokenToWethPath: abi.encodePacked(address(pairedToken), uint24(3000), address(weth))
                }),
                strategy: IUniCLStrat.StrategyConfig({
                    positionWidth: 2,
                    rebalanceTickThreshold: 30,
                    maxTickDeviation: 10,
                    twapInterval: 1800,
                    shortTwapInterval: 60,
                    maxTotalNAV: 100 ether
                })
            })
        );
    }

    function _deployTimelock(uint256 _minDelay) internal returns (TimelockController timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = dao;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution after the delay

        timelock = new TimelockController(_minDelay, proposers, executors, address(this));
        timelock.grantRole(timelock.CANCELLER_ROLE(), security);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));
    }

    /// @dev Schedules `_data` on `_timelock` using a data-derived salt and returns that salt
    ///      (callers pass it back to {_execute} / `hashOperation`). Deriving the salt from the
    ///      calldata means two operations with identical calldata cannot be queued at the same
    ///      time — fine for these tests, which never queue duplicates.
    function _schedule(TimelockController _timelock, address _target, bytes memory _data)
        internal
        returns (bytes32 salt)
    {
        salt = keccak256(_data);
        uint256 delay = _timelock.getMinDelay();
        vm.prank(dao);
        _timelock.schedule(_target, 0, _data, bytes32(0), salt, delay);
    }

    function _execute(TimelockController _timelock, address _target, bytes memory _data, bytes32 _salt) internal {
        _timelock.execute(_target, 0, _data, bytes32(0), _salt);
    }

    function _scheduleWarpExecute(TimelockController _timelock, address _target, bytes memory _data) internal {
        uint256 delay = _timelock.getMinDelay();
        bytes32 salt = _schedule(_timelock, _target, _data);
        vm.warp(block.timestamp + delay);
        _execute(_timelock, _target, _data, salt);
    }

    function _expectMissingRole(bytes32 _role) internal {
        vm.expectRevert(abi.encodeWithSelector(REGISTRY_CLIENT_MISSING_ROLE_SELECTOR, _role));
    }

    // ============ End State ============

    function test_EndState_PrivilegedRolesHeldOnlyByTimelocks() public view {
        Registry registry = protocol.registry;

        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, address(adminTimelock)));
        assertTrue(registry.hasRole(Auth.SECURITY_ROLE, security));

        // No EOA/multisig holds a privileged role directly
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, dao));
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, security));
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, address(this)));

        // Timelock governance: DAO proposes, security cancels, execution is open,
        // the deployer retains no timelock admin access
        assertTrue(adminTimelock.hasRole(adminTimelock.PROPOSER_ROLE(), dao));
        assertTrue(adminTimelock.hasRole(adminTimelock.CANCELLER_ROLE(), security));
        assertTrue(adminTimelock.hasRole(adminTimelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(adminTimelock.hasRole(adminTimelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(adminTimelock.hasRole(adminTimelock.PROPOSER_ROLE(), security));
    }

    // ============ No Direct Privileged Actions ============

    function test_DAO_CannotActDirectly() public {
        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(dao);
        protocol.amm.setConnectorWeight(NEW_CONNECTOR_WEIGHT);

        address newImplementation = address(new Controller());
        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(dao);
        protocol.controller.upgradeToAndCall(newImplementation, "");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, dao, Auth.ADMIN_ROLE)
        );
        vm.prank(dao);
        protocol.registry.grantRole(Auth.KEEPER_ROLE, dao);
    }

    function test_Security_CannotConfigureOrUnpause() public {
        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(security);
        protocol.amm.setConnectorWeight(NEW_CONNECTOR_WEIGHT);

        vm.prank(security);
        protocol.amm.pause();

        _expectMissingRole(Auth.ADMIN_ROLE);
        vm.prank(security);
        protocol.amm.unpause();
    }

    // ============ Timelocked Actions ============

    function test_ConfigChange_ExecutesViaAdminTimelockAfterDelay() public {
        bytes memory data = abi.encodeCall(AMM.setConnectorWeight, (NEW_CONNECTOR_WEIGHT));
        bytes32 salt = _schedule(adminTimelock, address(protocol.amm), data);

        // Premature execution reverts
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _execute(adminTimelock, address(protocol.amm), data, salt);

        vm.warp(block.timestamp + ADMIN_TIMELOCK_DELAY);
        _execute(adminTimelock, address(protocol.amm), data, salt);

        assertEq(protocol.amm.connectorWeight(), NEW_CONNECTOR_WEIGHT);
    }

    function test_Upgrade_ExecutesViaAdminTimelockAfterDelay() public {
        address newImplementation = address(new Controller());
        bytes memory data = abi.encodeCall(protocol.controller.upgradeToAndCall, (newImplementation, ""));

        _scheduleWarpExecute(adminTimelock, address(protocol.controller), data);

        address implementation =
            address(uint160(uint256(vm.load(address(protocol.controller), ERC1967_IMPLEMENTATION_SLOT))));
        assertEq(implementation, newImplementation);
    }

    function test_RoleManagement_ExecutesViaAdminTimelock() public {
        address newKeeper = makeAddr("newKeeper");
        bytes memory data = abi.encodeCall(protocol.registry.grantRole, (Auth.KEEPER_ROLE, newKeeper));

        _scheduleWarpExecute(adminTimelock, address(protocol.registry), data);

        assertTrue(protocol.registry.hasRole(Auth.KEEPER_ROLE, newKeeper));
    }

    function test_OracleFeedChange_ExecutesViaAdminTimelock() public {
        MockPriceFeed newFeed = new MockPriceFeed(FEED_DECIMALS, FEED_PRICE * 2);
        bytes memory data =
            abi.encodeCall(IOracle.updateUsdFeedInfo, (address(0), address(newFeed), STALENESS_INTERVAL));

        _scheduleWarpExecute(adminTimelock, address(protocol.oracle), data);

        assertEq(address(protocol.oracle.getUsdFeedInfo(address(0)).priceFeed), address(newFeed));
    }

    // ============ Security Emergency Path ============

    function test_Security_PausesAllModulesImmediately() public {
        vm.startPrank(security);
        protocol.amm.pause();
        protocol.controller.pause();
        protocol.exitQueue.pause();
        protocol.strategyManager.pause();
        strategy.pause();
        protocol.registry.pause();
        vm.stopPrank();

        assertTrue(protocol.amm.paused());
        assertTrue(protocol.controller.paused());
        assertTrue(protocol.exitQueue.paused());
        assertTrue(protocol.strategyManager.paused());
        assertTrue(strategy.paused());
        assertTrue(protocol.registry.paused());
    }

    function test_SecurityRegistryPause_FreezesRoleGrantsEvenViaTimelock() public {
        // A security Registry pause blocks in-flight privilege escalation: even a queued,
        // matured timelock grant cannot execute until the (timelocked) unpause.
        address attacker = makeAddr("attacker");
        bytes memory data = abi.encodeCall(protocol.registry.grantRole, (Auth.ADMIN_ROLE, attacker));
        bytes32 salt = _schedule(adminTimelock, address(protocol.registry), data);

        vm.prank(security);
        protocol.registry.pause();

        vm.warp(block.timestamp + ADMIN_TIMELOCK_DELAY);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        _execute(adminTimelock, address(protocol.registry), data, salt);

        assertFalse(protocol.registry.hasRole(Auth.ADMIN_ROLE, attacker));
    }

    function test_Unpause_GoesThroughAdminTimelock() public {
        vm.prank(security);
        protocol.amm.pause();

        bytes memory data = abi.encodeCall(protocol.amm.unpause, ());
        _scheduleWarpExecute(adminTimelock, address(protocol.amm), data);

        assertFalse(protocol.amm.paused());
    }

    function test_Security_CancelsQueuedOperation() public {
        bytes memory data = abi.encodeCall(AMM.setConnectorWeight, (NEW_CONNECTOR_WEIGHT));
        bytes32 salt = _schedule(adminTimelock, address(protocol.amm), data);
        bytes32 operationId = adminTimelock.hashOperation(address(protocol.amm), 0, data, bytes32(0), salt);

        vm.prank(security);
        adminTimelock.cancel(operationId);

        vm.warp(block.timestamp + ADMIN_TIMELOCK_DELAY);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _execute(adminTimelock, address(protocol.amm), data, salt);
    }
}
