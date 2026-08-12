# Verification: weighted withdrawals can round all positive legs to zero

BASE: `734df96a1391e95dd40843210997da0b9f3ab05e`

VERDICT: CONFIRMED behavior; retained as Informational hardening rather than a
standalone security finding.

## Mechanism

`StrategyManager._withdrawFromStrategies` computes every leg independently as
`amount * weight / cumulativeWeight` and skips zero legs
(`StrategyManager.sol:1080-1127`). It never assigns the discarded remainder to
an eligible final strategy. With a one-wei request and two strategies weighted
50/50, both legs are zero even when both advertise positive withdrawal
capacity; the call returns successfully without moving ETH.

`StrategyKeeperExecutor.setMinWithdrawETH(0)` intentionally permits any
positive shortfall (`StrategyKeeperExecutor.sol:304-317`). Its discovery branch
checks only that aggregate `maxWithdrawal()` is positive, so a one-wei deficit
can repeatedly select `WithdrawShortfall` while the weighted manager call makes
no progress.

## Disposition

The trace is exact but demonstrated impact is one raw wei. Larger requests do
not make every positive-weight leg zero: once the request reaches the aggregate
weight denominator, at least one leg progresses. A user also cannot generally
choose an exact one-wei controller deficit, and the default withdrawal floor is
`0.01 ether`; reaching the edge requires ADMIN deliberately enabling the
documented zero-threshold mode plus a dust-sized residual deficit.

Treat this as Informational rounding/liveness hardening. Assign the residual to
the last eligible strategy, or have Controller/Keeper reject a successful
zero-progress withdrawal so monitoring does not report completion.

## Evidence status

The complete source-level worked example is retained in
`work/pashov/raw/agent-10.md` as `R10-01`. No additional PoC was warranted
because the arithmetic is deterministic and the only demonstrated harm is
dust-scale.

AGENT_STATUS: COMPLETE
