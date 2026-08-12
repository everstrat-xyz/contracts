# Plamen P1 — zero-state-return

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope/read: full 39 files; skill 158/158 (no references); rules 193/193; bundle 139/207/181/9,417/101 lines

## FINDING ZSR-1 — First depositor captures almost all pre-bootstrap residual backing

file: `src/contracts/AMM.sol`
function: `_bootstrap`
mechanism: Bootstrap mints supply solely from the incoming deposit's USD value and never accounts for existing ETH/strategy/supported-token NAV, even though all of that residual is included immediately after bootstrap.
consequence: The first whitelisted depositor receives all shares except the fixed 1-EVE dead supply and can redeem approximately 99.9% or more of any third-party/protocol assets sent before launch.
trigger: first whitelisted depositor after any pre-bootstrap residual reaches AMM, Controller, StrategyManager, or a registered strategy
severity: medium
rationale: Residual capture is permissionless once whitelisted and can be nearly total, but it requires pre-launch assets not supplied by the attacker and is limited by deployment ceremony.
poc: none — worked calculation/code trace
evidence: `AMM.sol:103-108`, `Controller.sol:57`, and StrategyManager/UniCL `receive()` accept ETH before bootstrap. `AMM.sol:432-449` uses only `msg.value → depositUSD`, mints `depositUSD-1e18` to the user and one EVE dead, then sets bootstrapped. `StrategyManager._totalNAVInETH:940-950` subsequently counts every residual. At the $1,000 minimum, the user owns 999/1,000 of supply and captures 99.9% of residual NAV.
fix: Require total pre-deposit NAV to be zero at bootstrap, sweep/assign residuals explicitly, or size initial supply/locked shares from the complete pre/post-deposit NAV.
related: none
verdict: PARTIAL
step_execution: ✓1, ✓2a, ✓2b, ✓2c, ✓2d, ✓3, ✓4, ✓5, ✓5b, ✓6
rules_applied: R4:✓, R5:✓, R6:✗(permissionless first depositor), R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(self-donation is unprofitable), R16:✓
preferred_tag: CODE-TRACE
material_harm: The owner of pre-launch residual assets loses nearly all of that value to the first depositor's redeemable EVE claim.
missing_precondition: nonzero third-party/protocol residual NAV exists before the first deposit
precondition_type: BALANCE / STATE
why_this_blocks: With zero residual, the fixed dead supply merely charges the intended bootstrap cost; an attacker's own donation is not profitable because it shares the loss to dead supply.
postconditions: First user owns `(depositUSD-1 EVE)/depositUSD` of a supply backed by both its deposit and the unpriced residual.
postcondition_types: STATE, BALANCE
who_benefits: first whitelisted depositor

## FINDING ZSR-2 — Collected fee counters survive strategy depletion and charge future backing

file: `src/contracts/strategies/UniCLStrat.sol`
function: `withdraw`, `_removeLiquidityAndCollect`, `_unchargedLpFeeAmounts`
mechanism: StrategyManager harvests before withdrawal, but `settlePerformanceFee` does not poke; withdrawal then pokes/accrues previously unmaterialized LP fees, collects them, and may pay them out as principal while cumulative earned-minus-charged counters persist after the strategy assets approach/return to zero.
consequence: A later depositor/remaining holder can be diluted by a performance-fee mint calculated on historical fee tokens that former holders already withdrew, or harvesting can remain reverted until new NAV exceeds the stale fee claim.
trigger: unpoked fee growth at withdrawal (or fee rate zero), substantial strategy depletion, then later deposit and fee harvest/rate activation
severity: medium
rationale: The cross-epoch charge transfers value between cohorts and can block harvest; magnitude is bounded by historical uncharged LP fees and configured fee BPS.
poc: none — state trace
evidence: `StrategyManager.sol:1151-1164` calls harvest before strategy withdrawal. `UniCLStrat.sol:389-403` states settlement “does not poke”; withdrawal at `325` calls `_removeLiquidityAndCollect`, whose `758-769` pokes, accrues and collects. `_unchargedLpFeeAmounts:891-906` preserves cumulative earned-minus-charged even after `tokensOwed`/assets fall to zero. Future `_mintPerformanceFeeEVE` charges that ETH-equivalent against then-current NAV.
fix: Poke/accrue and settle atomically before any liquidity collection/withdrawal, and reset/checkpoint fee counters when collected fee assets leave the strategy or NAV returns to zero.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2a, ✓2b, ✓2c, ✓2d, ✓3, ✓4, ✓5, ✓5b, ✓6
rules_applied: R4:✗(closed trace), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(cohort transfer undocumented), R14:✓, R15:✗(keeper/user exit state), R16:✓
preferred_tag: CODE-TRACE
material_harm: New or remaining EVE holders surrender backing to the treasury for LP fees already consumed by prior withdrawals, and harvest can be unavailable until enough new NAV arrives.
postconditions: Fee assets leave or shrink while `_cumulativeLpFeesEarned - _cumulativeLpFeesCharged` remains positive across the depleted/renewed strategy epoch.
postcondition_types: STATE, BALANCE, TIMING
who_benefits: earlier withdrawing holders first, then DAO treasury at expense of later holders

## LEAD ZSR-L1 — A wiped-out but bootstrapped pool cannot recapitalize through normal entry

file: `src/contracts/AMM.sol`
function: `_enter`
suspicion: Dead supply makes `totalSupply` permanently nonzero after bootstrap. If total NAV reaches zero or rounds price to zero, `_premiumPriceFromNAV` returns zero and `convertAssetsInverse(msg.value,0)` reverts; the incoming deposit is deliberately excluded, so normal entry cannot restart the pool.
blocked_by: Requires total asset wipe or sufficiently tiny NAV, and anyone can restore positive pricing with an out-of-band direct ETH donation; material operational policy is unknown.
next_step: Define insolvency/recapitalization behavior and test the minimum donation required across worst-case supply/connector weight; add an explicit guarded recapitalization/reset path if recovery is intended.

## CLEARED

area: EVE total-supply return to zero
checked: Bootstrap permanently mints 1e18 EVE to `0x...dEaD`; only role-gated AMM/StrategyManager burns can burn their own/approved balances, so the dead balance cannot be burned in ordinary operation. `bootstrapped` therefore cannot coexist with `totalSupply==0` on the intended role graph, and first-depositor logic cannot recur.

## CLEARED

area: Pending claims and queued requests at the supply floor
checked: Escrowed queued EVE remains in total supply until processing; processed EVE is burned before a matching `claimableBalances`/`lockedForClaims` liability is created; locked claim ETH is excluded from free NAV and claim remains callable while paused. Unpriced or expired requests can return recorded EVE through cancellation, so no pending obligation becomes ownerless at the living-user exit boundary.

## CLEARED

area: First-call/default state initialization
checked: AMM initializes nonzero connector/minimum and branches explicitly on `bootstrapped`; ExitQueue initializes batch 1/createdAt; executor `lastSyncAt` and dust thresholds are initialized; zero Forwarder makes executors inert; zero reserve/exit target/sync interval/cooldown/weights/fee rate have explicit disable/exclude semantics; UniCL invalid zero ticks are guarded by `initTicks/_positionIsValid`; zero Oracle/signers/strategies fail closed until deployment configuration.

## Zero-state matrix

| State | Can reach? | Persistent state/assets | Result |
|---|---|---|---|
| EVE supply 0 pre-bootstrap | yes | possible unsolicited NAV | ZSR-1 residual capture |
| EVE supply 0 post-bootstrap | no intended path | 1 EVE dead supply | initial branch cannot recur |
| Strategy NAV/liquidity ~0 | yes | fee earned/charged counters, withdrawal timestamp, ticks | ZSR-2 cross-epoch fee risk |
| Protocol NAV/price 0 with dead supply | loss state | bootstrapped=true, supply>0 | ZSR-L1 entry division by zero |
| Empty strategy set | yes via ADMIN | Controller/AMM assets remain | NAV/entry/exit work; batch deposit/harvest explicitly reverts |
| Empty queue/current batch | normal | createdAt/currentBatchId persist | next request/pricing works |

## Commands/results

- Base-only `git show 734df96:PATH | nl -ba | sed -n ...` traced AMM bootstrap/pricing, Math zero denominators, EVE burn authority, StrategyManager fee/withdraw ordering, UniCL accrue/collect/counters, ExitQueue initialization and keeper defaults.
- Tests: not run; no test-tree read. ZSR-1 is conditional on residual balance; ZSR-L1 is deliberately a lead pending insolvency-policy/materiality validation.

AGENT_STATUS: COMPLETE
