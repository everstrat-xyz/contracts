# Plamen P1 — share-allocation-fairness

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope/read: full 39 files; skill 116/116 (no references); rules 193/193; bundle 139/207/181/9,417/101 lines
allocation_model: EVE is a pooled-NAV ERC-20 receipt; users mint at premium `NAV/(supply*connectorWeight)` and burn at base `NAV/supply`; exits may enter a priced batch queue; LP fees and donations appreciate NAV; DAO fees mint dilutive EVE.

## FINDING SAF-1 — Unpoked LP fees are captured by late entrants when the entry premium is low

file: `src/contracts/strategies/UniCLStrat.sol`
function: `navInETH`, `sync`
mechanism: NAV reads Uniswap `tokensOwed`, but fee growth is absent until a `burn(...,0)` poke; a depositor can mint EVE before predictable sync/deposit/rebalance materializes already-earned fees.
consequence: At valid `connectorWeight=1`, a late entrant acquires a pro-rata claim on historical LP fees it did not earn, directly diluting earlier holders.
trigger: whitelisted depositor observing unpoked fee growth; connector weight sufficiently high; later strategy poke
severity: medium
rationale: The entry and materialization sequence is permissionless/predictable and profitable at a valid configuration, while practical loss is bounded by unpoked fees and the configured entry premium.
poc: none — worked numerical trace
evidence: `UniCLStrat.sol:199-202,665-676,859-872` values liquidity plus stored `tokensOwed`; lines `362-380` expressly say unpoked fee growth is invisible until sync/remove. `StrategyKeeperExecutor.sol:202-204,263-270` schedules predictable sync. Example: accounted NAV=100 ETH, supply=100 EVE, hidden fees=10 ETH, `c=1`, deposit=10 ETH → 10 EVE minted; poke makes NAV=120 and new supply=110, so entrant's base claim is 10.909 ETH and incumbents lose 0.909 ETH of historical fees.
fix: Include live fee-growth deltas in strategy NAV, or require a bounded-fresh poke/checkpoint before AMM mint/burn pricing.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓2c, ✓2d, ✓2e, ✓3, ✓4, ✓4b
rules_applied: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✓, R16:✓
preferred_tag: CODE-TRACE
allocation_type: pro-rata NAV snapshot with discrete external-fee checkpoint
time_weighting: absent; normally unnecessary only when all accrued value is in the mint snapshot
material_harm: Existing EVE holders lose part of pre-entry LP fee accrual to a depositor that enters immediately before materialization.
postconditions: New shares exist at understated NAV; the next poke raises NAV and allocates hidden fees across old and new supply.
postcondition_types: STATE, TIMING, BALANCE, EXTERNAL
who_benefits: late entrant

## FINDING SAF-2 — Swap-and-pop removal lets the newest batch member jump the queue

file: `src/contracts/ExitQueue.sol`
function: `pullRequest`, `closeRequest`, `unprocessedUsers`
mechanism: Per-batch ordering uses OpenZeppelin `EnumerableSet`; removing processed/cancelled users swap-and-pops the last member into the vacated low index, while keeper processing always requests a prefix from index zero.
consequence: A late user can split across addresses near the tail, jump ahead after the first partial upkeep, consume scarce Controller liquidity, and delay older requests until the three-day escape window.
trigger: token holder(s) joining late in a batch; any partial processing/cancellation before full settlement
severity: medium
rationale: Queue position is permissionlessly manipulable and determines access to scarce liquidity; users retain their EVE after escape, limiting harm mainly to delayed/foregone fixed-price settlement.
poc: none — collection-order trace
evidence: `ExitQueue.sol:219-220` appends to the set; `243-245` and `264-266` remove members; `unprocessedUsers` reads `.at(i)` in index order. `QueueKeeperExecutor._affordableRequests` fetches `[0,cap)` and stops at the first unaffordable request, so a large swapped-to-front tail request can also block smaller older requests behind it.
fix: Store a stable FIFO array/queue with a monotonic processing cursor and tombstones; never use EnumerableSet index order as economic priority.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓2c, ✓2d, ✓2e, ✓3, ✓4, ✓4b
rules_applied: R4:✗(deterministic OZ set semantics), R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(EVE/native only), R12:✓, R13:✓, R14:✓, R15:✗(no flash loan needed), R16:✓
preferred_tag: CODE-TRACE
allocation_type: queue-based redemption
time_weighting: insertion priority intended by prefix processing but not preserved by storage removal
material_harm: Earlier redeemers can lose timely access to a favorable fixed-price settlement and be forced to cancel after newer requests consume available liquidity.
postconditions: Tail addresses move into low indices after removals and are selected by the next prefix upkeep.
postcondition_types: STATE, TIMING, BALANCE
who_benefits: late/split requester
verification_note: Dedicated regression verification should confirm the protocol's intended FIFO guarantee and model attacker control of tail position at each removal; the storage-order mutation is deterministic, but profit/priority severity depends on those assumptions.

## FINDING SAF-3 — Changing the performance fee reprices historical accrued fees

file: `src/contracts/StrategyManager.sol`
function: `setPerformanceFeeBps`
mechanism: No fee checkpoint occurs before the rate changes, so all uncharged historical LP-fee amounts are multiplied by the new rate at their next settlement.
consequence: A fee increase reallocates up to 20% of pre-change uncharged fee accrual from holders to the treasury retroactively.
trigger: ADMIN changes rate; next keeper/admin harvest or strategy withdrawal
severity: low
rationale: The fairness deviation can be material to accrued fees, but governance is timelocked and the fee is capped at 20%.
poc: none — formula trace
evidence: `StrategyManager.sol:673-675,825-829` only stores the new rate; `UniCLStrat.sol:382-415` applies the supplied current BPS to all `_unchargedLpFeeAmounts` and then marks the full earned counters charged.
fix: Settle at the old rate before update or checkpoint fee growth per rate epoch.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓2c, ✓2d, ✓2e, ✓3, ✓4, ✓4b
rules_applied: R4:✗(closed trace), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(retroactivity undocumented), R14:✓, R15:✗(admin path), R16:✓
preferred_tag: CODE-TRACE
allocation_type: dilutive performance-fee share mint
time_weighting: rate epochs are not tracked
material_harm: Holders lose a portion of fees earned before governance announced the higher rate.
postconditions: Old fee accrual is pending under the new BPS until settled and diluted into treasury EVE.
postcondition_types: STATE, TIMING, BALANCE
who_benefits: DAO treasury

## FINDING SAF-4 — Emergency token de-enumeration opens a discounted mint window

file: `src/contracts/StrategyManager.sol`
function: `removeSupportedERC20`
mechanism: SECURITY can remove a nonzero held token from NAV immediately while AMM minting remains independently live.
consequence: An associated depositor can mint underpriced EVE and capture omitted value if/when ADMIN restores the asset to NAV.
trigger: SECURITY plus whitelisted depositor; omitted value `X > NAV*(1-connectorWeight)` for outright round-trip profit
severity: medium
rationale: Potential holder dilution is material and immediate, but requires role abuse, significant balance, and later restoration.
poc: none — algebra trace
evidence: `StrategyManager.sol:491-501,940-968` drops held value solely by set removal; `AMM.sol:408-421` prices mint from that NAV. With pre-removal NAV A and weight c, the attacker profits after re-add exactly when `X>A*(1-c)`.
fix: Atomically pause minting or preserve quarantined NAV on security removal.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓2c, ✓2d, ✓2e, ✓3, ✓4, ✓4b
rules_applied: R4:✗(closed trace), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(role action), R16:✓
preferred_tag: CODE-TRACE
allocation_type: NAV-based share mint under privileged asset enumeration
time_weighting: N/A; backing snapshot is incomplete
material_harm: Incumbents lose pro-rata ownership of restored backing through discounted attacker dilution.
postconditions: Held backing is omitted from NAV and mint price until restoration.
postcondition_types: ACCESS, STATE, BALANCE, TIMING
who_benefits: security-role affiliate

## LEAD SAF-L1 — Optional recovery-token support creates the same mint discontinuity

file: `src/contracts/strategies/UniCLStrat.sol`
function: `emergencyExit`
suspicion: Paired inventory moves from counted strategy NAV into StrategyManager, where it is omitted unless separately supported; deployment labels support optional.
blocked_by: Actual deployed support set/emergency runbook sequence was not supplied.
next_step: Verify deployment configuration; enforce paired-token support before strategy registration or always pause AMM around unwind.

## CLEARED

area: Ordinary entry/redemption symmetry and rounding
checked: Incoming `msg.value` is removed from pre-mint NAV; mint rounds down in protocol favor; immediate and queued exits burn/settle at base NAV price; queued escrow remains in total supply until burn; claim liabilities are excluded from free NAV after burn. The premium/base spread is intentional and user-bounded by min/max parameters.

## CLEARED

area: Aggregate strategy weights and cross-address entry
checked: No entry accepts a beneficiary distinct from `msg.sender`. Eligible deposit/withdraw weights normalize by their cumulative sum, so independent per-strategy weights need not sum to 100 and cannot allocate more than requested; floor/cap leftovers remain with Controller.

## Coverage/commands

- Steps 1,2,2c,2d,2e,3,4,4b all completed over EVE, fee mint, deposits, immediate/queued exits, batch ordering, bootstrap, deployment sequencing, weights, hidden LP accrual, donations, claims, and emergency assets.
- Base-only `git show 734df96:PATH | nl -ba | sed -n ...` confirmed cited AMM, ExitQueue, keeper, StrategyManager, UniCL and deployment paths.
- Tests: not run; no test tree read. Numerical examples were evaluated directly from base formulas.

AGENT_STATUS: COMPLETE
