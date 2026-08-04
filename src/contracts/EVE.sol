// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {RegistryClient} from "registry/client/RegistryClient.sol";

import {Auth} from "../libraries/Auth.sol";

import {IEVE} from "../interfaces/IEVE.sol";

/**
 * @title EVE token
 * @notice Static ERC20 token with minting capabilities
 * @dev Mint and burn are authorized via MINTER_ROLE on the protocol Registry (typically the AMM).
 */
contract EVE is IEVE, ERC20, RegistryClient {
    // ============ Constants ============

    /// @notice Role allowed to mint and burn (authority on Registry)
    bytes32 public constant MINTER_ROLE = Auth.MINTER_ROLE;

    /**
     * @notice Constructor for EVE token
     * @param _registry The protocol Registry (role authority)
     */
    constructor(address _registry) ERC20("Everything Strategy", "EVE") RegistryClient(_registry) {}

    /**
     * @notice Returns the version of the contract
     * @return string The version number
     */
    function version() public pure virtual returns (string memory) {
        return "1.0.0";
    }

    /**
     * @inheritdoc IEVE
     */
    function mint(address to, uint256 amount) external onlyAuthRole(Auth.MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @inheritdoc IEVE
     */
    function burn(uint256 amount) external onlyAuthRole(Auth.MINTER_ROLE) {
        _burn(msg.sender, amount);
    }

    /**
     * @inheritdoc IEVE
     */
    function burnFrom(address account, uint256 amount) external onlyAuthRole(Auth.MINTER_ROLE) {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }
}
