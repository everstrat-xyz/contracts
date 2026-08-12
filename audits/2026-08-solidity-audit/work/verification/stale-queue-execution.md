# Stale QueueKeeper `ProcessRequests` after escape boundary

## Verdict

**CONFIRMED — Medium severity.** At base commit
`734df96a1391e95dd40843210997da0b9f3ab05e`, a `ProcessRequests` payload produced
while a priced batch is still inside its three-day commitment window remains executable by
the registered Forwarder after the window expires. `performUpkeep` rechecks affordability,
but not whether the batch is now post-commitment. This contradicts the executor's stated
rule that after expiry the remaining users must close their requests.

This is not permissionlessly triggerable: only the configured Forwarder can call
`performUpkeep`. It is nevertheless reachable under ordinary automation latency because
the on-chain function accepts cached `performData` without a check timestamp or deadline.

## Intended semantics from the immutable base

- `QueueKeeperExecutor.sol:23-42` says every action is revalidated, defines expired batches
  as skippable, and says that after keeper commitment expiry remaining users must
  `closeRequest`.
- `IExitQueue.sol:118-121` defines `MAX_BATCH_PROCESSING_TIME` as the maximum time from
  pricing by which all requests must be processed. `ExitQueue.sol:27` sets it to three days.
- Base tests reinforce the handoff: `QueueKeeperExecutor.t.sol:537-575` expects an expired
  request to remain for its owner to close; `ExitQueue.t.sol:668-703` tests that closing is
  barred at exact equality but succeeds one second later.
- The cursor is a processing pointer, not authorization to settle forever. A fresh check
  peeks past expired batches and may return `AdvanceCursor`
  (`QueueKeeperExecutor.sol:144-177,299-324`).

## Exact transition

Let `E = pricedAt + MAX_BATCH_PROCESSING_TIME` for an affordable, nonempty priced batch.

1. At any time `t <= E` (the test uses `t == E`), `_isBatchSkippable` returns false because
   its test is strict `block.timestamp > E` (`QueueKeeperExecutor.sol:299-305`).
2. `checkUpkeep` finds a positive affordable prefix and returns
   `abi.encode(ProcessRequests, batchId)` (`QueueKeeperExecutor.sol:157-161`).
3. At `t = E + 1`, a fresh `checkUpkeep` skips that batch and returns `AdvanceCursor` in the
   one-batch case. At this timestamp `requestCanBeClosed` is true and
   `AMM.cancelRedemption` can return the escrowed EVE: `ExitQueue.sol:253-266,294-315` and
   `AMM.sol:188-193`.
4. The cached payload takes a different path. `performUpkeep(ProcessRequests)` invokes only
   `_affordableRequests`; that helper checks `canBeProcessed`, users, price tolerance, and
   Controller balance, but never expiry (`QueueKeeperExecutor.sol:209-215,336-363`).
5. The Forwarder therefore calls `Controller.processRequests`. The AMM pulls the request,
   burns the EVE, and credits fixed-price ETH for claiming (`Controller.sol:418-449`;
   `AMM.sol:215-240`). The cursor is advanced only after processing.

At `t == E`, the user cannot cancel and processing is still intended. At `t == E + 1`, both
the user's cancellation and the cached Forwarder execution are individually valid. They
race by transaction ordering: cancellation first removes the request and makes an all-user
stale payload revert with count zero; stale execution first marks it processed and removes
the cancellation option. A mined cancellation cannot be overwritten.

## Forwarder authority and reachability bounds

- `KeeperExecutorBase.sol:39-46` requires `msg.sender == forwarder`; an unset zero address
  rejects everyone. `setForwarder` is nonzero and ADMIN_ROLE-only
  (`KeeperExecutorBase.sol:59-66`). The isolated test proves an arbitrary user is rejected.
- Production deployment intentionally grants KEEPER_ROLE to the executor, not Chainlink,
  then leaves the executor inert until the upkeep is registered and governance calls
  `setForwarder` (`DeployAll.s.sol:21,44-45,98-101` and
  `ProtocolDeployBase.sol:290-301`). The immutable base does not contain a concrete live
  Forwarder address; live registration/configuration was outside this no-live-systems test.
- Required condition: the configured Forwarder executes a payload simulated before expiry
  after time has advanced beyond expiry, and at least one affordable request remains. No
  on-chain delay bound prevents execution later than `E + 1`.
- A third party cannot forge the call, and a request outside tolerance returns EVE instead
  of burning it. For an in-tolerance request, the user still receives claimable ETH at the
  batch's fixed price; the harm is loss of the documented escape option and potentially the
  economic difference versus recovering EVE after a delayed batch, not direct theft.

## Impact, severity, and recovery

Medium is appropriate: the transition can irreversibly settle a user's redemption after
the documented maximum processing period and defeat an already-open escape hatch, with
potential value impact if the fixed batch price is worse than retaining EVE. Exploitability
is reduced because only the configured automation Forwarder can submit the call and the
user can win the same-timestamp cancellation race.

Before stale execution, the user can call `cancelRedemption`; ADMIN/SECURITY can pause the
executor, and ADMIN can replace its Forwarder. After processing there is no queue-level
rollback: an in-tolerance user can only claim the credited ETH, while an out-of-tolerance
request has its EVE returned. A narrow fix is to reject `ProcessRequests` in
`performUpkeep` when `_isBatchSkippable(queue, batchId)` is true, before affordability and
the Controller call.

## Regression and attempts

Test: `test/audit/candidates/verification/StaleQueueExecution.t.sol`

It uses the real base protocol and asserts the equality boundary, the fresh post-boundary
`AdvanceCursor` result, successful cancellation in one snapshotted branch, arbitrary-caller
rejection, and successful stale Forwarder processing in the restored branch.

Pinned offline command (attempt 1 of 3):

```text
FOUNDRY_OUT=/private/tmp/stale-queue-out-1 \
FOUNDRY_CACHE_PATH=/private/tmp/stale-queue-cache-1 \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/StaleQueueExecution.t.sol -vvv
```

Result: `1 passed; 0 failed; 0 skipped`. No further attempts were needed. Forge emitted a
non-test-affecting warning that its signature cache under `~/.foundry` was not writable.

No production source was edited; no network or live system was used.

AGENT_STATUS: COMPLETE
