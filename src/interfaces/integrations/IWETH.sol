// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
// solhint-disable compiler-version, use-natspec, import-path-check

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IWETH is IERC20Metadata {
    function deposit() external payable;
    function withdraw(uint256 _amount) external;
}
