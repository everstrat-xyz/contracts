// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Auth} from "../../libraries/Auth.sol";

import {INAVGuardian} from "../../interfaces/automation/INAVGuardian.sol";

import {CREReceiverBase} from "./CREReceiverBase.sol";

interface IPausableModule {
    function pause() external;
}

/**
 * @title NAVGuardian
 * @notice CRE pause-only SECURITY_ROLE wrapper for automated NAV anomaly response.
 * @dev Holds SECURITY_ROLE but exposes only pause actuation by immutable code —
 * emergency recovery paths are unreachable through this contract. Deploy in
 * {reportOnly} mode first; grant SECURITY_ROLE only after false-positive bake-in.
 *
 * Report params for PauseOnAnomaly: `abi.encode(bytes32[] modules)` where each
 * entry is a Registry Auth key (e.g. Auth.AMM).
 */
contract NAVGuardian is INAVGuardian, CREReceiverBase {
    uint256 public constant MIN_PAUSE_INTERVAL = 1 hours;
    uint8 public constant MAX_PAUSES_PER_DAY = 3;

    bool public disabled;
    bool public reportOnly;
    uint256 public lastPauseAt;
    uint8 public pausesToday;
    uint256 public dayStart;

    constructor(address registry_, address forwarder_, uint64 chainSelector_, uint64 maxReportAge_)
        CREReceiverBase(registry_, forwarder_, chainSelector_, maxReportAge_)
    {
        reportOnly = true; // fail-safe default until governance flips it
        dayStart = _currentDayStart();
    }

    function version() external pure returns (string memory) {
        return "1.0.0-cre";
    }

    function _processReport(uint8 action, bytes memory params) internal override {
        if (disabled) revert GuardianIsDisabled();
        if (GuardianAction(action) != GuardianAction.PauseOnAnomaly) revert GuardianUnknownAction();

        bytes32[] memory modules = abi.decode(params, (bytes32[]));
        if (modules.length == 0) revert GuardianEmptyModules();

        _enforceRateLimit();

        if (reportOnly) {
            emit GuardianWouldPause(modules, action);
            return;
        }

        for (uint256 i; i < modules.length; ++i) {
            IPausableModule(registry().getContractByKey(modules[i])).pause();
        }
        emit GuardianPaused(modules, action);
    }

    function setReportOnly(bool _reportOnly) external onlyAuthRole(Auth.ADMIN_ROLE) {
        emit ReportOnlyChanged(_reportOnly);
        reportOnly = _reportOnly;
    }

    /**
     * @inheritdoc INAVGuardian
     * @dev Instant kill by ADMIN or SECURITY — does not wait for the 48h role revoke.
     */
    function disable() external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        if (disabled) revert GuardianAlreadyDisabled();
        disabled = true;
        emit GuardianDisabled(msg.sender);
    }

    function _enforceRateLimit() internal {
        uint256 today = _currentDayStart();
        if (today != dayStart) {
            dayStart = today;
            pausesToday = 0;
        }

        if (lastPauseAt != 0 && block.timestamp - lastPauseAt < MIN_PAUSE_INTERVAL) {
            revert GuardianRateLimited();
        }
        if (pausesToday >= MAX_PAUSES_PER_DAY) revert GuardianRateLimited();

        lastPauseAt = block.timestamp;
        pausesToday += 1;
    }

    function _currentDayStart() internal view returns (uint256) {
        return block.timestamp - (block.timestamp % 1 days);
    }
}
