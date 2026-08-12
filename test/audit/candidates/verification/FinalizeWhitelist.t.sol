// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolDeployBase} from "../../../../script/ProtocolDeployBase.sol";
import {AMM} from "../../../../src/contracts/AMM.sol";
import {Whitelist} from "../../../../src/contracts/Whitelist.sol";
import {Registry} from "registry/Registry.sol";
import {IAMM} from "../../../../src/interfaces/IAMM.sol";
import {IRegistry} from "interfaces/IRegistry.sol";
import {Auth} from "../../../../src/libraries/Auth.sol";

contract FinalizeWhitelistDummy {}

/// @dev Exposes the exact production deployment helpers while making this contract the
/// Registry's temporary bootstrap deployer/admin.
contract FinalizeWhitelistHarness is ProtocolDeployBase {
    Registry public deployedRegistry;

    function deployRegistry(address admin) external returns (Registry registry_) {
        registry_ = _deployRegistry(admin);
        deployedRegistry = registry_;
    }

    function register(bytes32 key, address value) external {
        deployedRegistry.registerContract(key, value);
    }

    function grant(bytes32 role, address account) external {
        deployedRegistry.grantRole(role, account);
    }

    function finalize(address admin, address security) external {
        _finalizeDeployerTieredAccess(deployedRegistry, address(this));
        _verifyDeployerTieredAccess(deployedRegistry, address(this), admin);
        _verifyCriticalRoleGrants(deployedRegistry, security);
    }
}

contract FinalizeWhitelistVerificationTest is Test {
    uint256 internal constant ADMIN_DELAY = 48 hours;
    uint256 internal constant CONNECTOR_WEIGHT = 5e17;

    address internal dao = makeAddr("dao");
    address internal security = makeAddr("security");
    address internal user = makeAddr("user");

    TimelockController internal timelock;
    FinalizeWhitelistHarness internal harness;
    Registry internal registry;
    AMM internal amm;
    Whitelist internal whitelist;
    FinalizeWhitelistDummy internal dummy;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = dao;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(ADMIN_DELAY, proposers, executors, address(0));

        harness = new FinalizeWhitelistHarness();
        registry = harness.deployRegistry(address(timelock));
        dummy = new FinalizeWhitelistDummy();
        amm = new AMM(address(registry), CONNECTOR_WEIGHT);
        whitelist = new Whitelist(address(registry));

        // Populate every key and role checked by _verifyCriticalRoleGrants, but
        // deliberately omit Auth.WHITELIST to model a skipped DeployWhitelist step.
        harness.register(Auth.CONTROLLER, address(dummy));
        harness.register(Auth.EXIT_QUEUE, address(dummy));
        harness.register(Auth.ORACLE, address(dummy));
        harness.register(Auth.EVE, address(dummy));
        harness.register(Auth.AMM, address(amm));
        harness.register(Auth.STRATEGY_MANAGER, address(dummy));
        harness.register(Auth.CONVERTER, address(dummy));
        harness.register(Auth.QUEUE_KEEPER_EXECUTOR, address(dummy));
        harness.register(Auth.STRATEGY_KEEPER_EXECUTOR, address(dummy));

        harness.grant(Auth.SECURITY_ROLE, security);
        harness.grant(Auth.MINTER_ROLE, address(amm));
        harness.grant(Auth.MINTER_ROLE, address(dummy));
        harness.grant(Auth.CONVERTER_CALLER_MANAGER_ROLE, address(dummy));
        harness.grant(Auth.KEEPER_ROLE, address(dummy));

        // This succeeds: the production verifier omits WHITELIST, and the
        // harness permanently gives up its bootstrap ADMIN_ROLE.
        harness.finalize(address(timelock), security);
    }

    function test_FinalizePassesWithoutWhitelistAndBricksBothEntryPaths() public {
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, address(harness)));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, address(timelock)));

        bytes memory missingWhitelist =
            abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.WHITELIST);

        vm.expectRevert(missingWhitelist);
        registry.getContractByKey(Auth.WHITELIST);

        vm.deal(user, 2 ether);
        vm.startPrank(user);
        vm.expectRevert(missingWhitelist);
        amm.enter{value: 1 ether}(1);
        vm.expectRevert(missingWhitelist);
        amm.enterWithInvite{value: 1 ether}(1, bytes32("invite"), block.timestamp + 1 days, "");
        vm.stopPrank();
    }

    function test_RecoveryRequiresAdminTimelockRegistration() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(harness), Auth.ADMIN_ROLE
            )
        );
        harness.register(Auth.WHITELIST, address(whitelist));

        bytes memory data = abi.encodeCall(Registry.registerContract, (Auth.WHITELIST, address(whitelist)));
        bytes32 salt = keccak256("register-whitelist-recovery");

        vm.prank(dao);
        timelock.schedule(address(registry), 0, data, bytes32(0), salt, ADMIN_DELAY);

        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(registry), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + ADMIN_DELAY);
        timelock.execute(address(registry), 0, data, bytes32(0), salt);

        assertEq(registry.getContractByKey(Auth.WHITELIST), address(whitelist));

        // Registration repairs peer resolution; the fresh gate now rejects by policy
        // (not with RegistryContractNotRegistered) until governance seeds/opens it.
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAMM.AMMNotWhitelisted.selector, user));
        amm.enter{value: 1 ether}(1);
    }
}
