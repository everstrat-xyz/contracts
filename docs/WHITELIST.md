# Whitelist — Entry Gate Overview & Integration Guide

Static invite gate for protocol **entry**. Grounded in `src/contracts/Whitelist.sol`,
`src/interfaces/IWhitelist.sol`, and the AMM wiring in `src/contracts/AMM.sol` at the
revision this file was committed with.

Related:

- Contract surface: `[README.md](../README.md)` (Whitelist + AMM sections)
- Architecture: `[mermaid/mermaid-smart-contracts.md](../../mermaid/mermaid-smart-contracts.md)`
- Deploy: `[DeployWhitelist.s.sol](../script/DeployWhitelist.s.sol)` /
`[DeployAll.s.sol](../script/DeployAll.s.sol)`

---

## 1. Overview

### 1.1 What it does

While the invite period is active, the AMM admits native-ETH deposits only from
addresses that pass `Whitelist.isWhitelisted(user)`:


| Path                                                            | Gate                                                           |
| --------------------------------------------------------------- | -------------------------------------------------------------- |
| `AMM.enter(minTokens)`                                          | Requires `isWhitelisted(msg.sender)`; else `AMMNotWhitelisted` |
| `AMM.enterWithInvite(minTokens, inviteId, deadline, signature)` | Redeems an EIP-712 voucher for `msg.sender`, then enters       |
| `AMM.exit(...)`                                                 | **Never** consults the Whitelist                               |


The gate is permanent until governance calls irreversible `disable()`, after which
`isWhitelisted` returns `true` for every address and entry is open.

### 1.2 Design principles

1. **On-chain gate, not UI.** Checking admission in the frontend is UX only —
  anyone can call the AMM directly. The AMM is the enforcement point.
2. **Entry-only.** Users can always leave (`exit` / cancel / claim), including
  banned addresses.
3. **Opaque invite ids.** `inviteId` is a server-chosen `bytes32`, never the
  human invite code and never a direct on-chain hash of it, so chain state does
   not leak the code space.
4. **Permissionless redeem.** `Whitelist.whitelist(...)` has no caller
  restriction — a relayer can sponsor gas. The voucher binds `_user`; the AMM
   always passes `msg.sender`.
5. **No previous-Whitelist fallback.** A redeployed Whitelist starts empty.
  Migrate admitted users via `addToWhitelist`, or open the protocol with
   `disable()`.
6. **Do not confuse with StrategyManager's supported-ERC-20 whitelist** — that
  is a separate NAV-accounting allowlist (`addSupportedERC20` /
   `removeSupportedERC20`).



### 1.3 Components

```
┌─────────────┐     EIP-712 voucher      ┌──────────────┐
│ Invite      │ ───────────────────────► │  Whitelist   │  Registry key: WHITELIST
│ backend /   │   (user, inviteId,       │  (static)    │
│ KMS signer  │    deadline, sig)        └──────┬───────┘
└─────────────┘                                 │ isWhitelisted / whitelist()
                                                ▼
                                         ┌──────────────┐
                                         │     AMM      │  enter / enterWithInvite
                                         └──────────────┘
```

- **Whitelist** — static (`RegistryClient` + OZ `EIP712`); roles resolved via Registry.
- **AMM** — resolves peers through `Auth.whitelist(registry)` at call time.
- **Invite signer** — EOA (or smart account that recovers as ECDSA) authorized via
`addSigner`; typically a KMS-held key on the invite backend.

---



## 2. On-chain model



### 2.1 EIP-712 domain and typehash


| Field             | Value                                                                 |
| ----------------- | --------------------------------------------------------------------- |
| Domain name       | `"EverStratWhitelist"`                                                |
| Domain version    | `"1"`                                                                 |
| Struct            | `Invite(address user, bytes32 inviteId, uint256 deadline)`            |
| `INVITE_TYPEHASH` | `keccak256("Invite(address user,bytes32 inviteId,uint256 deadline)")` |


Signing uses the standard EIP-712 typed-data hash (`_hashTypedDataV4`). Recovery
must land on an address with `_isSigner[signer] == true`.

### 2.2 Admission state (`isWhitelisted`)

Evaluation order:

1. If `disabled == true` → **true** for everyone (bans ignored for entry).
2. Else if `_banned[user]` → **false**.
3. Else → `_whitelisted[user]`.

`isBanned(user)` may still return `true` after `disable()`; it is retained for
introspection and no longer blocks entry.

### 2.3 Redeem path (`whitelist`)

```
whitelist(user, inviteId, deadline, signature)
├── isWhitelisted(user)? → return (no-op; invite left unconsumed)
├── banned(user)?        → revert WhitelistUserBanned
├── invite already used? → revert WhitelistInviteAlreadyUsed
├── timestamp > deadline?→ revert WhitelistSignatureExpired
├── recover(sig) not a signer? → revert WhitelistInvalidSignature
└── mark invite used, set _whitelisted[user], emit UserWhitelisted
```

The no-op when already whitelisted (including after `disable()`) is intentional:
`AMM.enterWithInvite` stays safe without an AMM-side `disabled` check, and
relayer / user races do not burn a voucher that was already redeemed.

### 2.4 Admin / security mutators


| Function                    | Role                                | Notes                                          |
| --------------------------- | ----------------------------------- | ---------------------------------------------- |
| `addToWhitelist(users[])`   | `ADMIN_ROLE`                        | Batch admit; clears any invite-period ban so re-admit actually restores `isWhitelisted` |
| `removeFromWhitelist(user)` | `ADMIN_ROLE`                        | Clears membership + sets ban for invite period (undo via `addToWhitelist`) |
| `addSigner(signer)`         | `ADMIN_ROLE`                        | Authorize invite-signing key                   |
| `removeSigner(signer)`      | `ADMIN_ROLE` **or** `SECURITY_ROLE` | Instant revoke of a leaked key                 |
| `disable()`                 | `ADMIN_ROLE`                        | Irreversible; opens entry to everyone          |


All of the above except `disable()`'s own "already disabled" check are gated by
`whenNotDisabled` and revert with `WhitelistIsDisabled` once the gate is open
(invite-period admin is then meaningless). `whitelist()` itself is **not**
`whenNotDisabled`-gated.

In production, `ADMIN_ROLE` is held by the 48h admin timelock; `SECURITY_ROLE`
by the security multisig with no delay. `removeSigner` is asymmetric on purpose:
leaked signer → unlimited admissions until cut off. Per-user bans stay ADMIN-only
(policy, not circuit breaker) — Security already has `pause()` on the AMM and
`removeSigner` for true emergencies.

### 2.5 Events and errors

**Events:** `UserWhitelisted`, `UserWhitelistedByAdmin`,
`UserRemovedFromWhitelist`, `SignerAdded`, `SignerRemoved`, `WhitelistDisabled`.

**Errors:** `WhitelistZeroAddress`, `WhitelistIsDisabled`,
`WhitelistInviteAlreadyUsed`, `WhitelistSignatureExpired`,
`WhitelistInvalidSignature`, `WhitelistSignerAlreadyAdded`,
`WhitelistSignerNotFound`, `WhitelistUserBanned`.

AMM entry error: `AMMNotWhitelisted(address user)`.

---



## 3. AMM integration



### 3.1 `enter`

```solidity
function enter(uint256 _minTokensToMint) external payable whenNotPaused nonReentrant {
    if (!_isWhitelisted(msg.sender)) revert AMMNotWhitelisted(msg.sender);
    _enter(_minTokensToMint);
}
```

Use when the wallet is already admitted (prior voucher redeem, admin batch, or
gate disabled). Frontend can call `Whitelist.isWhitelisted(wallet)` before
simulating the write.

### 3.2 `enterWithInvite`

```solidity
function enterWithInvite(
    uint256 _minTokensToMint,
    bytes32 _inviteId,
    uint256 _deadline,
    bytes calldata _signature
) external payable whenNotPaused nonReentrant {
    Whitelist(_registry.whitelist()).whitelist(msg.sender, _inviteId, _deadline, _signature);
    _enter(_minTokensToMint);
}
```

Atomic admit-then-mint for first-time invitees. The voucher's `user` field **must**
equal `msg.sender` (the AMM always passes `msg.sender` into `whitelist`). A
signature for Alice cannot admit Bob's mint.

After `disable()`, this path still succeeds: `whitelist` no-ops, then `_enter`
runs like a normal mint.

### 3.3 Relayer-sponsored admit (two txs)

Because `whitelist` is permissionless, a relayer can admit without minting:

1. Relayer (or user) calls `Whitelist.whitelist(user, inviteId, deadline, sig)`.
2. User later calls `AMM.enter(minTokens)` (already whitelisted).

Useful when the mint amount / ETH funding is not ready at redeem time. The
voucher is consumed on step 1; step 2 does not need the signature again.

### 3.4 Exit

No Whitelist reads. Banned or never-whitelisted holders can still burn, queue,
cancel, and claim.

---



## 4. Off-chain integration flow



### 4.1 Invite backend (signer)

The backend owns the human invite-code space. The chain only ever sees opaque
`inviteId`s and EIP-712 signatures. Treat the signing key (KMS) and any
`inviteId`-derivation secret with equal care.

#### 4.1.1 Recommended end-to-end flow

1. User authenticates to the API and presents a human invite code (or other
   eligibility proof), plus the wallet address that will call the AMM.
2. Backend validates the code against its store: exists, not fully redeemed
   on-chain, not reserved by someone else, rate limits / abuse checks.
3. Backend **reserves** the code for that wallet (see §4.1.2) before signing
   anything.
4. Backend looks up or creates the opaque `inviteId` for this issuance.
   - Prefer a random `bytes32` stored with the code / reservation, **or**
   - `inviteId = HMAC(serverSecret, code)` (or equivalent) — a leak of the
     secret lets an attacker grind the code space against on-chain
     `isInviteUsed` / `UserWhitelisted` events.
5. Backend sets `deadline = now + reservationTTL` (same clock the reservation
   uses), builds EIP-712 typed data for the deployment `chainId` + Whitelist
   `verifyingContract`, signs with the authorized KMS key, and returns
   `{ user, inviteId, deadline, signature }` to the client (or relayer).
6. On successful on-chain admit (`UserWhitelisted` / `isInviteUsed(inviteId)`),
   mark the code **redeemed** and never re-issue vouchers for it.
7. Prefer short TTL windows (minutes, not days) so stolen vouchers and
   abandoned reservations expire quickly.

**Do not** put the human invite code on-chain. **Do not** use
`keccak256(code)` alone as `inviteId` (the code space becomes grindable from
chain data).

#### 4.1.2 Invite-code reservation (match TTL to voucher `deadline`)

On-chain, a voucher is only checked at submission time (`deadline`,
`isInviteUsed`, signature). Two clients can both hold a valid-looking
signature for the **same** code if the backend signs twice. The second
submitter then pays gas and reverts with `WhitelistInviteAlreadyUsed` (same
`inviteId`) or succeeds as a second admission (if the backend minted a second
`inviteId` for the same code). Either way the UX is bad: someone discovers the
failure only after paying for the transaction.

Prevent that with an **exclusive reservation** in the backend store:

| Code state | Meaning |
|---|---|
| `available` | Not reserved, not redeemed; may be claimed |
| `reserved` | Locked to one `user` until `reservationExpiresAt` |
| `redeemed` | On-chain admit observed (or confirmed); terminal |
| `revoked` | Ops invalidated the code (optional) |

**Rules:**

1. **Reserve before sign.** Transition `available → reserved(user, expiresAt)`
   atomically (row lock / conditional update). Only the winner of that
   compare-and-swap receives a signature.
2. **Bind reservation to the wallet.** Store `reservedFor = user`. Do not hand
   Alice’s signature to Bob; the on-chain struct already binds `user`, and the
   AMM always passes `msg.sender`.
3. **Align clocks:** set
   `reservationExpiresAt == voucher.deadline` (or reservation slightly
   *shorter* than `deadline` if you want the API to refuse refreshes before the
   chain rejects). Never issue a voucher whose `deadline` outlives the
   reservation — otherwise a second party can be signed after you consider the
   code free while the first party’s sig is still valid on-chain.
4. **One outstanding voucher per code.** While `reserved`, reject other wallets
   with a clear API error (“code held by another wallet until `<timestamp>`”)
   *before* they build a mint tx.
5. **Release on expiry.** When `now > reservationExpiresAt` and the
   corresponding `inviteId` is still unused on-chain, move back to `available`
   (or allow the same user to renew). Then another person may reserve.
6. **Renewal.** If the same wallet asks again while still reserved and not
   expired, return the existing voucher **or** re-sign with the same
   `inviteId` / `user` and an extended `deadline` only if you also extend
   `reservationExpiresAt` in the same transaction of record. Prefer returning
   the existing voucher to avoid deadline skew.
7. **Confirm redeem off the reservation.** Index `UserWhitelisted` (or poll
   `isInviteUsed`) and flip to `redeemed`. Do not rely on the client claiming
   success.

```
Client A                         Backend                          Client B
   |                                |                                |
   |-- redeem(code, walletA) ------>|                                |
   |                                |-- lock code → reserved(A, T)   |
   |                                |-- sign Invite(A, id, T)        |
   |<-- {inviteId, T, sig} ---------|                                |
   |                                |                                |
   |                                |<-- redeem(code, walletB) ------|
   |                                |-- still reserved(A)? → 409     |
   |                                |-- no signature issued -------->|
   |                                |                                |
   |-- enterWithInvite (gas) ------>| chain                         |
   |   success / used inviteId      |-- mark redeemed                |
```

Without the reservation step, A and B can both leave the API with signatures;
whichever submits second wastes gas learning the code is gone or expired.

#### 4.1.3 `inviteId` lifetime vs reservation

- If the first reservation expires **without** an on-chain redeem, the
  `inviteId` remains unused. You may re-issue that same `inviteId` to the next
  reserver (new `user` + new `deadline` + new signature) or allocate a fresh
  `inviteId`. Both are valid on-chain; pick one policy and stick to it.
- Once `isInviteUsed(inviteId)` is true, never reuse that id.
- HMAC-from-code schemes imply a stable id per code — fine with exclusive
  reservation; do not sign two different `user`s for that id concurrently.

#### 4.1.4 What the backend should return on conflicts

| Situation | Suggested API behaviour |
|---|---|
| Code unknown / revoked | `404` / `410` — no voucher |
| Code reserved by another wallet, reservation live | `409` + `reservationExpiresAt` — no voucher |
| Code reserved by caller, still live | Return existing voucher (or renew per §4.1.2.6) |
| Code redeemed on-chain | `410` — tell client to use `AMM.enter` if `isWhitelisted` |
| Caller already `isWhitelisted` | Skip signing; client should `enter` only |
| Caller `isBanned` | Refuse to sign; on-chain redeem would revert anyway |

#### 4.1.5 Relayer note

If a relayer calls `Whitelist.whitelist(user, …)` separately from mint, the
backend reservation / redeem tracking should still key off the same
`inviteId` and `UserWhitelisted` — the gas payer is irrelevant; the admitted
address is `user`.

### 4.2 Client / frontend

**Already whitelisted**

1. `isWhitelisted(wallet)` → true (or `disabled()` → true).
2. Simulate / send `AMM.enter{value}(minTokensToMint)`.

**First mint with invite**

1. Request a voucher from the backend for `(code, wallet)`. Handle reservation
   conflicts (`409` held by another wallet, expired code, etc.) **before**
   prompting a wallet signature / gas spend.
2. Optionally simulate `enterWithInvite` (catches expiry / used invite without
   paying full mint gas on some RPCs; still not a substitute for reservation).
3. Send `AMM.enterWithInvite{value}(minTokens, inviteId, deadline, signature)`
   before `deadline`. If the reservation TTL is about to elapse, re-fetch a
   renewed voucher rather than submitting a near-expired one.

**Relayer path**

1. Relayer submits `Whitelist.whitelist(user, …)` using a voucher issued under
   the same reservation rules.
2. Wait for receipt / `UserWhitelisted`.
3. User submits `AMM.enter`.

Surface common reverts to the user:


| Revert                       | Likely cause                                 |
| ---------------------------- | -------------------------------------------- |
| `AMMNotWhitelisted`          | Called `enter` without admission             |
| `WhitelistSignatureExpired`  | Stale voucher — refresh from API             |
| `WhitelistInviteAlreadyUsed` | Code / id already redeemed                   |
| `WhitelistInvalidSignature`  | Wrong chain / contract / signer / typed data |
| `WhitelistUserBanned`        | Address banned for invite period             |




### 4.3 Signing checklist (EIP-712)

Integrators must match OZ `EIP712` exactly:

- `name` = `EverStratWhitelist`, `version` = `1`
- `chainId` = deployment chain
- `verifyingContract` = Whitelist address (Registry `WHITELIST` key)
- Primary type `Invite` with fields `user` (address), `inviteId` (bytes32),
`deadline` (uint256) in that order
- ECDSA signature in standard 65-byte `r ‖ s ‖ v` form recoverable by
`ECDSA.recover`

Mismatch on any domain field → `WhitelistInvalidSignature`.

### 4.4 Indexing / ops

Useful subscriptions:

- `UserWhitelisted(user, inviteId, timestamp)` — redeemations
- `UserWhitelistedByAdmin(user, timestamp)` — governance batch admits
- `UserRemovedFromWhitelist(user, timestamp)` — invite-period bans
- `SignerAdded` / `SignerRemoved` — rotate / incident on signing keys
- `WhitelistDisabled(timestamp)` — invite period ended permanently

Views for dashboards: `disabled()`, `isWhitelisted(user)`, `isBanned(user)`,
`isSigner(signer)`, `isInviteUsed(inviteId)`.

---



## 5. Deployment & lifecycle



### 5.1 Deploy


| Path              | Notes                                                                                                                |
| ----------------- | -------------------------------------------------------------------------------------------------------------------- |
| `DeployAll`       | Deploys Whitelist with the core stack, registers `Auth.WHITELIST`, seeds signer when `WHITELIST_SIGNER_ADDRESS != 0` |
| `DeployWhitelist` | Modular; requires `REGISTRY_ADDRESS` + `WHITELIST_SIGNER_ADDRESS`                                                    |


`WHITELIST_SIGNER_ADDRESS` is **required** env (`vm.envAddress`). Explicit
`address(0)` postpones seeding — add a signer later via timelocked `addSigner`.

Register `WHITELIST` before users mint; the AMM resolves it at entry time.

### 5.2 Invite period → open protocol

1. Operate with signers + optional `addToWhitelist` for partners.
2. Ban abuse via `removeFromWhitelist` (48h ADMIN path).
3. On incident (leaked signer): security calls `removeSigner` immediately;
  pause AMM if needed; rotate to a new signer via timelocked `addSigner`.
4. When ready for public entry: ADMIN schedules `disable()` → irreversible.



### 5.3 Redeploy / replace

Whitelist is static. Replacing it means:

1. Deploy a new Whitelist; register `WHITELIST` to the new address (ADMIN /
  timelock).
2. New contract starts **empty** — re-admit via `addToWhitelist` or call
  `disable()` if the invite period is over.
3. Update backend `verifyingContract` and re-issue vouchers (old signatures are
  invalid for the new domain separator).

---



## 6. Threat model (short)


| Threat                             | Mitigation                                                                                                            |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| UI-only gate bypass                | AMM enforces `isWhitelisted` / voucher redeem                                                                         |
| Invite code enumeration from chain | Opaque `inviteId`; never store raw codes on-chain                                                                     |
| Stolen voucher                     | Short `deadline`; one-time `inviteId`; bans block re-admit                                                            |
| Leaked signing key                 | `SECURITY_ROLE.removeSigner` (instant); rotate signer                                                                 |
| Relayer griefing unused invites    | Already-whitelisted no-op leaves invite unconsumed only when admit already succeeded; used invites cannot be replayed |
| Ban after `disable()`              | Bans ignored for entry once gate is open (by design)                                                                  |
| Blocking exits                     | Not possible via Whitelist — `exit` never checks it                                                                   |


---



## 7. Quick reference


| Item           | Location                                                    |
| -------------- | ----------------------------------------------------------- |
| Contract       | `src/contracts/Whitelist.sol`                               |
| Interface      | `src/interfaces/IWhitelist.sol`                             |
| Registry key   | `Auth.WHITELIST`                                            |
| AMM entry      | `enter`, `enterWithInvite`                                  |
| Unit tests     | `test/unit/Whitelist.t.sol`, `test/unit/AMMWhitelist.t.sol` |
| Trees          | `test/trees/Whitelist.tree`                                 |
| Deploy scripts | `script/DeployWhitelist.s.sol`, `script/DeployAll.s.sol`    |
| Env            | `WHITELIST_SIGNER_ADDRESS`                                  |


