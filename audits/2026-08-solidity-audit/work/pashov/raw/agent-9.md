# Reviewer 9 — boundary and external-call correctness

Scope was read completely, in bundle order. Review and validation used local files only.

## Material reasoning markers

[Feynman: UniCLStrat._pauseStrategy] This path marks the strategy stopped, tries to bring pool assets back, and then removes the Converter's permission to spend both pool tokens. If any mandatory step fails, the whole attempt is undone, including the stopped state.

[Socratic: src/contracts/strategies/UniCLStrat.sol:644 — why?] Why is removing token permission allowed to be mandatory when the comment's only justification is that both configured tokens are assumed never to reject an approval?

[Inversion: UniCLStrat._pauseStrategy] (1) make `pairedToken.approve(converter, 0)` revert; (2) make the pool unwind revert with large data; (3) remove the Converter registry entry so resolving its address reverts. Move (1) rolls back the pause; move (2) is contained by the parameterless catch; move (3) also rolls back the pause.

[Feynman: UniCLStrat.emergencyExit] Once stopped, the strategy measures its wrapped and paired-token inventory, unwraps wrapped ETH, sends all native ETH to StrategyManager, and only then attempts the paired-token transfer. The stated goal is that a bad paired token cannot stop the ETH recovery.

[Socratic: src/contracts/strategies/UniCLStrat.sol:498 — why?] Why is the paired token queried before the ETH sweep when a failed paired-token transfer is deliberately treated as non-fatal?

[Inversion: UniCLStrat.emergencyExit] (1) make the paired token's `balanceOf(strategy)` revert; (2) make its transfer return false; (3) make StrategyManager reject native ETH. Move (1) prevents even pre-existing native ETH from moving; move (2) is correctly contained; move (3) deliberately fails the strict destination transfer.

[Feynman: StrategyManager._withdrawFromStrategies] This path first asks every selected strategy how much can be withdrawn, calculates allocations, and then asks each funded strategy to pay the Controller. It promises that failure of one strategy will not stop recovery from the others.

[Socratic: src/contracts/StrategyManager.sol:1095 — why?] Why is `maxWithdrawal()` outside the per-strategy failure boundary when it is an external part of deciding whether that same strategy can be used?

[Inversion: StrategyManager._withdrawFromStrategies] (1) first strategy reverts from `maxWithdrawal()`; (2) first strategy reports capacity but reverts from `withdraw()`; (3) first strategy returns zero capacity. Move (1) aborts the entire batch, move (2) is contained, and move (3) is skipped as intended.

## Confirmed defects

FINDING | contract: UniCLStrat | function: pause / _pauseStrategy | bug_class: emergency-pause-blocked-by-token-approval | group_key: UniCLStrat | pause | emergency-pause-blocked-by-token-approval
boundary: `_removeConverterAllowances()` calls `token0.forceApprove(converter, 0)` and `token1.forceApprove(converter, 0)` after setting the paused state.
assumption: WETH and the configured paired token are standard assets whose `approve()` cannot revert.
actual: a paused, blacklisting, or otherwise degraded paired token can revert approval; `forceApprove` cannot turn a reverting zero-approval into success, so transaction atomicity rolls back `_pause()` too.
path: SECURITY/ADMIN calls `pause()` -> `_pause()` writes paused=true -> pool unwind is attempted -> paired-token approval reverts -> entire transaction rolls back -> paused remains false -> `emergencyExit()` remains unreachable because it requires pause.
proof: local regression mocks only `pairedToken.approve(converter, 0)` to revert. `pause()` reverts and `strategy.paused()` remains false. `test_RevertingPairedApproveRollsBackEmergencyPause` passes.
expected: engaging the circuit breaker remains possible when any external pool/token integration is degraded.
actual_result: a single configured token's approval behavior can veto the circuit breaker and the emergency recovery prerequisite.
consequence: assets remain in an active strategy during precisely the token failure/blacklist incident that may require immediate shutdown; recovery needs the token to resume or new code/configuration.
fix: make allowance revocation best-effort after the local pause, using a parameterless-catch self-call (and an explicit failure event), so token revert data cannot roll back the circuit breaker.

FINDING | contract: UniCLStrat | function: emergencyExit | bug_class: paired-balance-read-blocks-eth-recovery | group_key: UniCLStrat | emergencyExit | paired-balance-read-blocks-eth-recovery
boundary: `pairedToken.balanceOf(address(this))` is an unguarded external call made before WETH unwrap and native-ETH transfer.
assumption: paired-token transfer failure is non-fatal and therefore cannot roll back or prevent the ETH-first emergency sweep.
actual: a token that reverts its balance query aborts before any ETH action; the later `trySafeTransfer` protection is never reached.
path: strategy is paused and holds native/WETH -> SECURITY/ADMIN calls `emergencyExit()` -> WETH balance read succeeds -> paired balance read reverts -> transaction ends -> no unwrap and no native transfer to StrategyManager.
proof: with a paused strategy holding exactly 2 ETH, local regression makes only `pairedToken.balanceOf(strategy)` revert. `emergencyExit()` reverts, StrategyManager receives 0, and the strategy retains 2 ETH. `test_RevertingPairedBalanceReadBlocksNativeEthEmergencySweep` passes.
expected: native ETH/WETH is recovered even while every interaction with the paired token is failing.
actual_result: the paired token can hostage unrelated native and wrapped ETH before the documented best-effort boundary.
consequence: emergency liquidity recovery is unavailable during a paired-token outage despite immediately transferable ETH inventory.
fix: unwrap and sweep ETH before touching the paired token, then put both the paired balance query and transfer in one parameterless-catch, only-self best-effort helper.

FINDING | contract: StrategyManager | function: _depositToStrategies / _withdrawFromStrategies / _checkAndRebalanceStrategies / _syncStrategies | bug_class: unguarded-preflight-defeats-batch-isolation | group_key: StrategyManager | batch strategy actions | unguarded-preflight-defeats-batch-isolation
boundary: per-strategy external probes (`maxDeposit`, `isHealthy`, `maxWithdrawal`, and `paused`) execute outside the `try/catch` that protects the corresponding batch action.
assumption: the documented best-effort batch paths isolate a degraded strategy and continue operating on healthy strategies.
actual: a probe revert bubbles out of the entire batch before the protected action is reached.
path: register `S_bad` then `S_good`, each with withdrawal weight 50 and 5 ETH capacity -> `S_bad.maxWithdrawal()` starts reverting while `S_good` remains healthy -> Controller requests a 10 ETH all-strategy withdrawal -> first planning-loop call reverts -> `S_good.withdraw()` is never called -> Controller receives 0.
proof: the first loop at `_withdrawFromStrategies` directly evaluates `strategy.maxWithdrawal()` before allocations and before the later guarded `withdraw`; identical pre-guard calls exist in the other listed batch loops. A direct or carefully ranged call can work around the failed member, but the default all-strategy automation cannot.
expected: failed strategy contributes zero/gets skipped while remaining strategies are processed.
actual_result: one failed read aborts every strategy in the requested range.
consequence: default keeper deposits, liquidity withdrawals, rebalances, or syncs can stall until operators identify/exclude or governance removes the failing strategy; queued-exit funding can be delayed even when healthy strategies hold sufficient ETH.
fix: include each strategy's probes in its per-member failure boundary (prefer a bounded/parameterless catch) and treat probe failure as ineligible while continuing the loop.

## Leads

LEAD | contract: StrategyManager | function: batch try/catch sites | bug_class: revert-returndata-memory-grief | group_key: StrategyManager | batch catch reason | revert-returndata-memory-grief
code_smells: all best-effort batch action catches bind and emit unbounded `bytes memory reason`, while UniCLStrat explicitly uses parameterless catches to avoid returndata bombs.
description: a strategy capable of returning very large revert data may exhaust the caller while Solidity copies/allocates `reason`, defeating batch isolation; exact compiler-generated copy behavior and a gas-calibrated local proof were not completed, so this remains a LEAD.

## Local regression

- File: `test/audit/candidates/pashov/Agent09.t.sol`
- Command: `FOUNDRY_OUT=out-pashov-agent-09 FOUNDRY_CACHE_PATH=cache-pashov-agent-09 forge test --match-path test/audit/candidates/pashov/Agent09.t.sol`
- Result: 2 passed, 0 failed, 0 skipped. No fork or network used.

## Specific cleared areas

- `ProtocolDeployBase._requireUnregistered`: a registered-key success enters the success body and its deliberate revert propagates; it is not swallowed by the catch for the external call.
- Converter swap dispatch: disallowed adapters are rejected, a code-less formerly allowed adapter cannot satisfy the exact 32-byte return requirement, routes are validated before token pull, and output/input deltas are measured rather than trusting adapter-reported amounts.
- Converter WETH zero/value branches: zero wrap is a no-op; nonzero wrap consumes exactly `msg.value`; nonzero unwrap validates the receiver and reverts atomically if native delivery fails.
- AMM payable accounting: entry value is sourced solely from `msg.value`; queued redemption processing checks `msg.value >= owed` and returns excess to Controller; no separate caller-controlled native `amount` can diverge from payment.
- Whitelist signatures: empty/malformed signatures fail validation, expired invites fail, the deadline boundary is intentionally inclusive, and invite IDs are consumed before completion under an atomic call.
- Uniswap path bytes: empty, short, overlong/multihop, and malformed-length paths are rejected for the single-hop adapter; forward exact-output paths are reversed before router use.
- Keeper `performData`: malformed or out-of-range enum encodings revert before action, and only the configured forwarder can supply it; no partial state is committed first.
- UniCLStrat normal withdrawal: zero receiver/amount are rejected, native delivery failure reverts atomically, and StrategyManager measures the Controller's actual received balance delta.

AGENT_STATUS: COMPLETE
