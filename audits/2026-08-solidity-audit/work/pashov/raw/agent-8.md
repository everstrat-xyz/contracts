# Pashov reviewer 8 — paired-operation and branch-symmetry review

Scope: immutable local snapshot only. The 9,635-line reviewer bundle was read completely and in order. No reviewer or methodology output was read. Production source was not modified.

## Material reasoning markers

[Feynman: QueueKeeperExecutor.checkUpkeep] This function looks at the live queue and recommends one currently useful action. It deliberately treats a priced batch older than the processing commitment as finished keeper work and moves past it so remaining users can cancel.

[Feynman: QueueKeeperExecutor.performUpkeep] This function receives a previously suggested action, recomputes whether that same action is still useful, and executes it. Its stated contract is that stale input is rejected.

[Socratic: src/contracts/automation/QueueKeeperExecutor.sol:207 — why?] Why does the processing branch recompute affordability but not recompute the same post-commitment expiry predicate that caused `checkUpkeep` to skip the batch?

[Inversion: QueueKeeperExecutor.performUpkeep] (1) Record `ProcessRequests` one second before expiry and submit it one second after expiry; (2) let a user become cancellation-eligible before replaying old data; (3) replay a batch identifier that remains priced and affordable but is no longer inside the checker’s live processing set.

[Feynman: ExitQueue.closeRequest/pullRequest] Closing gives queued tokens back when a request is still cancellable; pulling permanently marks it processed and chooses either token return for slippage or ETH settlement. After the commitment expires, the first path becomes available, so a late second path changes the user’s available outcome.

[Socratic: src/contracts/ExitQueue.sol:228 — why?] Why does `closeRequest` enforce the commitment boundary while `pullRequest` contains no matching upper-time boundary, even though keeper documentation says post-commitment users must close?

[Inversion: ExitQueue request finalization] (1) Process at the exact boundary, which remains allowed; (2) process at boundary plus one, which should be cancellation-only; (3) race a cancellation with previously valid keeper data and observe which terminal state wins.

[Feynman: StrategyKeeperExecutor.checkUpkeep/performUpkeep] The checker recommends an action only when all action-specific predicates hold; the performer is supposed to verify those predicates again because conditions can change between simulation and execution.

[Socratic: src/contracts/automation/StrategyKeeperExecutor.sol:237 — why?] Why is `totalMaxWithdrawal > 0` required while recommending a withdrawal but absent while executing the same action?

[Inversion: StrategyKeeperExecutor.performUpkeep] (1) Make withdrawal capacity fall from one ether to zero after checking; (2) remove the final strategy after a sync recommendation; (3) pause or cool down the only deposit-capable strategy after a deposit recommendation.

[Feynman: Converter exact-input/exact-output pair] Exact-input spends a fixed input and measures the new output; exact-output produces a fixed output, measures input actually spent, refunds the remainder, and verifies that newly produced output covers the payout.

[Inversion: Converter swap pair] (1) Pre-seed input/output balances and make an adapter misreport; (2) return malformed adapter data; (3) spend only part of the exact-output allowance. Balance deltas, returndata length checks, output checks, and refunds preserve the intended pair.

[Feynman: UniswapV3ConverterAdapter direction pair] Both public directions accept a forward path; exact-output reverses that path only at the router boundary. Quotes use the same TWAP/oracle comparison and mirror the fee adjustment onto output versus input.

[Inversion: UniswapV3ConverterAdapter direction pair] (1) Supply a multi-hop route; (2) swap endpoint order in the reverse route; (3) use a pool whose TWAP cannot be observed. Route checks, shared decoding, and pool/observe failures reject these cases.

[Feynman: UniCLStrat inventory pair] One branch exchanges excess WETH for the paired token and the other exchanges paired-token value back to WETH. Exact-output withdrawal sourcing mirrors the quote, oracle bound, slippage cap, and balance-cap behavior of exact-input balancing.

[Socratic: src/contracts/strategies/UniCLStrat.sol:1086 — why?] Why choose the oracle conversion branch from a decoded endpoint rather than assuming path bytes? Because route encoding is adapter-specific; the endpoint helper keeps both configured directions symmetric.

[Inversion: UniCLStrat route pair] (1) Configure two forward paths; (2) reverse only one token pair; (3) change adapters while retaining incompatible bytes. `_validateRouteConfig` checks both paths and both endpoint directions before storage changes.

[Feynman: StrategyManager batch/direct operation pairs] Batch operations distribute across eligible strategies and tolerate individual failures; direct operations select one registered strategy and fail strictly. Both return unused deposit ETH and measure actual withdrawal delivery.

[Inversion: StrategyManager operation variants] (1) Give one strategy zero weight; (2) make one strategy revert; (3) withdraw and immediately redeposit. Weight skipping, partial-success handling, and the shared cooldown cover the intended variant differences.

[Feynman: Oracle forward/inverse conversion] Conversion first uses the requested directed pair, then its inverse, then a two-USD-feed cross-rate. Token removal erases both outbound and inbound pair registrations.

[Inversion: Oracle pair lifecycle] (1) Remove a token with inbound pairs; (2) ask for the inverse when only one direction exists; (3) return a future or stale timestamp. Cleanup, inverse division, and feed validation preserve the lifecycle.

[Feynman: AMM redemption branches] An immediate exit burns tokens and pays free ETH now; a queued exit escrows tokens, then either cancellation returns them or processing burns them and records claimable ETH.

[Feynman: Registry and Whitelist paired administration] Single and batch registry operations share their validation and bookkeeping; whitelist removal sets a ban while re-addition clears both the ban and prior whitelist state.

## Confirmed defect

FINDING | contract: QueueKeeperExecutor | function: performUpkeep | bug_class: stale-perform-data-expiry-bypass | group_key: QueueKeeperExecutor | performUpkeep | stale-perform-data-expiry-bypass
pair_or_branch: `checkUpkeep(ProcessRequests)` vs `performUpkeep(ProcessRequests)`, with `ExitQueue.closeRequest` vs `pullRequest` terminalization
asymmetry: `checkUpkeep` skips batches for which `_isBatchSkippable` is true, including `block.timestamp > pricedAt + MAX_BATCH_PROCESSING_TIME` (`QueueKeeperExecutor.sol:157-162,298-305`), but `performUpkeep` only requires `_affordableRequests(...) > 0` (`:207-213`); that helper does not check expiry, and `ExitQueue.pullRequest` also has no expiry check.
path: ordinary automation check before expiry -> encoded `ProcessRequests(batchId)` -> transaction delayed past expiry -> user becomes eligible for `AMM.cancelRedemption` -> forwarder submits the old data -> `performUpkeep` -> `Controller.processRequests` -> `AMM.processRedemption` -> `ExitQueue.pullRequest` marks the request processed.
proof: Local regression creates batch 1 with a 1 ETH redemption. Before expiry, `checkUpkeep` returns `ProcessRequests(1)`. After warping to `pricedAt + MAX_BATCH_PROCESSING_TIME + 1`, `requestCanBeClosed(1,user)` is true and a fresh check returns `AdvanceCursor(2)`. Submitting the saved data nevertheless succeeds; afterwards the request is absent from `unprocessedUsers`, `requestCanBeClosed` is false, and the user has a positive claimable ETH balance.
expected: Once the commitment window is past, stale processing data is rejected and the request remains available to the user’s escape-hatch cancellation path.
actual: A payload that is no longer emitted by `checkUpkeep` still processes the request after expiry.
consequence: Delayed but formerly valid automation data can replace the protocol’s documented post-commitment cancellation outcome with forced redemption settlement, defeating the intended terminal-state handoff at the expiry boundary.
description: The performer does not mirror the checker’s batch-expiry eligibility rule.
fix: Share one process-eligibility helper between check and perform, or at minimum reject `ProcessRequests` when `_isBatchSkippable(queue, batchId)` is true before computing affordability.

## Leads

LEAD | contract: StrategyKeeperExecutor | function: performUpkeep | bug_class: incomplete-check-execute-parity | group_key: StrategyKeeperExecutor | performUpkeep | incomplete-check-execute-parity
code_smells: The checker requires `_totalMaxWithdrawal(strategyManager_) > 0` for `WithdrawShortfall` and `strategyCount() > 0` for `Sync`, while the matching performer branches omit those predicates. A once-valid payload can therefore complete as a zero-withdrawal or zero-strategy operation after intervening state changes.
description: The parity defect is real, but this pass did not establish a material protocol-state consequence beyond misleading/no-op upkeep and a delayed future sync, so it remains a LEAD.

## Executable evidence

- Candidate: `test/audit/candidates/pashov/Agent08.t.sol`
- Command: `FOUNDRY_OUT=out-pashov-agent-08 FOUNDRY_CACHE_PATH=cache-pashov-agent-08 forge test --match-path test/audit/candidates/pashov/Agent08.t.sol`
- First invocation: compile failed because the new candidate imports were one directory level short; all candidate imports were corrected with `apply_patch` before validation continued.
- Final result: compiler successful; 1 test passed, 0 failed, 0 skipped. Foundry emitted only a non-fatal local signature-cache permission warning after the pass.
- Production source changes: none.

## CLEARED_AREAS

- `Converter`: exact-input/exact-output deadline, adapter, route, balance-delta, minimum/maximum, refund, and payout symmetry; wrap/unwrap no-op behavior.
- `UniswapV3ConverterAdapter` and `UniswapV3Path`: forward/reverse route handling, single-hop validation, quote/swap direction pairing, allowance clearing, and TWAP/oracle deviation checks.
- `UniCLStrat`: WETH/paired-token route endpoint pairing, exact-input/exact-output oracle bounds, deposit/withdraw accounting, pause/unpause allowance lifecycle, main/alternate position removal, and pending/settled LP-fee accounting.
- `ExitQueue`: `requestCanBeClosed` and `_validateRequestCanBeClosed` use the same membership, processed-state, and exact-boundary rule; the defect is confined to the processing-side missing expiry guard described above.
- `AMM`: `enter`/`enterWithInvite`, immediate/queued exits, cancel/process outcomes, and claim storage updates.
- `Controller`/`StrategyManager`: range/all/direct forwarding, deposit refunds, withdrawal balance deltas, cooldown writes, strict-direct versus best-effort-batch behavior, rebalance/sync variants, strategy add/remove/force-remove cleanup, and fee-harvest variants.
- `Oracle`: token-to-USD/USD-to-token conversion, direct/inverted/fallback pair selection, feed add/update/remove, and inbound/outbound cleanup.
- `Registry`/`Whitelist`: single/batch registration and role operations, grant/revoke bookkeeping, whitelist/ban reversal, signer add/remove, and intentional pause/disable asymmetries.
- `QueueKeeperExecutor`: price and cursor branches, affordability prefix accounting, cursor advancement, pause checks, and exact expiry boundary; only stale ProcessRequests execution is uncleared.
- `StrategyKeeperExecutor`: action priority, deposit capacity/cooldown mirror, pending-redemption cost mirror, exit-liquidity/excess arithmetic, and harvest gating, subject to the explicit LEAD above.

AGENT_STATUS: COMPLETE — full bundle read; 1 confirmed defect, 1 lead, 1 isolated passing regression; production source unchanged.
