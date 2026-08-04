// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IRegistry} from "interfaces/IRegistry.sol";

/**
 * @title Auth
 * @notice Canonical Registry keys and protocol role identifiers.
 */
library Auth {
    // ============ Protocol Keys ============

    bytes32 internal constant CONTROLLER = keccak256("CONTROLLER");
    bytes32 internal constant AMM = keccak256("AMM");
    bytes32 internal constant STRATEGY_MANAGER = keccak256("STRATEGY_MANAGER");
    bytes32 internal constant EXIT_QUEUE = keccak256("EXIT_QUEUE");
    bytes32 internal constant ORACLE = keccak256("ORACLE");
    bytes32 internal constant EVE = keccak256("EVE");
    bytes32 internal constant CONVERTER = keccak256("CONVERTER");
    bytes32 internal constant QUEUE_KEEPER_EXECUTOR = keccak256("QUEUE_KEEPER_EXECUTOR");
    bytes32 internal constant STRATEGY_KEEPER_EXECUTOR = keccak256("STRATEGY_KEEPER_EXECUTOR");
    bytes32 internal constant WHITELIST = keccak256("WHITELIST");

    function controller(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(CONTROLLER);
    }

    function amm(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(AMM);
    }

    function strategyManager(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(STRATEGY_MANAGER);
    }

    function exitQueue(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(EXIT_QUEUE);
    }

    function oracle(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(ORACLE);
    }

    function eve(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(EVE);
    }

    function converter(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(CONVERTER);
    }

    function queueKeeperExecutor(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(QUEUE_KEEPER_EXECUTOR);
    }

    function strategyKeeperExecutor(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(STRATEGY_KEEPER_EXECUTOR);
    }

    function whitelist(IRegistry _registry) internal view returns (address) {
        return _registry.getContractByKey(WHITELIST);
    }

    // ============ Protocol Roles ============
    //
    // PL-003 governance tiering: privileged roles are held exclusively by OpenZeppelin
    // TimelockController instances in production, while SECURITY is held directly by an
    // emergency multisig:
    //
    //   SECURITY_ROLE        -> no delay   (emergency response: pause + emergency exits)
    //   ADMIN_ROLE           -> 48h delay  (config, strategy set, registry wiring, role
    //                                       management, oracle feeds, unpause, UUPS upgrades)
    //
    // UUPS upgrades share ADMIN_ROLE (no dedicated upgrader role, by design — the team
    // minimizes the role surface). Longer delays for upgrades are enforced by scheduling
    // policy: the DAO proposer schedules upgrade operations on the admin timelock with a
    // delay above the 48h minimum (e.g. 72h).

    /// @notice Protocol governance: configuration, strategy management, registry wiring,
    ///         role management, oracle feed/token configuration, unpause, and UUPS upgrades.
    ///         Held by the 48h timelock in production.
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Emergency response across the protocol. Held directly by the security multisig
    ///         (no timelock) because these actions must be available the instant a threat is
    ///         detected. Beyond pausing, it can trigger the emergency capital-recovery paths:
    ///           - pause() on AMM, Controller, ExitQueue, StrategyManager, UniCLStrat, Registry
    ///           - Controller.emergencyExitToAMM() (sweep idle Controller ETH back to the AMM)
    ///           - UniCLStrat.emergencyExit() (unwind a paused strategy back to StrategyManager)
    ///         It can never unpause, configure, or upgrade: unpause stays with ADMIN_ROLE so a
    ///         compromised security multisig cannot re-open the protocol.
    bytes32 internal constant SECURITY_ROLE = keccak256("SECURITY_ROLE");

    /// @notice Keeper automation on Controller (distributions, exit queue batching, etc.)
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice EVE mint and burn (typically granted to the AMM)
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Converter wrap, unwrap, and swap operations (granted by registered StrategyManager)
    bytes32 internal constant CONVERTER_CALLER_ROLE = keccak256("CONVERTER_CALLER_ROLE");

    /// @notice Admin of CONVERTER_CALLER_ROLE; held by the Converter so only grantCallerRole/revokeCallerRole
    ///         can grant or revoke CONVERTER_CALLER_ROLE (prevents individual strategies from self-escalating).
    bytes32 internal constant CONVERTER_CALLER_MANAGER_ROLE = keccak256("CONVERTER_CALLER_MANAGER_ROLE");
}
