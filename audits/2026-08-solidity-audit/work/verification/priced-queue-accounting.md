# Verification: priced queue liabilities distort active-share accounting

VERDICT: CONFIRMED

SEVERITY: Medium

CONFIDENCE: High. The immutable state transitions, cohort arithmetic, and a full AMM/Controller/ExitQueue conservation test all agree; the only material uncertainty is how often large NAV changes and user actions interleave before keeper processing in production.

BASE: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`. Only immutable production source, interfaces, and base tests were read through `git show`. No audit output, existing audit test, history, network, live system, production edit, or commit was used.

## Confirmed accounting state

When immediate ETH is unavailable, `AMM.exit` transfers the user's EVE to AMM and records the request; it does not burn EVE (`AMM.sol:168-181`). `ExitQueue.priceBatch` then fixes one `finalEvePrice` for the nonempty batch without moving assets or tokens (`ExitQueue.sol:173-188`). Controller obtains that price as current `NAV / totalSupply` (`Controller.sol:331-336`).

Consequently, immediately after pricing:

- queued EVE remains in `EVE.totalSupply` and sits escrowed on AMM;
- ETH backing the request remains in Controller/strategies/AMM free balance and remains in NAV;
- each in-tolerance request's eventual ETH amount is fixed as `queuedTokens * finalEvePrice`;
- the queued tokens are burned and fixed ETH leaves NAV only during `processRedemption` (`AMM.sol:215-241`).

Keeping both sides is ratio-neutral at the pricing instant. It is not neutral after NAV changes while the liability stays fixed.

## Exact cohort arithmetic

At pricing let total NAV be `N`, total supply `S`, in-tolerance queued shares `Q`, and fixed liability `L = Q*N/S`. Active supply is `A = S-Q`. After a NAV delta `G`, raw AMM base price is:

`P_raw = (N+G)/S`.

Because queued users are owed fixed `L`, active holders actually own the residual, whose price is:

`P_active = (N+G-L)/(S-Q) = N/S + G/(S-Q)`.

For any positive `G`, `P_raw < P_active`: active exits burn too many shares, and entries mint too many. For negative `G`, the direction reverses, allowing early active exits to externalize more of the loss onto remaining active holders; if NAV falls below `L`, the fixed queue is undercollateralized.

For a deposit `D` at connector-weight fraction `c`, implementation minting is `X = D*S*c/(N+G)`. Correct active-cohort pricing would mint `X* = D*(S-Q)*c/(N+G-L)`. A positive gain always gives `X > X*`. The entrant's post-processing base claim exceeds its deposit when:

`G * (Q - S*(1-c)) > N*(S-Q)*(1-c)`.

Thus direct profit at the default `c=0.5` requires `Q/S > 50%` plus sufficient gain, but misallocation exists for every nonzero delta even below that profit threshold.

## Regression trace and conservation

Created `test/audit/candidates/verification/PricedQueueAccounting.t.sol`; no production changes. It uses the real Registry roles, Whitelist, AMM, Controller, StrategyManager, Oracle, ExitQueue, and EVE flow at the default 50% connector weight.

1. Bootstrap: `N=100 ETH`, `S=100,000 EVE` (99,999 holder plus one dead EVE); base price is 0.001 ETH/EVE.
2. Queue: 80,000 EVE requests 80 ETH with 100% tolerance. Pricing fixes `L=80 ETH` at 0.001. Supply remains 100,000, AMM escrows 80,000 EVE, and all 100 ETH remains NAV.
3. Gain: 80 ETH is transferred to AMM after pricing. Raw price becomes 0.0018, while the 20,000 active shares own `180-80=100 ETH`, or 0.005 each.
4. Pre-processing active exit: a 10,000-EVE holder receives 18 ETH and burns all shares at raw price, although its residual-cohort value is 50 ETH. The missing 32 ETH remains for other active cohorts.
5. Pre-processing entry: with raw NAV 162 ETH and raw supply 90,000, a 10 ETH entrant pays the 0.0036 premium price and receives 2,777.777777777777777777 EVE. Active-residual premium pricing would have used 82 ETH / (10,000 * 0.5) = 0.0164 ETH/EVE.
6. Processing pays/credits the queued cohort exactly 80 ETH and burns its 80,000 EVE. After claim, active NAV is 92 ETH and active supply is 12,777.777777777777777777 EVE; base price is approximately 0.0072.
7. The 10 ETH entrant now owns approximately 20 ETH. The incumbent holder plus dead share owns approximately 72 ETH.

Exact asset conservation:

`80 queued payout + 18 active-exit payout + 92 remaining NAV = 190 ETH`

`190 ETH = 100 initial NAV + 80 gain + 10 entrant deposit`.

No value disappears: approximately 10 ETH moves to the entrant, the premature active exiter forfeits 32 ETH relative to its fixed-liability residual value, and the remaining incumbent ends with 72 ETH. The queued cohort receives its fixed 80 ETH and does not share the post-pricing gain.

Pinned offline command:

`FOUNDRY_OUT=/private/tmp/priced-queue-accounting-out FOUNDRY_CACHE_PATH=/private/tmp/priced-queue-accounting-cache /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/PricedQueueAccounting.t.sol -vvv`

Attempt 1/3: PASS — 1 passed, 0 failed, 0 skipped. The sole warning was Foundry's denied attempt to flush its global signature cache outside the isolated paths.

## Slippage, cancellation, and timing bounds

- A request is paid only if `finalEvePrice` remains within its requested tolerance; otherwise processing returns its EVE and costs zero ETH (`ExitQueue.sol:228-247`; `Controller.sol:435-448`). The regression uses 100% tolerance. Post-pricing NAV changes do not update `finalEvePrice` or the slippage comparison.
- Users may cancel freely before pricing. Once priced, requests cannot cancel for `MAX_BATCH_PROCESSING_TIME = 3 days`; afterward the escape hatch returns their EVE (`ExitQueue.sol:27,253-268,279-297`). Cancellation removes that fixed liability and makes the shares active again.
- Processing ends the distortion for the shares it burns. However, automated pricing and processing are separate upkeep actions (`QueueKeeperExecutor.sol:192-215`), so they cannot be atomic and a transaction/MEV window always exists; insufficient Controller liquidity can extend it up to the three-day commitment window.
- Entry requires whitelist access. A profitable entrant needs an exogenous gain or protocol appreciation; self-funding a large gain is generally uneconomic. Strategy NAV, Oracle-valued holdings, donations, fees, or losses can nevertheless change without the queued users changing their fixed claim.

## Severity rationale

Medium is appropriate because ordinary NAV movement plus allowed user actions can redistribute material value among users, and the regression produces a 10 ETH entrant gain with exact conservation. It requires a priced-but-unprocessed window, a meaningful queue fraction/NAV delta, whitelist access for entry, and (for direct entrant profit under `c<1`) the threshold above. Fast keeper processing and the three-day escape bound reduce exposure, keeping it below High.

## Recommendation

At pricing, segregate each positive fixed liability from live NAV and exclude the corresponding queued shares from pricing supply. Maintain `activeNAV = totalNAV - reservedPricedLiabilities` and `activeSupply = totalSupply - escrowedInToleranceQueuedShares` for all AMM enter/exit prices, updating both atomically on processing, slippage return, and escape cancellation. Alternatively, block active enters/exits while any priced batch remains unresolved, but this has a larger liveness cost. Add invariant tests that gains/losses after pricing accrue only to active supply and that cohort value conserves across partial processing.

AGENT_STATUS: COMPLETE
