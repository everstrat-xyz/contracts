// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IWhitelist {
    // ============ Events ============

    /**
     * @notice A user has been whitelisted by redeeming a server-signed invite voucher.
     */
    event UserWhitelisted(address indexed user, bytes32 indexed inviteId, uint256 timestamp);

    /**
     * @notice A user has been whitelisted directly by an admin (no invite consumed).
     */
    event UserWhitelistedByAdmin(address indexed user, uint256 timestamp);

    /**
     * @notice A user has been removed (banned) from the whitelist while the gate is active.
     * @dev "Permanent" only for the invite period: while `disabled()` is false, vouchers
     * for this address cannot re-admit it and `isWhitelisted` returns false. Once
     * `disable()` opens the gate, bans no longer block entry (`isWhitelisted` returns true
     * for everyone); `isBanned` may still report the historical flag.
     */
    event UserRemovedFromWhitelist(address indexed user, uint256 timestamp);

    /**
     * @notice A new invite-signing key has been authorized.
     */
    event SignerAdded(address indexed signer);

    /**
     * @notice An invite-signing key has been revoked.
     */
    event SignerRemoved(address indexed signer);

    /**
     * @notice The whitelist gate has been permanently disabled; `isWhitelisted()` now
     * returns true for every address. Ban state is ignored once the gate is open.
     */
    event WhitelistDisabled(uint256 timestamp);

    // ============ Errors ============

    /**
     * @notice Provided address is a zero address.
     */
    error WhitelistZeroAddress();

    /**
     * @notice The whitelist gate is disabled. Thrown by `disable()` when already disabled,
     * and by invite-period admin mutators (`addToWhitelist`, `removeFromWhitelist`,
     * `addSigner`, `removeSigner`) once the gate has been permanently opened.
     * `whitelist()` is intentionally not gated — it no-ops when disabled via `isWhitelisted`.
     */
    error WhitelistIsDisabled();

    /**
     * @notice The provided invite id has already been consumed.
     */
    error WhitelistInviteAlreadyUsed(bytes32 inviteId);

    /**
     * @notice The voucher's deadline has passed.
     */
    error WhitelistSignatureExpired(uint256 deadline);

    /**
     * @notice The voucher signature does not recover to an authorized signer.
     */
    error WhitelistInvalidSignature();

    /**
     * @notice The signer is already authorized.
     */
    error WhitelistSignerAlreadyAdded(address signer);

    /**
     * @notice The signer is not currently authorized.
     */
    error WhitelistSignerNotFound(address signer);

    /**
     * @notice `_user` is banned while the whitelist gate is still active, so a voucher
     * (including a stale unconsumed one) cannot admit them.
     * @dev Ban enforcement ends when `disable()` opens the protocol — this error is only
     * reachable while `disabled()` is false.
     */
    error WhitelistUserBanned(address user);

    // ============ View Functions ============

    /**
     * @notice Get the version of the whitelist contract.
     */
    function version() external pure returns (string memory);

    /**
     * @notice Whether the whitelist gate has been permanently disabled. Once true,
     * `isWhitelisted()` returns true for every address (bans no longer gate entry).
     */
    function disabled() external view returns (bool);

    /**
     * @notice Whether `_signer` is currently an authorized invite signer.
     */
    function isSigner(address _signer) external view returns (bool);

    /**
     * @notice Whether `_inviteId` has already been consumed.
     */
    function isInviteUsed(bytes32 _inviteId) external view returns (bool);

    /**
     * @notice Whether `_user` has been banned via `removeFromWhitelist`.
     * @dev The flag is sticky in storage for introspection, but it only gates entry and
     * voucher redemption while `disabled()` is false. After `disable()`, bans are ignored
     * by `isWhitelisted` / `whitelist` even if this still returns true.
     */
    function isBanned(address _user) external view returns (bool);

    /**
     * @notice Whether `_user` is currently whitelisted.
     * @dev Returns true for everyone once `disabled()` is true (bans are ignored — the gate
     * being open means the protocol is open). While the gate is active, returns false for
     * banned addresses, otherwise checks local whitelist state only. A redeployed Whitelist
     * starts empty — migrate with `addToWhitelist` or open with `disable()`.
     */
    function isWhitelisted(address _user) external view returns (bool);

    // ============ User Functions ============

    /**
     * @notice Redeem a server-signed invite voucher to whitelist `_user`.
     *
     * Requirements:
     * - None if `_user` is already whitelisted or the gate is disabled (no-op, invite is
     *   left unconsumed — including after `disable()`, so `AMM.enterWithInvite` stays safe)
     * - `_inviteId` must not have been used before
     * - `block.timestamp` must not exceed `_deadline`
     * - `_signature` must recover to an authorized signer over the EIP-712 struct
     *   `Invite(address user, bytes32 inviteId, uint256 deadline)`
     * @dev Permissionless so a relayer can sponsor the gas of a user's first transaction.
     * @param _user The address to whitelist (bound inside the signed voucher).
     * @param _inviteId Opaque server-generated invite identifier (not derived from the
     * human-facing invite code on-chain).
     * @param _deadline Unix timestamp after which the voucher is no longer valid.
     * @param _signature EIP-712 signature over the voucher, from an authorized signer.
     */
    function whitelist(address _user, bytes32 _inviteId, uint256 _deadline, bytes calldata _signature) external;

    // ============ Owner/Admin Functions ============

    /**
     * @notice Directly whitelist a batch of addresses without consuming an invite
     * (e.g. team, partners, integrators). Also clears any invite-period ban so a prior
     * `removeFromWhitelist` can be undone in the same call — `_banned` is checked before
     * `_whitelisted` in `isWhitelisted`, so admit without clearing the ban would be a no-op
     * for entry.
     *
     * Requirements:
     * - Caller has ADMIN_ROLE
     * - The gate is not disabled
     * - No address in `_users` is the zero address
     * @param _users Addresses to whitelist.
     */
    function addToWhitelist(address[] calldata _users) external;

    /**
     * @notice Ban `_user` for the remainder of the invite period. While the gate is still
     * active, `isWhitelisted` returns false and vouchers (including stale unconsumed ones)
     * cannot re-admit them.
     *
     * This is not a forever ban on protocol entry: once `disable()` opens the gate, bans
     * no longer block `isWhitelisted` / `enter` — only the invite-period exclusion is
     * "permanent."
     *
     * Requirements:
     * - Caller has ADMIN_ROLE
     * - The gate is not disabled (`disable()` already opened entry to everyone, so banning
     *   afterwards is meaningless and reverts with `WhitelistIsDisabled`)
     */
    function removeFromWhitelist(address _user) external;

    /**
     * @notice Authorize a new invite-signing key.
     *
     * Requirements:
     * - Caller has ADMIN_ROLE
     * - The gate is not disabled (invite signing is meaningless once entry is open)
     * - `_signer` is not the zero address
     * - `_signer` is not already authorized
     */
    function addSigner(address _signer) external;

    /**
     * @notice Revoke an invite-signing key. Instant (no timelock delay) so a leaked key
     * can be cut off immediately.
     *
     * Requirements:
     * - Caller has ADMIN_ROLE or SECURITY_ROLE
     * - The gate is not disabled (signer management is meaningless once entry is open)
     * - `_signer` is currently authorized
     */
    function removeSigner(address _signer) external;

    /**
     * @notice Permanently disable the whitelist gate. Irreversible.
     * @dev After this, `isWhitelisted` returns true for every address — including any that
     * were banned during the invite period. Ban flags may remain visible via `isBanned`
     * but no longer gate entry.
     *
     * Requirements:
     * - Caller has ADMIN_ROLE
     * - The gate is not already disabled
     */
    function disable() external;
}
