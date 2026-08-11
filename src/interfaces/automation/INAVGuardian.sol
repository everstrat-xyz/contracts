// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ICREReceiverBase} from "./ICREReceiverBase.sol";

/**
 * @title INAVGuardian
 * @notice CRE pause-only wrapper holding SECURITY_ROLE.
 * @dev Exposes only pause actuation. Never unpause, emergency*, or configure.
 * Instant {disable} by ADMIN or SECURITY bounds misbehaving-workflow DoS.
 */
interface INAVGuardian is ICREReceiverBase {
    enum GuardianAction {
        None,
        PauseOnAnomaly
    }

    event GuardianPaused(bytes32[] modules, uint8 action);
    event GuardianWouldPause(bytes32[] modules, uint8 action);
    event GuardianDisabled(address indexed by);
    event ReportOnlyChanged(bool reportOnly);

    error GuardianIsDisabled();
    error GuardianUnknownAction();
    error GuardianRateLimited();
    error GuardianEmptyModules();
    error GuardianAlreadyDisabled();

    function MIN_PAUSE_INTERVAL() external pure returns (uint256);
    function MAX_PAUSES_PER_DAY() external pure returns (uint8);

    function disabled() external view returns (bool);
    function reportOnly() external view returns (bool);
    function lastPauseAt() external view returns (uint256);
    function pausesToday() external view returns (uint8);
    function dayStart() external view returns (uint256);

    function setReportOnly(bool _reportOnly) external;
    function disable() external;
}
