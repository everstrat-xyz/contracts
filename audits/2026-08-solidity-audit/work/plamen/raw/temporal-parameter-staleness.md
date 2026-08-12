# Plamen raw pass: temporal-parameter-staleness

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full immutable 39-file source scope
method: multi-transaction state inventory; cached/current parameter matrix; mandatory increase/decrease and retroactivity traces
plugin_confidence: high for fee/cooldown/queue code semantics; medium for migration exposure because deployed sequencing and module addresses were not supplied

MULTI_STEP_OPERATIONS
- Invite: off-chain signature -> `Whitelist.whitelist`/`AMM.enterWithInvite`; cached signer address, invite ID, user and deadline; current signer authorization is re-read.
- Redemption: `AMM.exit` -> `ExitQueue.priceBatch` -> Controller/AMM process -> `AMM.claim`; request price/tokens/tolerance and batch created/priced timestamps/final price are snapshots.
- Cancellation: queued request -> user cancel before pricing, or after immutable 3-day processing window.
- Strategy cooldown: successful withdrawal stores `lastStrategyWithdrawal` -> later deposit compares current `strategyDepositCooldown`.
- Performance fee: LP fees accrue/materialize -> later settle computes the entire uncharged base at current `performanceFeeBps` -> EVE mint.
- Automation: off-chain `checkUpkeep` -> Forwarder `performUpkeep`; performData selects only action/batch, while state/amounts/thresholds are recomputed.
- Strategy emergency recovery: pause/unwind -> emergencyExit -> StrategyManager sweep -> Controller sweep -> AMM liquidity.
- Registry/config migration: module/adapter/feed/route configured -> later consumers resolve Registry dynamically except adapter immutables and strategy route state.
- Timelock schedule -> execute is implemented by pinned OpenZeppelin dependency; in-scope scripts configure the minimum delay/roles but do not cache execution parameters.

CACHED_PARAMETER_MATRIX
- `priceTolerance`, `evePriceAtRequestTime`, `tokensToBurn`: user/request snapshots; not governance-changeable; final processing reuses intentionally.
- `createdAt` + current `minBatchAge`: duration is re-read, ADMIN-changeable, bounded 1-7 days; not snapshotted.
- `pricedAt` + `MAX_BATCH_PROCESSING_TIME`: delay is immutable 3 days; no stale mutable parameter.
- `claimableBalances`: fixed credited debt; no fee/delay is re-read at claim.
- `lastStrategyWithdrawal` + current cooldown: duration is re-read, ADMIN-changeable, bounded 0-1 day.
- uncharged LP-fee token counters + current `performanceFeeBps`: rate is re-read, ADMIN-changeable 0-20%, and no epoch/rate checkpoint exists.
- `lastSyncAt` + current `syncInterval`: re-read, ADMIN-changeable including zero disable; only keeper housekeeping.
- keeper thresholds/reserves/targets: not encoded in performData; all re-read at performance.
- adapter `oracle`: cached immutable from Registry at deployment while Registry Oracle key is replaceable; not revalidated.
- strategy adapter/routes: cached mutable config while Converter allowlist is independently mutable; route validity is rechecked only when route config is set.

FINDING
file:         src/contracts/StrategyManager.sol
function:     setPerformanceFeeBps / _harvestPerformanceFeesFor
mechanism:    The fee rate has no accrual epoch: settlement passes the current `performanceFeeBps` over each strategy's entire uncharged historical LP-fee base, so a rate change applies retroactively—including fees earned while the rate was zero.
consequence:  Increasing/re-enabling the rate mints an unannounced retroactive EVE fee and dilutes existing holders for pre-change earnings; decreasing it forgives treasury fees already economically accrued under the former rate.
trigger:      ADMIN_ROLE changes `performanceFeeBps`, then a keeper/admin harvests or a withdrawal invokes pre-withdraw harvesting
severity:     medium
rationale:    Governance is timelocked and the rate is capped at 20%, but impact dominates because every holder can be diluted by up to 20% of NAV attributable to historical LP fees that were never earned under the new rate.
poc:          none — reasoning with worked values
evidence:     `StrategyManager.sol:673-675,825-830` changes only the scalar rate; `:734-743` forwards the current rate at settlement. `UniCLStrat.sol:382-409` multiplies all `_unchargedLpFeesInETH()` by that supplied rate, and only then advances charged counters at `:413-414`. Example: NAV=100 ETH, supply=100 EVE, 50 ETH historical uncharged fees, old rate=0, new rate=20% => fee=10 ETH and mint=10*100/(100-10)=11.111 EVE, giving treasury 10% of post-mint supply.
fix:          Settle/checkpoint every strategy at the old rate before changing it, or store fee-rate epochs and apply each rate only to fee growth accrued during that epoch; when switching from zero, checkpoint the existing base as charged.
related:      none
plamen_verdict: CONFIRMED
plamen_steps: ✓1 ✓2 ✓3(increase+decrease) ✓3b ✓4 ✓5
plamen_rules: R4:✓, R5:✓, R6:✓(ADMIN/keeper), R8:✓, R10:✓, R11:✓(LP fee tokens), R12:✓, R13:✓(`0 disables fees`), R14:✓, R15:✗(no flash-loan precondition), R16:✓(fee base is oracle-valued)
preferred_tag: CODE-TRACE
material_harm: Existing EVE holders lose part of their pro-rata ownership to treasury dilution for LP fees accrued before the newly selected rate applied.
postconditions: historical uncharged counters are marked fully charged; new EVE is minted to the then-current treasury; holder ownership percentage falls
postcondition_types: STATE, TIMING, BALANCE
who_benefits: DAO treasury under an increase; holders under a decrease

LEAD
file:         src/contracts/adapters/UniswapV3ConverterAdapter.sol
function:     constructor / _oracleQuote
suspicion:    The adapter snapshots the Registry's Oracle into an immutable. Replacing Registry `ORACLE` leaves an allowed active adapter reading the old Oracle while UniCLStrat's independent bounds resolve the new Oracle, enabling stale pricing or swap/withdrawal liveness failure.
blocked_by:   Governance can predeploy and atomically coordinate a replacement adapter/route/allowlist batch; no actual migration sequence or deployed addresses were supplied.
next_step:    Simulate an Oracle-key replacement with the existing adapter still allowed, then test quote, rebalance and withdrawal under divergent old/new feeds.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗, R12:✓, R13:✗, R14:✓, R15:✓, R16:✓

LEAD
file:         src/contracts/strategies/UniCLStrat.sol
function:     setRouteConfig / swap helpers
suspicion:    Strategy route validity is checked only at construction/update; independent later `Converter.setAllowedAdapter(adapter,false)` makes stored route config stale and causes every swap-requiring deposit, rebalance or withdrawal to revert.
blocked_by:   This requires a governance sequencing error and can be avoided with one timelock batch that installs new routes before removing the old adapter.
next_step:    Exercise the exact adapter-removal migration order and require an on-chain active-route invariant before allowlist removal.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✗, R14:✓, R15:✗, R16:✓

LEAD
file:         src/contracts/Whitelist.sol
function:     removeSigner / addSigner / whitelist
suspicion:    Signatures have no signer epoch: revocation makes old vouchers invalid only while the address stays unauthorized; re-adding the same signer reactivates every still-unexpired pre-revocation signature from that key.
blocked_by:   Re-adding a compromised key is an ADMIN governance choice, deadlines still cap validity, and no signer-rotation/reuse policy was supplied.
next_step:    Establish whether signer-address reuse is supported; if yes, include a per-signer epoch in the EIP-712 voucher and increment it on removal.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗, R12:✓, R13:✗, R14:✗, R15:✗, R16:✗

CLEARED
area:         Fee-rate increase/decrease modeling
checked:      Increase (including 0->nonzero) charges all earlier uncharged growth at the new rate; decrease charges it at the lower rate; 20% is the upper bound. Treasury-address changes similarly redirect a later mint, but do not increase holder dilution.

CLEARED
area:         Strategy deposit cooldown changes
checked:      Decrease lets deposits resume sooner; increase extends the current check. However cooldown is capped at 1 day while production ADMIN changes wait at least 48h, so any pre-proposal withdrawal has expired before the change can execute; there is no stale cached duration with material user harm.

CLEARED
area:         Redemption temporal snapshots
checked:      Request price/tolerance/tokens are fixed by the user, batch final price is intentionally fixed for consistent settlement, claim debt is fixed, and the 3-day post-pricing escape window is immutable. Connector weight affects premium entry only, not queued base-price redemption.

CLEARED
area:         Mutable queue/keeper intervals
checked:      `minBatchAge` increase/decrease applies to existing `createdAt` but is bounded 1-7 days and users can cancel while unpriced; `syncInterval` changes only housekeeping. `maxUsersPerUpkeep`, reserve, thresholds and targets are re-read rather than cached.

CLEARED
area:         Automation check-to-perform staleness
checked:      Queue and strategy executors treat performData as an action selector only; current batch IDs, affordability, liabilities, balances, thresholds, route state and amounts are recomputed during `performUpkeep`, and stale work reverts.

READ_COUNTS
- Plamen rules: orchestrator-rules.md 79/79; finding-output-format.md 114/114.
- Skill: temporal-parameter-staleness/SKILL.md 143/143; directly referenced required files: 0 (`SEMI_TRUSTED_ROLES.md` is a cross-reference marker, not a linked path in the skill bundle; role behavior was traced in source/profile).
- Fresh shared bundle (completed once for P2): scope 139/139; profile 207/207; context 181/181; source 9,417/9,417 (39/39 files); finding-format 101/101.

COMMANDS_TESTS
- Enumeration: base-only `git grep -nEi 'interval|epoch|period|duration|delay|cooldown|timelock|createdAt|pricedAt|lastSyncAt|deadline|timestamp' 734df96 -- src script` plus full-source manual inventory.
- Validation: `git show 734df96:PATH | nl -ba | sed -n ...` for each closed trace.
- Tests: not run; arithmetic and rate/counter transitions are explicit at immutable base.
- Network/live systems/production edits/commit: not used.

AGENT_STATUS: COMPLETE
