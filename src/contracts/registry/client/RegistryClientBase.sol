// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRegistry} from "interfaces/IRegistry.sol";
import {IRegistryClient} from "interfaces/IRegistryClient.sol";

abstract contract RegistryClientBase is IRegistryClient {
    // ============ Modifiers ============

    /**
     * @notice Modifier that checks if the caller has a registered role
     * @param _role The role to check
     */
    modifier onlyAuthRole(bytes32 _role) {
        if (!registry().hasRole(_role, msg.sender)) {
            revert RegistryClientMissingRole(_role);
        }
        _;
    }

    /**
     * @notice Modifier that checks if the caller has at least one of two registered roles
     * @dev Used for actions reachable by two governance tiers — e.g. emergency pause is
     *      open to both ADMIN_ROLE (timelocked) and SECURITY_ROLE (immediate). The revert
     *      reports both accepted roles so the caller knows either would have sufficed.
     * @param _primaryRole The primary role
     * @param _secondaryRole The alternative role
     */
    modifier onlyEitherAuthRole(bytes32 _primaryRole, bytes32 _secondaryRole) {
        if (!registry().hasRole(_primaryRole, msg.sender) && !registry().hasRole(_secondaryRole, msg.sender)) {
            revert RegistryClientCallerHasNoneOfRoles(_primaryRole, _secondaryRole);
        }
        _;
    }

    /**
     * @notice Modifier that checks if the caller is a valid registered contract
     * @param _contractKey The key of the contract to check
     */
    modifier onlyAuthContract(bytes32 _contractKey) {
        if (msg.sender != registry().getContractByKey(_contractKey)) {
            revert RegistryClientInvalidCaller(_contractKey);
        }
        _;
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IRegistryClient
     */
    function registry() public view virtual returns (IRegistry);
}
