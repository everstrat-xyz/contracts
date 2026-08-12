# QuillShield raw pass — dos-griefing-analysis

Target: `734df96a1391e95dd40843210997da0b9f3ab05e` (immutable full snapshot)

FINDING
file:         src/contracts/automation/StrategyKeeperExecutor.sol
function:     checkUpkeep / performUpkeep (Rebalance)
mechanism:    Rebalance has unconditional first priority whenever an unpaused strategy reports unhealthy, but a failed batch rebalance is caught and the upkeep still succeeds without changing the condition; UniCLStrat deterministically has this split when the pool is not calm because `isHealthy()` returns false while `rebalance()` reverts `UniCLStratNotCalm`.
consequence:  Every subsequent strategy upkeep selects and pays for the same no-progress Rebalance action, starving WithdrawShortfall, ProvideExitLiquidity, DepositExcess, HarvestPerformanceFees, and Sync; in particular queued exits can remain unfunded until the market calms or governance/security intervenes.
trigger:      anyone able to move the configured pool spot outside the calm band, or ordinary sustained volatility / unavailable TWAP observations
severity:     medium
rationale:    The state mismatch is deterministic and readily reached during volatility; delayed redemption liquidity is material, but the separate queue escape hatch and privileged pause/remove recovery prevent permanent lock.
poc:          none — reasoning only
evidence:     `if (_rebalanceNeeded(strategyManager_)) { return (true, abi.encode(StrategyAction.Rebalance)); }` precedes shortfall at lines 169-181; execution merely calls `controller.checkAndRebalanceStrategies();` and emits success at 224-228. UniCLStrat lines 214-217 say `if (!_isCalm()) return false;`, while lines 350-353 say `if (!_isCalm()) revert UniCLStratNotCalm();`; StrategyManager lines 1181-1185 catch that revert and continue.
fix:          Make rebalance eligibility mean “unhealthy and currently rebalanceable” (for UniCL, expose/check calmness), or record failed/no-progress rebalances and allow lower-priority safety/liquidity actions before retrying.
related:      none

FINDING
file:         src/contracts/strategies/UniCLStrat.sol
function:     _pauseStrategy
mechanism:    The circuit breaker sets paused state and catches pool-unwind failure, but then calls two external token `forceApprove(..., 0)` operations without failure isolation, so either pool token can revert and roll the entire pause transaction back.
consequence:  A degraded, upgraded, blacklisting, or otherwise nonconforming paired token can prevent ADMIN_ROLE and SECURITY_ROLE from pausing the strategy, leaving deposits/actions enabled and making the pause-gated emergency exit unreachable.
trigger:      configured paired-token contract or its administrator causing `approve` to revert or return malformed failure data
severity:     medium
rationale:    Failure requires an integrated token to degrade, but it defeats the immediate circuit breaker exactly in that emergency and can strand strategy capital until the token recovers or governance replaces/removes the strategy.
poc:          none — reasoning only
evidence:     `_pause();` and the parameterless pool catch are at lines 633-642, followed by uncaught `_removeConverterAllowances();` at line 644; that helper executes `token0.forceApprove(..., 0); token1.forceApprove(..., 0);` at lines 1274-1276. The source's claim that token `approve()` cannot revert is an assumption, not an enforced invariant.
fix:          Move allowance revocation into a non-reverting best-effort self-call/low-level helper after `_pause`, emit failure, and provide a separately retryable allowance-cleanup function.
related:      none

FINDING
file:         src/contracts/strategies/UniCLStrat.sol
function:     emergencyExit
mechanism:    `pairedToken.balanceOf(address(this))` is an uncaught external call executed before WETH unwrap and the native-ETH sweep, despite the later paired-token transfer being intentionally best-effort.
consequence:  If the paired token becomes non-callable or returns malformed data, all immediately recoverable WETH and native ETH remain trapped in the paused strategy instead of reaching StrategyManager.
trigger:      configured paired-token contract or its administrator causing `balanceOf` to fail
severity:     medium
rationale:    The dependency-failure precondition is uncommon, but impact dominates because the designated emergency recovery path for independent ETH/WETH assets is synchronously blocked by the broken token.
poc:          none — reasoning only
evidence:     Lines 494-506 execute `uint256 _pairedBalance = pairedToken.balanceOf(address(this));` before `weth.withdraw(_wethBalance)` and `_sendETH(strategyManagerAddress, _ethToSend)`; only the later transfer at lines 508-514 uses `trySafeTransfer`.
fix:          Sweep native ETH/WETH first, then obtain/transfer the paired balance through a best-effort external self-call whose failure cannot revert the prior sweep.
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     _withdrawFromStrategies
mechanism:    The batch probes every strategy's external `maxWithdrawal()` before entering its failure-isolated withdrawal loop, so one reverting strategy aborts withdrawals from all healthy strategies.
consequence:  Controller cannot source redemption shortfalls from unaffected strategies, and the StrategyKeeper cannot fund queued exits until the bad strategy is fixed or force-removed through delayed ADMIN governance.
trigger:      any registered strategy that fails its `maxWithdrawal()` view because of a broken dependency, malicious upgrade, or returndata/gas grief
severity:     medium
rationale:    Registered strategies are governance-selected, lowering likelihood, but ordinary dependency failure can synchronously block all redemption-liquidity withdrawals and the recovery is timelocked.
poc:          none — reasoning only
evidence:     Lines 1090-1101 call `uint256 maxWithdrawal = strategy.maxWithdrawal();` without `try/catch` for every strategy; failure isolation starts only at `try IStrategy(strategy).withdraw(...)` on lines 1131-1141.
fix:          Wrap each `maxWithdrawal()` probe and withdrawal together per strategy (or skip failed probes with an event), while retaining a strict single-strategy path for operators.
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     _harvestPerformanceFeesFor / _depositToStrategies / _withdrawFromStrategies / _checkAndRebalanceStrategies / _syncStrategies
mechanism:    Best-effort catches bind arbitrary external revert bytes (`catch (bytes memory reason)`), forcing Solidity to copy attacker-controlled returndata before the handler can continue.
consequence:  A registered strategy that returns a sufficiently large revert-data bomb can exhaust the caller's gas and revert the entire transaction, defeating the advertised per-strategy failure isolation across keeper batches.
trigger:      compromised or malicious registered strategy
severity:     low
rationale:    Strategy registration is timelocked and trusted, but compromise/degradation is precisely what isolation should tolerate; impact spans all batch maintenance while recovery remains available by force-removal.
poc:          none — reasoning only
evidence:     Catch bindings occur at lines 751-753, 1030-1032, 1139-1141, 1183-1185, and 1218-1220. UniCLStrat itself recognizes this mechanism at lines 636-638: `binding the revert data would copy unbounded returndata into memory`.
fix:          Use parameterless `catch` in liveness-critical batch paths, or capture only a bounded returndata prefix with assembly and emit a hash/truncated reason.
related:      none

LEAD
file:         src/contracts/StrategyManager.sol
function:     _totalNAVInETH / _supportedERC20sNAVInETH and all full-range batch overloads
suspicion:    Admin-growable strategy and supported-token sets are enumerated in user-critical NAV/pricing and keeper paths, with multiple external calls per item and no on-chain cardinality cap; sufficiently large organic/configured sets can cross the block gas limit and freeze enter/exit/pricing.
blocked_by:   No production cardinality/growth assumptions or gas measurements were supplied, and only timelocked governance can grow these sets, so a realistic exhaustion bound cannot be established from source alone.
next_step:    Benchmark totalNAVInETH and each full-range keeper action at increasing registered-set sizes under the target chain gas limit; then cap set size or require paginated cached NAV/batches.

LEAD
file:         src/contracts/Oracle.sol
function:     removeToken
suspicion:    Removal synchronously copies and clears every outbound pair and scans every supported token for inbound pairs, making the emergency cleanup cost O(outbound pairs + supported tokens) and potentially uncallable after large configuration growth.
blocked_by:   Only ADMIN_ROLE can create tokens/pairs and no expected maximum registry size or target-chain gas limit was supplied.
next_step:    Measure worst-case removal gas at approved configuration limits; add paginated pair removal or explicit cardinality caps if the bound approaches the block limit.

LEAD
file:         src/contracts/automation/QueueKeeperExecutor.sol
function:     _affordableRequests
suspicion:    Processing stops at the first unaffordable request (`break`), so one large head request can block affordable later users in the same batch for the three-day commitment window even though `Controller.processRequest` supports individual processing.
blocked_by:   The requester must own economically meaningful EVE and StrategyKeeper is intended to withdraw the aggregate shortfall; no liquidity/configuration data was supplied to establish a cheap or durable grief.
next_step:    Model a whale/Sybil request ahead of small users under constrained strategy withdrawal and test whether keeper funding resolves the head before timeout; otherwise select affordable users individually or maintain a rotating cursor.

CLEARED
area:         ExitQueue growth and keeper gas bounds
checked:      User growth is partitioned by batch; one address has one request per batch, queued exits have a configurable minimum, automation caps processing at 100 users, cost scans at 50 users, and batch/cursor scans at 25 with a repeatable AdvanceCursor path.

CLEARED
area:         Push-payment and receiver-failure DoS
checked:      Queued redemption processing records pull-payment liabilities in AMM; user-controlled native calls occur only in individual `claim()`/immediate exit, not the batch loop. Slippage closures return the protocol's own EVE token, so arbitrary receiver fallback failure cannot poison a batch.

CLEARED
area:         Low-level call success and 63/64 gas griefing
checked:      Native sends and Converter low-level/delegate calls either require success or revert atomically; no untrusted relayer path consumes a nonce/marks completion after an ignored failed call.

CLEARED
area:         Force-fed ETH accounting
checked:      No strict `address(this).balance == accounting` invariant exists. AMM subtracts tracked claim liabilities, while Controller/StrategyManager/UniCLStrat treat unsolicited ETH as protocol NAV/liquidity; force-feeding does not brick arithmetic or withdrawals.

CLEARED
area:         Timestamp and block-window griefing
checked:      User actions cannot reset another user's cooldown or batch timestamp. The priced-batch window opens an escape hatch after three days and has no upper execution deadline; whitelist deadlines expire vouchers but do not lock existing funds or exits.

PLUGIN_CONFIDENCE
overall:      high for the four direct liveness mechanisms and medium for the returndata-bomb impact without a PoC; enumeration/head-of-line hypotheses remain LEADs because deployment bounds and economics are unknown.
rationale:    Every promoted item has an immutable-base call chain and concrete stuck/starvation consequence; likelihood-dependent size/economic claims were not promoted.

READ_COUNTS
skill:        342/342 lines (`SKILL.md`)
references:   466/466 lines (217 `dos-patterns.md` + 249 `gas-griefing-vectors.md`)
bundle:       10,045/10,045 lines (scope 139, profile 207, context 181, source 9,417, finding-format 101)
source_scope: 39/39 files, 9,417/9,417 bundled lines (25 runtime/library + 14 deployment)

COMMANDS_AND_TEST_RESULTS
- `wc -l` confirmed all instruction/reference/bundle counts above; source headings counted 39.
- `git cat-file -e 734df96a1391e95dd40843210997da0b9f3ab05e^{commit}` passed.
- Candidate validation and quoted line numbers used only `git show 734df96a1391e95dd40843210997da0b9f3ab05e:PATH | nl -ba` against the immutable base.
- Loop census used the 39 bundle paths, then `git show SHA:PATH | nl -ba | rg 'for\\s*\\(|while\\s*\\('`; 34 executable loops found (plus one comment match) and classified.
- No PoC or Forge test was added/run in the time-box; all findings are reasoning-only and explicitly say so.

AGENT_STATUS: COMPLETE
