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
 * @notice Shared base for Chainlink CRE / Keystone report receivers.
 * @dev Static (non-upgradeable). The Chainlink-managed KeystoneForwarder is the
 * sole caller of {onReport}. Workflow identity is ADMIN-bound. Subclasses must
 * re-validate every condition and amount from live chain state inside
 * {_processReport} — the report is treated as action selection / hints only.
 */
abstract contract CREReceiverBase is ICREReceiverBase, RegistryClient, Pausable, ReentrancyGuard, ERC165 {
    // ============ Immutables ============

    /// @inheritdoc ICREReceiverBase
    address public immutable FORWARDER;

    /// @inheritdoc ICREReceiverBase
    uint64 public immutable CHAIN_SELECTOR;

    /// @inheritdoc ICREReceiverBase
    uint64 public immutable MAX_REPORT_AGE;

    // ============ State ============

    /// @inheritdoc ICREReceiverBase
    bytes32 public expectedWorkflowId;

    /// @inheritdoc ICREReceiverBase
    address public expectedWorkflowOwner;

    /// @inheritdoc ICREReceiverBase
    bytes10 public expectedWorkflowName;

    /// @inheritdoc ICREReceiverBase
    uint64 public lastSequence;

    // ============ Constructor ============

    /**
     * @param registry_ Protocol Registry
     * @param forwarder_ Chainlink KeystoneForwarder (immutable)
     * @param chainSelector_ CCIP chain selector for this deployment
     * @param maxReportAge_ Maximum age of `observedAt` relative to `block.timestamp`
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
     */
    function onReport(bytes calldata metadata, bytes calldata report) external nonReentrant whenNotPaused {
        if (msg.sender != FORWARDER) revert CREReceiverOnlyForwarder();
        _validateWorkflow(metadata);

        Envelope memory e = abi.decode(report, (Envelope));
        if (e.chainSelector != CHAIN_SELECTOR) revert CREReceiverWrongChain();
        if (e.sequence <= lastSequence) revert CREReceiverReplayedSequence();
        if (e.observedAt > block.timestamp || block.timestamp - e.observedAt > MAX_REPORT_AGE) {
            revert CREReceiverStaleReport();
        }
        lastSequence = e.sequence;

        _processReport(e.action, e.params);
    }

    // ============ Admin ============

    /**
     * @inheritdoc ICREReceiverBase
     * @dev Pinning a workflow ID is the steady-state binding. Clearing to
     * `bytes32(0)` falls back to owner (+ optional name) validation.
     */
    function setExpectedWorkflowId(bytes32 _workflowId) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExpectedWorkflowIdChanged(expectedWorkflowId, _workflowId);
        expectedWorkflowId = _workflowId;
    }

    /**
     * @inheritdoc ICREReceiverBase
     */
    function setExpectedWorkflowOwner(address _owner) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExpectedWorkflowOwnerChanged(expectedWorkflowOwner, _owner);
        expectedWorkflowOwner = _owner;
    }

    /**
     * @inheritdoc ICREReceiverBase
     * @dev Name validation is only meaningful when `expectedWorkflowOwner` is set —
     * name-only binding is rejected at validation time (40-bit collision surface).
     */
    function setExpectedWorkflowName(bytes10 _name) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ExpectedWorkflowNameChanged(expectedWorkflowName, _name);
        expectedWorkflowName = _name;
    }

    /**
     * @inheritdoc ICREReceiverBase
     */
    function pause() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc ICREReceiverBase
     */
    function unpause() external onlyAuthRole(Auth.ADMIN_ROLE) {
        _unpause();
    }

    // ============ ERC-165 ============

    /**
     * @inheritdoc ERC165
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    // ============ Internal ============

    /**
     * @notice Subclass entrypoint after auth / replay / staleness checks
     * @dev Must re-validate action conditions and recompute any amounts from
     * live state. Wrong/stale claims should revert with the subclass's
     * "no upkeep needed" error (never execute on trust of the report alone).
     */
    function _processReport(uint8 action, bytes memory params) internal virtual;

    /**
     * @notice Validates workflow identity from Keystone metadata
     * @dev Metadata is typically 64 bytes from the production forwarder:
     * `workflowId (32) | workflowName (10) | workflowOwner (20) | reportId (2)`.
     * The first 62 bytes are the logical packed identity; trailing `reportId`
     * is ignored for identity checks. Require at least 62 bytes.
     *
     * Validation order (matches Chainlink ReceiverTemplate guidance):
     * 1. If `expectedWorkflowId` is set → require exact ID match (steady state)
     * 2. Else require `expectedWorkflowOwner` set and matching (name optional)
     * 3. Name-without-owner is rejected (collision guard)
     * 4. Completely unbound receiver rejects all reports
     */
    function _validateWorkflow(bytes calldata metadata) internal view {
        if (metadata.length < 62) revert CREReceiverInvalidMetadata();

        (bytes32 workflowId, bytes10 workflowName, address workflowOwner) = _decodeMetadata(metadata);

        if (expectedWorkflowId != bytes32(0)) {
            if (workflowId != expectedWorkflowId) revert CREReceiverUnexpectedWorkflow();
            return;
        }

        if (expectedWorkflowOwner == address(0)) {
            // Name-only is unsafe; unbound is inert.
            if (expectedWorkflowName != bytes10(0)) revert CREReceiverUnexpectedWorkflow();
            revert CREReceiverWorkflowUnbound();
        }

        if (workflowOwner != expectedWorkflowOwner) revert CREReceiverUnexpectedWorkflow();
        if (expectedWorkflowName != bytes10(0) && workflowName != expectedWorkflowName) {
            revert CREReceiverUnexpectedWorkflow();
        }
    }

    /**
     * @notice Decode workflow identity from Keystone metadata (first 62 bytes)
     * @dev Layout matches Chainlink ReceiverTemplate / KeystoneFeedsConsumer:
     * packed `bytes32 | bytes10 | address`. Assembly reads match the OZ/Chainlink
     * reference (workflowName loaded at offset 64 of the bytes object; owner
     * right-aligned via shr 96 from offset 74).
     */
    function _decodeMetadata(bytes calldata metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        assembly {
            workflowId := calldataload(metadata.offset)
            workflowName := calldataload(add(metadata.offset, 32))
            workflowOwner := shr(96, calldataload(add(metadata.offset, 42)))
        }
    }
}
