# Plamen P4 — DEX Integration Security

Target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`

## FINDING

id:           DEX-1
file:         src/contracts/strategies/UniCLStrat.sol
function:     constructor / uniswapV3MintCallback
title:        UniCL does not authenticate its callback-authorized pool through a trusted factory
mechanism:    `POOL_ADDRESS` is accepted after querying only token0/token1/tickSpacing. That address is then the sole identity guard in `uniswapV3MintCallback`, whose amount parameters are trusted without comparison to mint-computed maxima.
consequence:  A malicious interface-compatible pool supplied in deployment configuration can pass construction/calm checks, receive a funded `mint`, callback for all strategy WETH and paired tokens, and retain them without minting genuine liquidity.
material_harm: The entire ERC-20 inventory of a funded UniCL strategy can be stolen in one callback.
trigger:      malicious or substituted deployment `POOL_ADDRESS`, followed by a strategy deposit
severity:     medium
rationale:    Full strategy loss is high impact, but reachability depends on privileged deployment/configuration integrity rather than a permissionless replacement of the immutable address.
confidence:   high — closed adversarial-contract trace requiring no unknown genuine-Uniswap semantics.
verdict:      CONFIRMED
step_execution: ✓1(pool selection/authentication), ✓2(N/A router deadline), ✓3(callback transfer effects), ✓4(factory authenticity), ✓5(strategy→Converter approval reviewed)
rules_applied: R4:✓, R5:✗(one pool), R6:✓(deployment operator), R8:✓(immutable external address), R10:✓(full inventory), R11:✓, R12:✓, R13:✗(not intended), R14:✓, R15:✗(no flash prerequisite), R16:✗(not oracle-dependent)
depth_evidence: [TRACE:deployment pool→immutable pool→minting flag→pool callback→unbounded token transfers], [BOUNDARY:requested callback 0→none; balances→full drain; balances+1→revert]
evidence:     Constructor lines 136-155 store the supplied pool after token membership checks only; `_mintPosition` lines 739-755 calls it with `_minting=true`; callback lines 524-529 checks only caller/flag and transfers callback amounts. The deployment script forwards `POOL_ADDRESS` at lines 101-106 without a trusted-factory lookup.
poc:          none — base-SHA code trace
fix:          Constructor-verify the exact pool via a trusted immutable factory and bind callback payment to per-mint expected amount maxima stored before `pool.mint`.
related:      none

## FINDING

id:           DEX-2
file:         src/contracts/adapters/UniswapV3ConverterAdapter.sol
function:     validateRoute
title:        Route validation accepts nonexistent and invalid-fee pools
mechanism:    `validateRoute` checks only that the byte string is a 43-byte single-hop encoding. UniCL relies on that result plus token direction when installing routes, but pool existence and fee-domain validity are checked only later inside `_twapQuote`.
consequence:  A structurally valid route with a nonexistent pool (or fee `>=1_000_000`) can be installed successfully; funded deposits, rebalances, and withdrawals later revert when quoting, leaving normal strategy operation unavailable until the 48-hour admin path repairs the route or emergency unwind is used.
material_harm: Users can lose normal withdrawal/rebalance liveness for the full governance repair delay after an accepted route misconfiguration.
trigger:      ADMIN/deployer installs a well-shaped WETH↔paired-token path whose factory pool is zero or whose fee arithmetic is invalid
severity:     low
rationale:    The failure is deterministic and can affect a funded strategy, but it is privileged, recoverable, and primarily causes delayed availability rather than direct asset loss.
confidence:   high — validation and delayed quote paths are explicit; deployment state only determines whether the bad configuration is present.
verdict:      CONFIRMED
step_execution: ✓1(structural vs semantic validation), ✓2(deadline N/A), ✓3(revert propagates atomically), ✓4(fee/pool assumptions), ✓5(no approval occurs before quote)
rules_applied: R4:✓, R5:✗(single-hop), R6:✓(admin vs users), R8:✓(stored route), R10:✓(funded-strategy state), R11:✗(no transfer before failure), R12:✓, R13:✓, R14:✓, R15:✗(no flash precondition), R16:✓
depth_evidence: [TRACE:setRouteConfig→validateRoute(shape only)=true→route stored→later quote→factory.getPool=0→revert], [BOUNDARY:fee=0/valid tier→pool-dependent; 999999→arithmetic defined; 1000000→subtract/divide failure if pool exists]
evidence:     Adapter `validateRoute` returns only `isValidPath && isSingleHop` (lines 139-144). UniCL accepts routes after this check and token direction only (lines 593-615). `_twapQuote` performs the first `factory.getPool` lookup and reverts for zero (adapter lines 288-297); fee subtraction/division occurs at lines 175-180 and 198-206 without a `<1_000_000` validation.
poc:          none — base-SHA route lifecycle trace
fix:          Make adapter validation semantic: decode fee, require `fee < 1_000_000`, resolve a nonzero code-bearing factory pool, and verify it can serve the configured TWAP before UniCL stores the route.
related:      DEX-1

## LEAD

id:           DEX-L1
file:         src/contracts/Converter.sol
function:     executeSwapExactAmountIn / executeSwapExactAmountOut
suspicion:    Fee-on-transfer input can make the Converter receive less than the declared amount while the router is approved for the full amount; any pre-existing Converter balance may subsidize the authorized caller, and exact-output surplus refund arithmetic can otherwise revert.
blocked_by:   The supported paired-token set and whether any configured token charges transfer fees are unknown; standard WETH/USDC routes do not exhibit this behavior.
next_step:    Isolated regression with a fee-on-transfer token plus pre-donated Converter balance for both exact-input and exact-output paths.

## LEAD

id:           DEX-L2
file:         src/contracts/strategies/UniCLStrat.sol
function:     _giveConverterAllowances / _removeConverterAllowances
suspicion:    Strategy grants unlimited allowances to the Registry's current Converter. If Registry registration migrates to a new Converter, pause revokes only the new address and leaves the old proxy's allowance live.
blocked_by:   The old Converter cannot pull from the strategy through current honest code; material theft additionally requires old-proxy upgrade/compromise, whose authority overlaps broader ADMIN power.
next_step:    Add a Converter-rotation regression and decide whether migration policy requires explicit old-address allowance revocation.

## CLEARED

area:         Slippage origin and forwarding
checked:      UniCL obtains TWAP-based adapter quotes, independently checks symmetric Chainlink bounds, applies configurable 1-200 bps slippage, and forwards the resulting min-output/max-input unchanged through Converter to the router. Exact-output unaffordability falls back to the same protected exact-input path.

## CLEARED

area:         Deadline handling
checked:      UniCL uses `block.timestamp+15 minutes`, so the deadline is correctly documented as interface compliance rather than MEV protection. Because quote, oracle check, and swap execute atomically from live state, there is no cached pre-transaction quote whose age this deadline needs to bind.

## CLEARED

area:         Swap return and multi-output handling
checked:      Converter ignores adapter-reported output/spend, measures token balance deltas, checks min output/exact output and max input, refunds unused exact-output input, and transfers only measured/required output; reverts roll back the whole operation.

## CLEARED

area:         Router approval lifecycle
checked:      The adapter approves the immutable router for the exact per-swap input/max and clears allowance to zero after success; any router revert atomically rolls back the approval. No persistent router allowance exists.

## CLEARED

area:         Multi-hop behavior
checked:      Adapter and route installation require exactly one 43-byte hop, so there are no unchecked intermediate outputs. Exact-output reverses the forward path before router execution.

## SKILL CHECKLIST

- §1 slippage: complete — origin, forwarding, exact-in/out, zero/dust boundary, single-hop.
- §2 deadline: complete — current-time deadline is not treated as a security layer; no queued DEX call.
- §3 returns: complete — balance deltas and revert atomicity cleared; fee-on-transfer is DEX-L1.
- §4 fee/pool: complete — DEX-1 and DEX-2.
- §5 approvals: complete — per-router approvals cleared; Converter migration is DEX-L2.

## COVERAGE AND EXECUTION

- Instruction coverage: shared Plamen rules/format, dex-integration-security, and EVM generic rules read fully and applied to all DEX call sites in the 39-file scope.
- Fresh bundle read: 10,045/10,045 lines (`source.md` 9,417/9,417).
- Commands/results: base-only `git show 734df96` confirmed adapter validation/quote/swap paths, Converter balance-delta accounting, UniCL route installation/oracle bounds/approvals, pool constructor/callback, and deployment forwarding. No network, live system, production edit, prior-output read, or test execution.

AGENT_STATUS: COMPLETE
