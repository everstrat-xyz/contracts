# Unpoked Uniswap V3 fees are omitted from UniCL NAV

## Verdict

**CONFIRMED — Medium severity.** At immutable base commit
`734df96a1391e95dd40843210997da0b9f3ab05e`, UniCL NAV includes a position's
stored `tokensOwed`, but not fee growth that Uniswap has not yet materialized into those
fields. Consequently both StrategyManager/AMM NAV and `maxDeposit()` are stale between
position pokes. A permissionless AMM entrant can be over-minted relative to fee-inclusive
pricing, and a StrategyManager deposit sized to the advertised capacity can poke/reinvest
the hidden fees and finish above `maxTotalNAV`.

The issue does not fabricate or lose the fees: a later poke recognizes them. Its effects are
temporary under-reporting, irreversible cohort mispricing during that interval, and breach
of the configured strategy cap.

## What the base mock and real-pool test establish

`MockUniCLPool` is declared in `test/mocks/UniCLStratMocks.sol:122-327`.

- Its `PositionState` separates visible `tokensOwed0/1` from mock-only
  `pendingOwed0/1` (`:127-146`). `accrueFees` increments only pending fields (`:293-300`).
- `positions()` returns zero for both X128 fee-growth fields and only exposes
  `tokensOwed` (`:209-223`). A read therefore cannot recognize the injected growth.
- `mint` and `burn` call `_materializePendingFees`; importantly, `burn(..., 0)` does so
  before returning (`:225-256,302-310`). `collect` only drains already-visible owed tokens
  and does not materialize pending fees (`:275-290`).
- This mirrors the production poke dependency. `UniCLStrat.sync()` calls zero-liquidity
  burns (`UniCLStrat.sol:362-373,772-783`), and the base fork test generates fees with real
  swaps and observes `tokensOwed` rise only after `sync()`
  (`test/fork/UniCLStratFork.t.sol:289-306`).
- Existing unit tests expressly say pending fee growth is invisible until a poke
  (`test/unit/UniCLStrat.t.sol:721-748,765-827`). They test fee accounting, but not its NAV,
  admission-cap, or AMM-cohort consequences.

## Reachable accounting transitions

`navInETH()` values native ETH, idle pool tokens, position liquidity, and `tokensOwed`
(`UniCLStrat.sol:199-203,665-676,859-873`). It does not derive current fee growth from pool
globals/ticks. StrategyManager sums that value directly into protocol NAV
(`StrategyManager.sol:924-950`), and AMM entry prices from that total
(`AMM.sol:397-423`). AMM entry itself does not sync strategies.

Let:

- `V` = reported UniCL NAV before a poke;
- `F` = ETH value of fee growth that the next poke will add to `tokensOwed`;
- `M` = `maxTotalNAV`; and
- `N`, `S`, `c`, `D` = reported protocol NAV, EVE supply, connector-weight fraction, and
  entrant ETH respectively.

Before the poke, true recoverable strategy value is `V + F`, but the strategy returns `V`.
Its advertised capacity is

```text
H_reported = max(0, M - V)
H_fee_aware = max(0, M - V - F)
overstatement = H_reported - H_fee_aware
              = min(F, M - V) when V < M
```

For `V < M`, depositing the full reported `H = M - V` reaches exactly `M` at the
pre-poke check. `deposit()` checks `navInETH() > M` before calling
`_removeLiquidityAndCollect` (`UniCLStrat.sol:227-245`). The latter then orders poke,
accrue, burn, and collect (`:758-795`), so final NAV is approximately `M + F` (pool/swap
rounding aside). The excess is therefore approximately all of `F`, not merely the
headroom overstatement. Hidden fees may already place true value over the cap before this
deposit.

For AMM entry, ignoring integer floors:

```text
stale premium price = N / (S*c)
fee-aware price     = (N+F) / (S*c)
stale mint          = D*S*c / N
fee-aware mint      = D*S*c / (N+F)
extra mint          = D*S*c*F / (N*(N+F))
relative over-mint  = F / N
```

Thus the entrant shares in fees earned before entry and dilutes earlier holders relative to
the protocol's own fee-inclusive premium-price formula. Integer flooring can erase only a
sub-token-unit difference; meaningful `D`, `F`, and `S` produce the stated inequality.
Exit/base-price calculations are stale for the same reason and can make a redeemer burn
more EVE for requested ETH (`AMM.sol:138-166`).

## Regression evidence

`test/audit/candidates/verification/UnpokedFeeNAV.t.sol` uses the real AMM, Controller,
StrategyManager, Converter, and UniCL strategy with the base `MockUniCLPool`.

After a 40 ETH strategy deposit under a 60 ETH cap, it injects exactly 5 WETH of pending
fees and proves that pool pending state changes while position owed fields, strategy NAV,
protocol NAV, and `maxDeposit` do not. From one snapshot:

1. A 10 ETH AMM entrant receives exactly the stale-NAV mint and strictly more EVE than the
   fee-aware formula. `syncStrategy` then increases protocol NAV by exactly 5 ETH, and the
   incumbent's supply share is below the fee-aware counterfactual.
2. After restoring the same pre-poke state, Controller deposits the advertised headroom.
   The deposit succeeds, clears pending fee state, and ends approximately 5 ETH above the
   60 ETH cap (asserted within 100 wei).

Pinned Forge 1.0.0 offline attempt 1 of 3:

```text
FOUNDRY_OUT=/private/tmp/unpoked-fee-nav-out-1 \
FOUNDRY_CACHE_PATH=/private/tmp/unpoked-fee-nav-cache-1 \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/UnpokedFeeNAV.t.sol -vvv
```

Result: `1 passed; 0 failed; 0 skipped`. No further attempt was required. The only warning
was inability to write Forge's optional signature cache under `~/.foundry`.

## Severity, bounds, and recovery

Medium: AMM entry is permissionless and can transfer value between cohorts whenever an
observer knows fees accumulated since the last poke. Direct profit is moderated by the
AMM's premium connector weight, but the entrant is still over-minted versus intended
pricing; sufficiently large `F/N` can overcome that premium. The cap breach can exceed
risk limits but represents earned pool value, not stolen principal.

`F` is bounded by actual position fees accrued since its last mint/burn, token/oracle value,
and the pool's owed-token representation; it is not bounded by `maxTotalNAV`. The default
StrategyKeeper sync interval is one day, is admin-configurable, and can be disabled with
zero (`StrategyKeeperExecutor.sol:71-72,128-134,202-205,333-335`). Deposit automation has
higher priority than sync (`:191-205`), making the cap transition reachable before scheduled
housekeeping. Any sync, deposit, withdrawal, rebalance, or pause-unwind poke closes the stale
window, but already-minted/burned EVE is not repriced or reversible.

Immediate recovery is to sync all strategies before allowing more AMM pricing or deposits;
after a cap overrun, stop deposits and withdraw/reconfigure as policy requires. A durable
fix needs fee-inclusive NAV (derive pending V3 fee growth from pool/tick state) or an
enforced freshness/two-transaction sync gate before AMM pricing and strategy admission.
Merely poking and then reverting a cap-exceeding deposit would roll the poke back.

No production source was edited; no network or live system was used.

AGENT_STATUS: COMPLETE
