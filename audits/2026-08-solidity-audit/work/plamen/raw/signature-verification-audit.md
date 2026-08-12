# Plamen Raw Pass — signature-verification-audit

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full immutable primary scope, 39/39 files
methodology: Plamen signature-verification-audit; verifier enumeration plus checks 1-10 completed
read_counts: orchestrator-rules 79/79; finding-output-format 114/114; skill 289/289; direct required refs 0; scope 139/139; profile 207/207; context 181/181; source 9417/9417; bundle finding-format 101/101
constraints: base-only; no prior audit outputs/history/test-audit/post-base source; no network/live deployment
result: 0 FINDING, 1 LEAD, 8 CLEARED

VERIFIER_INVENTORY
- `Whitelist.whitelist(address,bytes32,uint256,bytes)`: the only protocol signature verifier; authorizes `Invite(user,inviteId,deadline)` under EIP-712 domain `EverStratWhitelist` / `1`.
- `AMM.enterWithInvite`: consumer only; forces the signed `user` to equal `msg.sender` before entering.
- Foundry `PRIVATE_KEY` reads are transaction-signing deployment inputs, not runtime authorization verifiers.
- No permit, meta-transaction, ERC-1271, raw `ecrecover`, aggregate/BLS, Merkle-signature, bridge-signature, or signature-derived identifier surface exists.

LEAD
id:           SIG-L1
file:         src/contracts/Whitelist.sol
function:     whitelist
suspicion:    On-chain verification assumes the external signer service protects its key, generates opaque collision-free `inviteId` values, selects appropriate deadlines, authenticates intended users, and avoids issuing conflicting vouchers; failure in that backend can authorize unintended admission or deny a valid voucher through ID collision.
blocked_by:   signer service, KMS policy, invite database/reservation logic, authentication, logs, and key-rotation runbook were not supplied.
next_step:    Review signer/KMS access policy and issuance code; test uniqueness/entropy and atomic reservation of `inviteId`, user binding, deadline caps, audit logs, compromise revocation, and signer rotation against the exact EIP-712 vectors.

CLEARED
area:         signature authenticity and encoding
checked:      `ECDSA.recover(_hashTypedDataV4(structHash), _signature)` must recover a currently authorized signer. OpenZeppelin ECDSA rejects malformed and high-s signatures, and `abi.encode` with a fixed typehash avoids packed-encoding ambiguity.

CLEARED
area:         signed-field completeness and function scope
checked:      `INVITE_TYPEHASH = keccak256("Invite(address user,bytes32 inviteId,uint256 deadline)")`; L134 encodes every authorization input. The project has one invite operation, so the typehash also supplies operation/function separation.

CLEARED
area:         domain, chain, contract, and redeployment separation
checked:      The static Whitelist constructor fixes EIP-712 name/version and OpenZeppelin EIP-712 binds the digest to current chain ID and verifying-contract address. A different chain, Whitelist address, or redeployment therefore cannot consume the same voucher digest.

CLEARED
area:         replay and one-time consumption
checked:      Global `_isInviteUsed[inviteId]` is checked before recovery and set before the whitelist effect/event. No external call occurs after verification, so the same invite cannot be reentered or consumed by a second unlisted user.

CLEARED
area:         relayer/front-running behavior
checked:      `whitelist` is permissionless, but the signature binds `_user`; a relayer/front-runner can only whitelist the intended user. If it races `enterWithInvite`, the victim's later whitelist call benignly returns because that same user is already admitted, then AMM entry proceeds.

CLEARED
area:         deadline semantics and signer revocation
checked:      L132 rejects only when `block.timestamp > deadline`, permitting use exactly at the signed deadline. L136 checks live signer membership, so `removeSigner` immediately invalidates all unredeemed vouchers from a compromised/retired signer.

CLEARED
area:         effect ordering and downstream asset flow
checked:      Used/whitelisted state is committed before the event and there are no calls in the verifier. `AMM.enterWithInvite` is non-reentrant and passes `msg.sender` as the signed user before executing the ordinary deposit flow.

CLEARED
area:         derived identifiers, aggregate signatures, and Merkle inclusion
checked:      Invite IDs are explicitly signed opaque inputs, not derived from recoverable signature bytes. The code has no aggregate threshold signature or Merkle proof path, making checks 9-10 N/A after full-scope enumeration.

CHECK_EXECUTION
1_validation: ✓ canonical EIP-712 digest + live signer authorization + OZ ECDSA recovery
2_replay: ✓ global invite-use mapping and effect order
3_scope: ✓ chain ID, verifying contract, name/version, typed operation and all action fields
4_offchain_approval: ? backend unavailable; emitted as SIG-L1
5_malleability: ✓ OpenZeppelin ECDSA; signature bytes are not used as an identifier
6_cross_chain_protocol_replay: ✓ domain separation; no second verifier/protocol domain in scope
7_deadlines: ✓ signed deadline and exact-boundary behavior
8_consumption_order: ✓ consumed before success, no external call window
9_derived_id: ✗ N/A; signer supplies and signs opaque ID
10_aggregate_merkle: ✗ N/A; absent
rules_applied: [R4:✓(off-chain uncertainty is a lead), R5:✗(single verifier), R6:✓(signer/admin/security rotation), R8:✓(used/signer state), R10:✓, R11:✗(verifier moves no tokens), R12:✓, R13:✗(no unsafe design normalization), R14:✗(no aggregate/limit setter), R15:✗(no balance precondition), R16:✗(no oracle dependency)]
confidence: high for on-chain clears — one verifier was exhaustively enumerated; medium for end-to-end invite security because the issuing backend is absent.

COMMANDS_AND_TESTS
- `git -C contracts grep -n -E 'EIP712|ECDSA|ecrecover|SignatureChecker|permit|INVITE_TYPEHASH|_signature|signature|nonces|nonce|MerkleProof|isValidSignature' 734df96 -- script src/contracts src/libraries` — one runtime verifier found.
- `git -C contracts show 734df96:src/contracts/Whitelist.sol | nl -ba | sed -n '20,145p;119,205p'` — traced domain, struct, replay, deadline, recovery, effects, and signer rotation.
- `git -C contracts show 734df96:src/contracts/AMM.sol | nl -ba | sed -n '112,137p'` — confirmed `msg.sender` binding and non-reentrant consumer.
- tests: not run; no unresolved in-scope code mechanism required a PoC.

AGENT_STATUS: COMPLETE
