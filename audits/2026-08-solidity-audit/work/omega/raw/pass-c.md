# Omega independent pass C

Snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
Focus: cross-contract state timing, external-data assumptions, asset exits, upgrades, and unusual branch combinations.
Constraints: local/read-only review of the frozen bundle and base source/tests; no network, live systems, post-base commits, prior review output, `work/pashov`, or `test/audit` were read.

## FINDING C-01 — Emergency-exited paired tokens have no asset-exit path

FINDING

- severity: medium
- likelihood: likely
- impact: material
- confidence: high
- affected: `src/strategies/UniCLStrat.sol::emergencyExit`; `src/strategies/StrategyManager.sol::{addSupportedERC20,removeSupportedERC20,_supportedERC20sNAVInETH}`
- summary: `UniCLStrat.emergencyExit()` intentionally transfers residual paired tokens to `StrategyManager`, but `StrategyManager` can only whitelist and price ERC-20 balances; it has no transfer, conversion, or recovery path for them. A successful emergency unwind can therefore strand assets while still counting them in NAV.
- evidence:
  - `UniCLStrat.emergencyExit()` performs a best-effort `pairedToken.trySafeTransfer(strategyManagerAddress, ...)` after unwinding positions.
  - `StrategyManager` states that supported-token handling is “ERC-20 accounting only” and that swap recovery is deferred.
  - `_supportedERC20sNAVInETH()` adds the manager's token balances to protocol NAV, while `removeSupportedERC20()` only removes the token from the accounting set.
  - No scoped `StrategyManager` function transfers or swaps a supported ERC-20 out.
- trigger: a paused/emergency strategy has nonzero paired-token inventory and `emergencyExit()` transfers it to `StrategyManager`.
- consequence: the token cannot fund native-ETH redemptions; leaving it supported overstates liquid backing, while removing it drops real value from reported NAV. Recovery requires a contract upgrade or otherwise out-of-band privileged intervention.
- exploit narrative: ordinary pool exposure produces paired inventory; security/admin executes the intended emergency exit; the transfer succeeds; subsequent EVE exits are priced against an asset the protocol cannot liquidate or return.
- recommendation: add a tightly authorized, paused-only recovery/conversion path with explicit token and receiver controls, balance-delta checks, slippage limits, and events; make emergency-exit completion distinguish transferred-but-unliquidated assets from native liquidity.
- poc: none — reasoning-only; the ingress and absence of any scoped egress are directly visible in the frozen source.

## FINDING C-02 — Unpoked Uniswap fee growth is omitted from NAV used for settlement

FINDING

- severity: medium
- likelihood: likely
- impact: material
- confidence: high
- affected: `src/strategies/UniCLStrat.sol::{navInETH,_amountsForPosition,sync}` and EVE entry/exit pricing consumers
- summary: position NAV includes liquidity principal and `tokensOwed`, but not fee growth accumulated since the last pool poke. `sync()` materializes that growth with a zero-liquidity burn, so the protocol settles users against a predictably stale, understated NAV between pokes.
- evidence:
  - `_amountsForPosition()` reads `liquidity`, `tokensOwed0`, and `tokensOwed1` from `pool.positions(...)`, then adds only liquidity amounts plus those stored owed values.
  - It does not derive pending fees from global/outside/inside fee-growth accumulators.
  - `sync()` calls `pool.burn(tickLower, tickUpper, 0)` for each position so accrued fees flow into `tokensOwed`.
  - The source explicitly notes that unpoked fee growth is invisible until `sync()` or another poke.
  - `IStrategy.navInETH()` requires accounting for all funds for which the strategy is economically responsible.
- trigger: LP fees accrue after the last poke and a user enters or exits through NAV-dependent EVE pricing before the next `sync()`.
- consequence: departing holders surrender their share of unmaterialized fees to remaining holders; other NAV-based actions also use an understated asset base. Repeated timing around fee-rich intervals can redistribute value.
- exploit narrative: wait for meaningful pool activity without a strategy poke, settle a redemption at understated NAV, then allow `sync()` to recognize fees for the residual supply. The inverse timing affects new issuance according to the AMM's premium/discount state.
- recommendation: compute pending fee growth in the view NAV using canonical Uniswap V3 fee-growth math, or require an atomic/fresh poke before any settlement and reject settlement once a short, explicit freshness bound expires.
- poc: none — reasoning-only; the omission and the materialization operation are explicit.

## FINDING C-03 — A new performance-fee rate applies retroactively to old uncharged fees

FINDING

- severity: medium
- likelihood: possible
- impact: material
- confidence: high
- affected: `src/strategies/StrategyManager.sol::setPerformanceFeeBps`; `src/strategies/UniCLStrat.sol::{pendingPerformanceFeeInETH,settlePerformanceFee}`
- summary: the manager changes the global fee rate without first settling accrued strategy fees. Each strategy stores a cumulative uncharged fee base and multiplies the whole base by the current manager rate, retroactively repricing fees earned under the previous rate.
- evidence:
  - `setPerformanceFeeBps()` updates the rate without harvesting/settling strategies first.
  - `UniCLStrat` accumulates `_unchargedLpFeesInETH` without rate-era checkpoints.
  - both pending and settlement calculations apply the then-current `_performanceFeeBps` to that entire accumulator.
- trigger: governance changes the rate while any strategy has nonzero uncharged LP fees, then a harvest/settlement occurs.
- consequence: increasing the rate transfers more historic value from EVE holders to the fee recipient than the rate in force while that value accrued; decreasing it under-collects historic fees. The error can cover the entire unsettled accumulator and is bounded only by the configured fee cap.
- exploit narrative: allow fees to accumulate at one rate, change the rate, and settle immediately; no per-period bookkeeping preserves the former entitlement.
- recommendation: atomically and successfully settle every strategy at the old rate before changing it, reverting the rate change on any settlement failure; alternatively checkpoint fee bases per rate epoch.
- poc: none — reasoning-only; the time-indexed accumulator and current-rate multiplication establish the mismatch.

## FINDING C-04 — Deployment configuration can silently eliminate the promised admin delay

FINDING

- severity: medium
- likelihood: possible
- impact: material
- confidence: high
- affected: `script/deploy/ProtocolDeployBase.s.sol::{_deployTimelocks,_deployTimelock}` and deployment verifiers
- summary: deployment advertises a 48-hour default admin timelock, but an environment override is accepted without a lower bound and verifiers do not check the deployed delay. A zero or short configured value silently removes the response window for upgrades and other admin actions.
- evidence:
  - `DEFAULT_ADMIN_TIMELOCK_DELAY` is `48 hours`.
  - `_deployTimelocks()` reads `TIMELOCK_ADMIN_DELAY` with that value only as a fallback.
  - `_deployTimelock()` passes the supplied value directly into `TimelockController`.
  - scoped verification checks role topology but does not assert `getMinDelay()`.
- trigger: an operator typo, stale environment, or intentionally weak `TIMELOCK_ADMIN_DELAY` during deployment.
- consequence: upgrades, registry changes, feeds, and other admin operations can execute with less notice than the documented safety model, preventing users/security operators from reacting.
- exploit narrative: deploy with delay `0`; role checks pass; a proposer schedules and immediately executes a privileged change despite the expected 48-hour buffer.
- recommendation: revert unless the configured delay is at least the declared protocol minimum, print it prominently, and make deployment verification assert the exact on-chain `getMinDelay()` for each timelock.
- poc: none — reasoning-only; the unchecked value flow is direct.

## FINDING C-05 — Replacing a live Registry key can orphan state and escrow in the old module

FINDING

- severity: medium
- likelihood: possible
- impact: material
- confidence: medium
- affected: `src/Registry.sol::_registerContract` and dynamically resolved protocol peers, especially `AMM`, `ExitQueue`, and `EVE`
- summary: `_registerContract()` overwrites an existing key with any code-bearing address, while modules dynamically resolve the current address and authorization also follows the current mapping. There is no state/liability migration protocol, so replacing a stateful module can make its old escrow inaccessible to the peer that must release it.
- evidence:
  - `_registerContract()` uses map `set` semantics and emits old/new addresses without rejecting an already populated stateful key.
  - modules resolve counterparties through the Registry at call time.
  - an old AMM can hold EVE for queued redemption, but queue close authorization recognizes only the currently registered AMM.
  - no scoped replacement operation migrates outstanding requests, claim liabilities, balances, or user accounting before the key switch.
- trigger: admin/timelock replaces a live stateful module key while the old instance has pending requests, claims, escrow, or other liabilities.
- consequence: cross-contract callbacks/authorization can fail and user assets can remain in the old instance until rollback, bespoke migration, or upgrade; swapping multiple keys in different transactions also exposes mixed-version states.
- exploit narrative: queue a redemption so the old AMM escrows EVE; replace the AMM key; the old AMM is no longer the authorized caller for queue closure, while the new AMM does not own the old escrow/state.
- recommendation: prohibit overwriting stateful singleton keys; use their UUPS upgrade path where available. For unavoidable replacement, use a versioned migration state machine with liability-zero preconditions or explicit state transfer, dual authorization during migration, and an atomic final cutover.
- poc: none — reasoning-only; confidence is medium because operational rollback can restore access, but no in-protocol migration invariant prevents the orphaned state.

## LEADS

LEAD

- hypothesis: `UniCLStrat._pauseStrategy()` can be rolled back by an approval-hostile paired token because `_removeConverterAllowances()` performs token approval mutations outside the pool-unwind `try/catch`, contradicting the intended dependency-independent circuit breaker.
- affected: `src/strategies/UniCLStrat.sol::{_pauseStrategy,_removeConverterAllowances}`
- why unresolved: failure depends on paired-token approval semantics and was not exercised under the time-box.
- next step: build an isolated mock token whose `approve(0)` reverts after strategy setup and assert whether `pause()` leaves the strategy paused or reverts atomically.

LEAD

- hypothesis: `StrategyKeeperExecutor._pendingRedemptionNeedsETH()` scans at most 50 users even when queue upkeep permits batches up to 100, so excess-deposit/liquidity decisions may ignore part of an immediately processable redemption liability and cause avoidable withdraw/deposit churn or delayed exits.
- affected: `src/keepers/StrategyKeeperExecutor.sol::_pendingRedemptionNeedsETH`; queue batch configuration
- why unresolved: the cap mismatch is concrete, but no bounded economic loss or durable starvation was established.
- next step: statefully queue more than 50 priced users, vary the ETH balance around the aggregate liability, and trace keeper action selection and completion latency.

## CLEARED AREAS

CLEARED

- claim-liability accounting: reviewed AMM process/claim/cancel ordering, exact ETH receipt, `lockedForClaims`, and free-balance checks; claim state clears before ETH send and no scoped over-withdraw path was found.

CLEARED

- converter adapter accounting: reviewed exact-input/output balance-delta enforcement, minimum output, maximum input, and refund paths; a whitelisted adapter cannot drain pre-existing balances merely by falsifying its return value under standard token semantics.

CLEARED

- queue accounting: reviewed request push/pull/close totals, set removal, controller snapshot-before-mutation behavior, and escape-hatch flow; no scoped total/request desynchronization was established.

CLEARED

- UUPS initialization and authorization: constructors disable initializers, proxies initialize atomically, and scoped upgrade authorization is admin-gated. This was a full-snapshot review, so no implementation-to-implementation storage-layout diff was available or claimed.

CLEARED

- whitelist and transfer reachability: EIP-712 invite domain/user/invite/deadline/replay bindings were traced; whitelist gates entry, while redemption, cancellation, and claims remain reachable without a transfer hook. No ERC-4626 conformance claim exists.

## Skill coverage

- `omega-audit-workflow/SKILL.md` and references `finding-format.md`, `pass-prompts.md`, and `merge-protocol.md`: read fully and applied.
- all 11 Omega lenses read fully and applied: accounting consistency; asset exit paths; enforceability check; external data trust; ordering and approval races; repo hygiene sweep; share and index accounting; standard conformance; time-indexed state; transfer-restriction hooks; upgrade diff review.
- pass-C routing applied: state timing, external assumptions, asset exits, upgrades/replacements, and unusual branch combinations. Snapshot mode was used for upgrade review because the scoped bundle is not a version diff.

## Commands and results

- `wc -l` over the workflow, three references, and 11 lens `SKILL.md` files: 4,118 lines total; every file then read through EOF with bounded `sed` ranges.
- `wc -l` over allowed bundle files: `scope.md` 139, `profile.md` 207, `context.md` 181, `xray.md` 253, `source.md` 9,417; each read fully through EOF.
- `rg '^### '` on `source.md`: enumerated all 39 bundled source sections for coverage.
- `git show 734df96a1391e95dd40843210997da0b9f3ab05e:<path>`: read relevant base tests/interfaces, including AMM, protocol test base, UniCL strategy fixtures/mocks, and `IOracle`, `IStrategy`, and `IAMM`.
- No candidate test was authored or run. The frozen profile records the baseline compile and test suite as passing; this pass does not represent that baseline as independently re-run.
- No network or live-system command was used; no commit was created.

AGENT_STATUS: COMPLETE
