// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IRegistry} from "interfaces/IRegistry.sol";

import {Auth} from "../../libraries/Auth.sol";

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Registry is AccessControlEnumerable, Pausable, IRegistry {
    using EnumerableMap for EnumerableMap.Bytes32ToAddressMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // ============ Constants ============

    /// @notice Role for the admin (granted to DAO)
    bytes32 public constant ADMIN_ROLE = Auth.ADMIN_ROLE;

    // ============ State Variables ============

    /// @notice Mapping from keys (keccak256 hashes of contract names) to contract addresses
    EnumerableMap.Bytes32ToAddressMap private _registeredAddresses;

    /// @notice Set of roles
    EnumerableSet.Bytes32Set private _registeredRoles;

    // ============ Constructor ============

    /**
     * @notice Constructor that initializes the registry
     * @param _admin The designated admin — the address intended to retain ADMIN_ROLE after
     *        bootstrap teardown (the admin TimelockController in production). Must differ from
     *        the deployer: ADMIN_ROLE is self-administered, so `_admin == msg.sender` would
     *        mean renouncing the deployer's bootstrap grant leaves no other ADMIN_ROLE holder
     *        and bricks the Registry. ADMIN_ROLE remains renounceable on-chain.
     */
    constructor(address _admin) {
        if (_admin == address(0)) revert RegistryZeroAddress();
        if (_admin == msg.sender) revert RegistryAdminIsDeployer();

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(Auth.KEEPER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(Auth.MINTER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(Auth.SECURITY_ROLE, ADMIN_ROLE);
        _setRoleAdmin(Auth.CONVERTER_CALLER_ROLE, Auth.CONVERTER_CALLER_MANAGER_ROLE);
        _setRoleAdmin(Auth.CONVERTER_CALLER_MANAGER_ROLE, ADMIN_ROLE);

        // ADMIN_ROLE is granted to the deployer as a TEMPORARY bootstrap grant so the deploy
        // scripts can wire the protocol; it MUST be renounced once deployment is finalized.
        // Creating a new role for the deployer is not necessary as it would allow to perform
        // the exact same actions as the ADMIN_ROLE. The `_admin != msg.sender` check above
        // guarantees the designated admin retains ADMIN_ROLE after the bootstrap renounce.
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IRegistry
     */
    function getContractByKey(bytes32 _key) external view returns (address) {
        return _getAddress(_key);
    }

    /**
     * @inheritdoc IRegistry
     */
    function getContractsByKeys(bytes32[] memory _keys) external view returns (address[] memory addresses) {
        addresses = new address[](_keys.length);
        for (uint256 i; i < _keys.length; ++i) {
            addresses[i] = _getAddress(_keys[i]);
        }
        return addresses;
    }

    /**
     * @inheritdoc IRegistry
     */
    function getContractsAndKeys() external view returns (bytes32[] memory keys, address[] memory addresses) {
        keys = new bytes32[](_registeredAddresses.length());
        addresses = new address[](_registeredAddresses.length());
        for (uint256 i; i < _registeredAddresses.length(); ++i) {
            (bytes32 key, address contractAddress) = _registeredAddresses.at(i);
            keys[i] = key;
            addresses[i] = contractAddress;
        }
    }

    /**
     * @inheritdoc IRegistry
     */
    function getRoles() external view returns (bytes32[] memory roles) {
        return _registeredRoles.values();
    }

    // ============ Contract Registration ============

    /**
     * @inheritdoc IRegistry
     */
    function registerContract(bytes32 _key, address _address) external whenNotPaused onlyRole(ADMIN_ROLE) {
        _registerContract(_key, _address);
    }

    /**
     * @inheritdoc IRegistry
     */
    function registerContracts(bytes32[] memory _keys, address[] memory _addresses)
        external
        whenNotPaused
        onlyRole(ADMIN_ROLE)
    {
        if (_keys.length != _addresses.length) revert RegistryInvalidLength();
        for (uint256 i; i < _keys.length; ++i) {
            _registerContract(_keys[i], _addresses[i]);
        }
    }

    /**
     * @inheritdoc IRegistry
     */
    function deregisterContract(bytes32 _key) external whenNotPaused onlyRole(ADMIN_ROLE) {
        _deregisterContract(_key);
    }

    /**
     * @inheritdoc IRegistry
     */
    function deregisterContracts(bytes32[] memory _keys) external whenNotPaused onlyRole(ADMIN_ROLE) {
        for (uint256 i; i < _keys.length; ++i) {
            _deregisterContract(_keys[i]);
        }
    }

    // ============ Role Management ============

    /**
     * @inheritdoc IAccessControl
     */
    function grantRole(bytes32 _role, address _account)
        public
        override(IAccessControl, AccessControl)
        whenNotPaused
        onlyRole(getRoleAdmin(_role))
    {
        if (_account == address(0)) revert RegistryZeroAddress();
        _grantRole(_role, _account);
    }

    /**
     * @inheritdoc IRegistry
     * @dev The caller must be the admin of EVERY role in the batch. If the caller is not admin
     *      of any single role, the entire call reverts with AccessControlUnauthorizedAccount.
     */
    function grantRoles(bytes32[] memory _roles, address[] memory _accounts) external whenNotPaused {
        if (_roles.length != _accounts.length) revert RegistryInvalidLength();
        for (uint256 i; i < _roles.length; ++i) {
            if (_accounts[i] == address(0)) revert RegistryZeroAddress();
            _checkRole(getRoleAdmin(_roles[i]));
            _grantRole(_roles[i], _accounts[i]);
        }
    }

    /**
     * @inheritdoc IAccessControl
     * @dev Rejects address(0) for symmetry with {grantRole}: the zero address can never
     *      hold a role (grants to it revert), so revoking from it is always a caller mistake.
     */
    function revokeRole(bytes32 _role, address _account)
        public
        override(IAccessControl, AccessControl)
        whenNotPaused
        onlyRole(getRoleAdmin(_role))
    {
        if (_account == address(0)) revert RegistryZeroAddress();
        _revokeRole(_role, _account);
    }

    /**
     * @inheritdoc IRegistry
     * @dev The caller must be the admin of EVERY role in the batch. See {grantRoles}.
     *      Rejects address(0) entries, matching {grantRoles} and {revokeRole}.
     */
    function revokeRoles(bytes32[] memory _roles, address[] memory _accounts) external whenNotPaused {
        if (_roles.length != _accounts.length) revert RegistryInvalidLength();
        for (uint256 i; i < _roles.length; ++i) {
            if (_accounts[i] == address(0)) revert RegistryZeroAddress();
            _checkRole(getRoleAdmin(_roles[i]));
            _revokeRole(_roles[i], _accounts[i]);
        }
    }

    /**
     * @inheritdoc IAccessControl
     * @dev Intentionally not gated by `whenNotPaused` so holders can voluntarily exit roles (including
     *      deployer ADMIN renounce during finalization) even while Registry registration/grants are frozen.
     */
    function renounceRole(bytes32 _role, address _callerConfirmation) public override(IAccessControl, AccessControl) {
        super.renounceRole(_role, _callerConfirmation);
        _unregisterRoleIfNeeded(_role);
    }

    // ============ Internal Functions ============

    function _getAddress(bytes32 _key) internal view returns (address) {
        if (!_registeredAddresses.contains(_key)) revert RegistryContractNotRegistered(_key);
        return _registeredAddresses.get(_key);
    }

    function _registerContract(bytes32 _key, address _address) internal {
        if (_address == address(0)) revert RegistryZeroAddress();
        if (_address.code.length == 0) revert RegistryContractNoCode();

        bool isNewRegistration = !_registeredAddresses.contains(_key);
        address oldAddress = isNewRegistration ? address(0) : _registeredAddresses.get(_key);

        _registeredAddresses.set(_key, _address);
        emit ContractRegistered(_key, oldAddress, _address);
    }

    function _deregisterContract(bytes32 _key) internal {
        if (!_registeredAddresses.contains(_key)) revert RegistryContractNotRegistered(_key);

        address oldAddress = _registeredAddresses.get(_key);
        _registeredAddresses.remove(_key);
        emit ContractUnregistered(_key, oldAddress);
    }

    function _grantRole(bytes32 _role, address _account)
        internal
        override(AccessControlEnumerable)
        returns (bool granted)
    {
        granted = super._grantRole(_role, _account);
        _registerRoleIfNeeded(_role);
    }

    function _revokeRole(bytes32 _role, address _account)
        internal
        override(AccessControlEnumerable)
        returns (bool revoked)
    {
        revoked = super._revokeRole(_role, _account);
        _unregisterRoleIfNeeded(_role);
    }

    /**
     * @notice Register a role if it is not already registered
     */
    function _registerRoleIfNeeded(bytes32 _role) internal {
        if (!_registeredRoles.contains(_role)) {
            _registeredRoles.add(_role);
            emit RoleRegistered(_role);
        }
    }

    /**
     * @notice Unregister a role if it is registered and it has no members
     */
    function _unregisterRoleIfNeeded(bytes32 _role) internal {
        if (_registeredRoles.contains(_role) && getRoleMemberCount(_role) == 0) {
            _registeredRoles.remove(_role);
            emit RoleUnregistered(_role);
        }
    }

    // ============ Pause ============

    /**
     * @notice Pauses registry mutations (registration and role changes)
     * @dev Emergency action: callable by ADMIN_ROLE (timelocked in production) or
     *      SECURITY_ROLE (immediate). Unpause remains ADMIN-only so re-opening always
     *      passes the timelock. Note a paused Registry also freezes role grants, so a
     *      security pause additionally blocks any in-flight privilege escalation.
     */
    function pause() external {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(Auth.SECURITY_ROLE, msg.sender)) {
            revert RegistryCallerHasNoneOfRoles(ADMIN_ROLE, Auth.SECURITY_ROLE);
        }
        _pause();
    }

    /**
     * @notice Unpauses the registry
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
}
