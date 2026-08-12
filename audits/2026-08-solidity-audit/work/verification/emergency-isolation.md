# UniCL emergency-path isolation verification

Scope: immutable commit `734df96a1391e95dd40843210997da0b9f3ab05e`. I read only base source/interfaces/docs/tests, excluding prior audit work and audit tests. Regression: `test/audit/candidates/verification/EmergencyIsolation.t.sol`.

## A — failed allowance revocation rolls back the pause

**Verdict: CONFIRMED. Suggested severity: Medium.**

### Exact transition

`pause()` calls `_pauseStrategy()` (`UniCLStrat.sol:460-462`). That helper:

1. writes the paused state with `_pause()`;
2. wraps only the pool unwind in a best-effort self-call; and
3. directly calls `_removeConverterAllowances()` afterward (`:633-645`).

Allowance removal calls `forceApprove(converter, 0)` on both pool tokens without a catch (`:1274-1277`). If either token rejects the zero approval, the entire transaction reverts, including the earlier Pausable state write and any successful first-token revocation.

The regression deploys with a paired token that initially permits the constructor's max approval, then rejects zero-value approvals. `pause()` reverts, `paused()` remains false, and both WETH and paired-token allowances remain at `type(uint256).max`. Once approval resumes, the same security caller pauses successfully and both allowances become zero.

### Intended semantics / assumptions

The source says the circuit breaker is engaged first and that a degraded pool cannot block it, but explicitly assumes the configured assets' `approve()` cannot revert (`UniCLStrat.sol:623-631`). Base tests establish that pool failures are caught and the pause/allowance revocation still succeeds (`UniCLStrat.t.sol:1086-1119`); they do not exercise token approval failure.

The behavior is therefore confirmed, while exploitability depends on allowing a paired token whose approvals can later fail. ERC-20 does not guarantee nonreverting `approve`, and upgradeable/paused tokens make that assumption operationally fragile.

### Impact and recovery

`emergencyExit()` requires `paused() == true` (`UniCLStrat.sol:494-496`), so this failure blocks both the circuit breaker and that recovery route. A persistent token failure has no strategy-local bypass. Recovery is to wait for/fix the token and retry; when ordinary pool/token paths still work, StrategyManager can attempt normal withdrawals. Force-removing the strategy restores protocol NAV liveness but does not recover assets held by it. Because an external asset failure can strand unrelated capital precisely during an incident, Medium is appropriate despite privileged asset configuration being required.

### Remediation

Make allowance revocation best-effort and incapable of reverting `_pause()`. Prefer independent, parameterless-catch self-calls per token, emit which revocation failed, and keep the paused state. The operator can then pause the Converter or retry revocation later. Do not bind unbounded revert data on this emergency path.

## B — paired-token `balanceOf` blocks the prior WETH/native sweep

**Verdict: CONFIRMED. Suggested severity: Medium.**

### Exact transition

Although the function documentation says native ETH is swept first and paired transfer failure must not roll it back (`UniCLStrat.sol:472-483`), implementation order is:

1. read WETH balance;
2. read paired-token balance;
3. unwrap WETH;
4. send all native ETH; and
5. best-effort transfer paired tokens (`:497-515`).

Only step 5 is tolerant. A revert at paired `balanceOf` occurs before either unrelated-asset recovery step.

The regression first pauses successfully, then places 2 ETH and 3 WETH on the strategy. A toggled paired-token `balanceOf` revert makes `emergencyExit()` revert with all 5 ETH-equivalent assets still on the strategy and no StrategyManager balance increase. Restoring the query and retrying transfers the full 5 ETH.

Base tests intentionally prove that reverting/false-returning paired **transfers** do not hostage the ETH sweep (`UniCLStrat.t.sol:1182-1218, 1250-1277`), reinforcing that failure isolation is intended. They do not cover the earlier balance query. The freeze runbook likewise states WETH is unwrapped and native ETH sent first (`docs/FREEZE_RUNBOOK.md:312-323`), which does not match call ordering for a failing query.

### Impact and recovery

A paired-token implementation that becomes broken or malicious can prevent recovery of otherwise healthy WETH/native ETH. If `balanceOf` remains broken, retrying cannot help; force-removal only stops NAV consultation and does not extract the assets from this static/nonupgradeable strategy. This capital-recovery failure supports Medium severity. It requires prior privileged configuration of the paired token and a nonstandard/degraded balance query.

### Remediation

Complete WETH unwrap and native transfer before touching the paired token. Then isolate the entire paired-token leg—including `balanceOf` and transfer—in a parameterless-catch self-call (or bounded low-level calls), emit a skip event on any failure, and continue LP-fee reset/event processing. This preserves retryability without letting paired-token returndata grief the ETH sweep.

## Test evidence

Attempt 1 of maximum 3:

```text
FOUNDRY_OUT=out-audit-emergency-isolation-verification \
FOUNDRY_CACHE_PATH=cache-audit-emergency-isolation-verification \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/EmergencyIsolation.t.sol -vvv
```

Result: `2 passed; 0 failed; 0 skipped`.

- `test_A_ZeroApprovalFailureRollsBackPauseState` — PASS
- `test_B_PairedBalanceFailureBlocksWethAndNativeSweep` — PASS

The post-suite signature-cache warning was sandbox-only and did not affect compilation or execution.

AGENT_STATUS: COMPLETE
