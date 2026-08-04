// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {RegistryClient} from "registry/client/RegistryClient.sol";

import {Auth} from "../libraries/Auth.sol";

import {IWhitelist} from "../interfaces/IWhitelist.sol";

/**
 * @title Whitelist
 * @notice Static contract gating protocol entry via server-signed invite vouchers.
 * @dev A voucher is an EIP-712 signature over `Invite(address user, bytes32 inviteId,
 * uint256 deadline)` from an authorized signer. `inviteId` is an opaque identifier chosen
 * by the server (never the invite code itself, or a direct hash of it) so on-chain state
 * never leaks the code space. `enterWithInvite()` on the AMM is the primary caller of
 * {whitelist}, but the function is permissionless so any relayer can sponsor gas.
 *
 * `AMM.exit()` never consults this contract: users can always leave the protocol
 * regardless of whitelist state.
 *
 * Redeployments start empty: migrate users via `addToWhitelist` (or open the gate with
 * `disable()`) rather than chaining to a prior deployment.
 */
contract Whitelist is IWhitelist, RegistryClient, EIP712 {
    // ============ Constants ============

    bytes32 public constant ADMIN_ROLE = Auth.ADMIN_ROLE;
    bytes32 public constant SECURITY_ROLE = Auth.SECURITY_ROLE;

    bytes32 public constant INVITE_TYPEHASH = keccak256("Invite(address user,bytes32 inviteId,uint256 deadline)");

    // ============ Storage Variables ============

    // bool variables
    /**
     * @notice Once true, {isWhitelisted} returns true for every address (bans ignored).
     * Irreversible.
     */
    bool public disabled;

    // complex types
    mapping(address user => bool) private _whitelisted;
    mapping(address user => bool) private _banned;
    mapping(bytes32 inviteId => bool) private _isInviteUsed;
    mapping(address signer => bool) private _isSigner;

    // ============ Modifiers ============

    /**
     * @dev Reverts once {disable} has opened the gate — admin invite-period mutators
     * (add/remove whitelist entries and signers) are then meaningless because
     * {isWhitelisted} already returns true for everyone. {whitelist} is not gated: it
     * no-ops via the isWhitelisted early return so {AMM.enterWithInvite} stays safe.
     */
    modifier whenNotDisabled() {
        if (disabled) revert WhitelistIsDisabled();
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Constructor for the Whitelist contract.
     * @param _registry Address of the protocol Registry (role authority).
     */
    constructor(address _registry) RegistryClient(_registry) EIP712("EverStratWhitelist", "1") {}

    // ============ View Functions ============

    /**
     * @notice Returns the version of the contract.
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @inheritdoc IWhitelist
     */
    function isSigner(address _signer) external view returns (bool) {
        return _isSigner[_signer];
    }

    /**
     * @inheritdoc IWhitelist
     */
    function isInviteUsed(bytes32 _inviteId) external view returns (bool) {
        return _isInviteUsed[_inviteId];
    }

    /**
     * @inheritdoc IWhitelist
     */
    function isBanned(address _user) external view returns (bool) {
        return _banned[_user];
    }

    /**
     * @inheritdoc IWhitelist
     */
    function isWhitelisted(address _user) public view returns (bool) {
        // Gate open => protocol open. Pre-disable bans are retained in storage for
        // `isBanned()` introspection but no longer block entry.
        if (disabled) return true;
        if (_banned[_user]) return false;

        return _whitelisted[_user];
    }

    // ============ User Functions ============

    /**
     * @inheritdoc IWhitelist
     */
    function whitelist(address _user, bytes32 _inviteId, uint256 _deadline, bytes calldata _signature) external {
        // Already whitelisted (including after disable(), which makes isWhitelisted true for
        // everyone): a benign no-op. Leaving the invite unconsumed matters for a relayer
        // racing the user's own redemption, permissionless replay of an already-redeemed
        // voucher, and enterWithInvite() after the invite period ends.
        if (isWhitelisted(_user)) return;

        // Explicit, not folded into the isWhitelisted() early return above: a ban must
        // reject a stale unconsumed voucher outright rather than silently re-whitelisting
        // the address the moment someone replays it.
        if (_banned[_user]) revert WhitelistUserBanned(_user);

        if (_isInviteUsed[_inviteId]) revert WhitelistInviteAlreadyUsed(_inviteId);
        if (block.timestamp > _deadline) revert WhitelistSignatureExpired(_deadline);

        bytes32 structHash = keccak256(abi.encode(INVITE_TYPEHASH, _user, _inviteId, _deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), _signature);
        if (!_isSigner[signer]) revert WhitelistInvalidSignature();

        _isInviteUsed[_inviteId] = true;
        _whitelisted[_user] = true;

        emit UserWhitelisted(_user, _inviteId, block.timestamp);
    }

    // ============ Owner/Admin Functions ============

    /**
     * @inheritdoc IWhitelist
     */
    function addToWhitelist(address[] calldata _users) external onlyAuthRole(Auth.ADMIN_ROLE) whenNotDisabled {
        for (uint256 i; i < _users.length; ++i) {
            address user = _users[i];
            if (user == address(0)) revert WhitelistZeroAddress();

            // Clearing ban here is the intentional undo path for removeFromWhitelist:
            // isWhitelisted checks _banned before _whitelisted, so re-admit must lift both.
            _banned[user] = false;
            _whitelisted[user] = true;
            emit UserWhitelistedByAdmin(user, block.timestamp);
        }
    }

    /**
     * @inheritdoc IWhitelist
     */
    function removeFromWhitelist(address _user) external onlyAuthRole(Auth.ADMIN_ROLE) whenNotDisabled {
        _whitelisted[_user] = false;
        _banned[_user] = true;

        emit UserRemovedFromWhitelist(_user, block.timestamp);
    }

    /**
     * @inheritdoc IWhitelist
     */
    function addSigner(address _signer) external onlyAuthRole(Auth.ADMIN_ROLE) whenNotDisabled {
        if (_signer == address(0)) revert WhitelistZeroAddress();
        if (_isSigner[_signer]) revert WhitelistSignerAlreadyAdded(_signer);

        _isSigner[_signer] = true;
        emit SignerAdded(_signer);
    }

    /**
     * @inheritdoc IWhitelist
     */
    function removeSigner(address _signer)
        external
        onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE)
        whenNotDisabled
    {
        if (!_isSigner[_signer]) revert WhitelistSignerNotFound(_signer);

        _isSigner[_signer] = false;
        emit SignerRemoved(_signer);
    }

    /**
     * @inheritdoc IWhitelist
     */
    function disable() external onlyAuthRole(Auth.ADMIN_ROLE) {
        if (disabled) revert WhitelistIsDisabled();

        disabled = true;
        emit WhitelistDisabled(block.timestamp);
    }
}
