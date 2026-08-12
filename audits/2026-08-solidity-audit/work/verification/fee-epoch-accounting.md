# Fee epoch accounting verification

Scope: immutable commit `734df96a1391e95dd40843210997da0b9f3ab05e`. I read only base source/interfaces/docs/tests (no prior audit outputs or audit tests). Regression: `test/audit/candidates/verification/FeeEpochAccounting.t.sol`.

## A — a changed `performanceFeeBps` applies to historical uncharged LP fees

**Verdict: CONFIRMED as behavior; not a demonstrated vulnerability. Suggested severity: Informational unless the intended economic policy requires rate epochs.**

### Exact transition

1. UniCL records cumulative native token fee amounts, not fee-rate epochs: `_cumulativeLpFeesEarned{0,1}` and `_cumulativeLpFeesCharged{0,1}` (`UniCLStrat.sol:92-105`).
2. `_unchargedLpFeeAmounts()` returns lifetime earned minus lifetime charged, including the live `tokensOwed - snapshot` delta (`:891-907`).
3. Both `pendingPerformanceFeeInETH(bps)` and `settlePerformanceFee(bps)` multiply that entire currently uncharged base by the BPS supplied at call time (`:382-415`). Successful settlement then advances charged all the way to earned; it does not preserve which rate applied while fees accrued (`:413-414`).
4. `StrategyManager.setPerformanceFeeBps()` simply replaces the global value (`StrategyManager.sol:673-675, 821-830`), and later forwards that current value to pending/settlement (`:662-667, 742, 775-777`). There is no pre-change settlement or accumulator checkpoint.

The regression materializes 0.4 WETH + 0.2 paired-token historical fees at 1:1 ETH value. The same untouched base reports 0.03 ETH at 500 BPS and 0.12 ETH at 2,000 BPS; settlement at 2,000 BPS returns 0.12 ETH.

### Intended-semantics evidence

This behavior is affirmatively covered by the pinned base suite: `StrategyManager.t.sol:3275-3285` sets BPS to zero, accrues fees, then enables BPS and expects those already-accrued fees to become chargeable. README also says fees are disabled when BPS is zero, rather than defining accrual-time fee epochs. Therefore a claim that the code violates the documented/base-tested semantics is refuted; the narrower behavioral claim is confirmed.

### Impact / missing assumption

An admin/timelocked fee increase reprices all not-yet-settled LP fees, including fees earned before the change. This is economically retroactive and worth documenting/monitoring, but the candidate needs an external specification promising accrual-time rates (or an untrusted/instant setter) to rise above Informational. The contract caps the rate at 2,000 BPS (`StrategyManager.sol:61-63, 825-829`).

## B — withdraw discovers fees after pre-withdraw settlement, then stale counters charge new backing

**Verdict: CONTESTED. The ordering and post-withdraw pending counter are CONFIRMED; depletion/new-backing charging was not established under the normal, lossless transition. Suggested severity: Informational as proven, potentially Low/Medium only with an additional depletion mechanism.**

### Confirmed prefix

1. The manager computes each withdrawal from `maxWithdrawal()` and only afterward performs the pre-withdraw harvest (`StrategyManager.sol:1086-1122` batch; `:1151-1157` single).
2. UniCL settlement intentionally does not poke (`UniCLStrat.sol:387-403`). Thus truly unpoked fee growth is invisible to the pre-withdraw settlement.
3. UniCL withdrawal then calls `_removeLiquidityAndCollect()` (`:321-345`), which pokes, accrues fees into cumulative earned, burns, collects, and zeroes owed snapshots (`:758-770`). The pinned base test explicitly expects this behavior (`UniCLStrat.t.sol:786-806`).

The regression confirms: pre-withdraw pending/settlement are zero; withdrawal discovers the fees; afterward 0.06 ETH is pending at 1,000 BPS.

### Why the alleged endpoint did not follow

`maxWithdrawal()` is the pre-poke `navInETH()` (`UniCLStrat.sol:209-212`). Unpoked fees are absent from both `tokensOwed` and that NAV. Consequently a request capped by the manager to pre-poke NAV cannot, in the lossless case, withdraw the newly discovered value too: the test's first "full" withdrawal leaves approximately 0.6 ETH of residual strategy NAV backing the 0.06 ETH pending fee. On the next normal manager withdrawal, settlement occurs before the residual can be drained and clears pending.

All production manager calls to `strategy.withdraw` are capped from `maxWithdrawal()` and use this pre-harvest ordering (`StrategyManager.sol:1080-1143, 1151-1164`). A caller cannot directly bypass UniCL's `onlyAuthContract(STRATEGY_MANAGER)` restriction (`UniCLStrat.sol:299-303`). Thus I did not reach a state where the strategy was depleted while earned exceeded charged, nor show a later deposit being charged for old fees.

### Missing assumption that could change the verdict

The countervailing argument relies on value conservation during unwind/conversion. A concrete lossy conversion, rounding, token impairment, or other depletion mechanism large enough to consume the hidden-fee residual while leaving `earned > charged` could make the endpoint reachable. The candidate must demonstrate that state under allowed production bounds and then show a later deposit increases NAV used to settle the stale base. Merely observing a nonzero post-withdraw counter is insufficient: here it remains backed by the fee assets that withdrawal just discovered.

## Test evidence

Command (attempt 1 of maximum 3):

```text
FOUNDRY_OUT=out-audit-fee-epoch-verification \
FOUNDRY_CACHE_PATH=cache-audit-fee-epoch-verification \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/FeeEpochAccounting.t.sol -vvv
```

Result: `2 passed; 0 failed; 0 skipped`.

- `test_A_CurrentRateRepricesSameHistoricalUnchargedFeeBase` — PASS
- `test_B_FirstFullWithdrawDiscoversFeesButLeavesTheirBacking` — PASS

The signature-cache flush warning was sandbox-only and occurred after the successful suite.

AGENT_STATUS: COMPLETE
