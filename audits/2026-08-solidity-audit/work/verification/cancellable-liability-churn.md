# Verification: cancellable current-batch liability churn

VERDICT: CONFIRMED
SEVERITY: Medium
BASE: `734df96a1391e95dd40843210997da0b9f3ab05e`
CONFIDENCE: High for the state/action chain; Medium for realized loss magnitude because pool fee tier, price movement, Automation cadence, and configured cooldown are deployment/runtime variables.

## Claim tested

`StrategyKeeperExecutor._pendingRedemptionNeedsETH` treats the current, unpriced batch as a liability even though its requests can be cancelled immediately and without a protocol penalty. A holder can therefore queue, induce strategy withdrawal, cancel, wait for excess redeposit, and repeat with the same EVE position.

## Evidence and exact path

1. A queued exit escrows EVE and creates the current-batch request. `AMM.exit` transfers `tokensToBurn` into the AMM, then calls `ExitQueue.pushRequest` (`AMM.sol:168-181`).
2. The current batch is unpriced: `priceBatch` is what sets `canBeProcessed = true`, then increments `currentBatchId` (`ExitQueue.sol:173-188`).
3. Cancellation is immediate before pricing. `closeRequest` only blocks while a batch is priced and still in its three-day commitment window (`ExitQueue.sol:253-267,279-297`). `AMM.cancelRedemption` then transfers the full stored `tokensToBurn` back; there is no fee or burn (`AMM.sol:188-193`).
4. Despite that option, `_pendingRedemptionNeedsETH` adds the current batch's `totalTokensToBurn * eveBasePriceInETH` (`StrategyKeeperExecutor.sol:494-512`). It does not test `canBeProcessed`, request age, or cancellation commitment.
5. At the defaults, `minWithdrawETH = 0.01 ether` and queue pricing waits at least one day (`StrategyKeeperExecutor.sol:62-67,128-134`; `QueueKeeperExecutor.sol:58-74,99-104,164-169`). Thus a cancellable request worth at least 0.01 ETH can select `WithdrawShortfall` before it can be priced.
6. `performUpkeep` recomputes this same liability and calls `controller.withdrawFromStrategies(shortfall)` (`StrategyKeeperExecutor.sol:229-238`). StrategyManager asks each selected strategy to withdraw and records `lastStrategyWithdrawal` on success (`StrategyManager.sol:1080-1142`).
7. After cancellation, `needsETH` becomes zero. Controller ETH is then `DepositExcess` when capacity is eligible (`StrategyKeeperExecutor.sol:191-195,246-253,399-408,435-438`). The optional cooldown delays this step; its default is zero and maximum is one day (`StrategyManager.sol:64-65,81-85,593-597`).
8. For in-scope UniCL capital rather than an idle-ETH mock, an LP-backed withdrawal calls `_removeLiquidityAndCollect`, converts inventory as needed, and can rebalance/add liquidity (`UniCLStrat.sol:299-345,758-795`). The base Uniswap adapter's swap quote/output explicitly includes the configured pool fee (`UniswapV3ConverterAdapter.sol:162-180,189-206`), so round trips can realize DEX fees/slippage; their numeric size is not fixed by this repository.

## Passing regression

File: `test/audit/candidates/verification/CancellableLiabilityChurn.t.sol`

`test_CancellableCurrentBatchForcesRepeatableWithdrawalAndRedeposit` proves:

- the unpriced request is immediately cancellable;
- it is nevertheless reported as an exact 1 ETH liability and selects `WithdrawShortfall`;
- the upkeep withdraws 1 ETH and starts the configured cooldown;
- cancel returns the user's exact pre-request EVE balance;
- redeposit is unavailable during cooldown, then selected after six hours;
- the same EVE requeues in the same unpriced batch and causes a second withdrawal.

`test_LpBackedWithdrawalForcesInventorySwap` proves that withdrawing 3 ETH from a 10 ETH LP-backed UniCL position invokes the Converter exact-input swap path and transfers paired inventory to it. This closes the “UniCL withdrawal could be a no-op” question, but intentionally does not invent a mainnet loss amount from mocks.

Command (attempt 1/3):

```text
FOUNDRY_OUT=/private/tmp/cancellable-liability-out \
FOUNDRY_CACHE_PATH=/private/tmp/cancellable-liability-cache \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/CancellableLiabilityChurn.t.sol -vvv
```

Result: `2 tests passed, 0 failed, 0 skipped`. Compilation used Solc 0.8.30. A non-test signature-cache permission warning followed the successful suites.

## Attacker economics and repeatability

- Trigger: any EVE holder whose queued redemption exceeds `minWithdrawETH` after Controller idle ETH. The user temporarily locks EVE only until cancellation and pays transaction gas; the test proves exact token restoration.
- Repeatability: immediate when `strategyDepositCooldown == 0` (the default), or once per configured cooldown when it is nonzero. The protocol's one-day queue-pricing floor gives ample time for strategy upkeep and cancellation ordering.
- Material consequence: keepers can be made to repeatedly unwind and redeploy LP capital for a liability the requester never committed to, charging Automation gas and exposing all EVE holders' NAV to repeated DEX fees/slippage; with a nonzero cooldown, usable capital also sits idle until redeposit is eligible.
- The attacker does not directly capture the DEX loss. This is a griefing vector; practical amplification is bounded by the holder's EVE balance, keeper response/cadence, available strategy liquidity, and any configured cooldown.

## Missing assumptions / limits

- Exact monetary loss needs deployed pool fee tier, current inventory composition, price path, gas pricing, keeper cadence, and configured `strategyDepositCooldown`. No network/deployment state was supplied or queried.
- A cycle that withdraws only idle native ETH in UniCL incurs no pool/Converter operation; the harmful fee path requires the shortfall to reach LP-backed capital. The dedicated UniCL test proves that branch is reachable.
- If QueueKeeper prices the batch before cancellation, normal cancellation is locked for three days; the attack relies on ordering cancellation after StrategyKeeper withdrawal but before QueueKeeper pricing. The minimum one-day pricing age makes this realistic, not atomic or guaranteed.
- If `minWithdrawETH` is raised above attacker capacity, no strategy withdrawal is selected. Admin can also enable a cooldown up to one day, reducing frequency but not eliminating the false liability.

## Recommendation

Do not withdraw strategy liquidity for a freely cancellable request. Exclude the current/unpriced batch from `_pendingRedemptionNeedsETH`, or introduce an irrevocable commitment/anti-grief penalty before including it. Keep priced, committed batches in the reserve calculation.

AGENT_STATUS: COMPLETE
