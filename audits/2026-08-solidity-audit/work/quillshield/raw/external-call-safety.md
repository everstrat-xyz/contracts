# QuillShield Q3 — external-call-safety

target: `734df96a1391e95dd40843210997da0b9f3ab05e`
mode: independent, read-only, base-SHA validation
scope: 39 Solidity files

## Read coverage

- Plugin instructions: `SKILL.md` 326/326 lines.
- Plugin references: `call-safety-patterns.md` 237/237 and `weird-erc20.md` 240/240; total 803/803 plugin lines.
- Bundle: `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `finding-format.md` 101/101, and `source.md` 9,417/9,417; total 10,045/10,045 lines.
- Applied to the full scope: low-level call results, gas/returndata griefing, delegatecall trust, ERC-20 return variants, fee-on-transfer/rebasing behavior, callbacks, approvals, blacklist/limit behavior, ETH sends, and push/pull recovery.

FINDING
file:         src/contracts/StrategyManager.sol:730-754,989-1033,1080-1141,1177-1185,1211-1220
function:     _harvestPerformanceFeesFor; _depositToStrategies; _withdrawFromStrategies; _checkAndRebalanceStrategies; _syncStrategies
mechanism:    Every best-effort strategy action binds `catch (bytes memory reason)`, so Solidity copies attacker-controlled, unbounded revert data into memory before entering the catch handler; a returndata bomb can therefore consume all gas instead of being isolated.
consequence:  One broken registered strategy can revert an entire harvest, deposit, withdrawal, rebalance, or sync batch, preventing healthy strategies from being processed and blocking strategy-sourced exit liquidity until operators pause/remove the bad strategy.
trigger:      An admin-registered strategy, or an external pool/token dependency whose revert data the strategy bubbles, returns sufficiently large revert data.
severity:     medium
rationale:    Likelihood is constrained to a registered strategy/dependency failure, but impact includes systemic batch and withdrawal liveness; confidence is high because the five catch bindings are direct and the code elsewhere explicitly uses parameterless catches to avoid this exact EVM behavior.
poc:          none — reasoning only
evidence:     Base lines 742-753 contain `try IStrategy(strategy).settlePerformanceFee(...) ... catch (bytes memory reason)`; lines 1027-1032, 1131-1140, 1181-1185, and 1216-1220 repeat the binding. Lines 1207-1209 state that the sync batch should catch a failure and continue. In contrast, `UniCLStrat._pauseStrategy` uses a parameterless catch with the comment that binding revert data would allow a returndata bomb.
fix:          Use parameterless `catch` blocks and emit a fixed failure code; if diagnostic bytes are required, make a bounded low-level-call wrapper that copies at most a small fixed prefix.
related:      QS-ECS-02

FINDING
file:         src/contracts/StrategyManager.sol:989-1014,1080-1101,1177-1187,1211-1221
function:     _depositToStrategies; _withdrawFromStrategies; _checkAndRebalanceStrategies; _syncStrategies
mechanism:    Strategy preflight calls (`maxDeposit`, `maxWithdrawal`, `paused`, and `isHealthy`) execute outside the guarded action calls, so an ordinary revert from one strategy bypasses the batch's per-strategy failure isolation.
consequence:  A pool, oracle, or token outage affecting one strategy aborts the whole range before later healthy strategies can receive deposits, provide withdrawals, rebalance, or sync.
trigger:      Any registered strategy whose view preflight reverts; the in-scope UniCL strategy reaches external pool/oracle/token calls from these views.
severity:     medium
rationale:    Dependency failure is plausible and blocks multiple operational and exit paths, although SECURITY_ROLE can mitigate by pausing the strategy; confidence is high from direct call placement outside every `try`.
poc:          none — reasoning only
evidence:     Base lines 1003-1008 call `strategy.maxDeposit()` and `strategy.isHealthy()` before the deposit `try` at 1027; lines 1093-1101 call `maxWithdrawal()` before the withdrawal `try` at 1131; lines 1180 and 1214 call view functions before their action `try` blocks. `UniCLStrat._maxDeposit` calls `_isCalm`/`navInETH`, and `_currentTick` calls `pool.slot0()` at lines 679-706.
fix:          Wrap each strategy's preflight and action in one parameterless per-strategy `try` boundary (or guarded self-call), emit a fixed failure event, and continue with the next strategy.
related:      QS-ECS-01

FINDING
file:         src/contracts/Converter.sol:121-135,141-211,371-408
function:     executeSwapExactAmountOut; _executeSwapExactAmountIn
mechanism:    Output minimum/exactness is checked against the Converter's received balance delta, then the same nominal amount is transferred again without measuring what the caller receives; a fee-on-transfer output token charges on that second hop after the check.
consequence:  A caller strategy can receive less than `_minAmountOut` or `_amountOut`, while the return value and `SwapExecuted` event report the larger pre-transfer amount, moving realized execution outside configured slippage guarantees.
trigger:      A CONVERTER_CALLER_ROLE strategy swaps into an admin-accepted fee-on-transfer token, or an accepted/upgradable output token later enables a transfer fee.
severity:     low
rationale:    Token/configuration compatibility is a prerequisite and the first-hop minimum limits common fees, but every successful affected exact-input swap realizes an unreported shortfall; confidence is high from the two-hop balance flow.
poc:          none — reasoning only
evidence:     Exact-input base lines 402-406 set `_amountOut = balanceOf(this) - _balanceBefore`, check it against `_minAmountOut`, then `safeTransfer(msg.sender, _amountOut)` without a recipient-delta check. Exact-output lines 198-209 likewise verify the delta into the Converter before forwarding `_amountOut`.
fix:          Explicitly reject fee-on-transfer output assets/routes, or measure the recipient's balance delta around the final transfer and require that the delivered amount satisfies the caller's minimum/exact requirement.
related:      none

LEAD
file:         src/contracts/Converter.sol:141-211,371-408
function:     executeSwapExactAmountOut; _executeSwapExactAmountIn
suspicion:    Nominal fee-on-transfer input pulls are not reconciled before adapter execution. In exact-output, `_balanceInBefore` is sampled after pulling `_amountInMaximum`, while the adapter receives the nominal maximum and the refund is computed as nominal maximum minus measured spend; a pre-existing same-token Converter balance can subsidize the short pull and nominal refund.
blocked_by:   The scoped design does not establish whether nonzero Converter token balances are protected protocol assets or whether fee-on-transfer input tokens are supported; no isolated mock-token proof was added in this pass.
next_step:    Run an isolated exact-output test with pre-balance `P`, nominal maximum `M`, and a token delivering `R < M`; verify the router can spend/refund against `P + R` and quantify the Converter balance loss.

CLEARED
area:         Low-level ETH send result handling
checked:      Converter unwrap, UniCL payout, AMM claims, Controller forwarding, and StrategyManager refunds all check low-level-call success or use OpenZeppelin `Address.sendValue`; claim paths update state before interaction and use `nonReentrant`.

CLEARED
area:         ERC-20 return-value and approval handling
checked:      Token transfers use `SafeERC20`/`trySafeTransfer`, and approvals use `forceApprove`, covering false/no-return and reset-to-zero approval variants. UniCL pause revokes Converter allowances and unpause restores them.

CLEARED
area:         Emergency failure isolation
checked:      UniCL pauses local state before its best-effort pool unwind, uses parameterless catches for potentially hostile returndata, sends ETH before the best-effort paired-token transfer, and leaves a failed paired transfer retryable.

CLEARED
area:         Delegatecall authorization boundary
checked:      Swap delegatecall targets must be ADMIN_ROLE-allowlisted adapters with deployed code and valid routes. This is an explicit trusted-adapter boundary; no unprivileged path to select an unlisted target was found.

CLEARED
area:         Direct callback authentication and reentrancy guards
checked:      The Uniswap mint callback requires the configured pool and an active `_minting` flag. State-changing Converter and strategy asset operations are `nonReentrant`; no callback path bypassing role/caller checks was found.

## Commands and tests

- Full reads used bounded `sed -n` ranges; `wc -l` established the counts above.
- Base validation used `git grep -n -E 'catch ...|maxDeposit|maxWithdrawal|isHealthy|paused' 734df96... -- src` and `git show 734df96...:<path> | nl -ba | sed -n ...`.
- Tests: not run; no test file created. Findings are direct control-flow/balance-accounting proofs against the immutable base.
- Production files were not edited; no network or live-system calls were made; no commit was created.

AGENT_STATUS: COMPLETE
