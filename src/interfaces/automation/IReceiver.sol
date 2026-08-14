// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IReceiver
 * @notice Chainlink Keystone / CRE consumer interface.
 * @dev Local copy of chainlink-evm IReceiver with a remapping-compatible IERC165
 * import (the versioned OpenZeppelin path used upstream does not resolve here).
 */
interface IReceiver is IERC165 {
    /**
     * @notice Handles an incoming Keystone / CRE report
     * @param metadata Workflow identity metadata (typically 64 bytes from the forwarder)
     * @param report ABI-encoded report payload
     */
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
