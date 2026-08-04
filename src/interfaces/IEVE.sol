// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title IEVE
 * @notice Interface for the EVE upgradeable contract
 * @dev Defines the core functionality for ERC20 token management and access control
 */
interface IEVE {
    // ============ Metadata ============

    /// @notice Returns the version of the contract
    function version() external pure returns (string memory);

    // ============ Token Management ============

    /// @notice Mints new tokens to a specified address
    /// @dev Only addresses with MINTER_ROLE can mint new tokens
    /// @param to The address to receive the newly minted tokens
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burns tokens from the caller's account
    /// @dev Only addresses with MINTER_ROLE can burn tokens they hold directly
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;

    /// @notice Burns tokens from a specified account with allowance
    /// @dev Only addresses with MINTER_ROLE can burn tokens from other accounts.
    ///      The caller must also have sufficient allowance granted by `account`.
    /// @param account The account to burn tokens from
    /// @param amount The amount of tokens to burn
    function burnFrom(address account, uint256 amount) external;
}
