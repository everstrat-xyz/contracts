// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ICREReceiverBase} from "../../src/interfaces/automation/ICREReceiverBase.sol";

/**
 * @title CRETestUtils
 * @notice Shared helpers for encoding Keystone metadata and CRE report envelopes.
 */
abstract contract CRETestUtils {
    uint64 internal constant TEST_CHAIN_SELECTOR = 16015286601757825753; // Ethereum Sepolia
    uint64 internal constant TEST_MAX_REPORT_AGE = 1 hours;

    function _encodeMetadata(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
        internal
        pure
        returns (bytes memory)
    {
        // Production forwarder delivers 64 bytes: identity (62) + reportId (2).
        return abi.encodePacked(workflowId, workflowName, workflowOwner, bytes2(0));
    }

    function _encodeReport(uint64 chainSelector, uint64 sequence, uint64 observedAt, uint8 action, bytes memory params)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            ICREReceiverBase.Envelope({
                chainSelector: chainSelector,
                sequence: sequence,
                observedAt: observedAt,
                action: action,
                params: params
            })
        );
    }
}
