# Plamen P1 — economic-design-audit

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope/read: full 39 files; skill 97/97 (no references); rules 193/193; bundle 139/207/181/9,417/101 lines

## FINDING ED-1 — Cancellable demand can force repeated strategy withdrawals

file: `src/contracts/automation/StrategyKeeperExecutor.sol`
function: `_pendingRedemptionNeedsETH`
mechanism: Current unpriced requests are included in `needsETH` and trigger WithdrawShortfall even though their owners can immediately delete them and recover all EVE.
consequence: A holder can externalize repeated withdrawal/redeposit pool fees, slippage, cooldown, and Automation cost to the protocol without committing to redeem.
trigger: token holder; honest executors/Forwarders
severity: medium
rationale: Permissionless, repeatable economic grief can erode NAV over time; rate is bounded by keeper cadence, strategy liquidity, and per-cycle market cost.
poc: none — code trace
evidence: `StrategyKeeperExecutor.sol:494-512` adds `currentBatchId.totalTokensToBurn` at base price; lines 174-181 withdraw the shortfall. `ExitQueue.sol:253-266,279-296` deletes any unpriced request without fee. Trace: queue → upkeep withdraws → cancel → redeposit excess → repeat.
fix: Fund only priced/committed requests, or introduce a commitment/cancellation charge before current-batch demand may drive external strategy actions.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓3, ✓4, ✗5(no emissions/rebase)
rules_applied: R4:✗(closed trace), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan profit prerequisite), R16:✓
preferred_tag: CODE-TRACE
material_harm: All EVE holders absorb strategy trading costs and delayed operations while the griefing holder recovers its complete EVE principal.
postconditions: Controller holds withdrawn ETH for a vanished liability and the withdrawn strategy may enter cooldown.
postcondition_types: STATE, BALANCE, TIMING
who_benefits: griefing holder / traders around forced swaps

## FINDING ED-2 — Fee-rate changes apply retroactively to all uncharged LP fees

file: `src/contracts/StrategyManager.sol`
function: `setPerformanceFeeBps`
mechanism: The setter updates `performanceFeeBps` without first settling accrued fees; the next strategy settlement multiplies the new rate by the entire historical uncharged LP-fee base.
consequence: Governance can raise the rate from 0/low to as much as 20% and transfer that percentage of previously earned, unharvested LP fees from EVE holders to the treasury.
trigger: ADMIN timelock changes the rate, then ADMIN/keeper harvests or withdraws
severity: low
rationale: The affected fee base can be material, but the action is capped at 20%, privileged, and exposed by a 48-hour timelock.
poc: none — algebra/code trace
evidence: `StrategyManager.sol:673-675,825-829` overwrites the rate only. `UniCLStrat.sol:382-409` computes `unchargedLpFees * currentBps / 10_000`; charged counters advance only at settlement (`413-414`). Example: 100 ETH of old uncharged fees accrued at 0%; changing to 2,000 bps makes the next fee 20 ETH-equivalent.
fix: Settle every registered strategy at the old rate before changing it, or checkpoint fee growth and apply each rate only to growth after its effective timestamp.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓3, ✓4, ✗5(no emissions/rebase)
rules_applied: R4:✗(closed trace), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(not documented as retroactive), R14:✓, R15:✗(admin setter), R16:✓
preferred_tag: CODE-TRACE
material_harm: EVE holders can lose up to 20% of LP fees accumulated before a fee increase, even though those fees accrued under the former rate.
postconditions: Historical uncharged token amounts become chargeable under the new rate until the next settlement.
postcondition_types: STATE, TIMING, BALANCE
who_benefits: configured DAO treasury

## FINDING ED-3 — Emergency asset relocation can discontinuously understate share backing

file: `src/contracts/strategies/UniCLStrat.sol`
function: `emergencyExit`
mechanism: Paired tokens leave a counted registered strategy and arrive at StrategyManager, which counts only separately allowlisted ERC-20s; strategy registration does not require that allowlist and deployment calls it optional.
consequence: Emergency handling can lower reported NAV without losing custody, letting a new depositor mint against an artificially small denominator and dilute incumbents.
trigger: ADMIN/SECURITY emergencyExit with nonzero paired tokens, missing support entry, and live AMM
severity: medium
rationale: The discontinuity can equal a large fraction of NAV under an explicitly allowed configuration; likelihood depends on unknown deployment configuration/emergency sequencing.
poc: none — code trace
evidence: `UniCLStrat.sol:494-515` transfers paired inventory; `StrategyManager.sol:940-968` counts only `_supportedERC20s`; `DeployUniCLStrat.s.sol:41-46` calls `addSupportedERC20` optional.
fix: Enforce recovery-token support in `addStrategy`, or carry a quarantined NAV asset record and pause minting until accounting is restored.
related: none
verdict: PARTIAL
step_execution: ✓1, ✓2, ✓3, ✓4, ✗5(no emissions/rebase)
rules_applied: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(privileged trigger), R16:✓
preferred_tag: CODE-TRACE
material_harm: Incumbent holders can be diluted while valuable paired-token backing remains in protocol custody but outside NAV.
missing_precondition: paired token omitted from StrategyManager support in the target deployment
precondition_type: STATE
why_this_blocks: A pre-supported token remains counted; deployment state was not supplied.
postconditions: Reported NAV falls by the transferred paired-token value until ADMIN adds support.
postcondition_types: STATE, BALANCE, ACCESS
who_benefits: depositor entering during undervaluation

## LEAD ED-L1 — Zero minimum queued exit permits cheap Sybil queue growth

file: `src/contracts/AMM.sol`
function: `setMinBatchExitETH`
suspicion: The allowed minimum is zero (`_setMinBatchExitETH` enforces only the 0.05 ETH upper bound), so a timelocked configuration can let many addresses enqueue economically tiny nonzero requests and exhaust the 20-user default processing cadence.
blocked_by: Requires ADMIN misconfiguration and a gas/cost/backlog experiment to calibrate practical materiality.
next_step: Base-only fuzz queue sizes and keeper gas/cadence at `minBatchExitETH=0`; enforce a nonzero lower bound if backlog is cheap.

## CLEARED

area: Performance-fee arithmetic and dilution
checked: For a 1 ETH fee base, 100/500/1,000 bps produce exactly 0.01/0.05/0.1 ETH before floor rounding. Minting `fee*supply/(NAV-fee)` gives the treasury a post-mint NAV claim equal to the fee; batched pro-rata EVE attribution assigns the final rounding remainder to the last strategy and preserves the total.

## CLEARED

area: Weight interaction and allocation conservation
checked: Deposit and withdrawal weights are independently 0..100 but are normalized by the eligible cumulative weight, so sums above/below 100 do not amplify the requested amount. Per-strategy caps and floor division make total allocation no greater than the input; leftovers return/stay at Controller.

## Economic coverage

- Boundary substitutions: connectorWeight `1..1e18` (near-confiscatory entry premium to parity); minBatchExit `0..0.05 ETH`; performanceFee `0..2,000 bps`; strategy weights `0..100`; cooldown `0..1 day`; maxTotalNAV `0..uint256`; swap slippage `1..200 bps`; queue age `1..7 days`; user cap `1..100`; keeper reserves/targets/thresholds `0/unbounded` as allowed.
- Invariants: NAV backing vs EVE supply; claim locks excluded after burn; deposit pending ETH excluded before mint; queued escrow remains in supply; requested allocations conserve amount; fee mint preserves post-mint claim.
- Interactions: connectorWeight×NAV/supply; supported-token set×Oracle×emergency transfer; weights×health/cap/cooldown; current batch×Controller reserve; rate×uncharged fee counters.
- Fee bases traced forward through settlement, aggregation, mint, and per-strategy attribution. No separate emissions, reward emission, or rebase mechanism exists.

## Commands/results

- Base-only `git show 734df96:PATH | nl -ba | sed -n ...` confirmed every cited boundary/formula/state path.
- `awk` concrete fee evaluation for `1e18` at 100/500/1,000 bps → `1e16/5e16/1e17`.
- Tests: not run; no test tree read. ED-3 deployment predicate remains explicitly PARTIAL.

AGENT_STATUS: COMPLETE
