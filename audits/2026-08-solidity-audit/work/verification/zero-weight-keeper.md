# Zero-weight StrategyKeeper allocation verification

VERDICT: CONFIRMED

SEVERITY: Low

## Candidate

StrategyKeeperExecutor treats a healthy/capable strategy as actionable without checking the
allocation weight that StrategyManager later uses. If every otherwise eligible strategy has a
zero weight, the selected DepositExcess or WithdrawShortfall upkeep succeeds but moves zero ETH,
then remains the highest-priority actionable upkeep on every subsequent check.

## Immutable-base evidence

- Base: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`.
- `src/contracts/StrategyManager.sol:832-859` explicitly permits zero deposit and withdrawal
  weights, meaning registration without participation in the respective batch allocator.
- Deposit predicate: `StrategyKeeperExecutor.sol:191-195,399-408` accepts any strategy that is
  out of cooldown, healthy, and reports `maxDeposit() > 0`; it never reads `depositWeight`.
- Deposit action: `StrategyKeeperExecutor.sol:246-253` calls the batch deposit and emits the
  requested excess without checking actual placement. `StrategyManager.sol:989-1019` sums the
  weights and, when the sum is zero, refunds all ETH to Controller and returns zero.
- Withdrawal predicate: `StrategyKeeperExecutor.sol:174-182,382-387` sums every strategy's
  `maxWithdrawal()` without reading `withdrawalWeight`.
- Withdrawal action: `StrategyKeeperExecutor.sol:229-238` calls the batch withdrawal and emits
  the requested shortfall without checking actual receipt. `StrategyManager.sol:1080-1103`
  returns zero when all participating withdrawal weights sum to zero.
- Controller preserves these zero-progress results rather than reverting:
  `Controller.sol:137-162,185-210`. Thus Automation sees a successful transaction even though
  its triggering state is unchanged.
- These actions outrank ProvideExitLiquidity, DepositExcess, fee harvest, and Sync; DepositExcess
  itself outranks harvest and Sync (`StrategyKeeperExecutor.sol:27-39,169-205`).

## Observable state traces

Deposit-only zero weight:

1. Register the sole strategy with `(depositWeight=0, withdrawalWeight=100)`; it is healthy and
   has positive deposit capacity. Entering with 1 ETH leaves 1 ETH on Controller.
2. Warp beyond the one-day Sync interval. Both Sync and deposit work appear due.
3. `checkUpkeep` selects DepositExcess. `performUpkeep` transfers 1 ETH to StrategyManager, which
   detects cumulative weight zero and refunds it.
4. After each of two successful upkeeps: Controller=1 ETH, StrategyManager=0, Strategy=0,
   `totalDeposited=0`, and `lastSyncAt` is unchanged. The next check again selects DepositExcess.
5. After ADMIN sets deposit weight to 100, the same action deposits the 1 ETH and Controller=0.

Withdrawal-only zero weight:

1. Register the sole strategy with `(depositWeight=100, withdrawalWeight=0)`, bootstrap with
   10 ETH, and deposit all 10 ETH into it through the normal keeper path.
2. The holder queues a 5 ETH exit and the batch is priced. Controller=0, Strategy=10 ETH,
   pending priced liability=5 ETH, and the strategy reports positive `maxWithdrawal`.
3. After Sync is also due, `checkUpkeep` selects WithdrawShortfall. Two successful executions
   each return actual withdrawn=0: Controller remains 0, Strategy remains 10 ETH,
   `totalWithdrawn=0`, `lastSyncAt` is unchanged, and the priced request remains unprocessed and
   unaffordable to QueueKeeper.
4. After ADMIN sets withdrawal weight to 100, the next strategy upkeep moves 5 ETH to Controller;
   QueueKeeper processes the request and the holder claims approximately 5 ETH.

## Priority, reachability, and bounds

- Zero is a supported ADMIN configuration both at strategy addition and later weight updates
  (`StrategyManager.sol:152-208,832-859`), so neither branch requires a malicious strategy.
- Deposit looping wastes keeper gas and indefinitely starves only lower-priority harvest/Sync
  while the excess and all-zero eligible deposit weights persist. The ETH is refunded, not lost.
- Withdrawal looping wastes keeper gas and also starves immediate-exit float funding, deposits,
  harvest, and Sync. More importantly, queued requests cannot be processed while Controller lacks
  ETH even though strategy liquidity exists.
- An ordinary user cannot route a direct strategy withdrawal. Production assigns KEEPER_ROLE only
  to QueueKeeperExecutor and StrategyKeeperExecutor (`script/DeployAll.s.sol:16-27`), and neither
  executor exposes Controller's weight-agnostic direct withdrawal path
  (`Controller.sol:216-225`; `StrategyManager.sol:1151-1169`).
- ADMIN can repair weights, but production ADMIN is a 48-hour timelock. A priced request cannot be
  cancelled during its commitment window; after strictly more than 3 days the user can invoke
  the escape hatch and recover EVE, not ETH (`ExitQueue.sol:27,253-266,279-297`;
  `AMM.sol:188-193`). These recovery paths bound the user impact and support Low rather than
  Medium severity. No asset theft or permanent loss was observed.
- The issue persists with multiple strategies whenever every strategy that the batch allocator
  could use has weight zero. A nonzero-weight eligible/capable strategy restores progress.

## Suggested correction

Make each keeper predicate mirror the allocator: require at least one eligible strategy with a
nonzero corresponding weight (and for withdrawal, positive usable capacity). In performUpkeep,
also treat a zero actual deposit/withdrawal as no progress rather than emitting the requested
amount as though it was completed. A regression should keep a lower-priority due action visible
when the higher-priority batch allocator would return zero.

## Validation

- Added isolated regression:
  `test/audit/candidates/verification/ZeroWeightKeeper.t.sol`.
- Base identity check:
  `git diff --exit-code --stat 734df96 -- src script test/helpers test/mocks foundry.toml remappings.txt lib`
  exited 0 with no differences.
- Forge attempt 1/3:
  `/private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/ZeroWeightKeeper.t.sol --out /private/tmp/zero-weight-keeper-a1-out --cache-path /private/tmp/zero-weight-keeper-a1-cache -vvv`
- Result: 2 passed, 0 failed, 0 skipped. Compiler succeeded with Solc 0.8.30. The final warning
  concerned inability to write Foundry's optional signature cache and did not affect results.
- Attempts 2-3 were not needed.

AGENT_STATUS: COMPLETE
