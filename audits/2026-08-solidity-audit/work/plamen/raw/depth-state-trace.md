# Plamen P4 — Depth State Trace

Target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`

## FINDING

id:           DS-1
file:         src/contracts/strategies/UniCLStrat.sol
function:     navInETH / sync / _amountsForPosition
title:        LP fee growth is priced into EVE only after a poke, creating stale-NAV entry and exit windows
mechanism:    `navInETH()` values position liquidity plus stored `tokensOwed`, while fee growth since the last pool update is explicitly invisible until `sync()` or remove/collect calls `burn(...,0)`; AMM entry, immediate exit, and batch pricing consume that stale NAV without first syncing strategies.
consequence:  A holder redeeming before the poke burns too much EVE and forfeits their share of already-earned LP fees to remaining holders; at connector weight `1e18` (an accepted configuration), a whitelisted account can enter at the understated base price immediately before a poke and capture a pro-rata share of fees earned before its deposit.
material_harm: Existing EVE holders can lose accrued yield to later entrants or remaining holders solely because they transact on different sides of an externally timed state-materialization event.
trigger:      any whitelisted entrant, EVE holder, or keeper action while Uniswap fee growth is unpoked
severity:     medium
rationale:    The impact is direct share-value redistribution and the window recurs between pokes; magnitude depends on pool volume and sync cadence, but neither a privileged misconfiguration nor malicious external contract is required for pre-sync redeemer loss.
confidence:   high — the source states that unpoked growth is invisible, and the full AMM→StrategyManager→UniCL NAV trace contains no pre-price poke.
verdict:      CONFIRMED
step_execution: ✓1(exploitable when fees accrued before pricing), ✓2([CROSS-DOMAIN-DEP: external Uniswap fee materialization; economic connector weight]), ✗3(no prior-output inventory permitted), ✓4([CODE]), ✓5, ✓6(natural accrual, keeper timing, normal user sequence)
rules_applied: R4:✓, R5:✓(all positions/strategies), R6:✓(keeper timing), R8:✓(stored external state), R10:✓(connectorWeight=1e18 and material fee interval), R11:✗(not donation), R12:✓, R13:✓, R14:✓, R15:✗(passive path suffices), R16:✓(valuation oracle still cannot see unpoked units), R17:✓
depth_evidence: [TRACE:pool fee growth→positions.tokensOwed unchanged→navInETH understated→AMM burns/mints at stale price→sync burn(0)→tokensOwed/NAV increase], [VARIATION:connectorWeight 5e17→1e18 removes entry premium], [BOUNDARY:fees=0→no delta; fees>0→redeemer forfeiture]
evidence:     UniCL `navInETH()` consumes `_balances()` (lines 199-203); `_amountsForPosition` adds only liquidity amounts and `_owed0/_owed1` returned by `pool.positions` (lines 859-872); the contract states “Unpoked fee growth is invisible until sync() or a remove/collect poke” (lines 375-380), and `sync()` materializes it through `_pokePositions()` (lines 362-372). AMM uses NAV directly for exit (AMM lines 151-160) and entry (lines 408-412).
poc:          none — base-SHA state/data-flow trace
fix:          Make NAV include live fee growth, or synchronously poke every registered strategy before any EVE mint/burn/batch-price snapshot; the latter needs bounded, failure-safe orchestration.
related:      none

### State graph for DS-1

`pool feeGrowth` → written by swaps; read/realized by `burn(0)` → `tokensOwed` → read by `_amountsForPosition` → `UniCLStrat.navInETH` → summed by `StrategyManager._totalNAVInETH` → read by AMM enter/exit and Controller batch pricing.

## FINDING

id:           DS-2
file:         src/contracts/StrategyManager.sol
function:     removeSupportedERC20
title:        Emergency token removal changes EVE NAV while user pricing remains live
mechanism:    ADMIN_ROLE or immediate SECURITY_ROLE can remove a nonzero token from `_supportedERC20s`, instantly excluding its entire held balance from `totalNAVInETH`; the transition neither pauses AMM pricing nor records a quarantined value/liability.
consequence:  Users who redeem after removal burn more EVE for the same ETH and permanently forfeit their claim on the excluded asset; if ADMIN later restores the token, remaining holders—and any entrant whose premium was below the omitted NAV fraction—receive the restored value.
material_harm: EVE holders can be underpaid or diluted during an emergency feed/token response even though the omitted ERC-20 remains held by the protocol.
trigger:      ADMIN_ROLE or SECURITY_ROLE removes a supported token with nonzero StrategyManager balance while AMM remains unpaused
severity:     medium
rationale:    Role-triggered and intended for emergencies, but a single immediate state change can reprice all user mint/burn operations and redistribute a material token balance; no invariant forces the role to pause first.
confidence:   high — direct storage-to-NAV-to-AMM trace; only the deployment balance/configuration determines magnitude.
verdict:      CONFIRMED
step_execution: ✓1(exploitable with nonzero balance and live AMM), ✓2([CROSS-DOMAIN-DEP: access-control operational sequencing; oracle failure]), ✗3(no prior-output inventory permitted), ✓4([CODE]), ✓5, ✓6(paths: emergency role, admin, natural emergency token receipt)
rules_applied: R4:✓, R5:✓(all holders), R6:✓(security role vs users), R8:✓(stored allowlist), R10:✓(material supported-token share), R11:✓, R12:✓, R13:✓(intentional circuit breaker still harms users), R14:✓, R15:✗(role gated), R16:✓, R17:✓
depth_evidence: [TRACE:remove set member→held balance unchanged→supportedERC20 NAV term becomes zero→AMM base/premium price drops], [BOUNDARY:balance=0→no pricing change; balance>0→NAV decreases by oracle value]
evidence:     The source explicitly says on-chain recovery is deferred (lines 465-468) and removal of a nonzero balance “drops that value out of NAV immediately” (lines 491-501). `_totalNAVInETH` adds only `_supportedERC20sNAVInETH` (lines 940-950), which iterates current set members (lines 961-969). AMM user functions remain independently gated only by AMM pause.
poc:          none — base-SHA state trace
fix:          Require AMM pricing to be paused before removing a nonzero token and preserve the balance as a quarantined NAV/liability until it is recovered or governance explicitly socializes the loss.
related:      DS-1

## LEAD

id:           DS-L1
file:         src/contracts/automation/StrategyKeeperExecutor.sol
function:     performUpkeep (Sync)
suspicion:    `lastSyncAt` advances before `Controller.syncStrategies`; the manager catches per-strategy failures, so an all-failed batch still returns success and suppresses automatic retry for the configured interval while DS-1 stale NAV persists.
blocked_by:   Needs a regression with one/all strategy `sync()` calls reverting to quantify the extra stale window and confirm emitted failure observability is not paired with an off-chain retry policy.
next_step:    Mock all strategies reverting on sync and assert `lastSyncAt` plus next `checkUpkeep` behavior.

## CLEARED

area:         ExitQueue request aggregate mutation
checked:      `pushRequest` adds exactly one user/request and increments `totalTokensToBurn`; both `pullRequest` and `closeRequest` remove the user and decrement the same request amount atomically, with membership/processed guards preventing a second decrement.

## CLEARED

area:         Strategy deposit/withdraw cooldown lifecycle
checked:      Successful withdrawals alone timestamp `lastStrategyWithdrawal`; failed calls do not, deposits consult the same mapping, and remove/re-add deliberately retains the timestamp, so the cooldown cannot be cleared by registration churn.

## COVERAGE AND EXECUTION

- Instruction coverage: shared Plamen rules/format, depth-state-trace, and EVM generic rules read fully; cache set-cover was N/A (no node-client bounded cache target), and identity/replay specialization was N/A.
- Full-scope state work: traced EVE supply/NAV, supported-token membership, strategy membership/weights/cooldown, queue totals/membership, LP fee earned/charged/snapshot fields, claim liabilities, and keeper timestamps across all 39 files.
- Fresh bundle read: 10,045/10,045 lines (`source.md` 9,417/9,417).
- Commands/results: bounded `sed`; base-only `git show 734df96:{src/contracts/StrategyManager.sol,src/contracts/AMM.sol,src/contracts/strategies/UniCLStrat.sol}` plus `git grep` confirmed cited functions/lines. No network, live system, production edit, prior-output read, or test execution.

AGENT_STATUS: COMPLETE
