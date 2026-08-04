// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRegistry} from "interfaces/IRegistry.sol";
import {RegistryClientBase} from "./RegistryClientBase.sol";

/**
 * @title RegistryClient
 * @notice Mixin for static contracts that use the Registry for roles and peer addresses.
 */
abstract contract RegistryClient is RegistryClientBase {
    // ============ State Variables ============

    /// @notice The registry contract
    IRegistry internal _registry;

    // ============ Constructor ============

    /**
     * @notice Constructor that sets the registry
     * @param registry_ The registry contract
     */
    constructor(address registry_) {
        if (registry_ == address(0)) revert RegistryClientZeroRegistry();
        _registry = IRegistry(registry_);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc RegistryClientBase
     */
    function registry() public view override returns (IRegistry) {
        return _registry;
    }
}
