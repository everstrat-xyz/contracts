// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Registry} from "registry/Registry.sol";
import {AMM} from "../../src/contracts/AMM.sol";
import {Oracle} from "../../src/contracts/Oracle.sol";
import {NAVGuardian} from "../../src/contracts/automation/NAVGuardian.sol";

import {Auth} from "../../src/libraries/Auth.sol";
import {ICREReceiverBase} from "../../src/interfaces/automation/ICREReceiverBase.sol";
import {INAVGuardian} from "../../src/interfaces/automation/INAVGuardian.sol";

import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {ProtocolTestBase} from "../helpers/ProtocolTestBase.sol";
import {CRETestUtils} from "../helpers/CRETestUtils.sol";

contract NAVGuardianTest is ProtocolTestBase, CRETestUtils {
    Registry public registry;
    AMM public amm;
    Oracle public oracle;
    NAVGuardian public guardian;

    address public forwarder;
    address public workflowOwner;
    address public security;
    bytes32 public workflowId;
    bytes10 public workflowName;
    uint64 internal _seq;

    function setUp() public {
        forwarder = makeAddr("keystoneForwarder");
        workflowOwner = makeAddr("workflowOwner");
        security = makeAddr("security");
        workflowId = keccak256("nav-guardian-v1");
        workflowName = bytes10("nav-guardi");

        ProtocolContracts memory contracts = _deployProtocol(address(this), DEFAULT_CONNECTOR_WEIGHT);
        registry = contracts.registry;
        amm = contracts.amm;
        oracle = contracts.oracle;

        MockPriceFeed ethPriceFeed = new MockPriceFeed(8, int256(4000e8));
        oracle.updateUsdFeedInfo(address(0), address(ethPriceFeed), 3600);

        registry.grantRole(Auth.SECURITY_ROLE, security);

        guardian = new NAVGuardian(address(registry), forwarder, TEST_CHAIN_SELECTOR, TEST_MAX_REPORT_AGE);
        guardian.setExpectedWorkflowOwner(workflowOwner);
        guardian.setExpectedWorkflowName(workflowName);
        guardian.setExpectedWorkflowId(workflowId);

        assertTrue(guardian.reportOnly());
    }

    function _metadata() internal view returns (bytes memory) {
        return _encodeMetadata(workflowId, workflowName, workflowOwner);
    }

    function _pauseReport(bytes32[] memory modules) internal {
        _seq += 1;
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            _seq,
            uint64(block.timestamp),
            uint8(INAVGuardian.GuardianAction.PauseOnAnomaly),
            abi.encode(modules)
        );
        vm.prank(forwarder);
        guardian.onReport(_metadata(), report);
    }

    function test_ReportOnly_EmitsWouldPause_DoesNotPause() public {
        bytes32[] memory modules = new bytes32[](1);
        modules[0] = Auth.AMM;

        vm.expectEmit(false, false, false, true, address(guardian));
        emit INAVGuardian.GuardianWouldPause(modules, uint8(INAVGuardian.GuardianAction.PauseOnAnomaly));
        _pauseReport(modules);

        assertFalse(amm.paused());
    }

    function test_LivePause_RequiresSecurityRoleOnGuardian() public {
        // Grant SECURITY_ROLE so pause() on AMM succeeds through the guardian.
        registry.grantRole(Auth.SECURITY_ROLE, address(guardian));
        guardian.setReportOnly(false);

        bytes32[] memory modules = new bytes32[](1);
        modules[0] = Auth.AMM;

        vm.expectEmit(false, false, false, true, address(guardian));
        emit INAVGuardian.GuardianPaused(modules, uint8(INAVGuardian.GuardianAction.PauseOnAnomaly));
        _pauseReport(modules);

        assertTrue(amm.paused());
    }

    function test_Disable_BySecurity() public {
        vm.prank(security);
        guardian.disable();
        assertTrue(guardian.disabled());

        bytes32[] memory modules = new bytes32[](1);
        modules[0] = Auth.AMM;
        _seq += 1;
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            _seq,
            uint64(block.timestamp),
            uint8(INAVGuardian.GuardianAction.PauseOnAnomaly),
            abi.encode(modules)
        );
        vm.prank(forwarder);
        vm.expectRevert(INAVGuardian.GuardianIsDisabled.selector);
        guardian.onReport(_metadata(), report);
    }

    function test_RateLimit_MinInterval() public {
        bytes32[] memory modules = new bytes32[](1);
        modules[0] = Auth.AMM;
        _pauseReport(modules);

        _seq += 1;
        bytes memory report = _encodeReport(
            TEST_CHAIN_SELECTOR,
            _seq,
            uint64(block.timestamp),
            uint8(INAVGuardian.GuardianAction.PauseOnAnomaly),
            abi.encode(modules)
        );
        vm.prank(forwarder);
        vm.expectRevert(INAVGuardian.GuardianRateLimited.selector);
        guardian.onReport(_metadata(), report);

        vm.warp(block.timestamp + guardian.MIN_PAUSE_INTERVAL());
        _pauseReport(modules); // succeeds
    }

    function test_NoUnpausePath() public {
        // Guardian must not expose unpause — only CREReceiverBase.unpause (ADMIN on guardian itself).
        // Pausing AMM via guardian does not create an unpause path through guardian for AMM.
        registry.grantRole(Auth.SECURITY_ROLE, address(guardian));
        guardian.setReportOnly(false);

        bytes32[] memory modules = new bytes32[](1);
        modules[0] = Auth.AMM;
        _pauseReport(modules);
        assertTrue(amm.paused());

        // Unpause remains on AMM via ADMIN (this test contract), not via guardian.
        amm.unpause();
        assertFalse(amm.paused());
    }
}
