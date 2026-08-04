// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

interface IRegistry is IAccessControl, IAccessControlEnumerable {
    // ============ Errors ============

    /// @notice Thrown when provided address is zero
    error RegistryZeroAddress();

    /// @notice Thrown when the constructor `_admin` is the deployer. The deployer only ever
    ///         holds a temporary bootstrap ADMIN_ROLE; the designated admin must be a distinct
    ///         address (the admin TimelockController in production) so renouncing the
    ///         bootstrap grant can never leave the Registry admin-less.
    error RegistryAdminIsDeployer();

    /// @notice Thrown when contract is not registered
    error RegistryContractNotRegistered(bytes32 key);

    /// @notice Thrown when contract has no code
    error RegistryContractNoCode();

    /// @notice Thrown when array lengths do not match
    error RegistryInvalidLength();

    /// @notice Thrown when the caller holds none of the roles accepted by an either-of gate
    error RegistryCallerHasNoneOfRoles(bytes32 primaryRole, bytes32 secondaryRole);

    // ============ Events ============

    /// @notice Emitted when a contract is registered
    event ContractRegistered(bytes32 key, address oldContractAddress, address newContractAddress);

    /// @notice Emitted when a contract is deregistered
    event ContractUnregistered(bytes32 key, address oldContractAddress);

    /// @notice Emitted when a new role is registered
    event RoleRegistered(bytes32 role);

    /// @notice Emitted when a role is unregistered because it has no members
    event RoleUnregistered(bytes32 role);

    // ============ Functions ============

    /**
     * @notice Get the address of a registered contract by its key (keccak256 hash of the name of the contract)
     * @param _key The key (keccak256 hash of the name of the contract)
     * @return The address of the contract
     */
    function getContractByKey(bytes32 _key) external view returns (address);

    /**
     * @notice Get the addresses of multiple registered contracts by their keys (keccak256 hashes of the names of the contracts)
     * @param _keys The keys (keccak256 hashes of the names of the contracts)
     * @return addresses The addresses of the contracts
     */
    function getContractsByKeys(bytes32[] memory _keys) external view returns (address[] memory);

    /**
     * @notice Get the keys and addresses of all registered contracts
     * @return keys The keys of the registered contracts
     * @return addresses The addresses of the registered contracts
     */
    function getContractsAndKeys() external view returns (bytes32[] memory keys, address[] memory addresses);

    /**
     * @notice Get all registered roles
     * @return roles The roles
     */
    function getRoles() external view returns (bytes32[] memory roles);

    /**
     * @notice Register a contract by its key (keccak256 hash of the name of the contract) and address
     * @param _key The key (keccak256 hash of the name of the contract)
     * @param _address The address of the contract
     */
    function registerContract(bytes32 _key, address _address) external;

    /**
     * @notice Register multiple contracts by their keys (keccak256 hashes of the names of the contracts) and addresses
     * @param _keys The keys (keccak256 hashes of the names of the contracts)
     * @param _addresses The addresses of the contracts
     */
    function registerContracts(bytes32[] memory _keys, address[] memory _addresses) external;

    /**
     * @notice Deregister a contract by its key (keccak256 hash of the name of the contract)
     * @param _key The key (keccak256 hash of the name of the contract)
     */
    function deregisterContract(bytes32 _key) external;

    /**
     * @notice Deregister multiple contracts by their keys (keccak256 hashes of the names of the contracts)
     * @param _keys The keys (keccak256 hashes of the names of the contracts)
     */
    function deregisterContracts(bytes32[] memory _keys) external;

    /**
     * @notice Grant multiple roles to multiple addresses
     * @param _roles The roles to grant
     * @param _accounts The addresses to grant the roles to
     */
    function grantRoles(bytes32[] memory _roles, address[] memory _accounts) external;

    /**
     * @notice Revoke multiple roles from multiple addresses
     * @param _roles The roles to revoke
     * @param _accounts The addresses to revoke the roles from
     */
    function revokeRoles(bytes32[] memory _roles, address[] memory _accounts) external;
}
