# StrategyManager batch failure-isolation verification

Scope: immutable commit `734df96a1391e95dd40843210997da0b9f3ab05e`. I read only base source/interfaces/tests, excluding prior audit outputs and audit tests. Regression: `test/audit/candidates/verification/StrategyBatchIsolation.t.sol`.

## A — unguarded preflight views abort whole batches

**Verdict: CONFIRMED. Suggested severity: Low.**

### Reachable paths

- Deposit preflight calls every strategy's `maxDeposit()` directly, then conditionally calls `isHealthy()` directly (`StrategyManager.sol:989-1014`). Only the later mutating `deposit()` is in `try/catch` (`:1021-1033`).
- Withdrawal preflight directly calls every `maxWithdrawal()` before any withdrawal action (`:1080-1103`). Only the later `withdraw()` is caught (`:1123-1141`).
- Rebalance directly calls `paused()` and `isHealthy()`; only `rebalance()` is caught (`:1177-1186`).
- Sync directly calls `paused()`; only `sync()` is caught (`:1211-1220`).

Any preflight revert therefore bubbles out of StrategyManager and reverts the full transaction. No healthy peer is serviced; if a healthy peer was processed before a later bad view, its effects are rolled back.

The regression registers one bad and one healthy strategy and separately proves:

1. reverting `maxDeposit()` aborts deposit allocation with zero healthy deposits;
2. reverting `isHealthy()` does the same;
3. reverting `maxWithdrawal()` aborts withdrawal with the healthy strategy still fully funded;
4. reverting `paused()` aborts both rebalance and sync with zero healthy calls; and
5. reverting `isHealthy()` aborts rebalance with zero healthy calls.

### Intended semantics and impact

The interface describes deposit, withdrawal, rebalance, and sync batches as best-effort and says the loop continues when the corresponding **action** reverts (`IStrategyManager.sol:321-358, 374-405, 418-460`). Base tests cover action reverts and healthy-peer continuation, e.g. `StrategyManager.t.sol:1375-1474, 1589-1606`; they do not cover preflight failures. Thus the implementation satisfies only narrower action-call isolation, while the candidate's preflight gap is real.

Impact is batch-operation liveness, including withdrawal sourcing, rather than direct asset loss. Exploitation requires an already admin-registered strategy to break or maliciously revert a view. Range and single-strategy Controller/StrategyManager overloads can exclude the bad strategy, and admin can force-remove it; these operational fallbacks and privileged admission support Low severity. Severity could rise if production automation cannot select a healthy range quickly enough to meet redemption liveness requirements.

### Remediation

Wrap each external preflight read independently and skip/report the failing strategy. Treat default values as ineligible (`max = 0`, paused/unhealthy), not as healthy. Ensure the failure-reporting implementation also bounds returndata as discussed in B.

## B — unbounded caught revert data defeats failure isolation

**Verdict: CONFIRMED. Suggested severity: Low.**

StrategyManager binds full revert data with `catch (bytes memory reason)` and emits it in five batch paths:

- performance-fee settlement (`StrategyManager.sol:740-753`);
- deposit (`:1021-1033`);
- withdrawal (`:1123-1141`);
- rebalance (`:1177-1186`); and
- sync (`:1211-1220`).

An external callee controls returndata length. Binding dynamic `bytes` requires copying that returndata into caller memory; emitting the full dynamic value adds further memory/log cost. A sufficiently large revert therefore consumes the manager's remaining gas before the catch body can finish, reverting the entire batch despite the nominal catch.

### Regression result

With a fixed 30,000,000-gas envelope:

- a registered strategy reverting from `sync()` with 4 bytes is caught, and the healthy peer's `sync()` executes;
- changing only the revert size to 3,000,000 bytes makes `syncStrategies()` return failure from gas exhaustion; the healthy peer is not serviced and its prior call count remains unchanged.

The test function consumed 29,643,761 gas, consistent with exhaustion of the bounded manager call. This is not merely an ordinary action revert: the compact revert succeeds under the identical envelope and path.

### Reachability, impact, and limits

A malicious or compromised registered strategy can return the payload directly, or a strategy can propagate oversized returndata from a downstream integration. It can block full-range keeper batches and roll back healthy-peer work. It cannot register itself, steal funds through this behavior, or permanently prevent operators from using range/single-strategy calls that omit it. Admin force-removal is also available. These prerequisites/fallbacks support Low severity despite the explicit best-effort guarantee being bypassed.

Gas limits vary by deployment chain; 30m is a concrete reproducible envelope, not a claim about every chain's current block limit. Because returndata size is attacker-controlled, simply increasing the transaction gas limit is not a robust fix.

### Remediation

Use a low-level call helper that copies at most a small fixed prefix of returndata (or no returndata), and emit a bounded prefix/hash plus a failure selector/status. Apply the same cap to newly caught preflight calls. A per-strategy call gas stipend can further contain execution, but does not by itself make unbounded returndata copying safe.

## Test evidence

Attempt 1 of maximum 3:

```text
FOUNDRY_OUT=out-audit-strategy-batch-verification \
FOUNDRY_CACHE_PATH=cache-audit-strategy-batch-verification \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/StrategyBatchIsolation.t.sol -vvv
```

Result: `4 passed; 0 failed; 0 skipped`.

- `test_A_DepositPreflightViewsAbortBeforeHealthyPeer` — PASS
- `test_A_WithdrawalMaxViewAbortsBeforeHealthyPeer` — PASS
- `test_A_PausedAndHealthViewsAbortRebalanceAndSyncBatches` — PASS
- `test_B_OversizedCaughtReasonExhaustsBatchGasAndRollsBackPeer` — PASS

The post-suite signature-cache warning was sandbox-only and did not affect compilation or execution.

AGENT_STATUS: COMPLETE
