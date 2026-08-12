# Plamen P1 — semi-trusted-roles

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full 39-file primary scope, 4,849 nSLOC
reads: skill 245/245 (no references); rules 193/193; bundle scope/profile/context/source/finding-format 139/207/181/9,417/101
enumeration: Slither unavailable; base-only grep fallback classified all 129 access-modifier occurrences and manually traced all ADMIN, SECURITY, KEEPER/executor, MINTER, converter-caller, registered-contract, Forwarder, and whitelist-signer paths.

## FINDING STR-1 — A cancellable request can force loss-making strategy churn

file: `src/contracts/automation/StrategyKeeperExecutor.sol`
function: `_pendingRedemptionNeedsETH`, `performUpkeep(WithdrawShortfall)`
mechanism: Strategy automation treats the current unpriced batch as a funding liability even though every request in that batch remains freely cancellable.
consequence: An EVE holder can repeatedly queue a large redemption, wait for honest automation to withdraw and rebalance strategy capital, then cancel and force the excess back through deposits, imposing DEX fees/slippage and cooldown/liveness degradation on all holders.
trigger: EVE holder with allowance when AMM free balance is below its requested exit; normal Chainlink automation
severity: medium
rationale: The grief path is permissionless to a token holder and repeatable at near-zero principal cost; impact is bounded per cycle but protocol NAV erosion and automation starvation accumulate.
poc: none — complete state/call trace
evidence: `StrategyKeeperExecutor.sol:508-512` values the unpriced batch; lines 174-181 select WithdrawShortfall. `ExitQueue.sol:253-266,279-296` allows an unpriced request to close immediately. Trace: `AMM.exit → pushRequest(current)` → honest `WithdrawShortfall → Controller.withdrawFromStrategies` → user `cancelRedemption` gets all escrowed EVE back → excess Controller ETH becomes depositable again. UniCL withdrawal/deposit removes, swaps, and re-adds liquidity.
fix: Do not withdraw against the cancellable current batch; reserve/fund only priced committed batches, or impose a cancellation cost/commitment before its requests drive strategy withdrawals.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓3, ✓4, ✓5, ✓6, ✓6b(fallback enumeration)
rules_applied: R4:✗(closed trace), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan benefit needed), R16:✓
preferred_tag: CODE-TRACE
material_harm: Existing EVE holders bear repeated pool fees, slippage, and delayed operations while the attacker recovers its full queued EVE principal.
postconditions: Strategy assets are withdrawn for a liability the requester can erase, leaving idle Controller ETH and a withdrawal cooldown after cancellation.
postcondition_types: STATE, TIMING, BALANCE
who_benefits: griefing token holder and any trader positioning around predictable strategy swaps

## FINDING STR-2 — The Forwarder can settle expired batches at stale committed prices

file: `src/contracts/automation/QueueKeeperExecutor.sol`
function: `performUpkeep`
mechanism: The view selector skips batches after `pricedAt + MAX_BATCH_PROCESSING_TIME`, but the ProcessRequests execution branch accepts any caller-supplied batch ID for which `_affordableRequests` is nonzero; that helper checks neither expiry nor cursor/scan membership.
consequence: A compromised Forwarder can process an expired colluding request at an old favorable price after NAV has fallen, draining excess ETH from the backing of remaining holders and defeating the user's advertised escape hatch.
trigger: configured Chainlink Forwarder (or its controlling Automation path), with an expired priced batch, affordable Controller balance, and price decline
severity: medium
rationale: Material stale-price overpayment is possible, but it requires compromise/collusion of a semi-trusted Forwarder and a favorable expired request.
poc: none — reasoning-only branch trace
evidence: `QueueKeeperExecutor.sol:302-305` defines expired batches as skippable; lines 209-215 execute an arbitrary decoded `batchId`; `_affordableRequests` at lines 336-348 checks only `canBeProcessed`, users, and affordability. `ExitQueue.pullRequest` at `228-247` has no expiry check, and `Controller.sol:435-448` pays `tokensToBurn * finalEvePrice` without comparing current NAV.
fix: In ProcessRequests, recompute the live cursor/scan selection and reject `_isBatchSkippable(queue,batchId)`, especially post-commitment batches; enforce the same deadline in `ExitQueue.pullRequest` as defense in depth.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓3, ✓4, ✓5, ✓6, ✓6b
rules_applied: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(native ETH/EVE only), R12:✓, R13:✓, R14:✓, R15:✗(role required), R16:✓
preferred_tag: CODE-TRACE
material_harm: Remaining EVE holders can lose backing when an expired request is paid at a stale price above current NAV/share.
postconditions: Old EVE is burned, stale-price ETH becomes claimable, and Controller balance is reduced after the commitment window.
postcondition_types: ACCESS, TIMING, BALANCE, STATE
who_benefits: compromised Forwarder and colluding expired requester

## FINDING STR-3 — Emergency unwind can silently remove paired-token value from NAV

file: `src/contracts/strategies/UniCLStrat.sol`
function: `emergencyExit`
mechanism: SECURITY may transfer paired tokens from a registered strategy (where they are counted) into StrategyManager, but StrategyManager counts them only if ADMIN separately added that token; the deployment flow calls this addition optional and registration enforces no invariant.
consequence: An honest or malicious emergency unwind can abruptly understate NAV while AMM entry remains live, enabling underpriced EVE minting and incumbent dilution.
trigger: ADMIN or SECURITY pauses UniCL and calls emergencyExit while paired balance is nonzero, token is not in StrategyManager's supported set, and AMM remains unpaused
severity: medium
rationale: The allowed deployment/state combination is explicit and the accounting discontinuity can be large; actual deployment configuration and emergency sequencing are unknown.
poc: none — code trace
evidence: `UniCLStrat.sol:494-515` transfers paired tokens to StrategyManager; `StrategyManager.sol:477-485` makes support a separate ADMIN action; `DeployUniCLStrat.s.sol:41-46` calls it optional. `_totalNAVInETH` counts only `_supportedERC20s`, while strategy NAV falls after transfer.
fix: Require every strategy recovery token to be supported before `addStrategy`, or atomically pause AMM entry and retain a quarantined NAV value during emergency transfer.
related: none
verdict: PARTIAL
step_execution: ✓1, ✓2, ✓3, ✓4, ✓5, ✓6, ✓6b
rules_applied: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(role action), R16:✓
preferred_tag: CODE-TRACE
material_harm: EVE holders can be diluted by deposits minted while a potentially large recoverable paired-token balance is absent from NAV.
missing_precondition: Target deployment must omit the paired token from StrategyManager support and hold paired-token inventory at unwind.
precondition_type: STATE / BALANCE
why_this_blocks: A correctly pre-supported token stays in NAV; deployment state was not supplied.
postconditions: Paired inventory moves out of counted strategy NAV into an unenumerated StrategyManager balance.
postcondition_types: STATE, BALANCE, ACCESS
who_benefits: any whitelisted depositor during the undervaluation window

## FINDING STR-4 — SECURITY can omit a live supported balance without closing entry

file: `src/contracts/StrategyManager.sol`
function: `removeSupportedERC20`
mechanism: Immediate SECURITY removal drops a still-held token from NAV without atomically pausing AMM entry.
consequence: A compromised security operator can create an undervaluation window and buy EVE for dilution profit if the omitted balance exceeds `NAV*(1-connectorWeight)` and ADMIN later re-adds it.
trigger: SECURITY_ROLE plus associated whitelisted buyer and sufficiently large supported balance
severity: medium
rationale: Immediate role abuse can materially dilute holders, though it needs a large residual balance and later independent ADMIN restoration.
poc: none — algebra/code trace
evidence: `StrategyManager.sol:491-501` explicitly drops nonzero value; `_totalNAVInETH:940-950` counts only the set; `AMM._enter:408-421` mints from that NAV.
fix: Make removal atomically pause AMM entry or preserve quarantined conservative value until ADMIN disposition.
related: STR-3
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓3, ✓4, ✓5, ✓6, ✓6b
rules_applied: R4:✗(closed trace), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(role required), R16:✓
preferred_tag: CODE-TRACE
material_harm: Incumbent holders lose pro-rata ownership through attacker dilution when omitted backing later returns to NAV.
postconditions: Lower reported NAV and mint price coexist with unchanged custody of the omitted token.
postcondition_types: ACCESS, STATE, BALANCE, TIMING
who_benefits: compromised security operator/affiliate

## CLEARED

area: Keeper parameter and recipient authority
checked: Executors never accept amounts or recipients from performData; live amounts are recomputed, Controller/StrategyManager fix recipients through Registry, and executor calls are nonReentrant. Strategy action priority is not re-enforced, but each alternate branch retains its own live predicate and no direct extraction route was found.

## CLEARED

area: Role revocation and user-to-admin griefing
checked: ADMIN can replace Forwarders/revoke roles after the timelock; SECURITY can immediately pause executors. Normal strategy removal's NAV residue can be user-donation-griefed, but `forceRemoveStrategy` bypasses NAV/paused-state reads, so critical removal remains reachable. Whitelist signer removal invalidates unused signatures at redemption.

## Role analysis summary

role_permissions: SECURITY—pause/cancel/recover/remove-token/remove-signer; executors—Controller keeper calls; Forwarders—select executor branches/data; whitelist signers—authorize invites; converter callers—wrap/unwrap/swap own approved assets.
timing_vectors: batch pricing/expiry, current-batch funding, rebalance/deposit/withdraw/harvest/sync timing.
parameter_vectors: arbitrary Forwarder batch/action; keeper amounts otherwise recomputed; security token/strategy selection.
omission_vectors: keepers/Forwarders may delay pricing, processing, fees, sync, or liquidity; users retain cancellation escape after expiry.
user_exploit_vectors: cancellable-liability churn (STR-1); last-second batch entry was checked and does not itself yield free value; donation around pricing transfers rather than creates value.
max_damage: stale-price or omitted-NAV paths can cause material backing loss/dilution; ordinary keeper omission delays service but does not seize custody.
mitigations: dedicated executor contracts, live branch checks, pause circuit breakers, ADMIN revocation/replacement, 48-hour timelock, three-day user escape hatch.

## Commands/results

- Full bundle/method line reads as recorded above.
- Base `git grep` access census → 129 total modifier occurrences; 70 ADMIN/SECURITY-specific occurrences.
- Base `git show ... | nl -ba | sed -n ...` traced Queue/Strategy executors, Controller, ExitQueue, StrategyManager, UniCL, AMM and deployment paths.
- Tests: not run; no test tree read. Findings are branch/state/algebra traces; actual deployment condition remains explicitly PARTIAL for STR-3.

AGENT_STATUS: COMPLETE
