# FinalizeProtocolDeploy can finalize without a Whitelist registration

Verdict: **CONFIRMED**

Severity: **Low — deployment-safety / complete new-entry availability loss**

Base: `734df96a1391e95dd40843210997da0b9f3ab05e`

## Claim

The modular finalizer can successfully renounce the deployer's temporary Registry `ADMIN_ROLE` while `Auth.WHITELIST` is unregistered. Both AMM deposit entry points then revert during Registry peer resolution, and only the admin TimelockController can repair the registration after its configured minimum delay.

## Exact base evidence

1. `script/ProtocolDeployBase.sol:488-512` resolves `CONTROLLER`, `EXIT_QUEUE`, `ORACLE`, `EVE`, `AMM`, `STRATEGY_MANAGER`, `CONVERTER`, and both keeper keys. It never resolves `Auth.WHITELIST`.
2. `script/FinalizeProtocolDeploy.s.sol:40-47` broadcasts `_finalizeDeployerTieredAccess` first, stops broadcasting, and only then calls `_verifyDeployerTieredAccess` and `_verifyCriticalRoleGrants`.
3. `ProtocolDeployBase.sol:418-421` makes the deployer renounce its bootstrap role whenever it still holds it. `:469-472` accepts the resulting state when the configured timelock remains admin.
4. `AMM.sol:115-132` gates both `enter` and `enterWithInvite` through Whitelist calls. `_isWhitelisted` at `:388-390` resolves `_registry.whitelist()`, so a missing key bubbles `RegistryContractNotRegistered(Auth.WHITELIST)` before deposit processing.
5. `Registry.sol:109-110` restricts `registerContract` to `ADMIN_ROLE` and `whenNotPaused`. After finalization the deployment EOA no longer has that role.
6. `script/ProtocolDeployBase.sol:36-39,352-378` gives the production admin timelock a default 48-hour minimum delay; an explicitly configured `TIMELOCK_ADMIN_DELAY` can be longer.
7. `script/DeployWhitelist.s.sol:35-48` demonstrates the omitted modular step: deploy Whitelist, register `Auth.WHITELIST`, then optionally seed a signer.
8. `mermaid/deployment-architecture.md:210-216` says finalization verifies every module registration and catches skipped modular steps, so this omission violates the documented fail-closed purpose.

## Reachability

- A modular operator skips `DeployWhitelist` (or broadcasts its deployment but fails before Registry registration).
- All keys and roles actually checked by `_verifyCriticalRoleGrants` are correctly configured.
- `FinalizeProtocolDeploy` broadcasts the deployer renunciation. Its subsequent verifier passes because Whitelist is absent from the predicate.
- The timelock remains the sole Registry admin. Calls to both AMM entry functions fail at Whitelist key resolution.
- `exit`, redemption cancellation, and claim do not consult Whitelist, so existing users' exit paths are not disabled by this defect alone.

No attacker privilege or race is required; this is an operator-omission guard failure. Following the documented modular sequence avoids the state, but the finalizer expressly exists to detect skipped steps.

## Regression test

Added:

`test/audit/candidates/verification/FinalizeWhitelist.t.sol`

The isolated test uses:

- the exact production `_verifyCriticalRoleGrants`, `_verifyDeployerTieredAccess`, and `_finalizeDeployerTieredAccess` helpers through a harness;
- the base Registry and AMM;
- a real OpenZeppelin `TimelockController` with a 48-hour minimum delay;
- every key and role checked by the finalizer, deliberately omitting only `WHITELIST`.

It proves:

1. finalization and all current checks succeed, while the bootstrap admin is lost;
2. `enter` and `enterWithInvite` both revert with `RegistryContractNotRegistered(WHITELIST)`;
3. the former bootstrap admin cannot register the missing key;
4. premature timelock execution fails;
5. delayed timelock registration succeeds, after which AMM entry reaches normal Whitelist policy (`AMMNotWhitelisted`) instead of missing-peer failure.

Command (detached base worktree, pinned Foundry 1.0.0, offline, isolated artifacts):

```sh
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/FinalizeWhitelist.t.sol \
  --skip AMM.t.sol --skip Controller.t.sol \
  --out out-audit-verify-finalize-whitelist \
  --cache-path cache-audit-verify-finalize-whitelist -vvv
```

Result: **2 passed, 0 failed, 0 skipped**.

The two `--skip` filters avoid unrelated immutable-base tests whose legacy `@openzeppelin/contracts-upgradeable/` import alias is absent from the base Foundry remappings. The candidate test and its imports compile and run from the detached commit. Local dependency checkouts were verified byte-for-commit against all three base gitlinks; no network data was used.

## Severity reasoning

Low is appropriate because:

- impact is complete loss of new deposits for at least the governance delay;
- the condition arises only from an incorrect modular deployment sequence, not an unprivileged attack;
- there is no direct asset theft or accounting corruption;
- existing exit/cancel/claim paths remain available; and
- governance can recover, although not immediately.

Severity could become operationally more serious if launch commitments require immediate entry availability or the configured timelock delay is substantially longer than 48 hours.

## Exact recovery

1. If the original Whitelist was deployed but not registered, verify its bytecode, immutable Registry, signer state, and address. Otherwise anyone may deploy a fresh Whitelist bound to the correct Registry.
2. The DAO proposer schedules a TimelockController operation calling:
   `Registry.registerContract(Auth.WHITELIST, whitelistAddress)`.
3. For a fresh empty Whitelist, batch or separately schedule the intended `addSigner`, `addToWhitelist`, or irreversible `disable` policy action. Registration alone restores peer resolution but does not admit users to an empty gate.
4. Wait `adminTimelock.getMinDelay()` (48 hours under the default policy), then any authorized/open executor executes the operation.
5. If Registry is paused, the same timelock recovery must unpause it before registration because `registerContract` is `whenNotPaused`.

## Recommended fix

- Add `_registry.getContractByKey(Auth.WHITELIST)` to `_verifyCriticalRoleGrants`.
- More importantly, run all module/role preflight checks **before** `vm.startBroadcast` and before `_finalizeDeployerTieredAccess`. A check added only at the current post-broadcast location detects the defect after the renunciation transaction is already irreversible.
- Retain post-finalization checks as end-state assertions, and add a regression that omits each required key one at a time.

AGENT_STATUS: COMPLETE
