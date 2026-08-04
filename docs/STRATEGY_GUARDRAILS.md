# Strategy Guardrail Standard

Issue: [#244](https://github.com/Guide-DAO-Organization/hackerhouse/issues/244).
Companion to [#241](https://github.com/Guide-DAO-Organization/hackerhouse/issues/241)
(AMM deviation guard removal).

With the AMM base-price deviation guard removed (#241), the **strategy layer is
the sole on-chain defense boundary** against NAV manipulation (flash loans,
pool manipulation, oracle attacks). The AMM settles `enter()`/`exit()` at the
current NAV-backed price without an on-chain band check, so every strategy
registered on the StrategyManager must carry its own manipulation defenses,
and the protocol must limit the blast radius when one doesn't.

This document is the normative standard:

1. **Mandatory guardrails** — what every strategy must implement before deployment
2. **Pre-deployment audit checklist** — verifiable steps, gate for `addStrategy`
3. **Governance-attack mitigation analysis** — timelock + caps + EVE governance
4. **Monitoring requirements** — what off-chain monitoring must track per strategy
5. **Incident response** — what to do when a strategy's guardrails fail

All "implemented" claims below are grounded in `smart-contracts/src/` at the
revision this file was committed with. Where the standard cites a mechanism it
cites the enforcing code. **GAP** means no on-chain enforcement exists today.

Relationship to the runbook: operational response flows (pause chains, freeze
procedures, event/selector catalogs) live in
[`FREEZE_RUNBOOK.md`](./FREEZE_RUNBOOK.md); this standard *references* them
instead of duplicating them.

---

## 1. Mandatory guardrails (per strategy)

Every strategy deployed to production MUST implement all four mandatory
guardrails. A strategy that cannot demonstrate every row of the table below
MUST NOT be registered via `StrategyManager.addStrategy()`.

### 1.1 Implementation status — UniCLStrat (reference implementation)

| Guardrail | Status | Enforcing mechanism (UniCLStrat) | Parameters / values |
|---|---|---|---|
| **TWAP calm check** (manipulation-resistant oracle; reject ops when spot deviates from TWAP) | **Implemented** | `_isCalm()` gates `deposit()`, `investIdleETH()`, `rebalance()`, and liquidity re-adds in `withdraw()`: spot tick **and** short-TWAP tick must both sit within ±`maxTickDeviation` of the long TWAP tick. NAV itself is TWAP-based (`_twapSqrtPrice()`), never spot. | `twapInterval` ≥ `MIN_TWAP_INTERVAL = 1800` (30 min) — enforced in constructor and `setTwapInterval()`; `shortTwapInterval` ≥ `MIN_SHORT_TWAP_INTERVAL = 60`; `maxTickDeviation` > 0 (constructor + `setMaxTickDeviation()`) |
| **Slippage protection** (`minAmountOut` on all swaps and liquidity operations) | **Implemented** | All swaps route through the shared Converter with a quote-derived `minAmountOut` (exact-input) / `maxAmountIn` (exact-output), cross-checked against symmetric Chainlink floor/ceiling (`_enforceOracleBounds`). Liquidity mints are sized from pool state in the same transaction and only execute inside the calm band. Note: the forwarded per-swap deadline (`block.timestamp + SWAP_DEADLINE_OFFSET`) is **not** a defense layer — it only satisfies the router interface (see `_swapViaRouteExactAmountIn` NatSpec). | `swapSlippageBps` default `DEFAULT_SWAP_SLIPPAGE_BPS = 100` (1%), hard-capped at `MAX_SWAP_SLIPPAGE_BPS = 200` (2%) in `_setSwapSlippageBps`; `MAX_QUOTE_DEVIATION_BPS = 200` (constant) |
| **Tick / range bounds** (positions bounded against adversarial range manipulation) | **Implemented** | Positions are derived deterministically: `_setTicks()` places `positionMain` around the current tick via `TickUtils.baseTicks(_tick, positionWidth * tickSpacing, tickSpacing)`; `positionAlt` is a single-sided band adjacent to the current tick. `_positionIsValid()` enforces `tickLower < tickUpper` within `[TickMath.MIN_TICK, TickMath.MAX_TICK]`. | `positionWidth` > 0 (constructor `_validatePositiveInt24` + `setPositionWidth()`); effective width = `positionWidth × tickSpacing` |
| **Max single-deposit cap** (per-transaction deposit limit relative to strategy TVL) | **GAP — not implemented as specified** | `deposit()` enforces only `_depositAmount <= _maxDeposit()`, where `_maxDeposit() = maxTotalNAV − navInETH()` (headroom to an **absolute** cap). A single transaction may therefore deposit up to the entire remaining headroom regardless of current TVL — there is no per-transaction cap expressed as a fraction of strategy TVL. `maxTotalNAV` bounds total exposure but not deposit velocity. | `maxTotalNAV` (absolute NAV ceiling; `setMaxTotalNAV()`, ADMIN_ROLE) |

### 1.2 Recommended guardrails

| Guardrail | Status (UniCLStrat / protocol) | Notes |
|---|---|---|
| **Per-strategy TVL cap** | **Implemented at strategy level** (`maxTotalNAV`); **GAP at StrategyManager level** — see §3.4 for the protocol-level design | The strategy-local cap only helps while the strategy itself is honest; it is not enforceable against a malicious strategy (its own `navInETH()`/`maxDeposit()` are self-reported). Protocol-level enforcement is specified in §3.4 (implementation tracked in #231 L-3). |
| **Cooldown / rate limiting** | **GAP — not on this branch** | Keeper-cycling cooldown (PLM-6 / #195) is developed on a separate, unmerged branch. Do not assume it exists. Mitigation until then: calm-check gating + off-chain cadence monitoring (§4). |
| **Emergency exit** (unwinding path when health degrades) | **Implemented** | `pause()` (ADMIN or SECURITY; best-effort pool unwind via try/catch self-call, emits `LiquidityUnwindSkipped` on pool failure, revokes Converter allowances) → `emergencyExit()` (requires pause; unwraps WETH directly via `weth.withdraw()`, sends ETH first then best-effort `trySafeTransfer` of paired token — emits `PairedTokenTransferSkipped` on blacklist/pause/false-return failure; never touches pool/Converter/Oracle). |
| **Health factor** (continuous on-chain metric) | **Implemented** | `isHealthy()`: false when paused, not calm, ticks uninitialized, price outside `positionMain`, or center-tick drift beyond `rebalanceTickThreshold`. Consumed by StrategyManager batch paths (deposit inclusion, rebalance triggering) and by off-chain monitoring (§4). |

---

## 2. Pre-deployment audit checklist

No strategy may be added via `StrategyManager.addStrategy()` without a
completed copy of this checklist attached to the timelock proposal. Each item
is verifiable on-chain or in the repo's test suite.

### 2.1 Code and parameter verification

- [ ] **Calm check present and gated**: every external function that deploys or
  moves capital reverts (or skips) when the manipulation check fails. For
  UniCL-style strategies: `deposit`/`rebalance`/`investIdleETH` revert
  `UniCLStratNotCalm`.
- [ ] **TWAP floors respected**: long TWAP window ≥ 1800 s, short TWAP window ≥
  60 s, enforced in the constructor **and** in every setter (`setTwapInterval`
  / `setShortTwapInterval` revert below the floors). For non-UniCL strategies:
  an equivalent manipulation-resistant price source with a documented
  bias-resistance argument.
- [ ] **TWAP cardinality check**: `pool.slot0().observationCardinality` covers
  the configured `twapInterval` at the pool's trade cadence. If it does not,
  `navInETH()` reverts (`UniCLStratPoolTWAPNotAvailable`) and **freezes
  protocol-wide pricing** — grow the buffer via
  `pool.increaseObservationCardinalityNext(n)` *before* `addStrategy()`
  (FREEZE_RUNBOOK §4.2).
- [ ] **Slippage params within caps**: slippage tolerance > 0 and ≤ the
  contract's hard cap (UniCLStrat: ≤ 200 bps); every swap path applies
  `minAmountOut`/`maxAmountIn`; quote-vs-oracle bounds enforced
  (`MAX_QUOTE_DEVIATION_BPS`), with the bound exceeding the route's pool fee
  tier.
- [ ] **Tick/range bounds**: position width is positive, a multiple of the
  pool's `tickSpacing` semantics, and re-derived from the *current* tick on
  rebalance — not attacker-influenceable calldata.
- [ ] **Blast-radius cap configured**: `maxTotalNAV` (or equivalent) is set to
  the intended maximum exposure for this strategy — not `type(uint256).max`.
- [ ] **Routes validated**: swap adapter is whitelisted on the Converter and
  route bytes validate against `Converter.validateRoute` / `routeTokens`
  (UniCLStrat checks this in the constructor and `setRouteConfig`).
- [ ] **Access control**: `deposit`/`withdraw`/`rebalance`/`sync` callable only
  by the registered StrategyManager; configuration and unpause behind
  `ADMIN_ROLE` (48h timelock); `pause`/`emergencyExit` behind `ADMIN_ROLE` or
  `SECURITY_ROLE`.
- [ ] **NAV invariant**: `navInETH()` includes *all* economically responsible
  funds (deployed capital + idle balances), is manipulation-resistant
  (TWAP-based valuation, not spot), and either succeeds or fails loudly — it
  must never silently under-report (a revert freezes pricing; a lie drains
  backing).

### 2.2 PoC manipulation tests (must exist and pass)

- [ ] **Flash-loan calm-check PoC** (fork or mock pool): a same-block tick skew
  beyond `maxTickDeviation` makes `deposit()`/`rebalance()` revert
  (`UniCLStratNotCalm`) and makes `maxDeposit()` return 0.
- [ ] **Quote-manipulation PoC**: a manipulated pool quote outside the Chainlink
  ±200 bps band reverts (`UniCLStratQuoteBelowOracleFloor` /
  `UniCLStratQuoteExceedsOracleCeiling`).
- [ ] **Slippage-bound PoC**: a sandwich attempt against an inventory swap
  loses to the `minAmountOut` floor — realized loss ≤ `swapSlippageBps`.
- [ ] **NAV-stability PoC**: `navInETH()` before vs. after the manipulation
  attempt moves within rounding, demonstrating TWAP-based valuation does not
  track the manipulated spot price.
- [ ] **Emergency-path PoC**: `pause()` + `emergencyExit()` succeeds with the
  pool degraded (unwind skipped, `LiquidityUnwindSkipped` emitted) and with
  the Converter paused.

### 2.3 Governance and operations

- [ ] Checklist linked in the timelock proposal scheduling `addStrategy()`;
  the 48h `CallScheduled` review window is used to re-verify §2.1 values on
  the deployed contract (not just in source).
- [ ] Paired token whitelisted via `StrategyManager.addSupportedERC20()`
  *ahead of any incident*, so an `emergencyExit()` keeps recoverable value in
  NAV (FREEZE_RUNBOOK §3.5).
- [ ] Monitoring (§4) confirmed live for the new strategy's address *before*
  the timelock executes.

---

## 3. Governance-attack mitigation analysis

Risk scenario (#244): an attacker accumulates governance power and adds a
strategy with no guardrails, then drains capital via manipulated NAV.

### 3.1 What exists today

| Mitigation | Status | Mechanism |
|---|---|---|
| **Strategy approval timelock** | **Implemented** | `addStrategy` is `onlyAuthRole(Auth.ADMIN_ROLE)`; in production ADMIN_ROLE is held by the 48h OpenZeppelin `TimelockController`, so every strategy addition is publicly visible ≥ 48h before execution (`CallScheduled` event). |
| **Timelock cancellation** | **Implemented** | The SECURITY multisig (and the DAO multisig) holds `CANCELLER_ROLE` on the admin timelock: a malicious queued `addStrategy` can be cancelled before execution (FREEZE_RUNBOOK §5.4 step 9). |
| **Instant circuit breakers** | **Implemented** | SECURITY can `pause()` the StrategyManager (blocks `addStrategy` execution — it is `whenNotPaused`) and the Registry (freezes all role grants — the anti-privilege-escalation switch; `addStrategy` also reverts because its internal `grantCallerRole` is pause-gated). |
| **Per-strategy NAV cap** | **Implemented per strategy** (`maxTotalNAV`) | Bounds deposits into an *honest* strategy. Does **not** constrain a malicious one (its `maxDeposit()`/`navInETH()` are self-reported). |
| **Per-strategy TVL cap at StrategyManager level** | **GAP — spec only** | Design in §3.4; implementation tracked in #231 L-3. |
| **Audit checklist as social gate** | **Implemented (this document)** | §2 is the documented requirement; no strategy is added without it. |
| **`maxStrategies` limit** | **Not implemented** | Considered option — see §3.5. |

### 3.2 What a malicious `addStrategy` can and cannot do

Assuming the 48h window is missed (nobody cancels), a registered malicious
strategy:

**Can:**
- **Attract deposits.** StrategyManager batch deposits include any registered
  strategy whose self-reported `isHealthy()` is true and `maxDeposit()` > 0,
  weighted by StrategyManager-owned `depositWeight` (0–100; set at
  `addStrategy` / weight setters — strategies cannot self-report allocation
  share). A malicious strategy can still report maximum health/headroom and,
  *if assigned a non-zero weight*, absorb up to its share of deployable
  Controller ETH (bounded further by the §3.4 TVL cap once implemented).
- **Over-report NAV.** `_totalNAVInETH()` sums each strategy's `navInETH()`
  with no sanity bound. An inflated NAV inflates `eveBasePriceInETH()`, so
  queued/immediate exits redeem more ETH than is backed — the actual drain
  vector.
- **Freeze pricing by reverting.** A `navInETH()` that always reverts halts
  `enter()`/`exit()`/batch pricing — griefing, not theft. Recovery:
  `forceRemoveStrategy` (tolerates a reverting or over-reporting NAV via
  try/catch), behind the 48h timelock (FREEZE_RUNBOOK §3.5). Clean removal
  of an emptied strategy still uses `removeStrategy` (requires successful
  dust-NAV read).
- **Trade its own balances** via its granted `CONVERTER_CALLER_ROLE` on the
  Converter (wrap/unwrap/swap its own funds only).

**Cannot:**
- Move funds it never received — strategies hold only what the StrategyManager
  deposits into them; there is no strategy path into AMM/Controller balances.
- Execute instantly — the 48h timelock plus `whenNotPaused` on `addStrategy`
  gives SECURITY two independent ways to stop registration (cancel the op;
  pause the StrategyManager or Registry).
- Exceed `MAX_NAV_RESIDUE` (10 wei) and still be cleanly removable — residue
  and over-reporting cases have dedicated removal paths.
- Avoid detection — registration, deposits, and withdrawals all emit events
  (`StrategyAdded`, `FundsDepositedToStrategy`, …) and the NAV anomaly monitor
  (§4) flags the resulting price move.

### 3.3 EVE governance considerations

EVE (`src/contracts/EVE.sol`) is a **plain ERC-20 with no on-chain voting,
delegation, or checkpointing**. All privileged protocol power sits behind
`ADMIN_ROLE` on the Registry, held by the 48h timelock, whose sole proposer is
the DAO multisig. Therefore:

- There is no on-chain path by which accumulating EVE directly yields
  `addStrategy` power. "EVE governance capture" is an **off-chain/social**
  risk: it matters only insofar as the DAO's off-chain process maps EVE
  holdings to multisig proposals.
- The on-chain mitigations above (48h detection window, SECURITY canceller,
  SECURITY pauses) are precisely what makes a socially-captured proposal
  survivable: even a legitimately-proposed malicious `addStrategy` is visible
  for 48h and cancellable/pausable throughout.
- Operational requirement this implies: the DAO must publish the intent of
  every scheduled timelock op, and monitoring must page on every
  `CallScheduled` whose calldata does not match a published intent
  (FREEZE_RUNBOOK §7.1, TimelockController events).

### 3.4 Design: per-strategy TVL cap at the StrategyManager level (spec only)

> Implementation is tracked in #231 (L-3). This section is the agreed design
> so the audit standard and the future implementation cannot drift apart.

**Goal.** Even a fully compromised strategy can only drain its allocation, not
the entire protocol. The cap must be enforced by the StrategyManager — never
by reading the strategy's self-reported `maxDeposit()` alone.

**Storage.**
- `uint256 public defaultMaxAllocationPerStrategy` — global default (wei of
  ETH). `0` = unset → deposits blocked until configured (fail-closed for new
  deployments; existing deployments migrate by setting it via timelock).
- `mapping(address => uint256) public maxAllocationOverride` — optional
  per-strategy override; `0` means "use the default".

**Setter.** `setMaxAllocation(strategy, cap)` and
`setDefaultMaxAllocation(cap)` — `onlyAuthRole(Auth.ADMIN_ROLE)` (48h
timelock), emitting `MaxAllocationChanged(strategy, old, new)`.

**Enforcement point.** In `_depositToStrategy` / `_depositToStrategies`,
*after* the existing `min(amount, strategy.maxDeposit())` clamp, apply a
second clamp:

```text
headroom = cap > strategyNAV ? cap - strategyNAV : 0
depositAmount = min(depositAmount, headroom)
```

where `strategyNAV = IStrategy(strategy).navInETH()` (already read on these
paths' siblings; the NAV sum tolerates the extra read) and `cap` is the
override-or-default. **Clamp, do not revert** — consistent with the existing
headroom pattern (`maxDeposit`), so an over-cap strategy is skipped/trimmed
rather than DoS-ing batch deposits; unused ETH returns to the Controller as
today.

**Non-goals / explicit exclusions.**
- Withdrawals, rebalances, and NAV views are unaffected (caps limit inflow,
  not outflow or accounting).
- The cap does not prevent NAV *over-reporting* by a malicious strategy (that
  is what the timelock + monitoring + removal paths are for); it bounds how
  much *real capital* such a strategy can attract.
- Interaction with `depositWeight` weights: the clamp applies after weighting,
  so weighted allocation is unchanged below the cap.

### 3.5 `maxStrategies` limit — considered option, with recommendation

**Option.** Cap the number of registered strategies
(`require(strategyCount() < maxStrategies)` in `addStrategy`).

**For:** shrinks the governance-attack surface (fewer slots for a malicious
addition); bounds the unbounded `_totalNAVInETH()` loop, whose per-strategy
external calls are the protocol's main gas-scaling risk — a large strategy set
can make NAV (and therefore `enter()`/`exit()`) exceed block gas, an
irreversible freeze short of `forceRemoveStrategy`.

**Against:** the attack surface is already gated by the 48h timelock +
canceller; a count cap does nothing against the *first* malicious addition,
which is the realistic attack; it adds governance friction for legitimate
expansion (raising the cap is itself a 48h op).

**Recommendation.** **Defer, but set one before scaling beyond a handful of
strategies.** The decisive argument is gas, not governance: derive
`maxStrategies` from a measured `totalNAVInETH()` gas profile with headroom
(e.g. NAV must stay under 30% of block gas), and ship it together with the
§3.4 allocation cap (both touch `addStrategy`/deposit paths once). Not urgent
at the current single-strategy scale; required before third-party/community
strategies are admitted.

---

## 4. Monitoring requirements (per strategy)

Post-#241 there is no on-chain NAV-anomaly event: anomaly **detection is an
off-chain ops responsibility** (FREEZE_RUNBOOK §6.1). The monitor must track,
**per registered strategy**, at minimum:

**Events (alert conditions)** — catalog in FREEZE_RUNBOOK §7.1; the
strategy-relevant subset:
- Config events (`TwapIntervalUpdated`, `ShortTwapIntervalUpdated`,
  `MaxTickDeviationUpdated`, `PositionWidthUpdated`, `SwapSlippageUpdated`,
  `MaxTotalNAVUpdated`, `RouteConfigUpdated`, …) — **must match a known
  timelock op; anything else is a governance-compromise page.**
- `StrategyDepositFailed` / `StrategyWithdrawFailed` /
  `StrategyRebalanceFailed` / `StrategyHarvestFailed` / `StrategySyncFailed` —
  page (per-strategy keeper op failed inside the batch try/catch).
- `LiquidityUnwindSkipped`, `PairedTokenTransferSkipped`, `EmergencyExited`,
  `EmergencyWithdrawnToController` — page (emergency path used / partial recovery).
- `StrategyAdded` / `StrategyRemoved` /
  `StrategyForceRemoved` — page on `StrategyForceRemoved` (especially
  `navReverted = true`).
- Absence of `StrategyRebalanced` / `StrategySynced` over the expected keeper
  cadence — the strategy may be silently degraded.

**State polls (static calls)** — FREEZE_RUNBOOK §7.2; per strategy:
- `StrategyManager.strategyNAVInETH(s)` — alert on revert (isolates the broken
  strategy; `totalNAVInETH()` alone cannot).
- `IStrategy.isHealthy()` — alert when false beyond the rebalance cadence.
- `IStrategy.maxDeposit()` / `maxWithdrawal()` — persistent 0 on an unpaused
  strategy signals a sustained not-calm pool (manipulation red flag when the
  pool is otherwise liquid — FREEZE_RUNBOOK §4.1).
- `pool.slot0().observationCardinality` — must cover `twapInterval`.
- Block-over-block `strategyNAVInETH(s)` delta — feed into the §6 NAV-anomaly
  detector.

**NAV anomaly detection (the post-#241 model)** — track
`totalNAVInETH()` and `eveBasePriceInETH()` per block; alert on unexplained
single-transaction moves (suggested threshold > 5%) with no matching
`UserEntered` / `RedeemedImmediately` / `RedemptionQueued` /
`PerformanceFeePaid` event (FREEZE_RUNBOOK §6.2–6.4). Per-strategy NAV deltas
localize the anomaly before the response flow starts.

**Revert selectors to decode in alerts** — FREEZE_RUNBOOK §7.3, notably
`UniCLStratNotCalm()`, `UniCLStratPoolTWAPNotAvailable()`,
`UniCLStratQuoteFailed()`, `UniCLStratQuoteBelowOracleFloor(uint256,uint256)`,
`UniCLStratQuoteExceedsOracleCeiling(uint256,uint256)`.

---

## 5. Incident response — guardrail failure

Trigger: monitoring (§4) flags a guardrail failure — e.g. sustained
`UniCLStratNotCalm` clusters, quote-bound reverts, a strategy config event
with no matching timelock op, or an unexplained NAV move localized to one
strategy.

Response (all steps detailed in FREEZE_RUNBOOK; section references below):

1. **Pause the strategy** — `UniCLStrat.pause()` (SECURITY or ADMIN, instant).
   Flips the pause flag first (a degraded pool cannot block it), attempts the
   LP unwind best-effort, revokes Converter allowances. Batch keeper paths now
   skip the strategy. Note: pausing does **not** unfreeze pricing if
   `navInETH()` itself is reverting (FREEZE_RUNBOOK §3.4).
2. **Freeze wider if warranted** — if the failure looks like an active exploit
   or the NAV move is unexplained, run the full-freeze procedure
   (Registry → AMM → Controller → ExitQueue → StrategyManager → each
   strategy) *before* any further settlement at the suspect price
   (FREEZE_RUNBOOK §5.4, §6.3 step 4).
3. **Recover capital** — `emergencyExit()` (requires pause; bypasses pool and
   Converter by design) → `StrategyManager.emergencyWithdrawToController()` →
   `Controller.emergencyExitToAMM()` (FREEZE_RUNBOOK §3.5).
4. **Investigate** — reconcile NAV component-by-component
   (`strategyNAVInETH` per strategy, Controller/SM balances,
   `AMM.freeBalance()`); reconcile swept amounts against pre-incident NAV;
   identify whether the failure is a guardrail bug (fix/upgrade path), a
   parameter misconfiguration (48h setter op), or a malicious strategy
   (removal path) (FREEZE_RUNBOOK §6.3, §3.6).
5. **Remove or fix** — schedule `removeStrategy()` /
   `forceRemoveStrategy()` on the timelock **early** (cancellable if
   unneeded); for fixable strategies, correct parameters via the timelock.
6. **Resume** — staged un-freeze: infrastructure → strategies → flows → AMM
   last, with NAV reconciliation against off-chain expectations at each stage;
   every unpause is a DAO-proposed 48h timelock action
   (FREEZE_RUNBOOK §5.5).
7. **Post-mortem** — if the failure mode is not covered by §1 of this
   standard, amend the standard *before* any replacement strategy passes the
   §2 checklist.

---

*Maintenance note: this standard describes the contracts as deployed from this
repository revision. Re-verify every cited mechanism, parameter, and role gate
against the source whenever a contract is upgraded or redeployed, and update
the tables accordingly. A strategy that upgrades its implementation must
re-pass the §2 checklist.*
