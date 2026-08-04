// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IERC20
 * @notice Interface for ERC20 token standard
 * @dev Used in tests for mocking interactions with ERC20 tokens
 */
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
}
