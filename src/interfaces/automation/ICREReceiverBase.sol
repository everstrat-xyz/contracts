// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IReceiver} from "./IReceiver.sol";

/**
 * @title ICREReceiverBase
 * @notice Shared interface for CRE / Keystone report receivers.
 *
 * Auth surface follows Chainlink's ReceiverTemplate
 * (https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts):
 * forwarder gate + optional workflow ID / author / name binding. EverStrat wires
 * configuration through Registry ADMIN (not Ownable) and adds an Envelope layer
 * for chain/sequence/staleness replay protection.
 */
interface ICREReceiverBase is IReceiver {
    // ============ Types ============

    /**
     * @notice EverStrat report envelope (workflow payload inside `report`).
     * @dev Amounts are deliberately absent — subclasses recompute from live state.
     */
    struct Envelope {
        uint64 chainSelector;
        uint64 sequence;
        uint64 observedAt;
        uint8 action;
        bytes params;
    }

    // ============ Events ============

    event ExpectedWorkflowIdUpdated(bytes32 indexed previousId, bytes32 indexed newId);
    event ExpectedAuthorUpdated(address indexed previousAuthor, address indexed newAuthor);
    event ExpectedWorkflowNameUpdated(bytes10 indexed previousName, bytes10 indexed newName);

    // ============ Errors ============

    // ReceiverTemplate-aligned identity errors
    error InvalidSender(address sender, address expected);
    error InvalidAuthor(address received, address expected);
    error InvalidWorkflowName(bytes10 received, bytes10 expected);
    error InvalidWorkflowId(bytes32 received, bytes32 expected);
    error WorkflowNameRequiresAuthorValidation();

    // EverStrat Envelope / config errors
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
    function expectedAuthor() external view returns (address);
    function expectedWorkflowName() external view returns (bytes10);
    function lastSequence() external view returns (uint64);
    function version() external pure returns (string memory);

    // ============ Admin (ReceiverTemplate setters; ADMIN_ROLE instead of Ownable) ============

    function setExpectedWorkflowId(bytes32 _id) external;
    function setExpectedAuthor(address _author) external;
    /// @notice Sets expected workflow name from plaintext (SHA256→hex→bytes10, per CRE engine)
    function setExpectedWorkflowName(string calldata _name) external;
    /// @notice Sets expected workflow name from a pre-encoded bytes10 (tests / advanced use)
    function setExpectedWorkflowName(bytes10 _name) external;
    function pause() external;
    function unpause() external;
}
