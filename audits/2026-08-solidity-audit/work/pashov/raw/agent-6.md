# Pashov reviewer 06 — helper/library/periphery correctness

Scope: immutable 9,585-line local bundle, read completely and in order. No reviewer output was read. Production source was not changed.

## Marked review notes

[Feynman: ProtocolDeployBase] This helper creates each protocol component, records its address, assigns the intended roles, and checks that the finished wiring points back to the same registry.

[Inversion: ProtocolDeployBase._registerAndVerify] Tried an already-used key, a zero address, and an address without code; the helper/Registry combination rejects all three.

[Feynman: RegistryClientBase] This base asks one shared registry either whether the caller has a role or whether the caller exactly matches a named component.

[Inversion: RegistryClientBase.onlyAuthContract] Tried an unregistered key, a replacement address, and an ordinary account; none is mistaken for the current registered component.

[Feynman: Math] These helpers rescale units, multiply an amount by a normalized price, divide by that price, and compare two values using a caller-supplied relative tolerance.

[Socratic: Math.sol:isRelativelyLessThan — why?] The comparison multiplies both sides because it assumes protocol prices remain far below the integer limit; realistic normalized NAV prices satisfy that assumption, while the tolerance itself is bounded to 100%.

[Inversion: Math.convertDecimals] Tried 19 decimals, a downscale that leaves dust, and identical precisions; excessive precision reverts, dust rounds down consistently, and identical precision is unchanged.

[Feynman: UniswapV3Path] This library recognizes packed paths, extracts their endpoint addresses and fee, and reverses a one-hop path for exact-output routing.

[Socratic: UniswapV3Path._readAddress — why?] Reading a full word at the last address is safe only because the desired address occupies the first 20 bytes of that word; shifting discards all following bytes, including zero-padded tail memory.

[Inversion: UniswapV3Path.decodeSingleHop] Tried 42 bytes, 44 bytes, and a valid 66-byte two-hop path; all are rejected by the one-hop decoder.

[Feynman: TickUtils] This library derives a time-averaged tick, rounds negative averages downward, and offers a version that reports an unavailable observation instead of propagating the pool's failure.

[Inversion: TickUtils.meanTickFromCumulatives] Tried delta -1 over 2 seconds, delta +1 over 2 seconds, and an exactly divisible negative delta; results round to -1, 0, and the exact quotient as intended.

[Feynman: FullMath and LiquidityAmounts] These helpers preserve the wide intermediate product needed for pool price math and translate between token amounts and concentrated-liquidity units across below-range, in-range, and above-range states.

[Inversion: LiquidityAmounts.getAmountsForLiquidity] Tried reversed bounds, a price on each endpoint, and zero liquidity; bounds normalize, endpoint branches are consistent, and zero stays zero.

[Feynman: Oracle conversion helpers] The oracle normalizes each feed to 18 decimals, rejects unusable or old readings, then uses a direct pair, an inverted pair, or two USD feeds to translate token amounts.

[Inversion: Oracle.convert] Tried identical tokens with different output precision, only an inverted pair, and no pair feed; each selects the intended conversion branch.

[Feynman: Converter swap helpers] The converter pulls the route's input token, runs allowed adapter code in the converter's balance context, measures actual balance changes, returns output, and refunds unused exact-output input.

[Socratic: Converter._dispatchSwap — why?] A 32-byte return check proves only that the adapter returned one word, not that it behaved correctly; correctness therefore comes from the admin allowlist plus measured token deltas, not from the decoded word.

[Inversion: Converter.executeSwapExactAmountOut] Tried an expired deadline, a disallowed adapter, and output below the requested amount; each reverts before settling a caller payout.

[Feynman: UniswapV3ConverterAdapter] The adapter decodes a one-pool route, quotes from a time average checked against the protocol oracle, grants the router a temporary allowance, performs the swap, and clears that allowance.

[Socratic: UniswapV3ConverterAdapter.validateRoute — why?] “Valid” here means byte-shape only; it does not establish nonzero/distinct endpoints, a usable fee, or that a corresponding pool exists, so callers must not treat it as proof that a route is executable.

[Inversion: UniswapV3ConverterAdapter.swapExactAmountOut] Tried a multi-hop path, forward-versus-router reverse ordering, and unused allowance; the adapter rejects multi-hop, reverses once, and clears the residual approval.

[Feynman: UniCLStrat pause and emergency exit] Pausing first records the circuit-breaker state, attempts to unwind pool liquidity without requiring success, and then removes converter allowances. Emergency exit, available only while paused, converts held wrapped native value, sends native value to the manager, and attempts to send the paired token.

[Socratic: UniCLStrat._pauseStrategy — why?] The pool unwind is explicitly failure-tolerant, but token approval cleanup is not; this assumes both pool tokens' approval calls can never fail, even though the circuit breaker is meant for degraded dependencies.

[Inversion: UniCLStrat._pauseStrategy] Tried a reverting pool call, a reverting WETH approval, and a reverting paired-token approval; the pool case is caught, but either approval failure rolls back the already-recorded pause.

[Socratic: UniCLStrat.emergencyExit — why?] The paired-token balance is read before any native value is sent, which assumes a degraded token can still answer balance queries despite the stated requirement that paired-token failure must not hold the native sweep hostage.

[Inversion: UniCLStrat.emergencyExit] Tried a paired transfer that reverts, a paired transfer returning false, and a paired balance query that reverts; the first two are tolerated after the native sweep, while the balance-query failure prevents the sweep entirely.

[Feynman: Auth and Registry helpers] These files give every component and role one shared identifier and keep address/role enumeration synchronized with registry mutations.

[Inversion: Registry role bookkeeping] Tried a duplicate grant, revoking a non-holder, and the last member renouncing; membership and the enumerated role set remain consistent.

## Confirmed defects

FINDING | contract: UniCLStrat | function: _pauseStrategy | bug_class: fallible-cleanup-rolls-back-pause | group_key: UniCLStrat | _pauseStrategy | fallible-cleanup-rolls-back-pause
path: ADMIN_ROLE or SECURITY_ROLE caller -> pause() -> `_pause()` records the circuit breaker -> best-effort pool unwind completes or is caught -> `_removeConverterAllowances()` calls each pool token -> one approval failure reverts the transaction -> paused state rolls back -> emergencyExit remains unreachable
proof: In `Agent06.t.sol`, the paired token is made to revert specifically on `approve(converter, 0)`. Calling `strategy.pause()` reverts and `strategy.paused()` remains false. The isolated regression passes, proving the current behavior. This does not depend on pool liquidity or balances.
expected: Once an authorized caller invokes the emergency circuit breaker, a failure in dependency cleanup should be reported but must not undo the paused state.
actual: Either pool token can revert allowance removal and atomically undo `_pause()`.
consequence: A degraded pool token can block the prerequisite state for `emergencyExit`, leaving all strategy value on the normal operational path during the incident the pause path is intended to handle.
description: Mandatory token-approval cleanup contradicts the otherwise failure-tolerant circuit-breaker design and can roll back the pause.
fix: Make each allowance revocation best-effort (for example through a non-reverting self-call/low-level wrapper with a failure event) after recording the pause, and provide a retryable cleanup function.

FINDING | contract: UniCLStrat | function: emergencyExit | bug_class: pre-sweep-token-query-blocks-native-recovery | group_key: UniCLStrat | emergencyExit | pre-sweep-token-query-blocks-native-recovery
path: authorized caller pauses strategy -> strategy holds native ETH -> emergencyExit() -> WETH balance read -> pairedToken.balanceOf(strategy) reverts -> function exits before `_ethToSend` and `_sendETH` -> native balance remains on strategy
proof: In `Agent06.t.sol`, the paused strategy receives exactly 1 ETH, then only the paired token's `balanceOf(strategy)` call is mocked to revert. `emergencyExit()` reverts, the strategy still holds 1 ETH, and StrategyManager receives 0. The isolated regression passes, proving the ordering defect.
expected: Existing native ETH (and any independently recoverable asset) should be swept even when the paired token is nonresponsive, matching the function's stated best-effort token behavior.
actual: A fallible paired-token balance query occurs before the native sweep, so the best-effort transfer guard is never reached.
consequence: A nonresponsive paired token can prevent recovery of unrelated native value.
description: The emergency path protects the paired transfer but not the earlier paired balance query, so token failure can still hold the native sweep hostage.
fix: Isolate paired-token balance discovery and transfer inside one caught/best-effort operation, and sequence/catch all token interactions so an existing native balance is sent independently.

## Leads

LEAD | contract: UniswapV3ConverterAdapter | function: validateRoute | bug_class: structural-only-route-validation | group_key: UniswapV3ConverterAdapter | validateRoute | structural-only-route-validation
code_smells: Any 43-byte blob passes, including zero/identical token endpoints and fee values at or above the 1,000,000 fee denominator; the latter later underflows or divides by zero in quote fee adjustment if a factory resolves a pool.
description: This is an integration-hardening gap, but the local canonical factory/pool assumptions and strategy endpoint checks leave no confirmed non-admin value-loss path in scope; validate endpoints/fee and optionally pool existence before returning true.

LEAD | contract: TickUtils | function: tryMeanTick | bug_class: unchecked-observation-array-shape | group_key: TickUtils | tryMeanTick | unchecked-observation-array-shape
code_smells: A successful `observe` response is indexed at positions 0 and 1 without checking length; a nonconforming pool can return a validly encoded short array and trigger a local bounds panic outside the external-call failure being handled.
description: Canonical Uniswap V3 pools return one element per requested timestamp, so this needs a nonconforming configured pool; require both returned arrays to have the expected length if the helper is intended to be generically non-reverting.

## Regression evidence

Candidate: `test/audit/candidates/pashov/Agent06.t.sol`

Command: `FOUNDRY_OUT=out-pashov-agent-06 FOUNDRY_CACHE_PATH=cache-pashov-agent-06 forge test --match-path test/audit/candidates/pashov/Agent06.t.sol`

Result: 2 passed, 0 failed, 0 skipped. The compiler emitted only existing mock mutability warnings. Foundry also reported a non-test signature-cache write warning; the suite itself completed successfully.

## CLEARED_AREAS

- UniswapV3Path byte-length/alignment checks, endpoint extraction, fee extraction, and one-hop reversal.
- TickUtils negative-mean rounding and canonical two-observation handling.
- FullMath wide multiplication/division and LiquidityAmounts range branches.
- Math decimal conversion and normal protocol-scale asset/base/premium conversions.
- Oracle feed sign/timestamp/staleness/decimal checks and direct, inverted, and USD-cross conversion direction.
- Converter adapter allowlist gates, route dispatch shape, exact-input output measurement, exact-output input/output measurement, refunds, and adapter return-length check.
- UniswapV3ConverterAdapter TWAP/oracle deviation comparison, exact-output path reversal, and post-swap allowance clearing for canonical ERC-20s.
- Registry key lookup, role-admin dispatch, zero/code checks, and role enumeration bookkeeping.
- RegistryClient static and upgradeable registry storage/address checks.
- Auth key/role consistency, EVE mint/burn role forwarding, Whitelist invite binding/replay state, and deployment helper back-pointer verification.

AGENT_STATUS: COMPLETE — full bundle read; 2 FINDINGs, 2 LEADs; isolated 2-test regression suite passed; no production changes.
