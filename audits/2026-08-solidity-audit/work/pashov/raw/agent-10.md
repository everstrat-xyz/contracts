# Reviewer 10 — numerical / invariant / boundary seams

Scope: complete ordered review of `agent-10-bundle.md` (9,604 lines), limited to the bundled local snapshot. Production source was not modified. No network, fork, wallet, transaction, or other reviewer output was used.

## Material reasoning markers

[Feynman: `StrategyKeeperExecutor` turns an observed controller redemption deficit into a withdrawal request. Setting `minWithdrawETH` to zero deliberately makes every positive deficit actionable, including a one-wei deficit.]

[Socratic: `StrategyKeeperExecutor.checkUpkeep` / `performUpkeep` — why can an action be reported as successfully performed when the downstream weighted allocator transfers zero and leaves every predicate unchanged?]

[Inversion: Assume the smallest expressly supported positive deficit, `shortfall = 1`, and two healthy strategies with positive equal weights and positive withdrawal capacity. Every independently rounded allocation becomes zero.]

[Feynman: `StrategyManager._withdrawFromStrategies` computes each leg as `requested * weight / cumulativeWeight`, caps that leg, and never assigns the division remainder to another eligible strategy.]

[Socratic: `StrategyManager._withdrawFromStrategies` — why is there no remainder/progress rule when `_amount > 0` and aggregate withdrawal capacity is nonzero?]

[Inversion: Choose weights 50/50 and request 1 wei: `1 * 50 / 100 = 0` for both legs. The loop makes no external withdrawal call and returns `totalWithdrawn = 0`.]

[Feynman: The deposit-side weighted loop has the same truncating arithmetic, but automated deposits are guarded by a strictly positive configurable threshold; the withdrawal side uniquely allows a zero threshold and is therefore reachable at the all-zero allocation boundary.]

[Socratic: `StrategyKeeperExecutor.setMinWithdrawETH` — why does the documented zero-threshold mode accept sub-allocation-unit deficits without ensuring that the selected action can make progress?]

[Inversion: Repeat the same upkeep after the successful transaction: controller balance and redemption need are unchanged, so the same highest-priority withdrawal action is selected again indefinitely absent unrelated state changes.]

[Feynman: AMM mint/burn conversions use floor division consistently with minimum-output checks; small value loss remains bounded to ordinary integer dust rather than creating an independently demonstrated stuck state.]

[Socratic: exact-output quote fee gross-up — why is floor used instead of ceiling? The configured input-slippage padding ordinarily absorbs the one-unit underestimate, and no material local failure was established.]

[Inversion: At tiny quoted inputs both fee gross-up and slippage padding can floor, but the resulting concern is standard rounding dust and is not reported as a defect here.]

[Feynman: Performance-fee conversion can round a positive ETH fee to zero EVE, but the bundled bootstrap supply/NAV relationship makes the smallest ordinary fee mint nonzero; no complete material local trace was established.]

[Socratic: `StrategyManager._mintPerformanceFeeEVE` — why is a zero mint allowed after strategies settle fees? This remains non-material without a reachable supply/NAV state producing consequential value loss.]

[Inversion: Push fee to one wei and NAV per EVE above one ETH; the quotient can become zero, but that state and a non-dust consequence were not established from the bundled normal lifecycle.]

## CONFIRMED FINDING R10-01 — a positive withdrawal shortfall can round to zero on every strategy and permanently repeat

- **Contract / functions:** `StrategyKeeperExecutor.checkUpkeep`, `StrategyKeeperExecutor.performUpkeep`, `Controller.withdrawFromStrategies`, `StrategyManager._withdrawFromStrategies`.
- **Seam / lenses:** minimum boundary × weighted fixed-point truncation × progress/liveness invariant.
- **bug_class:** integer-rounding-induced no-progress state transition.
- **group_key:** `strategy-weighted-withdrawal-zero-progress`.
- **Root cause:** each strategy independently receives `amount * weight / cumulativeWeight`; all discarded remainders are lost, and neither the manager nor keeper requires a positive actual withdrawal when the request and aggregate capacity are positive.
- **Ordinary local sequence:**
  1. An admin selects the explicitly supported `minWithdrawETH = 0` mode.
  2. Two unpaused strategies are configured at weights 50 and 50, and each reports at least 1 wei of withdrawal capacity.
  3. A pending redemption needs exactly one wei more than the controller currently holds.
  4. `checkUpkeep` observes `shortfall = 1`, `1 >= 0`, and nonzero aggregate capacity, and returns `WithdrawShortfall`.
  5. `performUpkeep` calls the controller and manager with `_amount = 1`.
  6. The manager computes `1 * 50 / 100 = 0` for strategy A and the same for B. Both zero legs are skipped, so `totalWithdrawn = 0` and the call returns successfully.
  7. No relevant balance or queue state changed. The next check selects the identical action again.
- **Concrete worked evidence:** requested `1`; weights `[50, 50]`; capacities `[>=1, >=1]`; calculated legs `[0, 0]`; actual withdrawn `0`; remaining shortfall `1`.
- **Expected:** when a positive shortfall is deemed actionable and aggregate capacity is positive, execution should either withdraw a positive amount or explicitly signal that no progress is possible.
- **Actual:** execution succeeds and emits the upkeep action while withdrawing zero; the exact predicate that selected it remains true.
- **Consequence:** the highest-priority upkeep branch can repeatedly consume executions without advancing the pending redemption, starving later keeper actions and leaving the redemption blocked until unrelated state changes.
- **Smallest correction:** make weighted withdrawal remainder-aware. Track the remaining request and capacity, and assign residual units to eligible strategies (for example, give the final eligible strategy the remaining capped amount), guaranteeing `totalWithdrawn > 0` whenever `_amount > 0` and aggregate capacity is positive. As a defensive invariant, have the keeper/controller reject a zero-progress result instead of reporting successful execution.
- **Evidence method:** deterministic source-level arithmetic and state-transition trace. No candidate test was necessary or created.

## LEADS

- **LEAD R10-L1 — exact-output fee gross-up rounds down:** `UniswapV3Strategy` quote math uses floor division where a mathematical maximum-input quote normally requires ceiling. At very small token-unit amounts, subsequent slippage multiplication may also floor and a swap could revert. The bundled normal amount ranges and a material local consequence were not established; retained as a lead only.
- **LEAD R10-L2 — performance fee may settle before a zero EVE mint:** a positive `_totalFeeETH` can theoretically produce `evesToMint == 0` for an extreme supply/NAV ratio after strategies have advanced their charged-fee accounting. A reachable consequential lifecycle state was not established; retained as a lead only.

## CLEARED_AREAS

- `Math.convertAssets`, `mulDiv`, relative comparisons, base/premium price, mint and burn conversions: checked zero values, exact boundaries, scale order, and ordinary rounding direction; no material defect established beyond documented/floor dust.
- AMM bootstrap, enter, exit, spread, and minimum-output paths: checked zero input, minimum thresholds, exact reserve boundary, supply/NAV denominators, and inverse conversions.
- Exit queue request, escape, cancellation, controller processing, pagination, and claim accounting: checked exact delay boundary, cursor advancement, batch limits, partial processing, and pending-liability arithmetic.
- Controller allocation/reserve calculations and emergency movement: checked exact reserve equality, excess/shortfall subtraction guards, and state accounting order.
- Strategy deposit weighting: checked the paired floor-allocation behavior; automated deposits retain a strictly positive minimum threshold, so the demonstrated one-unit persistent keeper loop does not transfer to that branch.
- Strategy withdrawal cap handling and aggregate capacity: checked cap boundaries and paused/zero-capacity branches; aside from R10-01, no separate material mechanism was established.
- Performance fee aggregation and EVE conversion: checked zero fee, fee near NAV, denominator guards, and proportional dilution; only R10-L2 remains incomplete.
- Uniswap V3 oracle conversion, range construction, liquidity sizing, swap thresholds, fee settlement, and rebalance gates: checked token-decimal scaling, negative ticks, threshold equality, and exact-input/output rounding; only R10-L1 remains incomplete.
- Governance setters and numeric limits: checked inclusive/exclusive bounds, zero-enabled versus zero-forbidden thresholds, basis-point ceilings, weight sums, and delay/window ranges.

## AGENT_STATUS

AGENT_STATUS: COMPLETE

Confirmed findings: 1
Leads: 2
Candidate tests created/run: 0 (source-level proof was complete)
