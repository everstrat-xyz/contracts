// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {CREQueueExecutor} from "../../src/contracts/automation/CREQueueExecutor.sol";
import {Registry} from "registry/Registry.sol";
import {ICREReceiverBase} from "../../src/interfaces/automation/ICREReceiverBase.sol";
import {CRETestUtils} from "../helpers/CRETestUtils.sol";

/**
 * @title CREKeystoneMetadataTest
 * @notice Fork assertion for KeystoneForwarder metadata layout (64-byte identity slice).
 * @dev Skips when `SEPOLIA_RPC_URL` is unset. Does not require a live onReport delivery —
 *      it documents and locks the expected 64-byte metadata shape against the published
 *      Sepolia KeystoneForwarder address from the CRE forwarder directory.
 */
contract CREKeystoneMetadataTest is Test, CRETestUtils {
    address constant SEPOLIA_KEYSTONE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    function test_Fork_MetadataLayoutIs64Bytes() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);

        // Live forwarder has code.
        assertGt(SEPOLIA_KEYSTONE_FORWARDER.code.length, 0, "Sepolia KeystoneForwarder missing code");

        // Local consumer accepts the documented 64-byte metadata layout.
        Registry registry = new Registry(address(this));
        CREQueueExecutor executor = new CREQueueExecutor(
            address(registry), SEPOLIA_KEYSTONE_FORWARDER, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE
        );

        bytes32 workflowId = keccak256("fork-meta");
        bytes10 workflowName = bytes10("fork-meta-");
        address workflowOwner = address(this);
        executor.setExpectedAuthor(workflowOwner);
        executor.setExpectedWorkflowName(workflowName);
        executor.setExpectedWorkflowId(workflowId);

        bytes memory metadata = _encodeMetadata(workflowId, workflowName, workflowOwner);
        assertEq(metadata.length, 64, "production metadata must be 64 bytes");

        // Wrong length still rejected locally (layout guard).
        bytes memory shortMeta =
            bytes.concat(bytes32(workflowId), bytes10(workflowName), bytes19(uint152(uint160(workflowOwner))));
        assertEq(shortMeta.length, 61);
        bytes memory report = _encodeReport(TEST_CHAIN_SELECTOR, 1, uint64(block.timestamp), 0, "");
        vm.prank(SEPOLIA_KEYSTONE_FORWARDER);
        vm.expectRevert(ICREReceiverBase.CREReceiverInvalidMetadata.selector);
        executor.onReport(shortMeta, report);
    }
}
