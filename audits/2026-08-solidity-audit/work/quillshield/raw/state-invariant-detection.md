# QuillShield Q1 — state-invariant-detection

snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full frozen 39-file primary scope (25 runtime/library + 14 deployment)
input_read: `SKILL.md` 252/252 lines; references 2/2 files, 498/498 lines; bundle `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `source.md` 9,417/9,417, `finding-format.md` 101/101
workflow: all state variables clustered by co-modification; aggregation, conservation, ratio, monotonic, and synchronization relations inferred; every modifying entry point checked through transitive calls; temporary/reverting violations filtered at function exit
cluster_coverage: EVE supply/balances; AMM claims/free ETH/pricing; ExitQueue members/request totals/batch time; StrategyManager strategy/weight/role/NAV/fee sets; Oracle token/pair sets; Converter deltas; Registry roles/addresses; Whitelist admission/replay; keeper cursors/liabilities/timestamps; UniCL inventory/positions/fee snapshots; deployment role/config coupling
tests: none; findings are persistent-state equations demonstrated with frozen-source transitions and worked values

FINDING
file:         src/contracts/ExitQueue.sol
function:     priceBatch
mechanism:    Pricing fixes queued EVE claims in ETH but records neither a redemption liability nor an adjusted active supply; the escrowed EVE remains in `totalSupply` and its backing remains in reported NAV until each later processing call.
consequence:  NAV changes between pricing and processing are divided over shares that no longer participate in that change, so live AMM prices jump at settlement and users transacting in the interval can receive value belonging to active holders.
trigger:      any priced nonempty batch, a post-pricing NAV change, and an AMM entry/exit before the batch is processed
severity:     medium
rationale:    Plugin invariant confidence 96% — `activePrice = (NAV - fixedLiabilities) / activeSupply` is a strong ratio/conservation relation; timing and a material queued fraction govern exploit size.
poc:          none — reasoning only
evidence:     `priceBatch` only writes `finalEvePrice`, `canBeProcessed`, and `pricedAt` (ExitQueue.sol:176-187). AMM continues using unadjusted `totalSupply` and total NAV (AMM.sol:408-412,488-489), while burn and locked claim recognition occur only in `processRedemption` (225-240). Worked state with connectorWeight=1: NAV=100, supply=100, 50 EVE priced at 1; after 20 yield, reported price=120/100=1.2 but active price=(120-50)/(100-50)=1.4. A 12 ETH entry mints 10 EVE; after paying/burning the batch, NAV=82 and supply=60, making those shares worth 13.667 ETH.
fix:          At pricing, recognize fixed liabilities and remove accepted queued shares from the active pricing denominator, or settle queued requests at the current price; correctly classifying per-request tolerance may require bounded pricing/processing redesign.
related:      none

FINDING
file:         src/contracts/strategies/UniCLStrat.sol
function:     emergencyExit
mechanism:    A successful paired-token transfer moves value from a registered strategy (where `navInETH` counts it) to StrategyManager, which counts it only if the optional supported-ERC20 registration was performed.
consequence:  Emergency exit can make unchanged, recoverable token value disappear from protocol NAV, underpricing EVE and enabling a transfer to entrants/remaining holders when the token is later counted again.
trigger:      ADMIN/SECURITY pauses and exits UniCLStrat while it holds paired tokens that StrategyManager does not support
severity:     medium
rationale:    Plugin invariant confidence 99% — cross-location asset conservation is exact; the only feasibility condition is the explicitly optional token-registration step.
poc:          none — reasoning only
evidence:     `navInETH` prices both pool tokens (UniCLStrat.sol:199-203), then `emergencyExit` transfers `_pairedBalance` to StrategyManager (497-515). StrategyManager NAV prices only members of `_supportedERC20s` (StrategyManager.sol:940-968). The deployment guide calls `addSupportedERC20` optional (DeployUniCLStrat.s.sol:41-43), while UniCL itself says it is required for NAV continuity (481-483).
fix:          Before transferring paired tokens, require StrategyManager support; if absent, retain them in the still-registered strategy (or atomically register/account them before transfer).
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     forceRemoveStrategy
mechanism:    Force removal deletes any registered strategy from the sole NAV aggregation set regardless of its reported or recoverable assets, without establishing a liability/degraded state or stopping AMM pricing.
consequence:  EVE pricing resumes with protocol-owned assets omitted; users can redeem below backing or mint against the depressed NAV and capture value if the strategy is later recovered or re-added.
trigger:      ADMIN force-removes a funded or temporarily reverting strategy while AMM remains live
severity:     medium
rationale:    Plugin invariant confidence 98% — all ordinary fund moves conserve aggregate NAV and normal removal caps residue at 10 wei; this explicit bypass can omit an unbounded amount, although it is timelocked.
poc:          none — reasoning only
evidence:     Normal removal rejects NAV above `MAX_NAV_RESIDUE` (StrategyManager.sol:228-235), but `forceRemoveStrategy` treats NAV as observability only and always calls `_deregisterStrategy` (250-266). `_totalNAVInETH` sums only `_strategies` (940-950), and AMM derives prices directly from that value (AMM.sol:329-358).
fix:          Persist the removed strategy's last conservative NAV as a liability or enter a degraded mode that blocks AMM entry/exit until assets are recovered and explicitly written off.
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     removeSupportedERC20
mechanism:    Removing a supported token deletes a nonzero owned balance from the sole NAV summation set without changing custody, recording an exclusion liability, or stopping price-sensitive operations.
consequence:  Reported NAV no longer equals recoverable protocol assets, enabling redemptions at a haircut and cheap minting before a later re-add restores the omitted value.
trigger:      ADMIN/SECURITY removes a funded token and AMM remains live
severity:     medium
rationale:    Plugin invariant confidence 99% — the implementation explicitly documents the immediate NAV drop and conservation failure; impact depends on balance size and operational pause discipline.
poc:          none — reasoning only
evidence:     The function documents `Removing a token with a non-zero balance drops that value out of NAV immediately` and removes it without reading custody (StrategyManager.sol:491-501); `_supportedERC20sNAVInETH` iterates only current set members (961-969).
fix:          Track excluded nonzero balances in a degraded-accounting set that blocks AMM pricing until zeroed or restored; do not silently equate “unpriceable” with “not owned.”
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     setPerformanceFeeBps
mechanism:    The global fee rate can change while UniCL's cumulative earned-but-uncharged amounts remain in one undated bucket, so the next settlement applies the new rate to earnings accrued under the old rate.
consequence:  A fee increase retroactively dilutes holders for historical LP fees; a decrease also forgives previously accrued protocol fees, so charged value is not the sum of each epoch's earnings times its contemporaneous rate.
trigger:      ADMIN changes the rate before all strategy fee buckets are settled/checkpointed
severity:     medium
rationale:    Plugin invariant confidence 100% — the synchronization relation between rate epochs and accrued fee base is absent on every rate change; the timelock limits surprise but not retrospective accounting.
poc:          none — reasoning only
evidence:     `_setPerformanceFeeBps` only assigns `performanceFeeBps` (StrategyManager.sol:825-829). UniCL later applies the supplied current rate to all `_unchargedLpFeeAmounts` and sets cumulative charged equal to cumulative earned (UniCLStrat.sol:403-415). Thus 100 ETH accumulated at 0%, then a 20% setting, produces a 20 ETH fee claim.
fix:          Settle and checkpoint every registered strategy at the old rate before changing it, including a zero-rate checkpoint, or store accrual per rate epoch.
related:      none

LEAD
file:         src/contracts/automation/StrategyKeeperExecutor.sol
function:     _batchSettlementCost
suspicion:    `needsETH` is presented as the queued liability but persistently omits every user after index 49 in each priced batch, allowing the coupled idle-excess calculation to redeploy owed liquidity.
blocked_by:   The estimator is intentionally bounded and later upkeeps may restore liquidity; severity requires a schedule/illiquidity simulation.
next_step:    Run a >50-user batch state machine and test whether an initially fully funded batch reaches the escape-hatch deadline after `DepositExcess` and loss of strategy withdrawability.

LEAD
file:         src/contracts/strategies/UniCLStrat.sol
function:     investIdleETH
suspicion:    `totalDeposited` is described as lifetime ETH deposited but does not change when donated idle ETH is invested, while a separate `FundsInvested` event records the amount.
blocked_by:   The metric may intentionally mean only StrategyManager-originated deposits and is not used in protocol accounting.
next_step:    Confirm the metric's off-chain invariant; either redefine its documentation or increment a distinct lifetime-invested counter.

CLEARED
area:         AMM claim aggregation and ETH conservation
checked:      `lockedForClaims == sum(claimableBalances)` is co-modified on process/claim, and `address(AMM).balance == freeBalance + lockedForClaims` holds at every successful external exit.

CLEARED
area:         ExitQueue request aggregation
checked:      `batch.totalTokensToBurn == sum(tokensToBurn for unprocessedUsers)` is preserved by push, pull (including slippage close), and cancellation; `currentBatchId` is monotonic.

CLEARED
area:         Oracle and Registry set synchronization
checked:      Supported-token/pair set membership stays coupled to feed slots across upsert and inbound/outbound removal; registered-role membership is removed only when its enumerable member count reaches zero.

CLEARED
area:         Converter transaction conservation
checked:      Exact-input output and exact-output input/output are measured by balance deltas, refunds/payouts reconcile those deltas, and any failure reverts the temporary transfers.

CLEARED
area:         UniCL LP-fee counters
checked:      `charged <= earned`, owed snapshots, poke/accrue-before-collect, principal exclusion, dust retention, and emergency write-off were traced through deposit, withdraw, sync, settle, pause, and emergency exit.

CLEARED
area:         Fee-mint batch aggregation
checked:      Per-strategy fee ETH sums once into the dilution mint; pro-rata event allocations consume exactly `totalEves`, and downstream failure reverts prior strategy settlements atomically.

commands: full plugin/reference and allowed-bundle `sed -n` reads; frozen mutation inventory via `git grep -n -E '...state mutations...' 734df96 -- src script`; base evidence via `git show 734df96:PATH | nl -ba | sed -n ...`; no network, worktree source, or tests used
AGENT_STATUS: COMPLETE
