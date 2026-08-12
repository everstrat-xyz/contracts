# Plamen Raw Pass: event-correctness

**Target**: immutable `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
**Scope**: 39/39 source files; 115/115 executable local `emit` statements and 103/103 in-scope event declarations
**Method**: definition/emit reconciliation, value/index/order/branch/arity/semantic checks, then off-chain consequence analysis

## FINDING [EVT-1]: Strategy upkeep events report requested amounts as though they were actual movements

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5,6
**Rules Applied**: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(no ERC20 amount represented), R12:✓, R13:✗(not design-labelled), R14:✓, R15:✗(no flash-loan lever), R16:✗(no oracle dependency)]
**Depth Evidence**: [TRACE:WithdrawShortfall(shortfall) -> Controller/StrategyManager partial withdrawal -> emit amount=shortfall], [TRACE:DepositExcess(excess) -> capped/partial batch deposit -> emit amount=excess]
**Preferred Tag**: CODE-TRACE
**Severity**: Low
**Location**: `src/contracts/automation/StrategyKeeperExecutor.sol:229-253`; `src/interfaces/automation/IStrategyKeeperExecutor.sol:85-92`
**Description**: `StrategyUpkeepPerformed.amount` is documented as the ETH “withdrawn” or “deposited.” The WithdrawShortfall branch emits the computed target `shortfall`, even though StrategyManager can return less because withdrawals are capped and batch strategy calls can fail. DepositExcess likewise emits the requested `excess`, while capacity caps, cooldown/unhealthy skips, and caught strategy failures can make `actualDeposited` smaller or zero. The Controller already receives and emits the actual values, proving the outer event is reporting a target rather than the documented outcome.
**Impact**: An event-only automation dashboard or alerting rule overstates capital moved and can mark a reserve refill/deployment as successful when the underlying action was partial or a no-op.
**Material Harm**: Operators relying on `StrategyUpkeepPerformed` can delay intervention while redeemers remain underfunded or idle funds remain undeployed; on-chain balances are not corrupted.
**Evidence**: StrategyKeeper lines 236-238 call `withdrawFromStrategies(shortfall)` then emit `shortfall`; lines 247-253 do the same with `excess`. Controller lines 145-161 and 191-210 emit separate `(requestedAmount, actualAmount)` values. StrategyManager lines 1000-1039 cap/skip/catch deposits and lines 1090-1141 cap/catch withdrawals while summing actual Controller balance deltas.
**Postconditions Created**: A successful upkeep transaction contains a coarse log whose numeric payload can exceed the completed ETH movement.
**Postcondition Types**: [STATE, EXTERNAL]
**Who Benefits**: No direct attacker; the mismatch can conceal degraded strategy execution from incomplete monitoring.
**Semantic Invariant**: An event field described as completed ETH movement must equal the post-call balance delta or be named/documented as a requested target.
**Branch Preconditions**: At least one strategy is capped, skipped, or fails while the aggregate requested amount remains non-zero.
**Terminal Mechanism**: Keeper ignores the Controller's actual return/event and emits its pre-call estimate.
**Recommendation**: Return actual deposited/withdrawn values from the Controller calls to the keeper and emit those; otherwise rename/document the field as `requestedAmount` and require monitoring to consume the Controller completion event.

## LEAD [EVT-L1]: Keeper constructor defaults have no configuration-change events

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5,6
**Rules Applied**: [R4:✗(code clear), R5:✓, R6:✓, R8:✗(constructor-only), R10:✓, R11:✗(no token), R12:✓, R13:✓, R14:✓, R15:✗(no flash loan), R16:✗(no oracle)]
**Preferred Tag**: CONTESTED
**Severity**: Low
**Location**: `src/contracts/automation/QueueKeeperExecutor.sol:99-104`; `src/contracts/automation/StrategyKeeperExecutor.sol:128-135`
**Description**: Both static keeper constructors directly set fields that later have dedicated `*Changed` events, but emit no initial configuration events. An event-sourced consumer sees no baseline until the first setter call. AMM and StrategyManager deliberately route initialization through emitting setters, showing an inconsistent observability convention.
**Material Harm**: A log-only keeper monitor can assume zero/unknown thresholds and mispredict when automation should run, but no supplied consumer proves that production monitoring is event-only.
**Missing Precondition**: Evidence that a production consumer reconstructs keeper configuration solely from logs rather than reading deployment state.
**Precondition Type**: EXTERNAL
**Why This Blocks**: A consumer that reads public getters at deployment obtains the correct baseline.

## Emit Inventory

| Implementation | Emits checked | Result |
|---|---:|---|
| AMM | 9 | EVT-1 unrelated; values, IDs, branch coverage and timestamp semantics cleared |
| Controller | 12 | Requested/actual pairs are accurate and expose the keeper mismatch |
| Converter | 8 | Measured swap output/input semantics and role/config events cleared |
| ExitQueue | 4 | Batch/user IDs, tolerance polarity and cursor increment ordering cleared |
| Oracle | 8 | Add-vs-update conditional events and old/new feed/staleness values cleared |
| StrategyManager | 27 | Per-strategy success/failure, fee allocation, weight/config and removal events cleared |
| Whitelist | 6 | Invite/admin/ban/signer/disable branch events cleared |
| KeeperExecutorBase | 1 | Forwarder old/new values cleared |
| QueueKeeperExecutor | 6 | Action/batch/count and governance cursor values cleared |
| StrategyKeeperExecutor | 13 | EVT-1 + EVT-L1; setter old/new values otherwise cleared |
| Registry | 4 | Contract and role registration/removal values cleared |
| UniCLStrat | 17 | Fund, fee, emergency-degradation and configuration events cleared |
| **Total** | **115** | **115/115 reviewed** |

## CLEARED

- **AMM queued redemption polarity**: `RequestPulled.isWithinTolerance` emits `!closedDueToSlippage`; the AMM's processed event follows the corresponding refund or burn/claim state update.
- **Batch identifiers**: `BatchPriced` emits the old live ID before increment; `RequestPushed` snapshots the current ID; QueueKeeper price/process actions preserve their encoded/revalidated batch ID.
- **Queue processing count**: `QueueUpkeepPerformed.processedUsers` equals the exact atomic user-loop length; any inner failure reverts the outer transaction and removes the log.
- **Swap amounts**: exact-input output is a balance delta; exact-output input is a measured spend and output is the amount transferred to the caller. No adapter return value is emitted as settlement truth.
- **StrategyManager withdrawals**: both manager and Controller completion events use Controller balance deltas, not a strategy-declared return value.
- **Performance-fee allocation**: per-strategy `PerformanceFeePaid.eveAmount` values use pro-rata allocation with the final remainder, so their sum equals the single treasury mint; ETH equivalents sum to the settled total.
- **Old/new setters**: AMM, Oracle, Registry, StrategyManager, keeper and UniCL setters preserve the old value before assignment and emit the validated new value. Pre-assignment emits have no intervening failure/state branch and roll back atomically.
- **Best-effort failures**: strategy deposit/withdraw/rebalance/harvest/sync catches emit the correct strategy and raw reason; UniCL pause/emergency catches emit distinct unwind/paired-transfer failure signals.
- **Registry role inventory**: `RoleRegistered` fires only on first set membership and `RoleUnregistered` only after the final member is removed; inherited AccessControl events retain account-level detail.
- **Arity/type check**: all 115 executable emits match an in-scope or inherited event signature; no missing/defaulted parameter or wrong indexed entity was identified.

## Read / Validation Record

- Plamen rules: `orchestrator-rules.md` 79/79 lines; `finding-output-format.md` 114/114 lines.
- Skill: `event-correctness/SKILL.md` 37/37 lines. Its `{SCRATCHPAD}/emit_list.md` reference was not read because the assignment forbids prior work output; a fresh immutable-base inventory was generated instead.
- Fresh bundle reused for this sequential batch: `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `source.md` 9,417/9,417 (39/39 files), `finding-format.md` 101/101.
- Immutable interface context: 21/21 files, 3,564 Solidity lines, read via `git show 734df96:PATH`.
- Base-only commands: anchored `git grep -nE` emit/event inventories; targeted `git show 734df96:PATH | nl -ba | sed -n ...` for every emitting implementation and matching interfaces. No post-base source, prior work output, history, or `test/audit` read.
- Tests: not run; event arguments and partial-execution branches close by immutable source trace.
- Confidence: high for EVT-1's mismatch because requested and actual values coexist in the same call chain; medium for EVT-L1's off-chain consequence because no production consumer was supplied.

AGENT_STATUS: COMPLETE
