// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolDeployBase} from "../../../../script/ProtocolDeployBase.sol";

contract TimelockDeploymentHarness is ProtocolDeployBase {
    function deploy(uint256 delay, address proposer, address security) external returns (TimelockController) {
        return _deployTimelock(delay, address(this), proposer, security);
    }

    function verify(TimelockController timelock, address proposer, address security) external view {
        _verifyTimelockRoles(timelock, address(this), proposer, security);
    }
}

contract DeploymentTimelockConfigTest is Test {
    function test_ExplicitZeroDelayDeploysAndPassesCurrentVerification() external {
        TimelockDeploymentHarness harness = new TimelockDeploymentHarness();
        address dao = makeAddr("dao");
        address security = makeAddr("security");

        TimelockController timelock = harness.deploy(0, dao, security);

        assertEq(timelock.getMinDelay(), 0);
        harness.verify(timelock, dao, security);
    }

    function test_ZeroProposerPassesVerificationButNoRealActorCanScheduleRecovery() external {
        TimelockDeploymentHarness harness = new TimelockDeploymentHarness();
        address security = makeAddr("security");
        address ordinaryActor = makeAddr("ordinaryActor");
        TimelockController timelock = harness.deploy(48 hours, address(0), security);

        harness.verify(timelock, address(0), security);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(harness)));

        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes memory repairCall = abi.encodeCall(timelock.grantRole, (proposerRole, ordinaryActor));
        vm.prank(ordinaryActor);
        vm.expectRevert();
        timelock.schedule(address(timelock), 0, repairCall, bytes32(0), keccak256("repair"), 48 hours);
    }
}
