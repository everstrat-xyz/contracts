# Omega Pass B retry — top-down entrypoint review

Commit: `734df96a1391e95dd40843210997da0b9f3ab05e`

## Read status

- Omega workflow, finding format, Pass B prompt, merge protocol: COMPLETE
- All 11 Omega lens `SKILL.md` files: COMPLETE
- Allowed `scope.md`, `profile.md`, `context.md`, `xray.md`, `source.md` (9,417 lines): COMPLETE
- Review used only the immutable bundle and `git show 734df96:PATH`; no history, prior work, audit tests, post-base source, or network input.

## Entrypoint-first coverage

- Enumerated the profile's 155 ABI non-view/payable selectors plus five `receive()` entries (152 source-defined entries after inherited-selector adjustment), then reviewed their source bodies and internal callees.
- AMM (10): entry/invite, immediate/queued exit, cancel, claim, Controller settlement, config/pause, receive.
- Controller (25): all keeper allocation/withdraw/sync/rebalance/fee/queue methods, emergency/pause/upgrade, receive.
- Converter (13): wrap/unwrap, exact-in/out, quote dispatch, caller roles, adapters, pause/upgrade, receive.
- EVE (6): ERC-20 transfers/approvals plus role-gated mint/burn/burnFrom.
- ExitQueue (8): initialize, price/push/pull/close, pause/upgrade.
- Oracle (6): initialize, USD/pair upsert/removal, upgrade.
- StrategyManager (31): initialize, strategy lifecycle/weights, allocation, fee, emergency/token management, pause/upgrade, receive.
- Whitelist (6): permissionless voucher redemption and admin signer/user lifecycle/disable.
- Adapter (2): permissionless exact-in/out bodies (and quote/route views) in direct-call and Converter-delegatecall contexts.
- Queue/Strategy keeper executors (7/11): public checks, Forwarder callbacks, configuration, cursor/pause, every action branch.
- Registry (11): registration, role batches/singles/renounce, pause; UniCLStrat (19): lifecycle/config/emergency/self-call/mint callback/receive.

FINDING
file: `src/contracts/strategies/UniCLStrat.sol`
function: `constructor`, `_mintPosition`, `uniswapV3MintCallback`
mechanism: The immutable `pool` is accepted solely through interface calls and the WETH-token membership check; it is never authenticated through an expected factory. During `pool.mint`, `_minting=true`, and the callback accepts arbitrary requested token amounts from that configured address.
consequence: A malicious interface-compatible configured pool can request the strategy's entire token0/token1 inventory in its synchronous callback and retain it, causing loss of strategy assets.
trigger: A malicious or incorrectly sourced `POOL_ADDRESS` is deployed and subsequently registered as a strategy, then any deposit/rebalance/add-liquidity path reaches `pool.mint`.
severity: medium
rationale: Loss can be material and automatic after funding, but the immutable bad pool must first pass the admin/timelock strategy-onboarding process; an arbitrary external caller cannot replace it.
poc: Static trace: `_mintPosition` sets `_minting=true` -> calls attacker `pool.mint` -> pool calls back with each current balance -> sender/flag checks pass -> both `safeTransfer(pool, amount)` execute.
evidence: Lines 136-166 obtain `token0/token1/tickSpacing` from the supplied pool and only require one token be WETH; lines 750-755 open the callback window; lines 524-531 trust only `msg.sender==pool` and `_minting`; lines 1280-1296 validate nonzero addresses/config but no factory. `DeployUniCLStrat.s.sol:101-110` copies `POOL_ADDRESS` directly.
fix: Require `factory.getPool(token0,token1,fee)==pool` (and bind the intended factory/fee), then cap callback payments to amounts computed for that mint.
related: external-data-trust, standard-conformance, ordering-and-approval-races

FINDING
file: `src/contracts/StrategyManager.sol`; `src/contracts/strategies/UniCLStrat.sol`
function: `setPerformanceFeeBps`, `settlePerformanceFee`
mechanism: Changing `performanceFeeBps` writes the new rate without settling/checkpointing accrued LP fees. The next settlement multiplies all uncharged lifetime-since-last-settlement fee amounts by the single current rate, then marks all earned amounts charged.
consequence: A fee increase retroactively overcharges pre-change yield; a decrease undercharges it, transferring value between EVE holders and the DAO contrary to time-bounded fee economics.
trigger: LP fees accrue under rate R1, ADMIN calls `setPerformanceFeeBps(R2)`, and a later keeper/admin withdrawal or harvest settles them.
severity: medium
rationale: The distortion can cover the entire unsettled fee base (new rate is bounded at 20%); changing the rate is timelocked, but source provides no enforced pre-change settlement.
poc: For 100 ETH uncharged fees, changing 10% -> 20% before harvest makes line 409 return 20 ETH-equivalent and lines 413-414 write off the whole base, rather than charging 10 ETH on historical accrual.
evidence: `StrategyManager.sol:673-675,825-830` only validates/emits/stores; `:740-758` passes the current rate at harvest. `UniCLStrat.sol:395-415` applies that rate to all `_uncharged` and advances charged counters to earned.
fix: Settle every strategy at the old rate atomically before storing a new rate, or checkpoint fee growth/rate epochs and charge each epoch independently.
related: accounting-consistency, share-and-index-accounting, time-indexed-state

FINDING
file: `src/contracts/automation/QueueKeeperExecutor.sol`; `src/contracts/ExitQueue.sol`
function: `performUpkeep(ProcessRequests)`, `_affordableRequests`, `closeRequest`
mechanism: The process callback revalidates affordability only; it does not reject a batch that is now past `pricedAt + MAX_BATCH_PROCESSING_TIME`, behind the live cursor, or outside the scan window. `_affordableRequests` checks only `canBeProcessed` and request count.
consequence: Stale Forwarder performData can settle a request after the documented keeper commitment expired, racing away the user's now-open cancellation/escape-hatch choice; forged Forwarder data can also bypass oldest-live scan selection.
trigger: `checkUpkeep` selects ProcessRequests before expiry but `performUpkeep` lands just after expiry, or the configured Forwarder supplies such data while the request remains affordable.
severity: low
rationale: The state-machine promise is unenforced, but only the configured Forwarder/stale automation delivery reaches this branch and the user still receives normal priced settlement rather than direct theft.
poc: At `pricedAt+3 days+1`, `ExitQueue.closeRequest` permits cancellation; the same block's `performUpkeep(abi.encode(ProcessRequests,batchId))` obtains nonzero count and calls Controller because no expiry predicate is read.
evidence: `QueueKeeperExecutor.sol:38-42` says expired batches must be closed; `:192-215` lacks live-cursor/expiry checks; `:336-363` lacks expiry. `ExitQueue.sol:253-295` opens cancellation only after the same boundary, while `pullRequest:228-247` has no expiry guard.
fix: In the ProcessRequests branch require the batch is within the recomputed live scan and `!_isBatchSkippable(queue,batchId)`; preferably enforce expiry in the queue pull transition too.
related: enforceability-check, time-indexed-state, ordering-and-approval-races

FINDING
file: `src/contracts/strategies/UniCLStrat.sol`; `src/contracts/StrategyManager.sol`
function: `emergencyExit`, `emergencyWithdrawToController`, supported-ERC20 management
mechanism: Emergency exit transfers paired-token inventory to StrategyManager, but this release implements only NAV accounting for those ERC-20s. Its sole recovery function transfers native ETH; there is no token sweep or conversion exit.
consequence: Potentially unbounded paired-token value becomes unusable for redemptions until a timelocked UUPS upgrade is designed/deployed; removing support merely hides the stranded balance from NAV and can misprice exits.
trigger: Pausing UniCL unwinds liquidity into a nonzero paired-token balance and ADMIN/SECURITY calls `emergencyExit`.
severity: medium
rationale: This defeats part of the emergency capital-recovery chain and can prolong redemption illiquidity; it requires an emergency state and is recoverable through a governance upgrade, not permanently cryptographically lost.
poc: `emergencyExit` sends paired tokens to StrategyManager; enumerate all StrategyManager external entries: only `emergencyWithdrawToController` sends value and it sends `address(this).balance` as ETH.
evidence: `UniCLStrat.sol:494-515` transfers paired tokens to StrategyManager. `StrategyManager.sol:453-468` sweeps ETH and explicitly says ERC-20 recovery is deferred; `:477-502` only adds/removes accounting support; interface lines 483-510 confirms removal can drop nonzero balance from NAV.
fix: Add a pause-safe, role-gated token recovery/conversion route with balance-delta/slippage controls before using paired-token emergency transfer.
related: asset-exit-paths, accounting-consistency, enforceability-check

FINDING
file: `script/ProtocolDeployBase.sol`; `src/contracts/registry/Registry.sol`
function: `_requireUnregistered`, `_registerAndVerify`, `_registerContract`
mechanism: `_requireUnregistered` reverts inside the `try` success body, but its catch catches that same revert, so it always returns. Registry registration intentionally uses `EnumerableMap.set` and overwrites existing keys.
consequence: Rerunning a modular deploy step during bootstrap can silently replace a live critical module address rather than fail closed, potentially freezing or redirecting protocol authority/assets.
trigger: A still-bootstrap-admin deployer runs any `_registerAndVerify` modular script against a Registry key that is already populated.
severity: medium
rationale: Critical wiring can be overwritten, but execution needs the explicitly temporary ADMIN key; finalization removes that EOA authority and later governance actions are timelocked.
poc: Existing key -> `getContractByKey` succeeds -> local `revert` -> `catch {}` -> `registerContract` -> map `.set` overwrites and verification accepts the new value.
evidence: `ProtocolDeployBase.sol:207-217`; `Registry.sol:218-226` computes `oldAddress` then unconditionally sets the key.
fix: Record success in a boolean outside try/catch and revert after the try, or catch only the registry's not-registered error; add a non-overwriting Registry registration API for deploy scripts.
related: repo-hygiene-sweep, enforceability-check, upgrade-diff-review

LEAD
file: `src/contracts/Oracle.sol`
function: `_getPriceWithStalenessCheck`
suspicion: `latestRoundData()` discards `roundId` and `answeredInRound`; positivity and `updatedAt` staleness alone may accept an incomplete/superseded Chainlink round for legacy-compatible feeds.
blocked_by: Base source contains only the interface, not the configured aggregator implementations or an authoritative guarantee for their round semantics; deployed feed addresses are explicitly missing from context.
next_step: Validate every production feed implementation/proxy against its documented `latestRoundData` semantics; if incomplete rounds are possible, require `answeredInRound >= roundId` in addition to current checks.

## All-lens closure

CLEARED
area: accounting/share-index — AMM excludes pending `msg.value` and locked claims from NAV; Converter exact-in/out uses observed balance deltas; remaining defect is the fee-rate epoch finding above.
checked: Entry/exit/bootstrap/claim math, StrategyManager allocation/withdrawal and fee mint path, supported-token NAV, Converter refunds/output.

CLEARED
area: asset exits — user cancel/claim and ETH emergency chain are reachable while relevant modules are paused; paired-token gap is reported above.
checked: AMM, ExitQueue, Controller, StrategyManager, UniCL pause/unwind paths and all five receivers.

CLEARED
area: external trust/standards/transfer hooks — route tokens are bound and swaps use allowlisted adapters plus TWAP/oracle bounds; EVE is vanilla ERC-20 and whitelist gates entry, never exit. Pool authentication is reported; Oracle round semantics remain a LEAD.
checked: Oracle feeds/pairs, adapter router/factory, UniCL pool/callback, token transfer/approval sites, EIP-712 voucher binding/replay.

CLEARED
area: ordering/approval/time/enforceability — CEI/nonReentrant guards, callback flags, allowance clearing, queue transitions, deadlines/cooldowns were traced; exceptions are the queue expiry and retroactive fee findings.
checked: Every callback/receiver, keeper action branch, batch transition, pause/emergency/config boundary.

CLEARED
area: upgrade/diff/repo hygiene — snapshot review (no diff input); each UUPS implementation disables initializers, proxies initialize in constructor calldata, upgrades are ADMIN-gated, and storage gaps are present. The deferred ERC-20 recovery and broken deploy guard are reported.
checked: Five proxy implementations, deployment/finalization scripts, TODO/FIXME/deferred scan, Registry role/address lifecycle.

## Commands / tests

- Reads: `sed -n ... audits/2026-08-solidity-audit/bundle/{scope,profile,context,xray,source}.md`; complete Omega skill/reference reads.
- Validation: `git show 734df96a1391e95dd40843210997da0b9f3ab05e:PATH | nl -ba`; `git grep -n -E 'TODO|FIXME|XXX|HACK|deferred|future release|follow-up' 734df96 -- src script ':!test'`.
- Tests: not run; findings are deterministic source/call-chain proofs and the task requested no tests unless essential.

AGENT_STATUS: COMPLETE
