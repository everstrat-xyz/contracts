// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {Registry} from "registry/Registry.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {IRegistry} from "interfaces/IRegistry.sol";
import {Auth} from "../../src/libraries/Auth.sol";

contract RegistryTest is ProtocolTestBase {
    Registry public registry;
    address public admin;

    uint256 internal constant EXPECTED_PROTOCOL_KEY_COUNT = 8;
    uint256 internal constant EXPECTED_REGISTERED_ROLE_COUNT_AFTER_KEEPER_GRANT = 2;

    function setUp() public {
        admin = address(this);
        registry = _deployRegistry(admin);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize_GrantsAdmin() public view {
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, admin));
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        vm.expectRevert(IRegistry.RegistryZeroAddress.selector);
        new Registry(address(0));
    }

    function test_Initialize_RevertsWhenAdminIsDeployer() public {
        // The designated admin must never be the deployer key: msg.sender only receives a
        // temporary bootstrap ADMIN_ROLE, so `_admin == msg.sender` would mean renouncing
        // the bootstrap grant leaves no other ADMIN_ROLE holder and bricks the Registry.
        vm.expectRevert(IRegistry.RegistryAdminIsDeployer.selector);
        new Registry(address(this));

        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        vm.expectRevert(IRegistry.RegistryAdminIsDeployer.selector);
        new Registry(deployer);
    }

    function test_Initialize_GrantsAdminToDeployerAndParam() public {
        address deployer = makeAddr("deployer");
        address dao = makeAddr("dao");

        vm.prank(deployer);
        Registry reg = new Registry(dao);

        assertTrue(reg.hasRole(Auth.ADMIN_ROLE, dao));
        assertTrue(reg.hasRole(Auth.ADMIN_ROLE, deployer));
    }

    function test_AdminRole_IsSelfAdministered() public view {
        assertEq(registry.getRoleAdmin(Auth.ADMIN_ROLE), Auth.ADMIN_ROLE);
    }

    function test_ADMIN_ROLE_ReturnsProtocolConstant() public view {
        assertEq(registry.ADMIN_ROLE(), Auth.ADMIN_ROLE);
    }

    function test_Initialize_HasNoRegisteredContractsInitially() public view {
        (bytes32[] memory keys, address[] memory addresses) = registry.getContractsAndKeys();
        assertEq(keys.length, 0);
        assertEq(addresses.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    CONTRACT REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterAndResolveContract() public {
        AMM amm = _newAmm();
        _registerAmm(amm);
        assertEq(registry.getContractByKey(Auth.AMM), address(amm));
    }

    function test_RegisterContract_RevertsOnZeroAddress() public {
        vm.expectRevert(IRegistry.RegistryZeroAddress.selector);
        registry.registerContract(Auth.AMM, address(0));
    }

    function test_RegisterContract_RevertsOnNoCode() public {
        vm.expectRevert(IRegistry.RegistryContractNoCode.selector);
        registry.registerContract(Auth.AMM, makeAddr("eoa"));
    }

    function test_RegisterContract_RevertsWhenNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        registry.getContractByKey(Auth.AMM);
    }

    function test_RegisterContract_UpdatesExistingAddress() public {
        AMM firstAmm = _newAmm();
        AMM secondAmm = _newAmm();

        registry.registerContract(Auth.AMM, address(firstAmm));
        registry.registerContract(Auth.AMM, address(secondAmm));

        assertEq(registry.getContractByKey(Auth.AMM), address(secondAmm));
    }

    function test_RegisterContract_EmitsContractRegistered() public {
        AMM amm = _newAmm();

        vm.expectEmit(true, true, true, true);
        emit IRegistry.ContractRegistered(Auth.AMM, address(0), address(amm));
        registry.registerContract(Auth.AMM, address(amm));

        AMM newAmm = _newAmm();
        vm.expectEmit(true, true, true, true);
        emit IRegistry.ContractRegistered(Auth.AMM, address(amm), address(newAmm));
        registry.registerContract(Auth.AMM, address(newAmm));
    }

    function test_RegisterContracts_Batch() public {
        AMM amm = _newAmm();
        AMM controllerStub = _newAmm();

        bytes32[] memory keys = new bytes32[](2);
        address[] memory addresses = new address[](2);
        keys[0] = Auth.AMM;
        addresses[0] = address(amm);
        keys[1] = Auth.CONTROLLER;
        addresses[1] = address(controllerStub);

        registry.registerContracts(keys, addresses);

        assertEq(registry.getContractByKey(Auth.AMM), address(amm));
        assertEq(registry.getContractByKey(Auth.CONTROLLER), address(controllerStub));
    }

    function test_RegisterContracts_RevertsOnLengthMismatch() public {
        bytes32[] memory keys = new bytes32[](1);
        address[] memory addresses = new address[](2);

        vm.expectRevert(IRegistry.RegistryInvalidLength.selector);
        registry.registerContracts(keys, addresses);
    }

    function test_RegisterContracts_RevertsWhenPaused() public {
        AMM amm = _newAmm();
        bytes32[] memory keys = new bytes32[](1);
        address[] memory addresses = new address[](1);
        keys[0] = Auth.AMM;
        addresses[0] = address(amm);

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.registerContracts(keys, addresses);
    }

    function test_RegisterContracts_RevertsNonAdmin() public {
        AMM amm = _newAmm();
        bytes32[] memory keys = new bytes32[](1);
        address[] memory addresses = new address[](1);
        keys[0] = Auth.AMM;
        addresses[0] = address(amm);
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Auth.ADMIN_ROLE)
        );
        registry.registerContracts(keys, addresses);
    }

    function test_RegisterContracts_EmitsContractRegisteredForEach() public {
        AMM amm = _newAmm();
        AMM controllerStub = _newAmm();

        bytes32[] memory keys = new bytes32[](2);
        address[] memory addresses = new address[](2);
        keys[0] = Auth.AMM;
        addresses[0] = address(amm);
        keys[1] = Auth.CONTROLLER;
        addresses[1] = address(controllerStub);

        vm.expectEmit(true, true, true, true);
        emit IRegistry.ContractRegistered(Auth.AMM, address(0), address(amm));
        vm.expectEmit(true, true, true, true);
        emit IRegistry.ContractRegistered(Auth.CONTROLLER, address(0), address(controllerStub));
        registry.registerContracts(keys, addresses);
    }

    function test_GetContractsAndKeys_ReturnsAll() public {
        AMM amm = _newAmm();
        AMM controllerStub = _newAmm();

        bytes32[] memory keys = new bytes32[](2);
        address[] memory addresses = new address[](2);
        keys[0] = Auth.AMM;
        addresses[0] = address(amm);
        keys[1] = Auth.CONTROLLER;
        addresses[1] = address(controllerStub);
        registry.registerContracts(keys, addresses);

        (bytes32[] memory registeredKeys, address[] memory registeredAddresses) = registry.getContractsAndKeys();

        assertEq(registeredKeys.length, 2);
        assertEq(registeredAddresses.length, 2);

        bool foundAmm;
        bool foundController;
        for (uint256 i; i < registeredKeys.length; ++i) {
            if (registeredKeys[i] == Auth.AMM) {
                foundAmm = true;
                assertEq(registeredAddresses[i], address(amm));
            }
            if (registeredKeys[i] == Auth.CONTROLLER) {
                foundController = true;
                assertEq(registeredAddresses[i], address(controllerStub));
            }
        }
        assertTrue(foundAmm);
        assertTrue(foundController);
    }

    function test_GetContractsByKeys_ReturnsBatch() public {
        AMM amm = _newAmm();
        AMM controllerStub = _newAmm();
        registry.registerContract(Auth.AMM, address(amm));
        registry.registerContract(Auth.CONTROLLER, address(controllerStub));

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = Auth.AMM;
        keys[1] = Auth.CONTROLLER;

        address[] memory resolved = registry.getContractsByKeys(keys);
        assertEq(resolved.length, 2);
        assertEq(resolved[0], address(amm));
        assertEq(resolved[1], address(controllerStub));
    }

    function test_GetContractsByKeys_RevertsIfAnyKeyMissing() public {
        AMM amm = _newAmm();
        registry.registerContract(Auth.AMM, address(amm));

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = Auth.AMM;
        keys[1] = Auth.CONTROLLER;

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.CONTROLLER));
        registry.getContractsByKeys(keys);
    }

    function test_NonAdminCannotRegister() public {
        AMM amm = _newAmm();
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Auth.ADMIN_ROLE)
        );
        registry.registerContract(Auth.AMM, address(amm));
    }

    /*//////////////////////////////////////////////////////////////
                    CONTRACT UNREGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DeregisterContract() public {
        AMM amm = _newAmm();
        _registerAmm(amm);

        vm.expectEmit(true, true, true, true);
        emit IRegistry.ContractUnregistered(Auth.AMM, address(amm));
        registry.deregisterContract(Auth.AMM);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        registry.getContractByKey(Auth.AMM);
    }

    function test_DeregisterContract_RevertsWhenNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        registry.deregisterContract(Auth.AMM);
    }

    function test_DeregisterContract_AllowsReRegister() public {
        AMM amm = _newAmm();
        _registerAmm(amm);
        registry.deregisterContract(Auth.AMM);

        AMM newAmm = _newAmm();
        registry.registerContract(Auth.AMM, address(newAmm));
        assertEq(registry.getContractByKey(Auth.AMM), address(newAmm));
    }

    function test_DeregisterContract_RemovesFromGetContractsAndKeys() public {
        AMM amm = _newAmm();
        AMM controllerStub = _newAmm();
        registry.registerContract(Auth.AMM, address(amm));
        registry.registerContract(Auth.CONTROLLER, address(controllerStub));

        registry.deregisterContract(Auth.AMM);

        (bytes32[] memory keys,) = registry.getContractsAndKeys();
        assertEq(keys.length, 1);
        assertEq(keys[0], Auth.CONTROLLER);
    }

    function test_DeregisterContracts_Batch() public {
        AMM amm = _newAmm();
        AMM controllerStub = _newAmm();
        registry.registerContract(Auth.AMM, address(amm));
        registry.registerContract(Auth.CONTROLLER, address(controllerStub));

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = Auth.AMM;
        keys[1] = Auth.CONTROLLER;
        registry.deregisterContracts(keys);

        (bytes32[] memory remaining,) = registry.getContractsAndKeys();
        assertEq(remaining.length, 0);
    }

    function test_DeregisterContracts_RevertsWhenAnyKeyMissing() public {
        AMM amm = _newAmm();
        _registerAmm(amm);

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = Auth.AMM;
        keys[1] = Auth.CONTROLLER;

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.CONTROLLER));
        registry.deregisterContracts(keys);
    }

    function test_DeregisterContracts_EmitsContractUnregisteredForEach() public {
        AMM amm = _newAmm();
        AMM controllerStub = _newAmm();
        registry.registerContract(Auth.AMM, address(amm));
        registry.registerContract(Auth.CONTROLLER, address(controllerStub));

        bytes32[] memory keys = new bytes32[](2);
        keys[0] = Auth.AMM;
        keys[1] = Auth.CONTROLLER;

        vm.expectEmit(true, true, true, true);
        emit IRegistry.ContractUnregistered(Auth.AMM, address(amm));
        vm.expectEmit(true, true, true, true);
        emit IRegistry.ContractUnregistered(Auth.CONTROLLER, address(controllerStub));
        registry.deregisterContracts(keys);
    }

    function test_DeregisterContracts_RevertsWhenPaused() public {
        AMM amm = _newAmm();
        _registerAmm(amm);

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = Auth.AMM;

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.deregisterContracts(keys);
    }

    function test_NonAdminCannotDeregisterBatch() public {
        AMM amm = _newAmm();
        _registerAmm(amm);
        address outsider = makeAddr("outsider");

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = Auth.AMM;

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Auth.ADMIN_ROLE)
        );
        registry.deregisterContracts(keys);
    }

    function test_DeregisterContract_RevertsWhenPaused() public {
        AMM amm = _newAmm();
        _registerAmm(amm);

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.deregisterContract(Auth.AMM);
    }

    function test_NonAdminCannotDeregister() public {
        AMM amm = _newAmm();
        _registerAmm(amm);
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Auth.ADMIN_ROLE)
        );
        registry.deregisterContract(Auth.AMM);
    }

    /*//////////////////////////////////////////////////////////////
                        ROLE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GrantAndRevokeRole() public {
        address keeper = makeAddr("keeper");

        registry.grantRole(Auth.KEEPER_ROLE, keeper);
        assertTrue(registry.hasRole(Auth.KEEPER_ROLE, keeper));

        registry.revokeRole(Auth.KEEPER_ROLE, keeper);
        assertFalse(registry.hasRole(Auth.KEEPER_ROLE, keeper));
    }

    function test_GrantRole_RevertsOnZeroAccount() public {
        vm.expectRevert(IRegistry.RegistryZeroAddress.selector);
        registry.grantRole(Auth.KEEPER_ROLE, address(0));
    }

    function test_GrantRoles_Batch() public {
        address keeper = makeAddr("keeper");
        address minter = makeAddr("minter");

        bytes32[] memory roles = new bytes32[](2);
        address[] memory accounts = new address[](2);
        roles[0] = Auth.KEEPER_ROLE;
        accounts[0] = keeper;
        roles[1] = Auth.MINTER_ROLE;
        accounts[1] = minter;

        registry.grantRoles(roles, accounts);

        assertTrue(registry.hasRole(Auth.KEEPER_ROLE, keeper));
        assertTrue(registry.hasRole(Auth.MINTER_ROLE, minter));
    }

    function test_GrantRoles_RevertsOnLengthMismatch() public {
        bytes32[] memory roles = new bytes32[](1);
        address[] memory accounts = new address[](2);

        vm.expectRevert(IRegistry.RegistryInvalidLength.selector);
        registry.grantRoles(roles, accounts);
    }

    function test_GrantRoles_RevertsOnZeroAccount() public {
        bytes32[] memory roles = new bytes32[](1);
        address[] memory accounts = new address[](1);
        roles[0] = Auth.KEEPER_ROLE;
        accounts[0] = address(0);

        vm.expectRevert(IRegistry.RegistryZeroAddress.selector);
        registry.grantRoles(roles, accounts);
    }

    function test_RevokeRoles_Batch() public {
        address keeper = makeAddr("keeper");
        address minter = makeAddr("minter");

        registry.grantRole(Auth.KEEPER_ROLE, keeper);
        registry.grantRole(Auth.MINTER_ROLE, minter);

        bytes32[] memory roles = new bytes32[](2);
        address[] memory accounts = new address[](2);
        roles[0] = Auth.KEEPER_ROLE;
        accounts[0] = keeper;
        roles[1] = Auth.MINTER_ROLE;
        accounts[1] = minter;

        registry.revokeRoles(roles, accounts);

        assertFalse(registry.hasRole(Auth.KEEPER_ROLE, keeper));
        assertFalse(registry.hasRole(Auth.MINTER_ROLE, minter));
    }

    function test_RevokeRoles_RevertsOnLengthMismatch() public {
        bytes32[] memory roles = new bytes32[](1);
        address[] memory accounts = new address[](2);

        vm.expectRevert(IRegistry.RegistryInvalidLength.selector);
        registry.revokeRoles(roles, accounts);
    }

    function test_RevokeRole_RevertsOnZeroAccount() public {
        vm.expectRevert(IRegistry.RegistryZeroAddress.selector);
        registry.revokeRole(Auth.KEEPER_ROLE, address(0));
    }

    function test_RevokeRoles_RevertsOnZeroAccount() public {
        bytes32[] memory roles = new bytes32[](1);
        address[] memory accounts = new address[](1);
        roles[0] = Auth.KEEPER_ROLE;
        accounts[0] = address(0);

        vm.expectRevert(IRegistry.RegistryZeroAddress.selector);
        registry.revokeRoles(roles, accounts);
    }

    function test_GetRoles_IncludesAdminAfterInit() public view {
        bytes32[] memory roles = registry.getRoles();
        assertTrue(_containsRole(roles, Auth.ADMIN_ROLE));
    }

    function test_GetRoles_AddsRoleOnFirstGrant() public {
        address keeper = makeAddr("keeper");

        vm.expectEmit(true, false, false, true);
        emit IRegistry.RoleRegistered(Auth.KEEPER_ROLE);
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        assertTrue(_containsRole(registry.getRoles(), Auth.KEEPER_ROLE));
    }

    function test_GetRoles_RemovesRoleWhenLastMemberRevoked() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        vm.expectEmit(true, false, false, true);
        emit IRegistry.RoleUnregistered(Auth.KEEPER_ROLE);
        registry.revokeRole(Auth.KEEPER_ROLE, keeper);

        assertFalse(_containsRole(registry.getRoles(), Auth.KEEPER_ROLE));
    }

    function test_RevokeRole_KeepsRoleRegisteredWhenMembersRemain() public {
        address keeperOne = makeAddr("keeperOne");
        address keeperTwo = makeAddr("keeperTwo");

        registry.grantRole(Auth.KEEPER_ROLE, keeperOne);
        registry.grantRole(Auth.KEEPER_ROLE, keeperTwo);

        registry.revokeRole(Auth.KEEPER_ROLE, keeperOne);

        assertTrue(registry.hasRole(Auth.KEEPER_ROLE, keeperTwo));
        assertTrue(_containsRole(registry.getRoles(), Auth.KEEPER_ROLE));
        assertEq(registry.getRoleMemberCount(Auth.KEEPER_ROLE), 1);
    }

    function test_RevokeRole_RevertsWhenPaused() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.revokeRole(Auth.KEEPER_ROLE, keeper);
    }

    function test_RevokeRoles_RevertsWhenPaused() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        bytes32[] memory roles = new bytes32[](1);
        address[] memory accounts = new address[](1);
        roles[0] = Auth.KEEPER_ROLE;
        accounts[0] = keeper;

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.revokeRoles(roles, accounts);
    }

    function test_RenounceRole_UnregistersWhenLastMember() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        vm.expectEmit(true, false, false, true);
        emit IRegistry.RoleUnregistered(Auth.KEEPER_ROLE);
        vm.prank(keeper);
        registry.renounceRole(Auth.KEEPER_ROLE, keeper);

        assertFalse(registry.hasRole(Auth.KEEPER_ROLE, keeper));
        assertFalse(_containsRole(registry.getRoles(), Auth.KEEPER_ROLE));
    }

    function test_RenounceRole_RevertsOnBadConfirmation() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        vm.prank(keeper);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        registry.renounceRole(Auth.KEEPER_ROLE, makeAddr("wrongConfirmation"));
    }

    function test_RenounceRole_WorksWhenPaused() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        registry.pause();

        vm.expectEmit(true, false, false, true);
        emit IRegistry.RoleUnregistered(Auth.KEEPER_ROLE);
        vm.prank(keeper);
        registry.renounceRole(Auth.KEEPER_ROLE, keeper);

        assertFalse(registry.hasRole(Auth.KEEPER_ROLE, keeper));
        assertFalse(_containsRole(registry.getRoles(), Auth.KEEPER_ROLE));
    }

    function test_GetRoleMemberCount_AndGetRoleMember() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        assertEq(registry.getRoleMemberCount(Auth.KEEPER_ROLE), 1);
        assertEq(registry.getRoleMember(Auth.KEEPER_ROLE, 0), keeper);
    }

    function test_NonAdminCannotGrantOrRevoke() public {
        address outsider = makeAddr("outsider");
        address keeper = makeAddr("keeper");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Auth.ADMIN_ROLE)
        );
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Auth.ADMIN_ROLE)
        );
        registry.revokeRole(Auth.KEEPER_ROLE, keeper);
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AdminCanPauseAndUnpause() public {
        assertFalse(registry.paused());

        registry.pause();
        assertTrue(registry.paused());

        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_NonAdminCannotPause() public {
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IRegistry.RegistryCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE)
        );
        registry.pause();
    }

    function test_RegisterContract_RevertsWhenPaused() public {
        AMM amm = _newAmm();

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.registerContract(Auth.AMM, address(amm));
    }

    function test_GrantRole_RevertsWhenPaused() public {
        address keeper = makeAddr("keeper");

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.grantRole(Auth.KEEPER_ROLE, keeper);
    }

    function test_GrantRoles_RevertsWhenPaused() public {
        address keeper = makeAddr("keeper");
        bytes32[] memory roles = new bytes32[](1);
        address[] memory accounts = new address[](1);
        roles[0] = Auth.KEEPER_ROLE;
        accounts[0] = keeper;

        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.grantRoles(roles, accounts);
    }

    function test_Pause_RevertsWhenAlreadyPaused() public {
        registry.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.pause();
    }

    function test_Unpause_RevertsWhenNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        registry.unpause();
    }

    function test_NonAdminCannotUnpause() public {
        address outsider = makeAddr("outsider");
        registry.pause();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, Auth.ADMIN_ROLE)
        );
        registry.unpause();
    }

    function test_SecurityCanPauseImmediately() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);

        vm.prank(security);
        registry.pause();

        assertTrue(registry.paused());
    }

    function test_SecurityCannotUnpause() public {
        address security = makeAddr("security");
        registry.grantRole(Auth.SECURITY_ROLE, security);
        registry.pause();

        vm.prank(security);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, security, Auth.ADMIN_ROLE)
        );
        registry.unpause();
    }

    function test_NonAdminNonSecurityCannotPause() public {
        address outsider = makeAddr("outsider");

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IRegistry.RegistryCallerHasNoneOfRoles.selector, Auth.ADMIN_ROLE, Auth.SECURITY_ROLE)
        );
        registry.pause();
    }

    /*//////////////////////////////////////////////////////////////
                    REGISTRY-CENTRIC INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Integration_ProtocolWiringRegistersAllAuthKeys() public {
        ProtocolContracts memory protocol = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);

        assertEq(protocol.registry.getContractByKey(Auth.CONTROLLER), address(protocol.controller));
        assertEq(protocol.registry.getContractByKey(Auth.AMM), address(protocol.amm));
        assertEq(protocol.registry.getContractByKey(Auth.STRATEGY_MANAGER), address(protocol.strategyManager));
        assertEq(protocol.registry.getContractByKey(Auth.EXIT_QUEUE), address(protocol.exitQueue));
        assertEq(protocol.registry.getContractByKey(Auth.ORACLE), address(protocol.oracle));
        assertEq(protocol.registry.getContractByKey(Auth.EVE), address(protocol.token));
        assertEq(protocol.registry.getContractByKey(Auth.WHITELIST), address(protocol.whitelist));

        (bytes32[] memory keys,) = protocol.registry.getContractsAndKeys();
        assertEq(keys.length, EXPECTED_PROTOCOL_KEY_COUNT);
    }

    function test_Integration_ProtocolGrantsOperationalRolesOnRegistry() public {
        ProtocolContracts memory protocol = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);

        assertTrue(protocol.registry.hasRole(Auth.ADMIN_ROLE, admin));
        assertTrue(protocol.registry.hasRole(Auth.KEEPER_ROLE, admin));
        assertTrue(protocol.registry.hasRole(Auth.MINTER_ROLE, address(protocol.amm)));
    }

    function test_Integration_RepointingUpdatesResolvedAddress() public {
        AMM firstAmm = _newAmm();
        AMM secondAmm = _newAmm();

        registry.registerContract(Auth.AMM, address(firstAmm));
        assertEq(registry.getContractByKey(Auth.AMM), address(firstAmm));

        registry.registerContract(Auth.AMM, address(secondAmm));
        assertEq(registry.getContractByKey(Auth.AMM), address(secondAmm));
    }

    function test_Integration_DeregisterBlocksStrategyManagerNAV() public {
        ProtocolContracts memory protocol = _deployProtocol(admin, DEFAULT_CONNECTOR_WEIGHT);

        protocol.registry.deregisterContract(Auth.AMM);

        vm.expectRevert(abi.encodeWithSelector(IRegistry.RegistryContractNotRegistered.selector, Auth.AMM));
        protocol.strategyManager.totalNAVInETH();
    }

    function test_Integration_RoleLifecycleOnRegistry() public {
        address keeper = makeAddr("keeper");

        registry.grantRole(Auth.KEEPER_ROLE, keeper);
        assertTrue(registry.hasRole(Auth.KEEPER_ROLE, keeper));
        assertTrue(_containsRole(registry.getRoles(), Auth.KEEPER_ROLE));

        registry.revokeRole(Auth.KEEPER_ROLE, keeper);
        assertFalse(registry.hasRole(Auth.KEEPER_ROLE, keeper));
        assertFalse(_containsRole(registry.getRoles(), Auth.KEEPER_ROLE));
    }

    function test_Integration_GetRolesTracksMultipleRoles() public {
        address keeper = makeAddr("keeper");
        registry.grantRole(Auth.KEEPER_ROLE, keeper);

        bytes32[] memory roles = registry.getRoles();
        assertTrue(_containsRole(roles, Auth.ADMIN_ROLE));
        assertTrue(_containsRole(roles, Auth.KEEPER_ROLE));
        assertEq(roles.length, EXPECTED_REGISTERED_ROLE_COUNT_AFTER_KEEPER_GRANT);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _newAmm() internal returns (AMM) {
        return new AMM(address(registry), DEFAULT_CONNECTOR_WEIGHT);
    }

    function _registerAmm(AMM _amm) internal {
        registry.registerContract(Auth.AMM, address(_amm));
    }

    function _containsRole(bytes32[] memory _roles, bytes32 _role) internal pure returns (bool) {
        for (uint256 i; i < _roles.length; ++i) {
            if (_roles[i] == _role) return true;
        }
        return false;
    }
}
