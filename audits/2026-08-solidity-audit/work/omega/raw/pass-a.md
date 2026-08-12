# Omega pass A — bottom-up independent review

base: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: all 25 production Solidity files plus deployment/config context in the supplied bundle
method: immutable bundle and `git show <base>:<path>` only; no network, live systems, post-base commits, or other review output

FINDING
file:         src/contracts/StrategyManager.sol
function:     emergencyWithdrawToController / supported ERC-20 management
mechanism:    UniCLStrat's emergency exit sends its paired token to StrategyManager, but StrategyManager has no ERC-20 transfer, conversion, or recovery function and its emergency withdrawal handles native ETH only.
consequence:  Successfully recovered paired tokens become inaccessible without a contract upgrade; while supported they inflate NAV despite being unusable for ETH redemptions, and removing support merely deletes their NAV contribution while leaving them stranded.
trigger:      admin or security role invoking the documented UniCLStrat emergency exit when paired-token inventory remains
severity:     medium
rationale:    The emergency state is exceptional, but it deterministically strands potentially material protocol assets and requires privileged upgrade intervention; impact dominates likelihood.
poc:          none — reasoning only
evidence:     `UniCLStrat.sol:508-513`: `if (_pairedBalance > 0) { ... if (!pairedToken.trySafeTransfer(strategyManagerAddress, _pairedBalance)) { emit PairedTokenTransferSkipped(); } }`; `StrategyManager.sol:458-461`: `uint256 amount = address(this).balance; ... payable(registry().controller()).sendValue(amount);`; `StrategyManager.sol:466-468`: `ERC-20 accounting only in this release ... On-chain swap recovery of stranded supported ERC-20s back to native ETH via the shared Converter is deferred to a follow-up PR.`
fix:          Add an ADMIN/SECURITY-gated ERC-20 recovery path that transfers to Controller or converts through the configured Converter with explicit slippage bounds, and keep recovered-token NAV treatment consistent until conversion completes.
related:      none

FINDING
file:         src/contracts/automation/StrategyKeeperExecutor.sol
function:     checkUpkeep / performUpkeep
mechanism:    checkUpkeep always selects Rebalance before withdrawal and exit-liquidity actions whenever a strategy reports unhealthy, although UniCLStrat reports unhealthy when the pool is not calm and its rebalance necessarily reverts in that same state; StrategyManager catches that revert without changing state.
consequence:  During a prolonged non-calm/TWAP-unavailable state, every canonical automation cycle repeats a no-op rebalance and can indefinitely starve redemption-shortfall withdrawal, exit-liquidity provisioning, deposits, harvesting, and synchronization.
trigger:      adverse external pool/TWAP state followed by ordinary keeper operation through checkUpkeep
severity:     medium
rationale:    Market volatility or observation unavailability is plausible and can block protocol automation and delay queued exits, although privileged/manual recovery and the queue escape hatch limit ultimate loss.
poc:          none — reasoning only
evidence:     `StrategyKeeperExecutor.sol:169-181`: `if (_rebalanceNeeded(strategyManager_)) { return (true, abi.encode(StrategyAction.Rebalance)); }` precedes `WithdrawShortfall`; `UniCLStrat.sol:214-216`: `if (!_isCalm()) return false;`; `UniCLStrat.sol:350-352`: `if (isHealthy()) revert StrategyIsHealthy(); if (!_isCalm()) revert UniCLStratNotCalm();`; `StrategyManager.sol:1180-1185`: the call is wrapped in `try strategy.rebalance() ... catch ... { emit StrategyRebalanceFailed(...) }`.
fix:          Make rebalance eligibility distinguish an out-of-range calm position from a non-actionable unhealthy state, or apply bounded retry/backoff and allow liquidity-critical actions after a failed rebalance.
related:      none

LEAD
file:         src/contracts/StrategyManager.sol
function:     setPerformanceFeeBps / harvestPerformanceFees
suspicion:    Changing the global fee rate does not first settle accrued, uncharged strategy fees, while later settlement applies the current rate to the full cumulative uncharged fee base; a rate increase may therefore reprice historical earnings retroactively.
blocked_by:   The supplied policy does not establish whether performance fees are intentionally assessed at accrual time or harvest time.
next_step:    Confirm intended fee semantics, then run a two-epoch regression (accrue at rate A, set rate B, settle) and require old accruals to retain rate A if changes are prospective.

LEAD
file:         src/contracts/StrategyManager.sol
function:     _mintPerformanceFeeEVE
suspicion:    A strategy advances its cumulative charged-fee state before StrategyManager's share-mint calculation, so a positive `feeETH` that rounds to zero EVE could be permanently marked charged without compensating the DAO.
blocked_by:   Reachability depends on protocol-wide supply/NAV bounds; no asserted lower bound proves every positive fee maps to at least one EVE unit.
next_step:    Stateful-fuzz supply, NAV, and positive fee values across the permitted lifecycle; either revert/defer zero-share settlements or carry fee dust forward.

CLEARED
area:         AMM native-ETH accounting and claims
checked:      Traced instant and queued redemption through `lockedForClaims`, pull claims, cancellation, and emergency paths; state is reserved before payment, claim value is not reused, and cancellation remains available while paused.

CLEARED
area:         ExitQueue state machine and time edges
checked:      Checked queue cursor progression, pending/processed/cancelled transitions, final-price expiry, skip behavior, and the three-day user escape hatch; no duplicate settlement or trapped pending-state path was found.

CLEARED
area:         Converter custody and swap bounds
checked:      Checked measured balance-delta accounting, exact-input/output limits, refund/recipient flow, transient approvals, and authorization boundaries; no caller-selectable unbounded asset exit was found.

CLEARED
area:         Oracle pair lifecycle and normalization
checked:      Checked positive answer, `updatedAt`, future timestamp, staleness, feed-decimal normalization, pair direction, and removal cleanup; no stale or deleted pair remained usable through the reviewed paths.

CLEARED
area:         Upgradeability and initialization
checked:      Reviewed constructors disabling initializers, atomic proxy initialization in deployment scripts, ERC-7201 registry storage, and storage gaps. This was a full snapshot, so no implementation diff was available for layout comparison.

CLEARED
area:         Token restrictions and standard conformance
checked:      EVE inherits OpenZeppelin ERC-20 behavior and restricts mint/burn; whitelist checks constrain entry rather than token transfers, and ban/disable states do not remove redemption exits.

CLEARED
area:         UniCL callback and emergency sequencing
checked:      Verified callback sender plus `_minting` guard, pause-time allowance revocation, ETH-first emergency sweep, and best-effort paired-token transfer. The destination's missing ERC-20 exit is reported separately.

## Exact Omega lens coverage

- omega-asset-exit-paths: mapped ETH/ERC-20 custody and terminal exits; produced finding 1.
- omega-enforceability-check: checked limits, role checks, deadlines, and runtime enforcement rather than comments alone.
- omega-accounting-consistency: traced NAV, supply, claim liabilities, queue totals, strategy deposits/withdrawals, and fee state.
- omega-external-data-trust: reviewed Chainlink validity, Uniswap TWAP availability/deviation, token decimals, and quote-to-execution bounds.
- omega-ordering-and-approval-races: reviewed CEI, transient allowances, callbacks, keeper priority, and same-block action ordering; produced finding 2.
- omega-upgrade-diff-review: no diff supplied; reviewed snapshot initialization, authorization, registry namespace, storage gaps, and deployment wiring.
- omega-time-indexed-state: reviewed queue expiry/cancellation windows, oracle staleness, invite deadlines, TWAP horizons, and fee epoch ambiguity.
- omega-share-and-index-accounting: reviewed EVE mint/burn pricing, NAV denominator, fee-share dilution, rounding, and zero-rounded fee lead.
- omega-transfer-restriction-hooks: verified entry-only whitelist/ban design and that transfer-free exit paths remain available.
- omega-standard-conformance: checked ERC-20 semantics, SafeERC20 handling, UUPS surface, Chainlink Automation interface behavior, and Uniswap callback authentication.
- omega-repo-hygiene-sweep: reviewed pinned Foundry version, lockfiles/submodules, compiler/config profile, deployment scripts, and tracked CI context; no standalone exploit finding promoted.

## Commands and results

- Fully read the workflow `SKILL.md`, `finding-format.md`, `pass-prompts.md`, `merge-protocol.md`, and all 11 lens `SKILL.md` files: completed.
- Fully read bundle `scope.md` (139 lines), `profile.md` (207), `context.md` (181), `xray.md` (253), and `source.md` (9,417): completed.
- `git rev-parse HEAD`: shared checkout was not the audit base, so no working-tree source was trusted for conclusions.
- `git show 734df96a1391e95dd40843210997da0b9f3ab05e:<path>` / `git grep ... <base> -- <path>`: inspected base-only source/interface/test/config evidence; completed read-only.
- Foundry regression: not authored or run; both promoted mechanisms are established by mutually exclusive predicates/direct custody paths, and no test file was created.
- Baseline noted from supplied `scope.md`: 1,169 Forge tests passing; not independently rerun in this pass.

AGENT_STATUS: COMPLETE
summary: Two medium-severity reasoning-only findings, two explicit leads, and seven cleared areas; all 11 Omega lenses applied at the immutable base.
