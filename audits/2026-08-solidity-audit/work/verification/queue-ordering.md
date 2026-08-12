# Verification: ExitQueue ordering can obstruct affordable redemptions

VERDICT: CONFIRMED

SEVERITY: Low

CONFIDENCE: High for the ordering and keeper-liveness mechanism; medium for real-world frequency because material delay requires partial liquidity and favorable attacker ordering.

BASE: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e` only. Production sources/interfaces and pre-existing base tests were read through `git show`; no prior audit output, audit test, history, post-base source, network, live system, or production edit was used.

## Confirmed behavior

`ExitQueue` stores each batch's unprocessed users in OpenZeppelin `EnumerableSet.AddressSet`. Requests append through `add` (`ExitQueue.sol:195-223`), while cancellation and settlement remove through `remove` (`ExitQueue.sol:228-268`). The pinned OpenZeppelin implementation moves the last element into the removed element's slot before popping (`EnumerableSet.sol:86-109`) and expressly disclaims stable ordering (`:148-152`). Therefore, removing index zero from `[A, V1, V2, L]` deterministically produces `[L, V1, V2]`.

The ordering is economically operative. `QueueKeeperExecutor._affordableRequests` reads indices `[0, cap)`, accumulates their costs, and breaks on the first request exceeding the Controller balance (`QueueKeeperExecutor.sol:336-363`). `performUpkeep` then processes only `[0, count)` (`:209-215`). A newly promoted large request can consequently make `count == 0` even though a displaced older request is individually affordable.

This is not only a hypothetical FIFO cosmetic issue: the regression gives the Controller exactly the older victim's settlement cost, observes `affordableRequests(batch) == 0` and `checkUpkeep == false`, then successfully settles that victim through the role-gated single-user `Controller.processRequest` with the same balance (`Controller.sol:362-368,435-448`). Thus useful redemption liquidity exists but the normal queue executor cannot deploy it.

## Attacker control and repeatability

An attacker can place a small request early in an unpriced batch, allow older victims to queue behind it, place a large request last, then cancel the early request before pricing. Unpriced requests are immediately cancellable: `AMM.cancelRedemption` closes the request and returns all escrowed EVE (`AMM.sol:188-193`), and `ExitQueue` blocks cancellation only during the priced commitment window (`ExitQueue.sol:279-297`). The cancellation swap-promotes the attacker's large tail to index zero.

Exact last-position control is timing-dependent if unrelated requests arrive later. Coordinated Sybil requesters, consecutive/bundled transactions, or multiple tail positions improve control. The large request must be backed by the attacker's EVE and becomes non-cancellable for up to three days once priced, so repeat attacks require material capital and repeated positioning; they are not free.

Even without adversarial cancellation, ordinary processing has the same effect: processing the first request of `[V1, V2, L]` removes V1 and promotes later requester L ahead of V2. The second regression proves the resulting large head blocks V2 despite exact V2 liquidity.

## FIFO intent

No source/interface statement promises strict per-user FIFO, and `EnumerableSet` itself promises no order. However, the executor explicitly selects the “oldest live priced batch” and its “longest affordable prefix” (`QueueKeeperExecutor.sol:23-31`; `IQueueKeeperExecutor.sol:134-141`). Those prefix semantics make stable per-batch ordering an implicit fairness/liveness dependency. Accordingly, strict FIFO specification is ambiguous, but later-user promotion and automation head-of-line blocking are concrete regardless of naming.

## Material impact and bounds

The impact is delayed redemption and unfair reordering, not theft or permanent loss. It becomes material when Controller liquidity (plus immediately withdrawable strategy liquidity) can cover one or more displaced small requests but cannot cover the promoted large request. A later/Sybil requester can then postpone older users while those users' EVE remains escrowed.

The strategy keeper substantially mitigates normal solvent operation: it estimates pending priced-batch costs and attempts to withdraw the full shortfall (`StrategyKeeperExecutor.sol:174-182,494-540`). If strategies can supply the whole liability, the large request is funded and the block disappears. The issue persists under partial/temporarily illiquid strategies, failed/fee-reduced withdrawals, or before that liquidity arrives.

Delay is bounded: after `MAX_BATCH_PROCESSING_TIME = 3 days`, remaining users can cancel through the escape hatch and the queue keeper skips the batch (`ExitQueue.sol:27,253-268`; `QueueKeeperExecutor.sol:38-42`). A privileged keeper may also process an affordable victim directly. These bounds, attacker capital lock, and lack of loss calibrate severity to Low.

## Regression

Created `contracts/test/audit/candidates/verification/QueueOrdering.t.sol` without modifying production code.

Attempt 1/3:

`FOUNDRY_OUT=/private/tmp/queue-ordering-out FOUNDRY_CACHE_PATH=/private/tmp/queue-ordering-cache /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/QueueOrdering.t.sol -vvv`

Result: PASS — 2 passed, 0 failed, 0 skipped. The non-fatal signature-cache warning was caused by sandbox write denial outside the isolated build/cache paths.

Tests:

- `test_AttackerCancellationPromotesLargeTailAndBlocksAffordableOlderRequest`
- `test_ProcessingHeadPromotesLastRequesterAheadOfOlderUser`

## Recommendation

If request fairness is intended, replace `EnumerableSet` enumeration as queue order with an insertion-stable FIFO structure (for example, monotonic request IDs plus a head cursor/tombstones), and make keeper selection consume that order. Independently consider a bounded selection policy that can use available liquidity for later affordable entries without letting one oversized request force `count == 0`; document the chosen FIFO-versus-throughput tradeoff.

AGENT_STATUS: COMPLETE
