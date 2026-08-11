// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {RegistryClient} from "registry/client/RegistryClient.sol";

import {Auth} from "../../libraries/Auth.sol";

import {ICREReceiverBase} from "../../interfaces/automation/ICREReceiverBase.sol";
import {IReceiver} from "../../interfaces/automation/IReceiver.sol";

/**
 * @title CREReceiverBase
 * @notice Chainlink CRE / Keystone receiver base for EverStrat keepers.
 *
 * Security checks follow Chainlink's recommended `ReceiverTemplate`
 * (Building Consumer Contracts guide):
 *   1. `msg.sender` must be the KeystoneForwarder
 *   2. Optional workflow ID / author / name validation from metadata
 *   3. Workflow name validation REQUIRES author validation (40-bit collision)
 *   4. `_decodeMetadata` layout matches ReceiverTemplate
 *   5. ERC-165 advertises `IReceiver`
 *
 * EverStrat adaptations (not deviations from the auth model):
 *   - Forwarder is constructor-immutable (TECH_SPEC: rotating it is a redeploy)
 *   - Configuration gated by Registry `ADMIN_ROLE` instead of OZ `Ownable`
 *   - Receivers are unbound-inert until author or workflow ID is set
 *   - After template auth, decode EverStrat `Envelope` and enforce
 *     chainSelector / sequence / MAX_REPORT_AGE before `_processReport`
 *
 * @dev See https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts
 */
abstract contract CREReceiverBase is ICREReceiverBase, RegistryClient, Pausable, ReentrancyGuard, ERC165 {
    // ============ Immutables ============

    /// @inheritdoc ICREReceiverBase
    address public immutable FORWARDER;

    /// @inheritdoc ICREReceiverBase
    uint64 public immutable CHAIN_SELECTOR;

    /// @inheritdoc ICREReceiverBase
    uint64 public immutable MAX_REPORT_AGE;

    // ============ ReceiverTemplate permission fields ============

    /// @inheritdoc ICREReceiverBase
    bytes32 public expectedWorkflowId;

    /// @inheritdoc ICREReceiverBase
    address public expectedAuthor;

    /// @inheritdoc ICREReceiverBase
    bytes10 public expectedWorkflowName;

    /// @inheritdoc ICREReceiverBase
    uint64 public lastSequence;

    /// @dev Hex charset for ReceiverTemplate workflow-name encoding
    bytes private constant HEX_CHARS = "0123456789abcdef";

    // ============ Constructor ============

    /**
     * @param registry_ Protocol Registry
     * @param forwarder_ Chainlink KeystoneForwarder (required, non-zero — ReceiverTemplate rule)
     * @param chainSelector_ CCIP chain selector for this deployment
     * @param maxReportAge_ Maximum age of Envelope.observedAt relative to block.timestamp
     */
    constructor(address registry_, address forwarder_, uint64 chainSelector_, uint64 maxReportAge_)
        RegistryClient(registry_)
    {
        if (forwarder_ == address(0)) revert CREReceiverZeroAddress();
        if (maxReportAge_ == 0) revert CREReceiverInvalidConfig();
        FORWARDER = forwarder_;
        CHAIN_SELECTOR = chainSelector_;
        MAX_REPORT_AGE = maxReportAge_;
    }

    // ============ CRE entrypoint ============

    /**
     * @inheritdoc IReceiver
     * @dev Order of checks mirrors ReceiverTemplate.onReport, then EverStrat Envelope guards.
     */
    function onReport(bytes calldata metadata, bytes calldata report) external nonReentrant whenNotPaused {
        // ReceiverTemplate Security Check 1: trusted forwarder
        if (msg.sender != FORWARDER) revert InvalidSender(msg.sender, FORWARDER);

        // ReceiverTemplate Security Checks 2-4: workflow identity (if configured)
        _validateWorkflowIdentity(metadata);

        // EverStrat: require at least author or workflow ID before accepting work
        if (expectedWorkflowId == bytes32(0) && expectedAuthor == address(0)) {
            revert CREReceiverWorkflowUnbound();
        }

        // EverStrat Envelope layer (replay / cross-chain / staleness)
        Envelope memory e = abi.decode(report, (Envelope));
        if (e.chainSelector != CHAIN_SELECTOR) revert CREReceiverWrongChain();
        if (e.sequence <= lastSequence) revert CREReceiverReplayedSequence();
        if (e.observedAt > block.timestamp || block.timestamp - e.observedAt > MAX_REPORT_AGE) {
            revert CREReceiverStaleReport();
        }
        lastSequence = e.sequence;

        _processReport(e.action, e.params);
    }

    // ============ Admin (ReceiverTemplate setters; ADMIN_ROLE) ============

    /// @inheritdoc ICREReceiverBase
    function setExpectedWorkflowId(bytes32 _id) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExpectedWorkflowIdUpdated(expectedWorkflowId, _id);
        expectedWorkflowId = _id;
    }

    /// @inheritdoc ICREReceiverBase
    function setExpectedAuthor(address _author) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExpectedAuthorUpdated(expectedAuthor, _author);
        expectedAuthor = _author;
    }

    /**
     * @inheritdoc ICREReceiverBase
     * @dev Encoding matches ReceiverTemplate / CRE engine:
     * SHA256(name) → hex string → first 10 chars → bytes10.
     */
    function setExpectedWorkflowName(string calldata _name) external onlyAuthRole(Auth.ADMIN_ROLE) {
        bytes10 previousName = expectedWorkflowName;
        if (bytes(_name).length == 0) {
            expectedWorkflowName = bytes10(0);
            emit ExpectedWorkflowNameUpdated(previousName, bytes10(0));
            return;
        }

        bytes32 hash = sha256(bytes(_name));
        bytes memory hexString = _bytesToHexString(abi.encodePacked(hash));
        bytes memory first10 = new bytes(10);
        for (uint256 i = 0; i < 10; i++) {
            first10[i] = hexString[i];
        }
        expectedWorkflowName = bytes10(first10);
        emit ExpectedWorkflowNameUpdated(previousName, expectedWorkflowName);
    }

    /// @inheritdoc ICREReceiverBase
    function setExpectedWorkflowName(bytes10 _name) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExpectedWorkflowNameUpdated(expectedWorkflowName, _name);
        expectedWorkflowName = _name;
    }

    /// @inheritdoc ICREReceiverBase
    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /// @inheritdoc ICREReceiverBase
    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }

    // ============ ERC-165 ============

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    // ============ Internal ============

    /**
     * @notice Subclass business logic after ReceiverTemplate auth + Envelope guards
     */
    function _processReport(uint8 action, bytes memory params) internal virtual;

    /**
     * @notice ReceiverTemplate workflow-identity checks (ID / author / name)
     * @dev Name validation REQUIRES author validation — enforced here exactly as
     * in ReceiverTemplate.onReport. Metadata length: production delivers 64 bytes;
     * we accept >= 62 (identity) and ignore trailing reportId. Do not require == 62.
     */
    function _validateWorkflowIdentity(bytes calldata metadata) internal view {
        if (expectedWorkflowId == bytes32(0) && expectedAuthor == address(0) && expectedWorkflowName == bytes10(0)) {
            return; // no identity checks configured (ReceiverTemplate behavior)
        }

        // Reject truncated metadata; 64-byte production slices are fine (>= 62).
        if (metadata.length < 62) revert CREReceiverInvalidMetadata();

        (bytes32 workflowId, bytes10 workflowName, address workflowOwner) = _decodeMetadata(metadata);

        if (expectedWorkflowId != bytes32(0) && workflowId != expectedWorkflowId) {
            revert InvalidWorkflowId(workflowId, expectedWorkflowId);
        }
        if (expectedAuthor != address(0) && workflowOwner != expectedAuthor) {
            revert InvalidAuthor(workflowOwner, expectedAuthor);
        }

        // ================================================================
        // WORKFLOW NAME VALIDATION - REQUIRES AUTHOR VALIDATION
        // (copied rule from ReceiverTemplate — do not rely on name alone)
        // ================================================================
        if (expectedWorkflowName != bytes10(0)) {
            if (expectedAuthor == address(0)) {
                revert WorkflowNameRequiresAuthorValidation();
            }
            if (workflowName != expectedWorkflowName) {
                revert InvalidWorkflowName(workflowName, expectedWorkflowName);
            }
        }
    }

    /**
     * @notice Decode workflow identity — ReceiverTemplate._decodeMetadata layout
     * @dev Template takes `bytes memory` and reads:
     *   - offset 32: workflowId
     *   - offset 64: workflowName
     *   - offset 74: workflowOwner (shr 96)
     * We copy calldata → memory so the same assembly applies verbatim.
     */
    function _decodeMetadata(bytes calldata metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        bytes memory metadata_ = metadata;
        assembly {
            workflowId := mload(add(metadata_, 32))
            workflowName := mload(add(metadata_, 64))
            workflowOwner := shr(mul(12, 8), mload(add(metadata_, 74)))
        }
    }

    /// @dev ReceiverTemplate helper: bytes → lowercase hex string
    function _bytesToHexString(bytes memory data) private pure returns (bytes memory) {
        bytes memory hexString = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            hexString[i * 2] = HEX_CHARS[uint8(data[i] >> 4)];
            hexString[i * 2 + 1] = HEX_CHARS[uint8(data[i] & 0x0f)];
        }
        return hexString;
    }
}
