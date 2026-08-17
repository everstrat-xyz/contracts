# Freeze Runbook — Fail-Closed Operations Guide for the DAO

This runbook gives the DAO multisig, the security multisig, and keeper operators
step-by-step instructions for every scenario in which the protocol freezes or
degrades. The protocol is **deliberately fail-closed**: when a price input or a
strategy cannot be trusted, pricing and operations revert rather than settle at
a wrong price. Every freeze described here is therefore *expected behaviour* —
the job of the operator is to diagnose the cause, contain it, and re-open
through the proper governance path.

All statements in this document are grounded in the contracts under
`smart-contracts/src/` at the revision this file was committed with. Where the
runbook cites a function it cites the exact signature and the role gate
enforced on-chain.

---

## 0. Governance model recap (who can do what)

| Actor | On-chain identity | Delay | Powers |
|---|---|---|---|
| **Security multisig** | holds `SECURITY_ROLE` on the Registry directly | none | `pause()` on AMM, Controller, ExitQueue, StrategyManager, UniCLStrat, Converter, and Registry; `Controller.emergencyExitToAMM()`; `StrategyManager.emergencyWithdrawToController()`; `UniCLStrat.emergencyExit()`; `StrategyManager.removeSupportedERC20()` (instant stale-feed / dust-NAV unfreeze; `addSupportedERC20` stays ADMIN-only); `CANCELLER_ROLE` on the admin timelock. **Cannot** unpause, configure, or upgrade. |
| **ADMIN timelock** | 48h OpenZeppelin `TimelockController` holding `ADMIN_ROLE` on the Registry | 48h minimum | All configuration: Oracle feed/token setters, `unpause()` everywhere (including Converter), strategy add/remove, Registry contract registration and role management, all `set*` functions, UUPS upgrades, Converter adapter allowlist. ADMIN can also `pause()` (same gate as SECURITY). |
| **DAO multisig** | `PROPOSER_ROLE` (and `CANCELLER_ROLE`) on the admin timelock | schedules ops | Holds **no direct protocol role**. Every ADMIN action below is: DAO proposes on the timelock → 48h elapses → anyone executes (executor is `address(0)`, open execution). |
| **Keeper** | holds `KEEPER_ROLE` on the Registry | none | Controller operational functions: deposits/withdrawals to strategies, rebalance, sync, `priceBatch()`, `processRequest(s)()`, `provideExitLiquidity()`, fee harvest. In the automated setup `KEEPER_ROLE` is held by the two Chainlink CRE receivers (`CREQueueExecutor`, `CREStrategyExecutor`) and by nothing else; a manual break-glass multisig is an **optional, opt-in** additional holder — see §0.1 for the decision, risks, and policy. `CREStrategyExecutor` funds the AMM immediate-exit float via its `ProvideExitLiquidity` action (tops `AMM.freeBalance()` up to `exitLiquidityTargetETH` from idle Controller ETH above the reserve and pending redemption needs). |
| **Anyone** | — | none | `AMM.claim()`, `AMM.cancelRedemption()`, timelock execution after delay, Uniswap `pool.increaseObservationCardinalityNext()`. |

Key asymmetries to remember under incident pressure:

- **Pause is instant (SECURITY), unpause always costs 48h (ADMIN timelock).**
  Do not pause "just in case" — every pause commits the DAO to a 48h re-open
  path.
- **Converter `pause()` is `ADMIN_ROLE` or `SECURITY_ROLE`; `unpause()` is
  `ADMIN_ROLE`-only** (`onlyEitherAuthRole` / `onlyAuthRole`). Pausing a
  strategy remains useful in narrower incidents: `UniCLStrat.pause()` revokes
  that strategy's token allowances to the Converter without stopping other
  strategies' swaps.
- **The Oracle has no pause function at all.** Its fail-closed behaviour is
  the staleness/round validation in `_getPriceWithStalenessCheck()`; a bad feed
  makes reads revert on their own.
- A **Registry pause also freezes role grants and revokes** (`grantRole`,
  `grantRoles`, `revokeRole`, `revokeRoles`, `registerContract(s)`,
  `deregisterContract(s)` are all `whenNotPaused`), which blocks any in-flight
  privilege escalation. `renounceRole` still works while paused.

### 0.1 Break-glass keeper — the manual `KEEPER_ROLE` multisig

**Default: OFF.** A fresh deployment grants `KEEPER_ROLE` to the two CRE
receivers and to nothing else (`ProtocolDeployBase._deployCREExecutors`, and the
`_verifyCriticalRoleGrants` check that both executors hold it). Adding a manual
holder is a deliberate, separately proposed governance action — never a
deployment side effect. This section is the single source of truth for that
decision; every other mention in the repo points here.

**Why it exists as an option.** The CRE workflows are a *liveness* dependency:
if the DON stops delivering reports, or a workflow is misconfigured, or the
`writeReport` capability is disabled, every keeper path stops — `priceBatch()`,
`processRequests()`, `provideExitLiquidity()`, strategy deposits/withdrawals and
rebalances. The protocol keeps working for users on the paths that need no
keeper (`enter()`, immediate `exit()` against existing AMM float, `claim()`,
`cancelRedemption()` after the escape-hatch window), but queued redemptions stall
and the AMM float is not topped up. The relevant clocks are unforgiving:

| Clock | Value | What runs out |
|---|---|---|
| `ExitQueue.MAX_BATCH_PROCESSING_TIME` | 3 days | Priced batches go unprocessed; `pullRequest` is forbidden (`ExitQueueBatchExpired`); live NAV drops the liability with no reset tx; users fall back to `AMM.cancelRedemption()` (escape hatch) |
| Admin timelock delay | 48h minimum | Time to grant `KEEPER_ROLE` to a replacement address *after* the incident starts |

Granting a keeper reactively therefore consumes most of the escape-hatch window
before the first manual transaction can land. A pre-granted break-glass holder
converts a 48h governance round-trip into a signer round-trip.

**What the break-glass keeper can do.** Exactly the `KEEPER_ROLE` surface, no
more: the Controller operational functions listed in the §0 table. It is **not**
an admin — it cannot pause, unpause, configure any `set*`, register contracts,
grant roles, or upgrade. It cannot move ETH out of the protocol: every keeper
function moves value between Controller / StrategyManager / strategies / AMM,
and user payouts still route through the AMM pull-over-push `claim()`.

**What it costs — the honest risk.** `KEEPER_ROLE` is instant and untimelocked,
so a compromised keeper multisig is a real economic surface even though it is
not a fund-drain vector:

- **Timing selection.** `priceBatch()` settles a batch at the current
  `eveBasePriceInETH()`. A keeper chooses *which block* that happens in, and so
  picks a NAV print within the range the market offers.
- **Griefing / value leakage.** Repeated deposit → withdraw churn and forced
  `checkAndRebalanceStrategies()` calls make the strategy cross Uniswap spreads
  and pay LP/gas costs on every cycle. The strategy-layer guardrails (calm
  checks, TWAP + Chainlink quote deviation bounds, slippage) bound the damage
  per call; they do not bound the *number* of calls.
- **Float manipulation.** `provideExitLiquidity()` and `depositToStrategies()`
  let a keeper decide how much ETH sits in the AMM as immediate-exit float.

**Containment when it does go wrong.** `Controller.pause()` — instant,
`SECURITY_ROLE` — blocks every keeper entry point (all `KEEPER_ROLE` functions
on the Controller are `whenNotPaused`). That is the fast stop; use it first.
Revoking the role itself is `ADMIN_ROLE` and therefore 48h, and note the
interaction: **a Registry pause blocks `revokeRole`**, so if the Registry is
also paused the revoke cannot land until the Registry is unpaused. Sequence:
pause the Controller → propose the revoke → unpause the Registry if needed →
execute.

**Policy if the DAO enables it.**

1. Multisig only — never an EOA, and never the deployer key.
2. Signer set distinct from the DAO and security multisigs, so one compromised
   signer quorum cannot both act as keeper and cancel the response.
3. Granted by its own timelock proposal, with the address in the proposal
   description. Not bundled into an unrelated batch.
4. `strategyDepositCooldown` > 0 must be set **before** the grant executes —
   the cooldown is what bounds deposit/withdraw churn.
5. Monitored like an operator, not like a contract: alert on **any** transaction
   from the break-glass address (in steady state there should be none), and page
   on the keeper-failure selectors in §7.3.
6. Reviewed at every governance cycle: if the CRE workflows have been healthy,
   the standing recommendation is to revoke and re-grant on demand, accepting the
   48h latency.

---

## 1. Quick-reference matrix

| # | Scenario | Symptom | Who acts | Action | Time constraint |
|---|---|---|---|---|---|
| 1 | Chainlink feed stale / broken | `OracleStalePrice`, `OracleInvalidPrice`, `OracleNoRoundData`, `OracleInvalidTimestamp` reverts; if a UniCLStrat holds paired-token inventory or the StrategyManager holds a non-zero supported-ERC-20 balance, `enter()`/`exit()`/`eveBasePriceInETH()` also revert | ADMIN timelock (DAO proposes) | `Oracle.updateUsdFeedInfo(token, newFeed, stalenessInterval)` — this is also how a token is (re)registered | 48h timelock; per-token `stalenessInterval` defines when the freeze starts |
| 2 | Strategy `navInETH()` reverts | Every `AMM.enter/exit`, `eveBasePriceInETH()`, `Controller.priceBatch()` reverts (bubbled from `StrategyManager.totalNAVInETH()`) | SECURITY, then ADMIN | `UniCLStrat.pause()` → `UniCLStrat.emergencyExit()` → `StrategyManager.emergencyWithdrawToController()` → `Controller.emergencyExitToAMM()`; then ADMIN `StrategyManager.forceRemoveStrategy()` | pause/exit instant; `forceRemoveStrategy` needs 48h timelock |
| 3 | Strategy unhealthy (`isHealthy() == false`) but not reverting | No freeze; batch deposits skip it; keeper `checkAndRebalance*` triggers `rebalance()` | Keeper (SECURITY only if funds at risk) | `Controller.checkAndRebalanceStrategy(strategy)`; reverts `UniCLStratNotCalm` if pool not calm — back off and retry | none |
| 4 | Uniswap pool not calm | `UniCLStratNotCalm` reverts on deposit/rebalance; `maxDeposit() == 0`; withdrawals still work | Keeper | Back off; retry when pool calms. No governance action needed | TWAP windows: long ≥ 1800s, short ≥ 60s |
| 5 | Pool observation buffer too small | `UniCLStratPoolTWAPNotAvailable` revert from `navInETH()` → full pricing freeze (same blast radius as #2) | Anyone, then wait | `pool.increaseObservationCardinalityNext(n)`; buffer fills as the pool trades. If urgent: escalate to scenario-2 chain | buffer fill time depends on pool activity |
| 6 | Unexplained NAV anomaly (monitoring alert) | Off-chain NAV tracking flags a large single-tx base-price move not explained by enter/exit flow; on-chain there is **no deviation guard** — enter/exit keep working | Investigate first; SECURITY if unexplained | Reconcile NAV component-by-component (§6); if unexplained: SECURITY full-freeze (§5.4) → fix → staged un-freeze (§5.5) | pause instant for SECURITY; un-freeze always 48h |
| 7 | Active exploit / unknown anomaly | Anything not matching a known pattern | SECURITY | Full-freeze procedure (§5.4), then staged un-freeze (§5.5) | un-freeze requires 48h per timelock batch |
| 8 | Keeper stops processing a priced exit batch | Batch `pricedAt` older than 3 days, requests unprocessed; `pullRequest` reverts `ExitQueueBatchExpired`; `liveRedemptionOffsets` no longer deducts that batch | Users (self-service) | `AMM.cancelRedemption(batchId)` — escape hatch returns escrowed EVE (the only remaining path; pull is forbidden) | `ExitQueue.MAX_BATCH_PROCESSING_TIME = 3 days` |
| 9 | Registry paused | Role grants/revokes and contract registration revert; `StrategyManager.addStrategy()` reverts | ADMIN timelock | `Registry.unpause()` | 48h |
| 10 | In-window priced liability exceeds NAV | `StrategyManagerQueuedLiabilityExceedsNAV` (and/or `AMMEscrowExceedsSupply`) freeze `enter()`/`exit()`/`eveBasePriceInETH()`/`priceBatch()` | SECURITY, then wait | Pause ExitQueue so no new batches can be priced. Do **not** try to pull expired or underwater claims. Wait out `MAX_BATCH_PROCESSING_TIME` so remaining L lapses in the view; users `cancelRedemption` remaining requests; recap AMM prices. Investigate how L exceeded NAV (NAV bug vs oversize queue) | pause instant; L lapses after 3 days from each batch's `pricedAt` |

---

## 2. Scenario: Oracle stale / Chainlink feed failure

### 2.1 What actually freezes

`Oracle._getPriceWithStalenessCheck()` (`src/contracts/Oracle.sol`) reverts on
any of: `updatedAt == 0` (`OracleNoRoundData`), `answer <= 0` (`OracleInvalidPrice`),
`updatedAt > block.timestamp` (`OracleInvalidTimestamp`), or
`block.timestamp - updatedAt > stalenessInterval` (`OracleStalePrice`).
Every Oracle price/conversion path (`getUsdPrice`, `getPairPrice`, `convertTokenToUSD`,
`convertUsdToToken`, `convert`) goes through these checks. There is no cached fallback
price — fail-closed by design. Note that **token support is USD-feed registration**
(`updateUsdFeedInfo`); optional pair feeds are overlays that `convert` may prefer when
present, but a registered stale pair feed does not silently fall back to USD.

Paths that consume the Oracle:

| Consumer | Call | Effect of a feed outage |
|---|---|---|
| `AMM.eveBasePriceInUSD()` / `evePremiumPriceInUSD()` | `convertTokenToUSD(address(0), …)` | USD view functions revert. ETH-denominated views unaffected. |
| `AMM.enter()` — **bootstrap only** | `convertTokenToUSD` for the `MIN_INITIAL_DEPOSIT_USD` check | Only the very first deposit (pre-bootstrap) is blocked. |
| `Controller.harvestPerformanceFeeFromStrategy(/-ies)` → `StrategyManager` harvest paths | Fee base and mint both ETH-denominated — no USD conversion: `IStrategy.settlePerformanceFee` values the paired-token fee leg via `Oracle.convert(… → ETH)` (the WETH leg is 1:1), and `_mintPerformanceFeeEVE` reads `totalNAVInETH()` for the bonding-curve dilution mint | Fee harvest reverts on a stale paired-token or non-zero supported-ERC-20 feed (only when `performanceFeeBps > 0`). |
| `UniCLStrat.navInETH()` | `Oracle.convert(pairedToken, address(0), …)` to value paired-token inventory | **See warning below.** |
| `UniswapV3ConverterAdapter.quoteExactAmountIn/Out` | `Oracle.convert` cross-check of the TWAP quote | All strategy swaps revert (`UniCLStratQuoteFailed` bubbles from the strategy's try/catch around the quote). |
| `StrategyManager._totalNAVInETH()` | `Oracle.convert(token, address(0), …)` per non-zero supported-ERC-20 balance | A non-zero balance of a supported ERC-20 whose feed is stale **freezes NAV**. Drop the token via `removeSupportedERC20()` (`ADMIN_ROLE` or `SECURITY_ROLE`; no external calls — works while paused) to escape. |

> **Important nuance — the hot path is only oracle-free at the AMM level.**
> `AMM.enter()`/`exit()` never call the Oracle directly (ETH-first pricing).
> But `StrategyManager._totalNAVInETH()` sums every registered strategy's
> `navInETH()`, and `UniCLStrat.navInETH()` values its paired-token inventory
> through `Oracle.convert(pairedToken, address(0), …)`, which staleness-checks
> **both** the paired-token feed and the ETH/USD feed. So while a UniCLStrat
> with non-zero paired-token exposure is registered, a Chainlink outage on
> either feed **does freeze enter/exit/pricing** — transitively, via NAV.

> **Second nuance — emergency exit is now Converter- and Oracle-tolerant.**
> `UniCLStrat.emergencyExit()` does not touch the pool, does not call the
> Converter, and does not invoke any StrategyManager callback. It only unwraps
> WETH via `weth.withdraw()` and transfers native ETH + paired-token ERC-20 to
> the StrategyManager, then writes off pending strategy-local LP fees via
> `_resetLpFeeAccounting` (best-effort accrue with snapshot fallback if
> `positions` reverts, then `charged = earned`). It therefore succeeds under
> a total Chainlink outage, a paused Converter, or a bricked pool — exactly
> the conditions it is meant for. The paired-token balance lands on the
> StrategyManager and is priced into NAV only when whitelisted via
> `addSupportedERC20()`; if its feed is stale, NAV freezes *after* the exit
> until either the feed recovers or SECURITY/ADMIN `removeSupportedERC20()`s the
> token.

### 2.2 How to detect

- Off-chain: poll each feed's `latestRoundData()` and alert when
  `block.timestamp - updatedAt` exceeds ~80% of the token's configured
  `stalenessInterval` (read via `Oracle.getUsdFeedInfo(token)`).
- On-chain symptoms: keeper transactions reverting with `OracleStalePrice` /
  `OracleInvalidPrice` etc.; `AMM.enter()`/`exit()` reverting (bubbled through
  `totalNAVInETH()`); `eveBasePriceInUSD()` static-call failures in the
  frontend.
- Simplest health probe: static-call `AMM.eveBasePriceInETH()` and
  `AMM.eveBasePriceInUSD()` every block; the first failing while the second
  fails too points at NAV (strategy/oracle); only the second failing points at
  the ETH/USD feed alone.

### 2.3 Immediate actions (SECURITY, instant)

1. **Usually: nothing.** The staleness checks already prevent any mispriced
   settlement. Enter/exit reverting is the intended behaviour.
2. **Supported-ERC-20 stale-feed / dust freeze:** if NAV is frozen solely because
   a whitelisted ERC-20 on the StrategyManager has a non-zero balance and a
   stale/invalid feed (including a 1-wei griefing donation), call
   `StrategyManager.removeSupportedERC20(token)`
   (`onlyEitherAuthRole(ADMIN_ROLE, SECURITY_ROLE)`). This drops the balance
   out of NAV immediately with no external calls. Prefer pausing first if the
   balance is material, then remove, then let ADMIN re-whitelist after the feed
   recovers (48h). `addSupportedERC20` stays ADMIN-only.
3. Pause **only if** the failure mode is a *wrong-but-fresh* price (e.g. a
   compromised or misbehaving aggregator still updating): then
   `AMM.pause()` and `Controller.pause()` (both
   `onlyEitherAuthRole(ADMIN_ROLE, SECURITY_ROLE)`) to stop entry/exit and
   keeper flows while the feed is investigated, and consider the full-freeze
   procedure (§5.4). A *stale* feed does not need a pause — it blocks itself.

### 2.4 Recovery (ADMIN timelock, 48h)

DAO proposes on the admin timelock; after 48h anyone executes:

```solidity
// Point the token at a healthy Token / USD feed and/or adjust the staleness window.
// First call for a token *is* registration (emits UsdFeedAdded, sets isTokenSupported).
// Validates feed.decimals() <= 18. Native ETH is _token == address(0).
Oracle.updateUsdFeedInfo(address _token, address _priceFeed, uint256 _stalenessInterval)
    // onlyAuthRole(ADMIN_ROLE)

// Remove a token whose feed is permanently dead (only if nothing prices it anymore):
// Also clears outbound/inbound pair feeds. Inverse of the first updateUsdFeedInfo.
Oracle.removeToken(address _token)   // onlyAuthRole(ADMIN_ROLE)
```

Notes:

- Extending `_stalenessInterval` to "ride out" a feed heartbeat gap is a risk
  decision — it widens the window in which an old price is accepted. Prefer
  switching feeds over loosening staleness.
- `updateUsdFeedInfo` reverts `OracleNothingToUpdate` if both values are
  unchanged.
- After the feed recovers, reconcile NAV (in ETH terms) against off-chain
  expectations — an unexplained step while pricing was frozen is a §6 anomaly.

### 2.5 Preventative monitoring

- Alert on the Oracle admin events: `UsdFeedAdded`, `TokenRemoved`,
  `UsdFeedUpdated`, `UsdStalenessIntervalUpdated` (any unexpected occurrence is
  a governance-compromise signal — SECURITY can freeze further role abuse by
  pausing the Registry).
- Track Chainlink aggregator announcements for feed migrations
  (`updateUsdFeedInfo` must be scheduled 48h ahead of a feed deprecation).
- Keep `stalenessInterval` per token aligned with the feed's documented
  heartbeat plus margin.

---

## 3. Scenario: strategy `navInETH()` reverting, or strategy unhealthy

### 3.1 What actually freezes — the strict NAV rule

`StrategyManager._totalNAVInETH()` (`src/contracts/StrategyManager.sol`) loops
over **all** registered strategies and sums `IStrategy(strategy).navInETH()`
with **no try/catch**. One reverting strategy therefore reverts:

- `AMM.enter()` and `AMM.exit()` (both read NAV),
- `AMM.eveBasePriceInETH()` / `evePremiumPriceInETH()` / USD views,
- `Controller.priceBatch()` (reads `eveBasePriceInETH()`),
- performance-fee minting (`_mintPerformanceFeeEVE` reads total NAV).

This is intentional: minting or burning EVE against an under-reported NAV
would let an attacker enter at a discount or drain backing. **Do not attempt
to "route around" the freeze — unwind or remove the broken strategy.**

Distinguish two different degradation levels:

| Condition | Blast radius |
|---|---|
| `navInETH()` **reverts** (oracle stale, TWAP unavailable, pool bricked) | Full pricing freeze: enter/exit/pricing/batch-pricing all revert. |
| `isHealthy() == false` or `maxDeposit()/maxWithdrawal() == 0` (view-level degradation, incl. paused strategy or uncalm pool) | **No freeze.** Batch paths skip the strategy by checking views; pricing keeps working. |

### 3.2 Batch keeper paths: what is (and is not) resilient on this code

The batch functions **wrap each per-strategy call in `try/catch`** and emit a
per-strategy failure event on revert — a single misbehaving strategy no longer
reverts the whole batch transaction. The events:

- `StrategyDepositFailed(strategy, reason)` (the `reason` is the raw revert data)
- `StrategyWithdrawFailed(strategy, reason)`
- `StrategyRebalanceFailed(strategy, reason)`
- `StrategyHarvestFailed(strategy, reason)`
- `StrategySyncFailed(strategy, reason)`

View-level skips still apply — batch functions include only strategies with the
right conditions, so the try/catch is the second layer of defence:

- `depositToStrategies(…)` includes only strategies with
  `isHealthy() && maxDeposit() > 0`; unused ETH is returned to the Controller.
- `withdrawFromStrategies(…)` includes only strategies with
  `maxWithdrawal() > 0` (a paused UniCLStrat returns 0 and is skipped); the
  pre-withdraw fee harvest shares the harvest try/catch so a settle failure
  does not block the rest of the withdraw batch.
- `syncStrategies(…)` no-ops on strategies whose `paused()` is true; each
  `sync()` is isolated in try/catch.
- `harvestPerformanceFeeFromStrategies(…)` wraps each `settlePerformanceFee()`
  in try/catch; failed strategies are omitted from the single EVE mint sum.
- `checkAndRebalanceStrategies(…)` skips strategies whose `paused()` is true;
  calls `rebalance()` on the rest, with each call isolated in try/catch.

Consequences for the keeper:

- A failed per-strategy operation emits the corresponding `*Failed` event
  instead of reverting. Alert on these events directly — they tell you which
  strategy is degraded without parsing revert data from a keeper revert.
- For `navInETH()` / view-level hard reverts: those still propagate to
  `totalNAVInETH()` and freeze pricing (no try/catch in the NAV sum). Use the
  paginated overloads (`depositToStrategies(startIndex, endIndex, amount)`,
  etc.) or the single-strategy variants to isolate a misbehaving strategy.
- Success events to alert on (their *absence* alongside a `*Failed` event is
  the signal): `FundsDepositedToStrategy(strategy, amount)`,
  `FundsWithdrawnFromStrategy(strategy, amount)`,
  `StrategyRebalanced(strategy)`, `StrategySynced(strategy)` on the
  StrategyManager, and the Controller wrappers
  `DepositToStrategiesCompleted`, `WithdrawalCompleted`,
  `DirectDepositCompleted`, `DirectWithdrawalCompleted`.

### 3.3 How to detect

- Poll `StrategyManager.strategyNAVInETH(strategy)` (static call) per
  registered strategy every block/minute; alert on revert. This isolates the
  broken strategy immediately, whereas `totalNAVInETH()` only tells you *some*
  strategy is broken.
- Alert on keeper transaction failures and on the revert selectors:
  `UniCLStratPoolTWAPNotAvailable`, `OracleStalePrice`,
  `UniCLStratNotCalm`, `StrategyManagerInvalidDepositWeight`,
  `StrategyManagerInvalidWithdrawalWeight`.
- Alert when `UniCLStrat.isHealthy()` is false for longer than the expected
  rebalance cadence.

### 3.4 Immediate actions (SECURITY, instant)

1. **Pause the strategy:**
   ```solidity
   UniCLStrat.pause()   // onlyEitherAuthRole(ADMIN_ROLE, SECURITY_ROLE), nonReentrant
   ```
   Side effects (by design, `_pauseStrategy()`):
   - Flips the Pausable flag **first**, before any external call — so a
     degraded pool can never block the circuit breaker.
   - Attempts to unwind pool liquidity and collect fees via a
     `try this.selfRemoveLiquidityAndCollect() {} catch {}` self-call (the
     parameterless `catch` is deliberate — it avoids a returndata-bomb griefing
     vector). On revert, emits `LiquidityUnwindSkipped()` and proceeds; the LP
     position stays in the pool and remains attributed to the strategy via
     `navInETH()`. Once the pool functions again, the admin can `unpause()`
     (then resume normal withdrawals) or re-run `pause()` (which re-attempts
     the unwind) followed by `emergencyExit()`.
   - Revokes the strategy's token approvals to the Converter.

   After pausing: `maxDeposit() == 0`, `maxWithdrawal() == 0`,
   `isHealthy() == false` — all batch keeper paths now skip the strategy.

   > **Pausing does NOT unfreeze pricing.** `_totalNAVInETH()` calls
   > `navInETH()` on *registered* strategies regardless of their pause state.
   > If `navInETH()` is the thing reverting, pricing stays frozen until the
   > revert source is fixed (feed restored / observation buffer filled) or the
   > strategy is emptied and removed.

2. **Consider pausing the AMM** (`AMM.pause()`, ADMIN or SECURITY) if you
   expect the NAV to change materially during the unwind and want to prevent
   entries/exits racing the recovery. Remember the 48h unpause cost.

### 3.5 Recovery — the emergency capital-recovery chain

All three sweep steps are SECURITY-or-ADMIN and instant; only the final
`forceRemoveStrategy` (when `navInETH()` still reverts) or `removeStrategy`
(when NAV reads successfully at dust) needs the 48h timelock.

```text
UniCLStrat.emergencyExit()                    (1) strategy  → StrategyManager
StrategyManager.emergencyWithdrawToController() (2) StrategyManager → Controller
Controller.emergencyExitToAMM()               (3) Controller → AMM (freeBalance)
StrategyManager.forceRemoveStrategy(strategy) (4) ADMIN timelock, 48h
  # use removeStrategy instead when navInETH() succeeds and reports ≤ MAX_NAV_RESIDUE
```

1. **`UniCLStrat.emergencyExit()`**
   `onlyEitherAuthRole(ADMIN_ROLE, SECURITY_ROLE)`, `nonReentrant`, **requires
   the strategy to be paused** (`UniCLStratNotPaused` otherwise).
   - Does **not** touch the pool or call the Converter — by design, so it works
     under a bricked pool or a paused Converter.
   - Unwraps the strategy's WETH balance via `weth.withdraw()` **directly**.
   - Sends all native ETH to the StrategyManager **first** (strict), then best-effort
     transfers any paired-token balance to the StrategyManager **as an ERC-20** via
     `SafeERC20.trySafeTransfer` (reverts, false returns, and USDT-style empty returndata).
     A blacklisted/paused USDC-style token emits `PairedTokenTransferSkipped` and leaves
     the balance on the strategy — it must not roll back the ETH sweep. A later
     `emergencyExit()` retries the transfer.
   - Writes off pending strategy-local LP fees via `_resetLpFeeAccounting()`:
     best-effort `_tryAccrueLpFees()` (reads `positions`; on any failure falls
     back to the aggregate `_lpFeesOwedSnapshot*` so accrue is a no-op), then
     sets `_cumulativeLpFeesCharged* = _cumulativeLpFeesEarned*` — same
     charged=earned alignment as `settlePerformanceFee`, without zeroing or
     rewriting earned down to `tokensOwed`. Fee accounting lives entirely on
     the strategy — there is no StrategyManager-side callback on emergency exit.
   - Emits `EmergencyExited(ethAmount)` (ETH only; the paired-token transfer
     amount is not in the event).

   > **NAV impact of the paired-token transfer:** paired tokens transferred to
   > the StrategyManager are priced into `_totalNAVInETH()` **only when
   > whitelisted** via `StrategyManager.addSupportedERC20()`. Unwhitelisted
   > paired tokens sit on the StrategyManager as orphan inventory (not in NAV).
   > Operational rule: when registering a UniCL strategy, whitelist its paired
   > token *ahead of any incident* via `addSupportedERC20()` so the
   > emergency-exit inventory keeps backing EVE. If the paired-token feed later
   > goes stale and freezes NAV, `removeSupportedERC20()` (ADMIN or SECURITY;
   > no external calls, works while paused) drops that value out of NAV
   > immediately.
   >
   > On-chain swap recovery of those ERC-20s back to native ETH via the shared
   > Converter is **deferended to a follow-up PR**. When the pool and Converter
   > are functional, prefer draining the strategy via keeper
   > `Controller.withdrawFromStrategy(strategy, amount)` first (which converts
   > paired tokens to WETH internally); keep `emergencyExit()` for when the
   > normal path is unusable.

2. **`StrategyManager.emergencyWithdrawToController()`**
   `onlyEitherAuthRole(ADMIN_ROLE, SECURITY_ROLE)`, `nonReentrant`. Sweeps the
   StrategyManager's entire **native ETH** balance to the Controller; reverts
   `StrategyManagerNoBalanceToRecover` when zero. Emits
   `EmergencyWithdrawnToController(amount)`. NAV-neutral (ETH stays counted).

3. **`Controller.emergencyExitToAMM()`**
   `onlyEitherAuthRole(ADMIN_ROLE, SECURITY_ROLE)`, `nonReentrant`, **not
   pause-gated** (works while the Controller is paused). Sweeps the entire
   Controller ETH balance to the AMM, where it becomes `freeBalance()` usable
   for immediate exits. Emits `EmergencyExitedToAMM(amount)`. NAV-neutral.

4. **`StrategyManager.removeStrategy(address _strategy)`**
   `onlyAuthRole(ADMIN_ROLE)` — DAO proposes on the timelock, executes after
   48h. Clean removal after the strategy is emptied. Semantics (verified in
   code):
   - **Callable while the StrategyManager is paused** (no `whenNotPaused`,
     unlike `addStrategy`).
   - Requires a successful `navInETH()` read. The residue guard applies:
     removal reverts with `StrategyManagerStrategyNAVResidueTooHigh` when
     `nav > MAX_NAV_RESIDUE` (**10 wei**). You cannot remove a strategy that
     still holds funds — empty it first (steps 1–3).
   - A reverting `navInETH()` **bubbles up** — use `forceRemoveStrategy()`
     instead (below).
   - Emits `StrategyRemoved(strategy)`.
   - Best-effort revoke of the strategy's `CONVERTER_CALLER_ROLE` via
     `Converter.revokeCallerRole()` — wrapped in try/catch; if the Registry is
     paused the revoke fails and `CallerRoleRevokeFailed(strategy)` is emitted
     (clean up later by re-`addStrategy` + `removeStrategy`, or pause the
     Converter via ADMIN or SECURITY).
   - **Note on strategy-local fee counters:** `removeStrategy` does not touch
     the strategy's own `_cumulativeLpFeesEarned*` / `_cumulativeLpFeesCharged*`
     counters — those live on the strategy contract. If you later re-`add()`
     the same strategy, those counters persist and continue to drive
     `pendingPerformanceFeeInETH` from where they left off.

   **`StrategyManager.forceRemoveStrategy(address _strategy)`** — same gate
   (`ADMIN_ROLE`, 48h timelock) and also callable while paused. Escape hatch
   for cases `removeStrategy` cannot handle: a strategy whose `navInETH()`
   is *over-reporting* (would exceed `MAX_NAV_RESIDUE` forever) **or
   reverting** (bubbles on the clean path). `forceRemoveStrategy` skips the
   residue check entirely, reads NAV via `try/catch` only for the event
   (`StrategyForceRemoved(strategy, reportedNAV, navReverted)`), and
   deregisters. Capital recovery is still via `IStrategy.emergencyExit()` /
   keeper withdrawals.

   Because the timelock schedules the removal 48h ahead, schedule it as soon
   as the incident starts even if you still hope to fix the strategy — the DAO
   (or SECURITY, both hold `CANCELLER_ROLE`) can cancel the queued operation
   if it becomes unnecessary. This caps the freeze at ~48h instead of 48h +
   diagnosis time.

### 3.6 Aftermath

- Removing a strategy whose `navInETH()` was reverting instantly restores
  `totalNAVInETH()` — pricing resumes at the new (lower) NAV.
- **Reconcile the new NAV.** If the emergency exit realized a loss (or stranded
  paired tokens shrank NAV), verify the new NAV is legitimate and matches
  off-chain expectations before re-opening user flows — an unexplained delta
  is a §6 anomaly.
- If the AMM/Controller were paused during the incident, run the staged
  un-freeze (§5.5).
- Post-mortem: reconcile `EmergencyExited`, `EmergencyWithdrawnToController`,
  `EmergencyExitedToAMM` amounts against pre-incident
  `strategyNAVInETH(strategy)`.

---

## 4. Scenario: Uniswap pool halted / not calm / TWAP observation buffer issues

`UniCLStrat` guards every pool interaction with a **calm-period check**
(`_isCalm()`): the spot tick *and* the short TWAP (window ≥ 60s) must both sit
within `maxTickDeviation` of the long TWAP (window ≥ 1800s = 30 min).

### 4.1 Pool not calm (volatility / manipulation attempt)

What degrades — **no pricing freeze**, only capital operations:

| Function | Behaviour when not calm |
|---|---|
| `deposit()` | reverts `UniCLStratNotCalm` |
| `investIdleETH()` | reverts `UniCLStratNotCalm` |
| `rebalance()` | reverts `UniCLStratNotCalm` |
| `withdraw()` | **works** — removes liquidity and pays out; only skips the re-add of remaining liquidity (`if (_isCalm())`) |
| `maxDeposit()` | returns 0 → batch deposits skip this strategy and refund the Controller |
| `isHealthy()` | returns false → keeper `checkAndRebalance*` will try `rebalance()` and revert `UniCLStratNotCalm` — the keeper must back off |
| `navInETH()` | **works** (prices the LP position off the long TWAP, not spot) |

Actions: none for governance. The keeper should treat `UniCLStratNotCalm` as
a retriable condition with backoff. Sustained not-calm (hours) on an otherwise
liquid pool is a manipulation red flag — consider `UniCLStrat.pause()`
(SECURITY) if combined with other anomalies.

### 4.2 Observation buffer cannot serve the TWAP window

If the pool's observation cardinality does not cover `twapInterval`,
`pool.observe()` reverts. The two code paths react differently
(`TickUtils.tryMeanTick` vs `meanTick`):

- `_isCalm()` uses the **non-reverting** variant → returns false (degrades to
  §4.1 behaviour).
- `navInETH()` → `_twapSqrtPrice()` → `_twap()` uses the **reverting** path →
  reverts `UniCLStratPoolTWAPNotAvailable` → `totalNAVInETH()` reverts →
  **full pricing freeze** (identical blast radius to §3.1). Note this happens
  even when the strategy holds no LP position — the TWAP read is
  unconditional in `_balancesOfPool()`.

When this occurs: at initial deployment against a fresh pool (the deploy
script `DeployUniCLStrat.s.sol` warns about exactly this), after an ADMIN
`setTwapInterval()` increase beyond the buffer, or on a pool whose cardinality
was never grown.

Recovery:

1. **Anyone** (no role needed) can call
   `pool.increaseObservationCardinalityNext(uint16 n)` on the Uniswap pool,
   sized so the buffer covers `twapInterval` at the pool's trade cadence.
   The buffer then fills as swaps happen — the freeze persists until enough
   observations accumulate.
2. If the pool is too inactive to fill the buffer in acceptable time, treat it
   as scenario 3: SECURITY `pause()` + `emergencyExit()`, ADMIN
   `forceRemoveStrategy()` (the `navReverted = true` path applies, since
   `navInETH()` is reverting).
3. Preventative: before `addStrategy()` of any UniCL strategy, verify
   `pool.slot0().observationCardinality` covers the configured `twapInterval`;
   before executing a queued `setTwapInterval()` increase, grow the buffer
   first.

### 4.3 Pool halted entirely / bricked

A pool with zero trading still serves `observe()` (it extrapolates from the
last observation), so pricing generally keeps working; the danger is a pool
whose contract calls revert (upgrade-frozen fork, self-destructed periphery,
etc.). Then `navInETH()` itself reverts. `UniCLStrat.pause()` still succeeds —
it flips the Pausable flag first and attempts the pool unwind as a best-effort
`try/catch` self-call, emitting `LiquidityUnwindSkipped()` if the pool is
bricked. Recovery path:
1. SECURITY `UniCLStrat.pause()` — flag flips, unwind attempt fails gracefully.
2. `UniCLStrat.emergencyExit()` — transfers whatever the strategy currently
   holds (WETH, paired token) to the StrategyManager; **does not** touch the
   pool. LP position stays attributed to the strategy via `navInETH()` — which
   will keep reverting until the pool functions again.
3. ADMIN `forceRemoveStrategy(strategy)` via the 48h timelock. The `try/catch`
   on `navInETH()` lets removal through with `navReverted = true`. Once removed,
   `totalNAVInETH()` no longer consults that strategy and pricing resumes —
   the LP position remains in the pool, owned by the (now-removed) strategy
   contract. If the pool recovers later, anyone with the matching role can
   re-`addStrategy()` it and recover the residual LP via normal withdrawals
   or a fresh `pause()` → `emergencyExit()` cycle.

---

## 5. Scenario: pause states across Registry / Controller / AMM / ExitQueue / StrategyManager / Converter

### 5.1 Who pauses, who unpauses (verified per contract)

| Contract | `pause()` | `unpause()` | Notes |
|---|---|---|---|
| Registry | `ADMIN_ROLE` **or** `SECURITY_ROLE` | `ADMIN_ROLE` only (48h) | static contract; reads (`getContractByKey`, `hasRole`) never pause |
| AMM | `ADMIN_ROLE` or `SECURITY_ROLE` (`onlyEitherAuthRole`) | `ADMIN_ROLE` only | static contract |
| Controller | `ADMIN_ROLE` or `SECURITY_ROLE` | `ADMIN_ROLE` only | |
| ExitQueue | `ADMIN_ROLE` or `SECURITY_ROLE` | `ADMIN_ROLE` only | |
| StrategyManager | `ADMIN_ROLE` or `SECURITY_ROLE` | `ADMIN_ROLE` only | |
| UniCLStrat | `ADMIN_ROLE` or `SECURITY_ROLE` (unwinds LP + revokes Converter allowances) | `ADMIN_ROLE` only (re-grants allowances) | |
| **Converter** | `ADMIN_ROLE` or `SECURITY_ROLE` | `ADMIN_ROLE` only | Instant circuit breaker for wrap/unwrap/swap; strategy pause still revokes that strategy's allowances |
| Oracle | — no pause exists | — | fail-closed via staleness checks |
| EVE | — no pause exists | — | mint/burn gated by `MINTER_ROLE` only |

Every unpause routes through the 48h admin timelock: **re-opening the
protocol is always a deliberate, DAO-proposed, publicly visible 48h action.**

### 5.2 What each pause blocks (and what keeps working)

**Registry paused** — blocks `registerContract(s)`, `deregisterContract(s)`,
`grantRole(s)`, `revokeRole(s)` (all `whenNotPaused`). **Role grants are
frozen** — this is the anti-privilege-escalation switch. Still working:
`renounceRole` (holders can always step down), all reads (so the rest of the
protocol keeps resolving addresses/roles and is otherwise unaffected).
Knock-ons: `StrategyManager.addStrategy` reverts (its `grantCallerRole` →
`Registry.grantRole` is pause-gated); `removeStrategy` still succeeds but
emits `CallerRoleRevokeFailed`.

**AMM paused** — blocks `enter()`, `exit()`, `processRedemption()` (so batch
payout processing halts). Still working:
- `claim()` — users can always pull previously credited ETH
  (pull-over-push: `claimableBalances` / `lockedForClaims`);
- `cancelRedemption(batchId)` — no pause gate on the AMM **or** on
  `ExitQueue.closeRequest()`, so users can reclaim escrowed EVE even during a
  full freeze (subject to the batch-window rule in §5.3);
- all views.

**Controller paused** — blocks every keeper function: deposits, withdrawals,
rebalance, sync, fee harvest, `provideExitLiquidity()`, `priceBatch()`,
`processRequest(s)()`. Still working: `emergencyExitToAMM()` (no pause gate)
and receiving ETH. Effect on users: entry/exit still work at the AMM while it
is unpaused (ETH just accumulates on the Controller; queued batches stop being
priced/processed — watch the 3-day escape hatch, §5.3).

**ExitQueue paused** — blocks `pushRequest()` (queued exits revert, so
`AMM.exit()` only works up to available `freeBalance()`; immediate exits are
unaffected), `pullRequest()` (batch processing halts even if the Controller
is live), and `priceBatch()` (`whenNotPaused` on the ExitQueue itself, so a
batch cannot be priced while the queue is paused — the Controller entry point
is separately Controller-pause-gated). Still working: `closeRequest()` —
**explicitly not pause-gated** so `AMM.cancelRedemption()` remains a user
escape route (subject to the batch-window rule in §5.3).

**StrategyManager paused** — blocks `addStrategy()` and all
Controller-driven fund movement (deposit/withdraw/rebalance/sync/harvest).
Still working: `removeStrategy()` (ADMIN), `forceRemoveStrategy()` (ADMIN),
`addSupportedERC20()` (ADMIN — intentionally not pause-gated),
`removeSupportedERC20()` (ADMIN or SECURITY — instant stale-feed / dust-NAV
escape hatch; also not pause-gated), `emergencyWithdrawToController()`
(ADMIN|SECURITY), and all NAV views — **pausing the StrategyManager does not
stop AMM pricing or enter/exit**.

**UniCLStrat paused** — blocks `deposit()`, `withdraw()`, `rebalance()`,
`sync()`, `investIdleETH()`; `maxDeposit()`/`maxWithdrawal()` return 0 and
`isHealthy()` returns false, so batch keeper paths skip it. `navInETH()` keeps
being consulted by total NAV (see §3.4). `emergencyExit()` **requires** the
pause and works even with a bricked pool (it bypasses both pool and
Converter).

**Converter paused** — blocks `wrapETH()`, `unwrapWETH()`,
`executeSwapExactAmountIn/Out()`. Any unpaused UniCLStrat's
`deposit()/withdraw()/rebalance()` will revert mid-flight (they wrap/unwrap
and swap through the Converter). `UniCLStrat.emergencyExit()` is unaffected
(bypasses the Converter by design). Quotes (`quoteSwapExactAmountIn/Out`) and
`grantCallerRole`/`revokeCallerRole` are not pause-gated on the Converter.

### 5.3 The `MAX_BATCH_PROCESSING_TIME` escape hatch (3 days)

`ExitQueue.MAX_BATCH_PROCESSING_TIME = 3 days` (constant).

Live share-price accounting (see `ExitQueue.liveRedemptionOffsets()`):

- Until `priceBatch`, queued EVE is still **cancellable equity** — NAV and
  supply are unchanged. Users can close the current unpriced batch at any time.
- Once a batch is **priced** (`Controller.priceBatch()` → `BatchPriced`,
  `pricedAt` set), live NAV deducts `remainingTokens * finalEvePrice` and live
  supply deducts remaining escrow. Requests **cannot be closed** for 3 days
  (`ExitQueueRequestCannotBeClosed`). Within that window they must be settled
  via `pullRequest()`.
- If **more than 3 days** pass after `pricedAt` without processing:
  - Liability **lapses in the view** with no reset transaction — enter/exit
    no longer reserve ETH for that batch.
  - `pullRequest` is **forbidden** (`ExitQueueBatchExpired`) so a keeper
    cannot pay a claim live NAV already dropped.
  - Any user can self-rescue: `AMM.cancelRedemption(batchId)` →
    `ExitQueue.closeRequest()` returns `viaEscapeHatch = true` and the AMM
    transfers the escrowed EVE back. This works **during a full protocol
    freeze** (neither function is pause-gated).
- Operational rule: **if you freeze the protocol while a priced batch is
  pending, you have a 3-day SLA.** Either finish processing the batch before
  pausing (preferred: `Controller.processRequests(batchId)` needs Controller,
  ExitQueue, and AMM all unpaused), or accept that after 3 days pull is
  forbidden, L drops out of NAV, and users exit the batch via the escape
  hatch. Monitor: alert when `block.timestamp - pricedAt > 2 days` on any
  batch with `unprocessedUsersCount(batchId) > 0`.
- If `totalNAVInETH()` reverts `StrategyManagerQueuedLiabilityExceedsNAV`
  (or AMM `AMMEscrowExceedsSupply`): pause ExitQueue so no further batches
  can be priced; wait for remaining in-window batches to lapse; users cancel
  leftover requests; then recap AMM. See scenario 10.

### 5.4 Full-freeze procedure (SECURITY multisig, single transaction batch if possible)

Use when facing an active exploit or an unexplained anomaly. Order matters —
freeze privilege escalation first, then user flows, then capital movement:

1. `Registry.pause()` — freezes all role grants/registrations (blocks an
   attacker holding a role-admin from escalating).
2. `AMM.pause()` — stops enter/exit/processRedemption.
3. `Controller.pause()` — stops all keeper flows and batch pricing.
4. `ExitQueue.pause()` — stops queue push/pull.
5. `StrategyManager.pause()` — stops fund movement into/out of strategies.
6. `UniCLStrat.pause()` for **each** registered strategy — unwinds LP to the
   strategy contract and revokes its Converter allowances. (Enumerate via
   `StrategyManager.strategies()`.)
7. `Converter.pause()` — stops wrap/unwrap/swap for every strategy at once
   (redundant with step 6's allowance revokes, but closes any remaining
   `CONVERTER_CALLER_ROLE` path immediately).
8. If capital must be pulled back: run the recovery chain of §3.5 steps 1–3
   (`emergencyExit()` per strategy → `emergencyWithdrawToController()` →
   `emergencyExitToAMM()`). Funds parked on the AMM are the safest resting
   place: they count into NAV, back `claim()`s, and the AMM is paused anyway.
9. If a malicious operation is already **queued on the timelock**: SECURITY
   holds `CANCELLER_ROLE` — cancel it on the `TimelockController` directly.

What users can still do while fully frozen (by design):
`AMM.claim()`, `AMM.cancelRedemption()` (un-priced batches immediately;
priced batches after the 3-day window), `Registry.renounceRole()`, and all
view functions.

### 5.5 Staged un-freeze procedure (ADMIN timelock; DAO proposes; 48h per schedule)

All unpauses are `ADMIN_ROLE`-gated, so each goes through the timelock. They
can be **batched into one timelock operation** (`scheduleBatch`) — but prefer
re-opening in stages across two or three operations so each stage can be
observed (and the next one cancelled) if something is still wrong:

1. **Pre-flight (before executing any unpause):**
   - Root cause fixed (feed updated §2.4, strategy removed §3.5, upgrade
     executed, …).
   - Static-call `StrategyManager.totalNAVInETH()` — must succeed.
   - Static-call `AMM.eveBasePriceInETH()` and reconcile it against off-chain
     NAV expectations: an unexplained step since the freeze began is a §6
     anomaly — do **not** re-open until it is explained.
2. **Stage 1 — infrastructure:** `Registry.unpause()`;
   `Converter.unpause()` (if it was paused); `StrategyManager.unpause()`.
   Verify: role grants work, NAV views stable.
3. **Stage 2 — strategies:** `UniCLStrat.unpause()` per strategy (re-grants
   Converter allowances). Keeper re-deploys idle Controller ETH gradually via
   `Controller.depositToStrategy(strategy, amount)` once stage 3 is done.
   Verify: `isHealthy()` true, pool calm, a small test
   deposit/withdraw round-trips.
4. **Stage 3 — flows:** `Controller.unpause()`, `ExitQueue.unpause()`.
   Keeper prices/processes any batch left from before the freeze
   (`priceBatch()` — note it reverts `ExitQueueBatchIsEmpty` if users escaped
   via the hatch, which is fine).
5. **Stage 4 — user entry/exit, last:** `AMM.unpause()`. Immediately verify a
   dust-sized `enter()` and `exit()` from an ops account, then announce
   re-open.

---

## 6. Scenario: unexplained NAV anomaly (monitoring alert)

### 6.1 There is no on-chain deviation guard — detection is off-chain

The AMM base-price deviation guard (`lastSettledBasePrice` checkpoint +
`maxPriceDeviation` band + once-per-block rule) was **removed** (see issue #241):
its only remaining rationale was catching NAV calculation bugs, at the cost of
freezing the AMM on any legitimate large NAV move. `enter()`/`exit()` now always
settle at the current NAV-backed price, and `ExitQueue.priceBatch()` accepts the
Controller-submitted base price without an on-chain band check.

Protection against bad prices now comes from the layers that remain on-chain:

1. **Strategy-layer defenses** — TWAP mirror checks, slippage limits, tick
   bounds, deadlines (UniCLStrat);
2. **Premium pricing** — the bonding-curve premium makes enter→exit cycles
   net-negative for an attacker;
3. **User slippage params** — `minTokensToMint` / `maxTokensToBurn` bound the
   price each user accepts;
4. **`SECURITY_ROLE` `pause()`** — the instant, no-timelock circuit breaker.

Anomaly **detection** is an off-chain ops responsibility: the indexer/dashboard
tracks `StrategyManager.totalNAVInETH()` and `AMM.eveBasePriceInETH()` per block
and alerts on large single-transaction moves (suggested threshold: > 5%) that
are not explained by enter/exit trade flow.

### 6.2 What a legitimate large move looks like

Do not page on moves with an obvious on-chain explanation:

- **Large enter/exit** — NAV moves by the deposit/withdrawal size (correlate
  with `UserEntered` / `RedeemedImmediately` / `RedemptionQueued` events in the
  same transaction);
- **Performance-fee harvest** — the fee mint drops the base price by roughly
  `fee/NAV`. This is correct bonding-curve mechanics, not a bug (correlate with
  `PerformanceFeePaid`);
- **Documented incident aftermath** — a realized loss from an emergency exit
  (§3.6), a strategy removal, or a feed correction after an oracle outage (§2).

### 6.3 Response flow (alert → investigate → pause if warranted → fix → unpause)

1. **Alert** — off-chain monitoring flags an unexplained NAV/base-price move.
2. **Investigate first** — reconcile NAV component-by-component:
   `StrategyManager.strategyNAVInETH()` per strategy, Controller balance,
   StrategyManager balance, `AMM.freeBalance()`. Find which component moved and
   which transaction moved it.
3. **If the move is explained** (see §6.2) — no action; log the alert as noise
   and tune the monitor threshold/correlation if it recurs.
4. **If the move is NOT explained** — treat as scenario 7: SECURITY runs the
   full-freeze procedure (§5.4) **before** any further settlement happens at the
   suspect price, then continue the investigation on-chain-forensically.
5. **Fix** — unwind or remove the offending strategy (§3.5), correct the feed
   (§2.4), or upgrade via the DAO timelock, depending on root cause.
6. **Re-open** — staged un-freeze (§5.5); every unpause is a DAO-proposed 48h
   timelock action.

### 6.4 Detection checklist for the monitor

- Track `totalNAVInETH()` and `eveBasePriceInETH()` per block; alert on
  single-transaction moves beyond the threshold with no matching
  `UserEntered` / `RedeemedImmediately` / `RedemptionQueued` /
  `PerformanceFeePaid` event.
- Alert on clusters of `RequestPulled(isWithinTolerance = false)` (slippage
  closures) — users self-protecting is an early anomaly signal.
- Alert on `RedemptionCancelled(viaEscapeHatch = true)` — keeper stalls look
  like (and can be caused by) pricing anomalies.

---

## 7. Monitoring & alerting appendix

### 7.1 Events to index (exact names, per contract)

**AMM** (`src/interfaces/IAMM.sol`)
- `UserEntered(address user, uint256 deposit, uint256 tokensMinted, uint256 timestamp)`
- `RedeemedImmediately(address user, uint256 redeemedETH, uint256 tokensBurned, uint256 timestamp)`
- `RedemptionQueued(address user, uint256 redemptionBatchId, uint256 timestamp)`
- `RedemptionProcessed(address user, uint256 redemptionBatchId, uint256 timestamp)`
- `RedemptionCancelled(address user, uint256 redemptionBatchId, bool viaEscapeHatch, uint256 timestamp)` — **alert when `viaEscapeHatch = true`** (keeper missed the 3-day window)
- `Claimed(address user, uint256 claimableETH, uint256 timestamp)`
- `ConnectorWeightChanged`, `MinBatchExitETHChanged` — governance changes, should match a known timelock op
- `Bootstrapped(address user, uint256 deposit, uint256 userTokensMinted, uint256 timestamp)`

**ExitQueue** (`src/interfaces/IExitQueue.sol`)
- `BatchPriced(uint256 batchId)` — start the 3-day processing SLA clock
- `RequestPushed(uint256 batchId, address user)`
- `RequestPulled(uint256 batchId, address user, bool isWithinTolerance)` — **alert on `isWithinTolerance = false`** clusters (slippage closures)
- `RequestClosed(uint256 batchId, address user, bool viaEscapeHatch)` — **alert on `viaEscapeHatch = true`**

**StrategyManager** (`src/interfaces/IStrategyManager.sol`)
- `StrategyAdded(address strategy)` / `StrategyRemoved(address strategy)` — clean dust-NAV removal
- `StrategyForceRemoved(address strategy, uint256 reportedNAV, bool navReverted)` — **page**: a strategy was force-removed without the residue guard (over-reporting / reverting / permanently-stuck NAV); **page on `navReverted = true`**
- `FundsDepositedToStrategy(address strategy, uint256 amount)`
- `FundsWithdrawnFromStrategy(address strategy, uint256 amount)`
- `StrategyRebalanced(address strategy)` / `StrategySynced(address strategy)` — absence over the expected keeper cadence is the alert
- `StrategyDepositFailed(address strategy, bytes reason)` / `StrategyWithdrawFailed(address strategy, bytes reason)` / `StrategyRebalanceFailed(address strategy, bytes reason)` / `StrategyHarvestFailed(address strategy, bytes reason)` / `StrategySyncFailed(address strategy, bytes reason)` — **page**: a per-strategy keeper op failed inside the batch try/catch (the batch itself did not revert)
- `SupportedERC20Added(address token)` / `SupportedERC20Removed(address token)` — governance changes; a `SupportedERC20Removed` under an active freeze is the supported-ERC-20 feed-stale escape hatch (§2.1 / §2.3) and may be emitted by SECURITY without a timelock
- `CallerRoleRevokeFailed(address strategy)` — orphaned `CONVERTER_CALLER_ROLE`, needs cleanup
- `EmergencyWithdrawnToController(uint256 amount)` — **page: emergency path used**
- `PerformanceFeePaid(address strategy, address treasury, uint256 eveAmount, uint256 feeETHEquivalent)`
- `PerformanceFeeBpsChanged(uint256 initial, uint256 current)` / `DaoTreasuryChanged(address initial, address current)` — fee-config changes

> Batch keeper paths (deposit / withdraw / rebalance / harvest / sync) wrap each
> per-strategy call in `try/catch` and emit `StrategyDepositFailed` /
> `StrategyWithdrawFailed` / `StrategyRebalanceFailed` / `StrategyHarvestFailed` /
> `StrategySyncFailed` on revert, so a single misbehaving strategy no longer
> reverts the whole batch. NAV (`_totalNAVInETH`) is **not** wrapped in
> try/catch — a reverting `navInETH()` freezes pricing.

**Controller** (`src/interfaces/IController.sol`)
- `DepositToStrategiesCompleted(requested, actual)` / `WithdrawalCompleted(requested, actual)` — alert when `actual` is persistently ≪ `requested`
- `DirectDepositCompleted(strategy, requested, actual)` / `DirectWithdrawalCompleted(strategy, requested, actual)`
- `ExitLiquidityProvided(uint256 amount)`
- `EmergencyExitedToAMM(uint256 amount)` — **page: emergency path used**
- `DirectPerformanceFeeHarvestCompleted`, `PerformanceFeeHarvestCompleted`

**Strategy (UniCLStrat / IStrategy)**
- `FundsDeposited(uint256)`, `FundsWithdrawn(uint256)`, `FundsInvested(uint256)`, `Rebalanced()`, `Synced()`
- `EmergencyExited(uint256 ethAmount)` — **page** (ETH amount only; paired-token transfer is not in the event — reconcile via token `Transfer` logs)
- `LiquidityUnwindSkipped()` — **page**: `pause()` was called and the pool-unwind self-call reverted; the strategy is paused but still holds an LP position
- `PairedTokenTransferSkipped()` — **page**: `emergencyExit()` swept ETH but the paired-token transfer reverted (blacklist/pause); paired inventory remains on the strategy — retry `emergencyExit()` once transferable
- `PerformanceFeeSettled(uint256 feeETH)` — strategy-local performance-fee settlement (drives the EVE dilution mint on the StrategyManager)
- Config events (`TwapIntervalUpdated`, `MaxTickDeviationUpdated`, `RouteConfigUpdated`, `SwapSlippageUpdated`, `MaxTotalNAVUpdated`, …) — must match known timelock ops

**Oracle** (`src/interfaces/IOracle.sol`)
- `UsdFeedAdded(token, priceFeed, stalenessInterval)`, `TokenRemoved(token)`, `UsdFeedUpdated(token, oldFeed, newFeed)`, `UsdStalenessIntervalUpdated(token, old, new)` — all must match known timelock ops; anything else is a governance-compromise page

**Registry** (`src/interfaces/IRegistry.sol`)
- `ContractRegistered(key, oldAddress, newAddress)` — **page**: address rewiring changes what "the AMM/Controller/…" *is*
- `ContractUnregistered(key, oldAddress)` — **page**
- `RoleRegistered(role)` / `RoleUnregistered(role)`
- OpenZeppelin `RoleGranted(role, account, sender)` / `RoleRevoked(role, account, sender)` — **page on any grant of `ADMIN_ROLE` or `SECURITY_ROLE`**
- `Paused(account)` / `Unpaused(account)` (OpenZeppelin `Pausable`) — emitted by **every** pausable contract; index on all of Registry, AMM, Controller, ExitQueue, StrategyManager, Converter, and each strategy

**TimelockController (admin timelock)**
- `CallScheduled` — begin the 48h review window: verify target/calldata against the DAO's announced intent; SECURITY cancels if malicious
- `CallExecuted`, `Cancelled`

### 7.2 State to poll (revert-based failure detection)

| Probe (static call) | Alert condition |
|---|---|
| `AMM.eveBasePriceInETH()` | reverts → NAV frozen (scenario 2/5) |
| `AMM.eveBasePriceInUSD()` | reverts while ETH view works → ETH/USD feed problem (scenario 1) |
| `StrategyManager.strategyNAVInETH(s)` per strategy | reverts → the frozen strategy, isolated |
| Chainlink `feed.latestRoundData()` per configured token | `now − updatedAt` > 80% of `Oracle.getUsdFeedInfo(token).stalenessInterval` |
| `UniCLStrat.isHealthy()` | false beyond rebalance cadence |
| `pool.slot0().observationCardinality` | < required for `twapInterval` |
| `AMM.eveBasePriceInETH()` block-over-block delta | unexplained single-tx move > ~5% (§6 monitoring flow) |
| `ExitQueue.batchInfo(id)` for open batches | `canBeProcessed && unprocessedUsersCount(id) > 0 && now − pricedAt > 2 days` (1-day margin before the 3-day hatch) |
| `paused()` on every pausable contract | any unexpected `true` |
| Keeper account transactions | any revert; decode selector against §7.3 |

### 7.3 Revert selectors worth decoding in alerts

`OracleStalePrice()`, `OracleInvalidPrice()`, `OracleNoRoundData()`,
`OracleInvalidTimestamp()`, `OracleInvalidFeedDecimals()`, `OraclePairNotRegistered()`,
`UniCLStratNotCalm()`, `UniCLStratNotPaused()`, `UniCLStratPoolTWAPNotAvailable()`,
`UniCLStratQuoteFailed()`, `UniCLStratQuoteBelowOracleFloor(uint256,uint256)`,
`UniCLStratQuoteExceedsOracleCeiling(uint256,uint256)`,
`StrategyManagerStrategyNAVResidueTooHigh(address)`,
`StrategyManagerERC20NotPriceable(address)`,
`StrategyManagerERC20NotSupported(address)`,
`StrategyManagerNoBalanceToRecover()`, `ExitQueueRequestCannotBeClosed()`,
`ControllerInsufficientBalance()`, `EnforcedPause()` (OpenZeppelin).

CRE receivers (`CREQueueExecutor` / `CREStrategyExecutor`) — these tell you *why* a
report bounced, which is the difference between a workflow bug and a DON outage:

| Selector | Reading |
|---|---|
| `InvalidSender(address,address)` | Something other than the KeystoneForwarder called `onReport` — **page**, this is an attempted forgery |
| `InvalidWorkflowId(bytes32,bytes32)` / `InvalidAuthor(address,address)` / `InvalidWorkflowName(bytes10,bytes10)` | Identity binding does not match the deployed workflow — usually a re-deployed workflow that was never re-bound by ADMIN |
| `CREReceiverWorkflowUnbound()` | Receiver deployed but never bound. Expected before go-live; **page** after |
| `CREReceiverWrongChain()` | Envelope carries another chain's selector — a workflow is writing to the wrong deployment |
| `CREReceiverReplayedSequence()` | Re-delivery of an already-executed report. Benign in isolation; a sustained stream means the workflow is not advancing its sequence |
| `CREReceiverFutureTimestamp()` | `observedAt` is ahead of chain time — **workflow clock skew or a malformed report**, not a delivery-latency problem |
| `CREReceiverStaleReport()` | `observedAt` is older than `MAX_REPORT_AGE` — **delivery latency**: DON congestion, a stuck workflow, or `MAX_REPORT_AGE` set too tight |
| `KeeperExecutorNoUpkeepNeeded()` | The report's claim did not survive re-validation against live state. Normal at low rates (races); a sustained stream means the workflow's off-chain view has drifted |
| `KeeperExecutorUnknownAction()` | Action byte outside the executor's enum — workflow/contract version mismatch |

### 7.4 Time constants cheat sheet

| Constant | Value | Where |
|---|---|---|
| Admin timelock delay | 48h minimum (`DEFAULT_ADMIN_TIMELOCK_DELAY`; deploy scripts revert below this floor; upgrades scheduled longer by policy) | `script/ProtocolDeployBase.sol` |
| `ExitQueue.MAX_BATCH_PROCESSING_TIME` | 3 days | `src/contracts/ExitQueue.sol` |
| Oracle staleness | per-token `stalenessInterval`, set via `updateUsdFeedInfo` | `src/contracts/Oracle.sol` |
| `UniCLStrat.MIN_TWAP_INTERVAL` | 1800 s (long TWAP floor) | `src/contracts/strategies/UniCLStrat.sol` |
| `UniCLStrat.MIN_SHORT_TWAP_INTERVAL` | 60 s | `src/contracts/strategies/UniCLStrat.sol` |
| `StrategyManager.MAX_NAV_RESIDUE` | 10 wei | `src/contracts/StrategyManager.sol` |

---

*Maintenance note: this document describes the contracts as deployed from this
repository revision. Re-verify every signature and role gate against the
source whenever a contract is upgraded or redeployed, and update the matrix
accordingly.*
