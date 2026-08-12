# Verification: failed rebalance monopolizes keeper priority

VERDICT: CONFIRMED

SUGGESTED SEVERITY: Medium

BASE: `734df96a1391e95dd40843210997da0b9f3ab05e`. Validation used the immutable production source, interfaces, base helpers/mocks, and one isolated local regression. No network or live deployment was used.

## Mechanism

`StrategyKeeperExecutor.checkUpkeep` returns the first actionable item from a strict priority list. An unhealthy, unpaused strategy selects `Rebalance` before redemption `WithdrawShortfall` (`StrategyKeeperExecutor.sol:169-181`). `performUpkeep(Rebalance)` rechecks only that a strategy is still unhealthy, calls the Controller, and reports a completed upkeep (`:224-228`). It does not require any strategy to become healthy or record backoff.

StrategyManager deliberately catches a failed strategy rebalance and continues (`StrategyManager.sol:1177-1187`). That failure isolation is useful for a batch, but it also means the keeper transaction succeeds without changing the predicate that selected it.

UniCL creates a deterministic production instance of the split predicate during a non-calm market:

- `isHealthy()` returns false whenever `_isCalm()` is false (`UniCLStrat.sol:214-223`);
- `rebalance()` first observes that it is unhealthy, then reverts `UniCLStratNotCalm` for the same condition (`:350-359`); and
- `maxWithdrawal()` remains equal to NAV while unpaused (`:209-212`), while `withdraw()` can remove liquidity and intentionally skips re-adding it when the pool remains non-calm (`:299-345`).

Thus the lower-priority withdrawal can be useful and executable at precisely the time every routine check selects a no-progress rebalance.

## Impact and bounds

While a registered UniCL pool is outside its configured calm bound, Chainlink Automation can repeatedly spend upkeep gas on successful-but-no-progress Rebalance calls. `WithdrawShortfall`, exit-liquidity top-ups, deposits, fee harvests, and sync remain unreachable through the normal `checkUpkeep` result. The highest impact is delayed funding of priced exit requests during volatile markets, when liquidity is likely most important.

This is automation starvation, not an authorization bypass or permanent lock. The configured Forwarder can execute explicitly encoded `WithdrawShortfall` data because that branch independently revalidates its own condition, and a caller with the relevant keeper authority can use the Controller directly. Governance can also intervene, although pausing UniCL makes its advertised `maxWithdrawal` zero. User cancellation opens after the queue escape period. These manual/recovery paths and the need for a non-calm pool keep the issue below High.

## Regression proof

`test/audit/candidates/verification/KeeperPriorityStarvation.t.sol` wires the real AMM, Controller, ExitQueue, StrategyManager, both executors, and a configurable strategy. It creates a priced redemption shortfall and an unhealthy strategy whose rebalance reverts but whose withdrawal works.

Observed transition:

1. `checkUpkeep` selects `Rebalance` even though a funded withdrawal shortfall exists.
2. Forwarder execution succeeds because StrategyManager catches the strategy revert; Controller liquidity remains zero.
3. A second `checkUpkeep` returns the same `Rebalance` action.
4. Executing `WithdrawShortfall` explicitly in the unchanged state transfers ETH to Controller, proving the lower-priority action was independently viable.

Pinned offline attempt 1/3:

`FOUNDRY_OUT=/private/tmp/keeper-priority-out FOUNDRY_CACHE_PATH=/private/tmp/keeper-priority-cache /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/KeeperPriorityStarvation.t.sol -vvv`

Result: 1 passed, 0 failed, 0 skipped. The only warning was the sandbox denying Foundry's unrelated global signature-cache write.

## Recommendation

Do not select Rebalance when a strategy is unhealthy solely because the pool is non-calm and rebalance cannot execute. Expose a dedicated `canRebalance` predicate, or make the health check and action preconditions identical. Additionally, record per-strategy failure/backoff and continue evaluating higher-impact liquidity work after a no-progress rebalance. Execution should emit whether any strategy actually changed state instead of reporting unconditional success.

AGENT_STATUS: COMPLETE
