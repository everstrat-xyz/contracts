# Plamen raw pass: external-precondition-audit

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full immutable 39-file source scope (25 runtime/library + 14 deployment files)
method: external-call requirement table, return-consumption review, and state-dependency/failure tracing
plugin_confidence: high for code traces; deployment-state likelihood remains unknown because no deployed addresses/configuration were supplied

FINDING
file:         src/contracts/strategies/UniCLStrat.sol
function:     pause / emergencyExit
mechanism:    The emergency paths assume the configured paired token's `approve` and `balanceOf` never revert: `pause()` calls uncaught `forceApprove(...,0)` after `_pause()`, and `emergencyExit()` reads `pairedToken.balanceOf` before unwrapping WETH or sending ETH.
consequence:  A paused/blacklisting/upgraded paired token can roll back the circuit breaker and prevent native ETH/WETH already held by the strategy from reaching StrategyManager.
trigger:      the paired-token integration begins reverting for this strategy; ADMIN_ROLE or SECURITY_ROLE then attempts emergency response
severity:     medium
rationale:    The trigger depends on a configured external asset failure, but impact dominates because the failure defeats both immediate pause and capital recovery during the exact emergency it is meant to contain.
poc:          none — immutable-base code trace
evidence:     `UniCLStrat.sol:633-645` — `_pause(); ... _removeConverterAllowances();`; `:1274-1276` — `token0.forceApprove(..., 0); token1.forceApprove(..., 0);`; `:497-506` — `_pairedBalance = pairedToken.balanceOf(...)` precedes `weth.withdraw` and `_sendETH` despite the comment `ETH first`.
fix:          Make allowance revocation best-effort after persisting the pause, and move/catch the paired-token balance probe so WETH unwrap and native-ETH sweep complete independently.
related:      none
plamen_verdict: CONFIRMED
plamen_steps: ✓1(interface requirement) ✓2(revert/return behavior) ✓3(state-to-use trace)
plamen_rules: R4:✓, R5:✗(single strategy), R6:✓(SECURITY/ADMIN response), R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✗(no aggregate), R15:✗(no flash-loan state), R16:✗(no oracle dependency)
preferred_tag: CODE-TRACE
material_harm: Depositors can lose timely access to strategy-held ETH/WETH, and the security multisig cannot engage the intended strategy circuit breaker while the token remains degraded.
postconditions: strategy remains unpaused or emergency sweep remains unapplied; funds stay at the strategy
postcondition_types: STATE, EXTERNAL, BALANCE
who_benefits: no required beneficiary; a malicious token controller or incident condition prolongs the lock

FINDING
file:         src/contracts/StrategyManager.sol
function:     _depositToStrategies / _withdrawFromStrategies / _checkAndRebalanceStrategies / _syncStrategies
mechanism:    Batch isolation wraps only the terminal strategy action; prerequisite calls such as `maxDeposit`, `isHealthy`, `maxWithdrawal`, and `paused` occur outside `try/catch`, so one reverting strategy aborts the whole batch.
consequence:  One degraded registered strategy blocks operations on healthy peers, including automated liquidity withdrawals needed for queued redemptions.
trigger:      any registered strategy reverts from one of the prerequisite view functions; the keeper invokes an all-strategy batch
severity:     medium
rationale:    A strategy failure is a realistic integration condition and the cross-strategy liveness impact dominates, although ADMIN_ROLE can force-remove the strategy after the governance delay.
poc:          none — immutable-base code trace
evidence:     `StrategyManager.sol:1000-1008` reads `maxDeposit()`/`isHealthy()` before the caught `deposit()` at `:1027`; `:1090-1094` reads `maxWithdrawal()` before the caught `withdraw()` at `:1131`; `:1177-1184` reads `paused()`/`isHealthy()` before caught `rebalance()`; `:1211-1219` reads `paused()` before caught `sync()`.
fix:          Put each strategy's complete probe-and-action sequence behind an external self-call caught per strategy, or individually catch every prerequisite and skip the failing strategy.
related:      none
plamen_verdict: CONFIRMED
plamen_steps: ✓1(interface requirement) ✓2(revert/return behavior) ✓3(batch state trace)
plamen_rules: R4:✓, R5:✓, R6:✓(keeper/admin recovery), R8:✓, R10:✓, R11:✗(strategy interface, not token transfer), R12:✓, R13:✓(documented best-effort), R14:✓(weighted aggregates), R15:✗(no flash-loan prerequisite), R16:✓(a strategy may depend on oracle/pool)
preferred_tag: CODE-TRACE
material_harm: Queued redeemers can wait without liquidity even when healthy strategies hold enough withdrawable ETH, while deposits/rebalances/syncs for every healthy peer also stop.
postconditions: batch transaction reverts atomically; no healthy peer is serviced; keeper action remains pending
postcondition_types: STATE, EXTERNAL, BALANCE
who_benefits: no required beneficiary; a malicious registered strategy could deliberately impose the outage

LEAD
file:         src/contracts/StrategyManager.sol
function:     addSupportedERC20 / _supportedERC20sNAVInETH
suspicion:    Registration checks code and Oracle support but never probes `balanceOf` or `decimals`; NAV subsequently calls `balanceOf` for every supported token and `decimals` for nonzero balances, so a nonconforming or later-degraded token can freeze all AMM pricing.
blocked_by:   ADMIN_ROLE chooses the token and SECURITY_ROLE can remove it immediately without an external call; no deployed token set was supplied, so material exposure is unknown.
next_step:    Inspect deployed supported-token addresses and exercise `balanceOf(StrategyManager)`/`decimals()` across failure and upgrade states.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan prerequisite), R16:✓

LEAD
file:         script/DeployUniCLStrat.s.sol
function:     _deploymentConfig / run
suspicion:    The script documents but does not enforce that the pool can serve `TWAP_INTERVAL`; after registration, `UniCLStrat.navInETH()` reverts when `observe` cannot cover the window and StrategyManager propagates that revert into AMM pricing.
blocked_by:   Registration is timelocked and no deployed pool/cardinality/history was supplied; the failure can self-resolve as observations accumulate.
next_step:    Before registration, call `navInETH()` at the exact deployed configuration and verify both TWAP windows against the pool observation history.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(pool interaction), R12:✓, R13:✓, R14:✗(no coupled setter defect), R15:✗(availability, not price manipulation), R16:✗(pool TWAP availability)

LEAD
file:         src/contracts/automation/StrategyKeeperExecutor.sol
function:     checkUpkeep helpers
suspicion:    `_rebalanceNeeded`, `_totalMaxWithdrawal`, `_depositCapacityAvailable`, and `_pendingPerformanceFeeETH` perform uncaught calls across all registered strategies; one degraded strategy can make off-chain checks revert before lower-priority actions such as exit-liquidity provision are considered.
blocked_by:   This overlaps the registered-strategy failure domain above, and actual Automation retry/funding behavior plus deployed strategies were not supplied.
next_step:    Simulate `checkUpkeep` with one strategy reverting in each probe and measure whether alternate/manual keepers preserve required redemption service.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(strategy calls), R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan prerequisite), R16:✓

CLEARED
area:         Converter adapter returns and token deltas
checked:      Allowlisting/code checks, route validation/token decoding, deadline and slippage bounds, delegatecall success plus exact 32-byte returndata, and balance-delta accounting/refunds were traced for exact-in and exact-out. Adapter-reported amounts do not determine payouts.

CLEARED
area:         Oracle feed basic external-return validation
checked:      Runtime reads reject missing rounds, nonpositive answers, future/stale timestamps, and normalize only feed decimals validated at registration. Round coherence and quote semantics are reserved for the oracle-specific pass.

CLEARED
area:         ETH receiver failure containment
checked:      User claim/immediate-exit transfers revert only that user's transaction; Controller/StrategyManager/AMM module transfers are strict and atomic. UniCLStrat's paired-token ordering is the material exception recorded above.

CLEARED
area:         ExitQueue and keeper array/range consumption
checked:      Parallel configuration arrays have equality checks, queue ranges validate bounds, request membership is checked before state changes, and keeper-returned user arrays are consumed within the requested capped length.

CLEARED
area:         External interaction requirement matrix
checked:      Registry peers require registered code and expected ABI; strategy calls require nonreverting well-formed views/actions; ERC-20/WETH calls require standard metadata/balance/approve/1:1 wrap behavior; feeds require valid round data/decimals/timestamps; Uniswap factory/pool/router require existing pools, two-observation results and callback/payment semantics; adapters require allowlisting, forward route endpoints, stateless delegatecall code and exact returndata; ETH receivers require acceptance. Violations were traced to caller behavior above.

READ_COUNTS
- Plamen rules: orchestrator-rules.md 79/79; finding-output-format.md 114/114.
- Skill: external-precondition-audit/SKILL.md 48/48; directly referenced required files: 0.
- Bundle: scope.md 139/139; profile.md 207/207; context.md 181/181; source.md 9,417/9,417; finding-format.md 101/101.
- Immutable context interfaces: 21/21 files, 3,564 Solidity lines, read only through `git show 734df96:PATH`.

COMMANDS_TESTS
- Source read in bounded `sed -n` chunks; no chunk was counted when a prior tool result was truncated.
- Base validation: `git show 734df96:PATH | nl -ba | sed -n ...` and `git grep ... 734df96 -- PATH` for every cited path.
- Tests: not run; findings are direct revert/order traces and no production/test-audit source was read or modified.
- Network/live systems/production source/commit: not used.

AGENT_STATUS: COMPLETE
