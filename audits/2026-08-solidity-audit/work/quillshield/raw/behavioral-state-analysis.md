# QuillShield Q1 — behavioral-state-analysis

snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full frozen 39-file primary scope (25 runtime/library + 14 deployment)
input_read: `SKILL.md` 134/134 lines; references 2/2 files, 95/95 lines; bundle `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `source.md` 9,417/9,417, `finding-format.md` 101/101
workflow: DeFi modules—full ETE/ACTE/SITE; EVE—ETE + lite ACTE/SITE; Registry/deployment governance—lite ETE + full ACTE/SITE; utilities/libraries—lite ACTE/SITE; five UUPS modules—full ACTE/SITE; advanced cross-contract, time, and upgrade checks completed
tests: none; medium/low mechanisms were validated by base-source traces and worked states

FINDING
file:         src/contracts/automation/QueueKeeperExecutor.sol
function:     performUpkeep
mechanism:    The `ProcessRequests` execution branch recomputes affordability but never rejects a batch whose three-day processing commitment has expired, even though discovery and cursor logic classify that same batch as skippable.
consequence:  A delayed or adversarial Forwarder transaction can settle an expired request at its stale batch price after the user has acquired the right to cancel, overpaying it from assets backing current holders when NAV has fallen.
trigger:      registered Chainlink Forwarder, including an upkeep selected before expiry but mined after it
severity:     medium
rationale:    BSA confidence 98% — the state mismatch is explicit and the deadline race is feasible; partial holder loss dominates the narrow Forwarder/timing precondition.
poc:          none — reasoning only
evidence:     `checkUpkeep` says `if (_isBatchSkippable(queue, batchId)) continue` (lines 157-160), and `_isBatchSkippable` returns true after `pricedAt + MAX_BATCH_PROCESSING_TIME` (299-305), but `performUpkeep` only does `count = _affordableRequests(...)` then `controller.processRequests(...)` (209-214). `ExitQueue.closeRequest` simultaneously opens cancellation after three days (ExitQueue.sol:262,294-295). At frozen 2 ETH/EVE, 10 EVE still pays 20 ETH after current backing falls to 1 ETH/EVE.
fix:          In the `ProcessRequests` branch, revert when `_isBatchSkippable(queue, batchId)` (or explicitly when the batch expiry has passed) before computing affordability.
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     removeSupportedERC20
mechanism:    ADMIN or SECURITY can remove a nonzero token balance from NAV without atomically disabling AMM pricing, and no degraded-accounting state prevents entry or exit while that owned value is omitted.
consequence:  Existing holders can redeem below backing, while whitelisted entrants can mint against understated NAV and capture part of the excluded balance when governance later restores the token.
trigger:      ADMIN/SECURITY removes a funded supported token while AMM remains open; a whitelisted user enters before restoration
severity:     medium
rationale:    BSA confidence 91% — the price discontinuity is deterministic and emergency removal is an intended reachable state; value transfer requires a funded token and an operational pause omission.
poc:          none — reasoning only
evidence:     The code states `Removing a token with a non-zero balance drops that value out of NAV immediately` and permits either role (lines 491-499). `_totalNAVInETH` sums only `_supportedERC20sNAVInETH` (940-950), while AMM `_enter` prices and mints from that NAV with no accounting-degraded guard (AMM.sol:408-421).
fix:          Make removal set a persistent degraded-accounting flag that blocks AMM entry/exit until the balance is zero or the token is restored; pausing only the StrategyManager is insufficient because AMM pricing is independently live.
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     setPerformanceFeeBps
mechanism:    Changing `performanceFeeBps` neither settles nor checkpoints existing uncharged LP fees, so UniCLStrat later applies the new rate to the entire historical `earned - charged` amount.
consequence:  Raising the fee, including enabling it from zero, retroactively dilutes existing EVE holders for LP fees earned before the announced rate took effect.
trigger:      ADMIN executes a fee-rate increase, followed by any fee harvest/deposit/withdraw settlement
severity:     medium
rationale:    BSA confidence 94% — the accumulator/rate transition is concrete and can charge up to 20% of uncharged historical LP fees; timelock visibility lowers likelihood but not the retrospective transfer.
poc:          none — reasoning only
evidence:     `_setPerformanceFeeBps` only writes the new value (StrategyManager.sol:825-829). `UniCLStrat.settlePerformanceFee` reads all `_unchargedLpFeeAmounts`, computes `feeETH = _feeBaseETH * _performanceFeeBps / BASIS_POINTS`, then marks all cumulative earnings charged (UniCLStrat.sol:403-415). A 0% period accumulating 100 ETH of fees followed by 20% yields a 20 ETH fee base charge.
fix:          Before changing the rate, settle every registered strategy at the old rate and checkpoint even when the old rate is zero; alternatively version fee accrual by rate epoch.
related:      none

FINDING
file:         script/ProtocolDeployBase.sol
function:     _deployTimelocks
mechanism:    The optional `TIMELOCK_ADMIN_DELAY` is passed directly to `TimelockController` without enforcing the documented 48-hour minimum, so any explicit value—including zero—overrides the safe fallback.
consequence:  A misconfigured production deployment silently loses the promised reaction window for upgrades, Registry rewiring, role grants, feed changes, and unpausing.
trigger:      deployment operator supplies `TIMELOCK_ADMIN_DELAY < 48 hours`
severity:     low
rationale:    BSA confidence 99% — the guard omission is unambiguous and affects all ADMIN transitions, but only a deployment/configuration mistake reaches it.
poc:          none — reasoning only
evidence:     The script labels 48 hours the production policy minimum and says the fallback is `never weaker` (lines 31-39), yet calls `_deployTimelock(vm.envOr("TIMELOCK_ADMIN_DELAY", DEFAULT_ADMIN_TIMELOCK_DELAY), ...)` without a lower-bound check (352-358).
fix:          Read the value once and require `minDelay >= DEFAULT_ADMIN_TIMELOCK_DELAY` before deployment.
related:      none

LEAD
file:         src/contracts/automation/StrategyKeeperExecutor.sol
function:     _batchSettlementCost
suspicion:    Capping each priced-batch liability at 50 users can label Controller ETH owed to later users as idle and redeposit it, contrary to the stated non-cannibalization invariant.
blocked_by:   Impact depends on live batch cardinality, withdrawal liquidity, and Automation scheduling; no deployment state was supplied.
next_step:    Model a >50-user priced batch with exactly sufficient Controller ETH, execute `DepositExcess`, then make strategy withdrawal unavailable and measure redemption delay/expiry.

LEAD
file:         script/ProtocolDeployBase.sol
function:     _deployTimelock
suspicion:    The immediate security multisig receives CANCELLER_ROLE on a self-administered timelock, so a compromised security signer can cancel the timelocked operation that would revoke its own canceller role and maintain an indefinite governance veto.
blocked_by:   This may be an accepted governance trust assumption; no explicit recovery/liveness requirement or production signer topology was supplied.
next_step:    Confirm the governance threat model and require an out-of-band recovery path or bounded/rotatable canceller authority if security-key compromise is in scope.

CLEARED
area:         AMM entry and claim ETH accounting
checked:      Incoming `msg.value` is removed from pricing NAV before minting; `lockedForClaims` is excluded from free balance/NAV and decremented before claim transfer.

CLEARED
area:         Whitelist invite state machine
checked:      EIP-712 vouchers bind user, opaque invite ID, and deadline; invite IDs are consumed before admission and bans cannot be replay-bypassed while the gate is active.

CLEARED
area:         Converter delegated swap boundary
checked:      Caller/adapter authorization, route endpoint binding, balance-delta verification, allowance clearing, and reentrancy ordering were traced for exact-input and exact-output flows.

CLEARED
area:         UniCLStrat callback and emergency ordering
checked:      Mint callback requires both the configured pool and an active mint; pause commits local state before best-effort pool unwind, and emergency ETH sweep precedes the fallible paired-token transfer.

CLEARED
area:         Upgrade initialization and authorization
checked:      Five UUPS implementations disable implementation initialization, proxy initializers use one-time guards, and upgrade authorization resolves Registry ADMIN_ROLE.

commands: `sed -n` full reads of all allowed bundle/plugin inputs; `git show 734df96:PATH | nl -ba | sed -n ...` for base-only evidence; `git grep ... 734df96 -- script src` for frozen transition/config searches; no network, worktree source, or tests used
AGENT_STATUS: COMPLETE
