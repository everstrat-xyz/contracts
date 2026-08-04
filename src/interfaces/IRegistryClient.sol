// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRegistry} from "interfaces/IRegistry.sol";

/**
 * @title IRegistryClient
 * @notice Shared surface for contracts that resolve roles and peers via the Registry.
 */
interface IRegistryClient {
    // ============ Errors ============

    /// @notice Thrown when provided address is zero
    error RegistryClientZeroRegistry();

    /// @notice Thrown when role is not granted
    error RegistryClientMissingRole(bytes32 role);

    /// @notice Thrown when the caller holds none of the roles accepted by an either-of gate
    error RegistryClientCallerHasNoneOfRoles(bytes32 primaryRole, bytes32 secondaryRole);

    /// @notice Thrown when caller is not a registered contract
    error RegistryClientInvalidCaller(bytes32 expectedContractKey);

    // ============ View Functions ============

    /// @notice Get the protocol Registry
    function registry() external view returns (IRegistry);
}
