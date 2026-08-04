// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";

import {Controller} from "../../src/contracts/Controller.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {Registry} from "registry/Registry.sol";

import {Auth} from "../../src/libraries/Auth.sol";

/**
 * @title DeployerAdminAccessTest
 * @notice Covers PL-003 Registry deployer-admin finalization used by deployment scripts:
 *         the deployer's bootstrap ADMIN_ROLE is always renounced so the role ends held only
 *         by the admin timelock (here represented by `dao`).
 */
contract DeployerAdminAccessTest is ProtocolTestBase {
    address internal deployer;
    address internal dao;

    function setUp() public {
        deployer = makeAddr("deployer");
        dao = makeAddr("dao");
    }

    function test_FinalizeDeployerTieredAccess_RenouncesDeployerAdmin() public {
        Registry registry = _deployRegistryAs(deployer, dao);

        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, dao));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, deployer));

        _finalizeDeployerTieredAccess(registry, deployer);

        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, dao));
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, deployer));
    }

    function test_FinalizeDeployerTieredAccess_WorksWhenRegistryPaused() public {
        Registry registry = _deployRegistryAs(deployer, dao);

        vm.prank(dao);
        registry.pause();

        _finalizeDeployerTieredAccess(registry, deployer);

        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, dao));
        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, deployer));
    }

    function test_FinalizeDeployerTieredAccess_IsIdempotentWhenAlreadyRenounced() public {
        Registry registry = _deployRegistryAs(deployer, dao);

        _finalizeDeployerTieredAccess(registry, deployer);
        _finalizeDeployerTieredAccess(registry, deployer);

        assertFalse(registry.hasRole(Auth.ADMIN_ROLE, deployer));
        assertTrue(registry.hasRole(Auth.ADMIN_ROLE, dao));
    }

    function test_FinalizeDeployerTieredAccess_DeployerCanRegisterBeforeFinalize() public {
        Registry registry = _deployRegistryAs(deployer, dao);
        AMM amm = new AMM(address(registry), DEFAULT_CONNECTOR_WEIGHT);

        vm.prank(deployer);
        registry.registerContract(Auth.AMM, address(amm));

        assertEq(registry.getContractByKey(Auth.AMM), address(amm));
    }

    function test_FinalizeDeployerTieredAccess_DeployerCannotRegisterAfterFinalize() public {
        Registry registry = _deployRegistryAs(deployer, dao);
        AMM amm = new AMM(address(registry), DEFAULT_CONNECTOR_WEIGHT);

        _finalizeDeployerTieredAccess(registry, deployer);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, Auth.ADMIN_ROLE)
        );
        vm.prank(deployer);
        registry.registerContract(Auth.AMM, address(amm));
    }

    function test_FinalizeDeployerTieredAccess_AdminCanRegisterAfterFinalize() public {
        Registry registry = _deployRegistryAs(deployer, dao);
        AMM amm = new AMM(address(registry), DEFAULT_CONNECTOR_WEIGHT);

        _finalizeDeployerTieredAccess(registry, deployer);

        vm.prank(dao);
        registry.registerContract(Auth.AMM, address(amm));

        assertEq(registry.getContractByKey(Auth.AMM), address(amm));
    }

    function test_FullDeploymentFlow_WithSeparateDaoAndDeployer() public {
        Registry registry = _deployRegistryAs(deployer, dao);

        ProtocolContracts memory protocol;
        protocol.registry = registry;
        _deployProtocolInstancesOnRegistry(protocol, DEFAULT_CONNECTOR_WEIGHT);

        vm.prank(deployer);
        _registerProtocolContractsWithoutPrank(protocol.registry, protocol, true);

        assertTrue(protocol.registry.hasRole(Auth.ADMIN_ROLE, deployer));
        assertTrue(protocol.registry.hasRole(Auth.ADMIN_ROLE, dao));

        vm.prank(dao);
        _grantProtocolRolesWithoutPrank(protocol.registry, protocol, dao, dao);

        _finalizeDeployerTieredAccess(protocol.registry, deployer);

        assertTrue(protocol.registry.hasRole(Auth.ADMIN_ROLE, dao));
        assertFalse(protocol.registry.hasRole(Auth.ADMIN_ROLE, deployer));
        assertTrue(protocol.registry.hasRole(Auth.KEEPER_ROLE, dao));
        assertTrue(protocol.registry.hasRole(Auth.MINTER_ROLE, address(protocol.amm)));
        assertEq(protocol.registry.getContractByKey(Auth.AMM), address(protocol.amm));

        vm.prank(dao);
        protocol.controller.pause();
        assertTrue(protocol.controller.paused());
    }

    function _registerProtocolContractsWithoutPrank(
        Registry _registry,
        ProtocolContracts memory _contracts,
        bool _registerAmm
    ) internal {
        uint256 count = _registerAmm ? 7 : 6;
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

        _registry.registerContracts(keys, addresses);
    }

    function _grantProtocolRolesWithoutPrank(
        Registry _registry,
        ProtocolContracts memory _contracts,
        address _admin,
        address _keeper
    ) internal {
        bytes32[] memory roles = new bytes32[](3);
        address[] memory accounts = new address[](3);

        roles[0] = Auth.ADMIN_ROLE;
        accounts[0] = _admin;
        roles[1] = Auth.KEEPER_ROLE;
        accounts[1] = _keeper;
        roles[2] = Auth.MINTER_ROLE;
        accounts[2] = address(_contracts.amm);

        _registry.grantRoles(roles, accounts);
    }
}
