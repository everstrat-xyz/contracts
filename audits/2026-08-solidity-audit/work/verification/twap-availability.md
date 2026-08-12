# UniCL TWAP availability can freeze protocol NAV

## Verdict

**CONFIRMED behavior — Low severity (configuration/liveness risk).** At immutable base
commit `734df96a1391e95dd40843210997da0b9f3ab05e`, the UniCL constructor,
StrategyManager registration, and `setTwapInterval` accept a long TWAP window without
checking whether `pool.observe([window, 0])` can serve it. Once registered, an unavailable
long observation makes UniCL `navInETH()` revert; StrategyManager intentionally propagates
that revert, freezing post-bootstrap AMM entry, exit, and price views.

Impact is protocol-wide, but the base twice documents the pool-history prerequisite and the
protocol state transitions that introduce it are ADMIN-controlled. This is therefore a
deployment/configuration hazard rather than a permissionless exploit under the documented
operating assumptions. If the audit threat model includes registering an under-provisioned
active pool whose observation ring can later be shortened by ordinary permissionless swaps,
the same trace has Medium liveness impact.

## Admission and configuration evidence

- `UniCLStrat.sol:50-57` explicitly warns that the pool must cover the 30-minute minimum or
  `navInETH()` freezes pricing until the buffer fills.
- Constructor validation checks nonzero addresses, positive tick settings, and only the
  lower bounds `twapInterval >= 1800` / `shortTwapInterval >= 60`; it never calls `observe`
  (`UniCLStrat.sol:1280-1296`). Route validation is unrelated to history.
- The deployment script similarly checks only those floors and leaves cardinality as an
  operator prerequisite (`DeployUniCLStrat.s.sol:91-120`, especially `:94-97`).
- `StrategyManager.addStrategy` checks address/code/duplication, sets weights, and grants a
  Converter role. It performs no `navInETH`, health, or observation preflight
  (`StrategyManager.sol:152-172`). A zero-weight or zero-NAV strategy still joins NAV.
- `setTwapInterval` is ADMIN_ROLE-only, but its internal validation is again only the
  1800-second floor, with no upper bound below `uint32.max` and no observation probe
  (`UniCLStrat.sol:420-434,554-558`).

## Exact failure trace and bounds

`navInETH()` always enters `_balancesOfPool()` and requests the long TWAP before checking
whether either position is initialized (`UniCLStrat.sol:199-203,665-676`). Therefore even a
new, empty strategy can freeze aggregate NAV.

1. `_twap()` calls `TickUtils.tryMeanTick(pool, twapInterval)`.
2. `tryMeanTick` calls `observe([interval, 0])` and maps an insufficient-buffer revert to
   `(false, 0)` (`TickUtils.sol:24-40,49-53`).
3. `_twap()` converts false into `UniCLStratPoolTWAPNotAvailable`
   (`UniCLStrat.sol:713-727`).
4. StrategyManager loops through every registered strategy and does not catch `navInETH`,
   expressly documenting that one revert freezes enter/exit/pricing
   (`StrategyManager.sol:924-950`).
5. AMM entry reads aggregate NAV after bootstrap (`AMM.sol:397-423`); exit reads it before
   calculating base price and burn amount (`AMM.sol:138-166`). All four public EVE price
   views ultimately use the same NAV.

The fail-soft surfaces differ: `isHealthy()` returns false and `maxDeposit()` returns zero
when `_isCalm` cannot observe (`UniCLStrat.sol:214-223,679-702`). A failure limited to the
short 60-second window therefore blocks health/deposit eligibility but does not itself break
NAV, which uses only the long window. The protocol-wide revert requires the configured long
window to be unavailable (or another failure on that long observe call).

An unbootstrapped AMM's first `_bootstrap` call does not query NAV, so this finding freezes
normal post-bootstrap pricing, not necessarily the first-ever deposit. Existing AMM claims
and cancellation paths that do not reprice NAV remain callable; new exits, entries, price
reads, and new queue batch pricing do not.

## Regression evidence

`test/audit/candidates/verification/TwapAvailability.t.sol` uses the real Registry,
StrategyManager, AMM, EVE, Oracle, Converter, and UniCL strategy plus an isolated pool whose
`observe` reverts `OLD` when a requested window exceeds retained history.

The test proves:

- constructor and registration succeed with 1,799 seconds retained and a 1,800-second long
  window; health/maxDeposit fail soft while strategy and aggregate NAV revert;
- growing history to 1,800 seconds restores NAV;
- changing the live strategy to 3,600 seconds succeeds while only 1,800 is retained, then
  aggregate price, AMM entry, and AMM exit all revert;
- clean `removeStrategy` is unusable because it reads NAV;
- each recovery works independently: history grows to 3,600, ADMIN lowers the interval to
  1,800, or ADMIN calls `forceRemoveStrategy`, whose NAV read is deliberately caught.

## Recovery, roles, and delay

Cold start recovers without a protocol call once the pool can serve the configured window,
provided its observation capacity is sufficient; the minimum allowed long window cannot be
lowered below 30 minutes. An overly long configured window can be lowered to any already
serviceable value at least 1,800 seconds.

Both `setTwapInterval` and `forceRemoveStrategy` require ADMIN_ROLE. The production role
model assigns ADMIN_ROLE to the 48-hour TimelockController, while SECURITY_ROLE has immediate
pause authority but no interval/force-remove authority (`DeployAll.s.sol:16-27`). Thus after
go-live these configuration recoveries normally require the 48-hour governance delay.
`forceRemoveStrategy` is explicitly designed to catch a reverting NAV and does not require
the strategy to be paused (`StrategyManager.sol:240-266`); ordinary `removeStrategy` cannot
recover this state because it calls the reverting NAV first (`:228-237`).

If capital exists, force-removal restores pricing by dropping the strategy from aggregate
NAV but does not itself recover its assets. Operators must separately pause/unwind and use
the strategy emergency path as appropriate; paired-token recovery must follow the documented
StrategyManager supported-token/oracle setup. Pausing alone does not make `navInETH` skip its
TWAP read.

## Attempts

Pinned Forge 1.0.0, offline, isolated output/cache:

```text
# Attempt 1
FOUNDRY_OUT=/private/tmp/twap-availability-out-1 \
FOUNDRY_CACHE_PATH=/private/tmp/twap-availability-cache-1 \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/TwapAvailability.t.sol -vvv
```

Result: `0 passed; 1 failed`. The trace proved every expected production revert reached up
to AMM entry. The harness then placed `expectRevert` before an external `EVE.balanceOf`
argument read, so that read incorrectly consumed the expectation. The value was cached
before `expectRevert`; no production logic changed.

```text
# Attempt 2
FOUNDRY_OUT=/private/tmp/twap-availability-out-2 \
FOUNDRY_CACHE_PATH=/private/tmp/twap-availability-cache-2 \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/TwapAvailability.t.sol -vvv
```

Result: `1 passed; 0 failed; 0 skipped`. The only warning was inability to write Forge's
optional signature cache under `~/.foundry`.

The remaining allowed attempt reproduced the combined verifier glob after the fixture fix:

```text
# Attempt 3
FOUNDRY_OUT=/private/tmp/twap-availability-out-3 \
FOUNDRY_CACHE_PATH=/private/tmp/twap-availability-cache-3 \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path 'test/audit/candidates/verification/*.t.sol' -vvv
```

Result: `20 test suites; 32 passed; 0 failed; 0 skipped`, including
`TwapAvailabilityTest`. No attempts remain or are needed.

No production source was edited; no network or live system was used.

AGENT_STATUS: COMPLETE
