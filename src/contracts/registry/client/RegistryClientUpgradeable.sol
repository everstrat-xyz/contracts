// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";

import {IRegistry} from "interfaces/IRegistry.sol";

import {RegistryClientBase} from "./RegistryClientBase.sol";

/**
 * @title RegistryClientUpgradeable
 * @notice Mixin for upgradeable contracts that use the Registry.
 */
abstract contract RegistryClientUpgradeable is Initializable, RegistryClientBase {
    // ============ Storage ============

    /// @custom:storage-location erc7201:everstrat.storage.RegistryClientUpgradeable
    struct RegistryClientUpgradeableStorage {
        IRegistry _registry;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("everstrat.storage.RegistryClientUpgradeable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REGISTRY_CLIENT_UPGRADEABLE_STORAGE_LOCATION =
        0xbd1fcda84d3854fffab59d162ed55717edaf79b73401f77c755ab4e42954fe00;

    function _getRegistryClientUpgradeableStorage() private pure returns (RegistryClientUpgradeableStorage storage $) {
        assembly {
            $.slot := REGISTRY_CLIENT_UPGRADEABLE_STORAGE_LOCATION
        }
    }

    // ============ Initialization ============

    /**
     * @notice Initializes the contract
     * @param _registry The address of the registry contract
     */
    function __RegistryClient_init(address _registry) internal onlyInitializing {
        if (_registry == address(0)) revert RegistryClientZeroRegistry();
        _getRegistryClientUpgradeableStorage()._registry = IRegistry(_registry);
    }

    // ============ View Functions ============

    /**
     * @notice Get the registry contract
     * @return The registry contract
     */
    function registry() public view override returns (IRegistry) {
        return _getRegistryClientUpgradeableStorage()._registry;
    }
}
