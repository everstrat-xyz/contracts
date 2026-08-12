# QuillShield Q2 — signature-replay-analysis

base_sha: 734df96a1391e95dd40843210997da0b9f3ab05e
scope: immutable 39-file Solidity/deployment scope
mode: fresh source-only review; no network, live systems, post-base source, tests/audit, or prior review output
result: 0 FINDING; 2 LEAD; 9 CLEARED

## Confidence

Confidence is high for the on-chain signature mechanism: the complete scope contains one application-level verifier, `Whitelist.whitelist`, and its caller/state lifecycle was traced against the base SHA and the exact pinned OpenZeppelin EIP712/ECDSA implementation. Confidence is medium for signer operations because the server/KMS, invite database, signer types, and deployed signer set were not supplied.

## FINDING

None. No same-chain, cross-chain, cross-contract, skipped-nonce, expired-signature, malleability, or zero-recovery path produced an unauthorized admission under the supplied source boundary.

## LEAD 1

LEAD
file:         src/contracts/Whitelist.sol
function:     addSigner / whitelist
suspicion:    `addSigner` accepts any nonzero address, but `whitelist` only uses EOA recovery; registering a Safe or other ERC-1271 contract signer would succeed while every voucher from it remains unverifiable.
blocked_by:   Project comments describe a server/KMS signing key and no deployed signer manifest was supplied, so contract-wallet signer support may be intentionally out of scope.
next_step:    Confirm the supported signer type; if EOA-only, reject code-bearing signer addresses and document it, otherwise verify with `SignatureChecker.isValidSignatureNow`/ERC-1271.

## LEAD 2

LEAD
file:         src/contracts/Whitelist.sol
function:     whitelist
suspicion:    Replay safety and liveness rely on the off-chain service assigning globally unique opaque `inviteId` values and bounded deadlines; duplicate IDs across users/signers cause first-use invalidation, while unnecessarily long deadlines extend exposure of leaked vouchers.
blocked_by:   Signer service, KMS policy, invite storage/schema, issuance rules, and monitoring were not supplied; the contract correctly enforces the exact ID and deadline the authorized signer commits to.
next_step:    Audit the signer service for cryptographically random globally unique IDs, atomic reservation/issuance, maximum voucher lifetime, key rotation/revocation, and prevention of raw invite-code leakage.

## CLEARED 1

CLEARED
area:         Signature-surface inventory
checked:      Full-scope search found one application verifier: `Whitelist.whitelist`, reached directly or through `AMM.enterWithInvite`. EVE has no permit, and the keeper, timelock, Registry, Converter, Oracle, strategy, and deployment transaction-signing paths do not verify user-supplied application signatures.

## CLEARED 2

CLEARED
area:         EIP-712 domain separation
checked:      Whitelist is static and constructs the meaningful domain `EverStratWhitelist` / `1`. Pinned OpenZeppelin EIP712 includes `block.chainid` and `address(this)`, caches only for the original chain/address, and rebuilds the separator if either context changes.

## CLEARED 3

CLEARED
area:         Typed voucher encoding
checked:      `INVITE_TYPEHASH` exactly matches `Invite(address user,bytes32 inviteId,uint256 deadline)`, and the struct hash uses `abi.encode` in the same field order before `_hashTypedDataV4`; no dynamic packed-encoding collision surface exists.

## CLEARED 4

CLEARED
area:         Same-chain replay and nonce consumption
checked:      `inviteId` is a global unordered nonce checked before verification and marked used before granting membership. There is no external call between verification and consumption/grant, and the transaction is atomic, so neither reentrancy nor a second submission can obtain another privilege.

## CLEARED 5

CLEARED
area:         Deadline enforcement
checked:      Deadline is included in the signed struct and redemption reverts when `block.timestamp > deadline`; validity at exactly the signed deadline is consistent. Removed signers and banned users also invalidate otherwise unexpired vouchers at execution time.

## CLEARED 6

CLEARED
area:         ECDSA recovery edge cases
checked:      The exact pinned OpenZeppelin `ECDSA.recover(bytes)` rejects malformed length, high-s malleable signatures, invalid v through failed recovery, and address(0); Whitelist then requires the recovered address to be currently authorized.

## CLEARED 7

CLEARED
area:         User/action binding and relaying
checked:      The voucher binds the admitted `_user`, and `AMM.enterWithInvite` supplies `msg.sender`, so a copied signature cannot admit or fund the copier. Permissionless direct relay can only whitelist the signed user, which is the documented sponsored-gas behavior.

## CLEARED 8

CLEARED
area:         Front-running, rollback, and idempotent replay
checked:      A relayer racing the user's entry merely admits the same user; the later call benignly no-ops and entry proceeds. If `_enter` reverts, Whitelist state rolls back with the outer transaction. Replaying after admission has no additional effect, and replay after a ban reverts.

## CLEARED 9

CLEARED
area:         Signer and deployment lifecycle
checked:      Signer removal immediately invalidates outstanding vouchers from that key, security may revoke without the admin delay, and redeploying Whitelist changes `verifyingContract`, preventing old-domain voucher reuse. Whitelist is non-upgradeable, so no in-place version/domain drift exists.

## Coverage

- Five replay types: same-chain, cross-chain/fork context, cross-contract/redeployment, unordered nonce/ID reuse, and delayed/expired execution.
- Domain checklist: name, version, chain ID, verifying contract, fork-aware cache invalidation, EIP-191/EIP-712 hashing, exact type hash, field order, and `abi.encode`.
- Recovery checklist: malformed signatures, zero recovery, lower-s, v handling, EOA versus ERC-1271 signer, and current signer authorization.
- State checklist: ID consumption order/atomicity, no external call before consumption, signer add/remove/re-add implications, bans, disabled gate, already-admitted early return, and deadline boundary.
- Caller checklist: direct permissionless relay, AMM `msg.sender` binding, mempool front-running, outer-call rollback, and absence of relayer-controlled target/value semantics.
- Permit/meta checklist: no ERC-2612, Permit2, allowance-by-signature, arbitrary-call meta-transaction, multisig aggregation, or account-abstraction verifier exists in primary scope; these items are not applicable.
- Deployment scripts' `vm.startBroadcast` uses normal transaction signing and introduces no contract-side reusable application authorization.

## Reads and commands

- Methodology: `SKILL.md` 331/331; `references/eip712-checklist.md` 204/204; `references/replay-taxonomy.md` 221/221 (756/756 total).
- Allowed bundle, freshly read: `scope.md` 139/139; `profile.md` 207/207; `context.md` 181/181; `finding-format.md` 101/101; `source.md` 9,417/9,417 (10,045/10,045 total).
- Base validation: `git grep -n -E 'ecrecover|ECDSA|EIP712|_hashTypedDataV4|TYPEHASH|signature|permit\\(|Permit2|isValidSignature|nonce|DOMAIN_SEPARATOR|startBroadcast' 734df96... -- src script` — completed; runtime hits reduced to Whitelist plus its AMM/interface surface.
- Base validation: numbered `git show 734df96...` slices for `src/contracts/Whitelist.sol`, `src/contracts/AMM.sol`, and `src/interfaces/IWhitelist.sol` — completed.
- Dependency pin validation: base tree resolves OZ Upgradeable `60b305...` and nested OZ Contracts `e4f702...`; numbered `git show e4f702...` slices of `EIP712.sol` and `ECDSA.sol` confirmed dynamic chain/address domain binding and strict recovery.
- Tests: none written or run; no source-level replay candidate survived reasoning, and the two leads require missing signer-service/deployment policy rather than a local regression.

AGENT_STATUS: COMPLETE
