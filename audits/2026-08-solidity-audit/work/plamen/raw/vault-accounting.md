# Plamen P4 — Vault Accounting

Target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`

## FINDING

id:           VA-1
file:         src/contracts/StrategyManager.sol
function:     emergencyWithdrawToController / _supportedERC20sNAVInETH
title:        ERC-20 emergency proceeds are included in NAV but have no realizable redemption path
mechanism:    UniCL emergency exit sends paired tokens to StrategyManager and the supported-token set prices them into total NAV, but StrategyManager implements only an ETH emergency sweep; it has no ERC-20 transfer, swap, approval, or recovery function. The source explicitly defers conversion of these “stranded supported ERC-20s.”
consequence:  EVE is priced as if the manager-held tokens back ETH redemptions, yet Controller cannot source ETH from them. Other ETH can pay early redeemers at the inflated price, while later redemptions queue or fail once liquid ETH is exhausted; removing the token instead crystallizes the repricing loss.
material_harm: EVE holders can be unable to redeem the portion of NAV represented by emergency paired-token proceeds, and redemption order determines which holders consume the remaining liquid ETH.
trigger:      ADMIN/SECURITY pauses UniCL and calls `emergencyExit` while it holds paired tokens; the paired token is supported for NAV
severity:     medium
rationale:    Emergency-state dependent but directly reachable in the intended workflow; impact is stranded protocol value and withdrawal insolvency at the token's full balance, meeting the stranded-asset severity floor.
confidence:   high — exhaustive base-SHA search finds accounting and removal only, while source explicitly says swap recovery is deferred.
verdict:      CONFIRMED
step_execution: ✓1, ✓2, ✗2(time-decay N/A), ✗2b(no time anchor), ✗2c(no overridden ERC4626 getter), ✗3(single fee type), ✓4, ✓5, ✓5b, ✓5c, ✓6
rules_applied: R4:✓, R5:✓(all EVE holders), R6:✓(security/admin emergency role), R8:✓(multi-step emergency→redemption), R9:✓, R10:✓(material paired-token balance), R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash precondition), R16:✓
depth_evidence: [TRACE:UniCL paired token→StrategyManager balance→supported-token NAV increases→AMM EVE price includes value→no SM ERC20 exit→ETH redemption shortfall], [BOUNDARY:pairedBalance=0→no issue; >0 unsupported→NAV omission; >0 supported→stranded counted NAV]
evidence:     UniCL says paired balances are transferred to StrategyManager and should be whitelisted so NAV counts them (UniCL lines 473-483, 494-515). StrategyManager states “On-chain swap recovery of stranded supported ERC-20s back to native ETH ... is deferred” (lines 465-468), its emergency function sends only `address(this).balance` ETH (lines 453-462), and its NAV loop values each supported balance (lines 961-968). Base-SHA `git grep` finds no token transfer/swap path in StrategyManager.
poc:          none — base-SHA asset-flow and exit-inventory trace
fix:          Add a pause-gated, role-controlled conversion/recovery path that routes each supported ERC-20 through the Converter with oracle/slippage bounds and sends realized ETH to Controller; exclude the asset from redeemable NAV until recovery is executable.
related:      none

## FINDING

id:           VA-2
file:         src/contracts/strategies/UniCLStrat.sol
function:     navInETH / sync / _amountsForPosition
title:        Share price excludes earned LP fees until state is poked
mechanism:    Vault NAV includes only position principal and materialized `tokensOwed`; the contract explicitly acknowledges that unpoked fee growth is invisible until `sync()` or remove/collect. EVE mint/burn and batch price snapshots do not require a preceding poke.
consequence:  Pre-poke redeemers burn shares at an understated value and relinquish accrued yield; when connector weight is `1e18`, a user entering immediately before the poke buys at the same understated base price and captures part of fees earned before entry.
material_harm: Vault yield is redistributed according to keeper/pool-update timing instead of share ownership during the period in which it was earned.
trigger:      normal fee accrual followed by user pricing before the next strategy poke
severity:     medium
rationale:    A recurring normal-operation accounting gap can transfer material yield; pool volume and time between pokes bound magnitude, while no privileged action is needed for redeemer harm.
confidence:   high — explicit source comment plus complete NAV/share-price trace.
verdict:      CONFIRMED
step_execution: ✓1, ✗2(no decay), ✗2b(N/A), ✓2c(reported vs economically held divergence), ✗3(single fee), ✓4, ✓5, ✓5b, ✓5c, ✓6
rules_applied: R4:✓, R5:✓, R6:✓(keeper timing), R8:✓, R10:✓, R11:✗(not donation), R12:✓, R13:✓, R14:✓, R15:✓(passive and ordered-entry paths considered), R16:✓
depth_evidence: [TRACE:feeGrowth accrues→tokensOwed unchanged→NAV/share price stale→user mint/burn→burn(0) materializes value], [VARIATION:connectorWeight=5e17 adds premium; 1e18 permits direct pre-poke capture]
evidence:     `navInETH` uses `_balances` (UniCL lines 199-203); `_amountsForPosition` adds only liquidity amounts and stored owed values (lines 859-872); lines 375-380 state unpoked growth is invisible; `sync` pokes at lines 370-372. AMM entry and exit read this NAV before mint/burn.
poc:          none — base-SHA state trace
fix:          Include live fee growth in NAV or enforce a bounded, failure-safe strategy synchronization before every share-price snapshot.
related:      VA-1

## LEAD

id:           VA-L1
file:         src/contracts/ExitQueue.sol
function:     priceBatch / Controller._processRequest
suspicion:    A batch caches EVE price and can process for up to 3 days without reserving assets at pricing time. NAV gains/losses between price and burn are therefore assigned entirely to remaining holders rather than queued holders, potentially creating loss-front-running or unfair underpayment.
blocked_by:   The intended moment at which a queued request becomes a fixed senior ETH claim is not specified clearly enough to distinguish defect from disclosed settlement design.
next_step:    Regression with a strategy loss and gain immediately after `priceBatch`, quantifying queued versus remaining holder value; confirm product disclosure.

## LEAD

id:           VA-L2
file:         src/contracts/automation/QueueKeeperExecutor.sol
function:     _affordableRequests
suspicion:    The affordable-prefix loop stops at the first unaffordable request, so an early large request can delay smaller same-batch requests even while newer batches are processed; EnumerableSet swap-and-pop also makes the effective order mutable after removals.
blocked_by:   No explicit per-user FIFO promise was found, and delay is capped by the 3-day escape hatch; deliberate first-position control and material harm need a focused regression.
next_step:    Construct a batch with large-first/small-later requests, partial Controller liquidity, and cancellation/removal permutations; compare behavior to documented queue fairness.

## CLEARED

area:         Initial and return-to-zero share state
checked:      Bootstrap requires `1000e18` USD value and burns `1e18` EVE to the dead address. Since that supply cannot be burned and `bootstrapped` never resets, total supply cannot return to zero; residual NAV remains priced against dead shares rather than being captured by a new first depositor.

## CLEARED

area:         Performance-fee dilution formula
checked:      For assets `A`, supply `S`, and fee `F<A`, minting `F*S/(A-F)` gives the treasury post-mint ownership value `F`; the code rejects `A<=F`, batches settlement atomically, and retains fee dust when the fee itself rounds to zero at strategy level.

## CLEARED

area:         Time-decay and cross-fee dependencies
checked:      No locked-profit/vesting/streaming decay or multiple interacting fee types exist. The sole performance fee is charged against cumulative uncharged LP fee units and paid by EVE dilution rather than asset extraction.

## SKILL CHECKLIST

- §1 share price adversity: complete (deposit, exit, fee materialization, loss, fee harvest).
- §2/2b time decay/anchor: N/A; no mechanism detected.
- §2c reported-vs-held divergence: complete; VA-2.
- §3 cross-fee ratio: N/A; one fee type.
- §4 first depositor/re-entry: complete and cleared.
- §5/5b/5c fee source, stress solvency, exchange-rate consistency: complete; dilution algebra cleared.
- §6 multi-step withdrawal fairness: complete; VA-L1/VA-L2.

## COVERAGE AND EXECUTION

- Instruction coverage: shared Plamen rules/format, vault-accounting, EVM generic rules, and zero-state-return read fully and applied to all 39 files.
- Fresh bundle read: 10,045/10,045 lines (`source.md` 9,417/9,417).
- Commands/results: base-only `git show 734df96` and `git grep` confirmed the paired-token flow, absence of StrategyManager ERC-20 exits, NAV consumers, fee formula, and cached queue price. No network, live system, production edit, prior-output read, or test execution.

AGENT_STATUS: COMPLETE
