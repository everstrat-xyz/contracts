// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IReceiver} from "./IReceiver.sol";

/**
 * @title ICREReceiverBase
 * @notice Shared interface for CRE / Keystone report receivers.
 *
 * Receivers are gated to the Chainlink-managed KeystoneForwarder. Workflow
 * identity (owner / name / id) is ADMIN-bound. Report envelopes never carry
 * authoritative ETH amounts, NAV, or prices — subclasses re-validate from
 * live chain state inside `_processReport`.
 */
interface ICREReceiverBase is IReceiver {
    // ============ Types ============

    /**
     * @notice CRE report envelope. Amounts are deliberately absent.
     * @param chainSelector CCIP chain selector; must match the deployment's selector
     * @param sequence Strictly increasing per-receiver sequence number
     * @param observedAt Workflow observation timestamp (unix seconds)
     * @param action Action selector interpreted by the subclass
     * @param params Action-specific hints only (never authoritative amounts)
     */
    struct Envelope {
        uint64 chainSelector;
        uint64 sequence;
        uint64 observedAt;
        uint8 action;
        bytes params;
    }

    // ============ Events ============

    event ExpectedWorkflowIdChanged(bytes32 oldWorkflowId, bytes32 newWorkflowId);
    event ExpectedWorkflowOwnerChanged(address oldOwner, address newOwner);
    event ExpectedWorkflowNameChanged(bytes10 oldName, bytes10 newName);

    // ============ Errors ============

    error CREReceiverOnlyForwarder();
    error CREReceiverUnexpectedWorkflow();
    error CREReceiverWrongChain();
    error CREReceiverStaleReport();
    error CREReceiverReplayedSequence();
    error CREReceiverInvalidMetadata();
    error CREReceiverZeroAddress();
    error CREReceiverInvalidConfig();
    error CREReceiverWorkflowUnbound();

    // ============ Views ============

    function FORWARDER() external view returns (address);
    function CHAIN_SELECTOR() external view returns (uint64);
    function MAX_REPORT_AGE() external view returns (uint64);
    function expectedWorkflowId() external view returns (bytes32);
    function expectedWorkflowOwner() external view returns (address);
    function expectedWorkflowName() external view returns (bytes10);
    function lastSequence() external view returns (uint64);
    function version() external pure returns (string memory);

    // ============ Admin ============

    function setExpectedWorkflowId(bytes32 _workflowId) external;
    function setExpectedWorkflowOwner(address _owner) external;
    function setExpectedWorkflowName(bytes10 _name) external;
    function pause() external;
    function unpause() external;
}
