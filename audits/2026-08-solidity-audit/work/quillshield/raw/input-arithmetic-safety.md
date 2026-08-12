# QuillShield Q3 — Input & Arithmetic Safety

- Target: `everstrat-xyz/contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
- Scope: all 39 primary files in `scope.md` (runtime contracts, local libraries, and deployment scripts)
- Independence: fresh pass; no history, other-review output, `test/audit/`, post-base source, network, or live systems used
- Read completion: plugin `SKILL.md` 349/349 lines; `precision-patterns.md` 224/224; `validation-checklist.md` 182/182 (755/755 plugin lines)
- Bundle completion: `scope.md` 139/139; `profile.md` 207/207; `context.md` 181/181; `finding-format.md` 101/101; `source.md` 9,417/9,417 (10,045/10,045 bundle lines)
- Confidence: high on the two concrete findings because the accepted values deterministically reach checked arithmetic reverts; medium on deployment impact because exploitation requires a configuration/operator precondition.

FINDING
file: `src/contracts/StrategyManager.sol:477-485,961-969`; `src/contracts/strategies/UniCLStrat.sol:1280-1296,1249-1263`; `src/libraries/Math.sol:40-52`
function: `StrategyManager.addSupportedERC20`, `StrategyManager._supportedERC20sNAVInETH`, `UniCLStrat._validateConstructorParams`, `UniCLStrat._tokenValueInETH`, `Math.convertDecimals`
mechanism: Token admission validates code and Oracle support, but never validates the token's `decimals()`. `Math.convertDecimals` deliberately rejects every precision above 18. A supported ERC-20 or UniCL paired token reporting more than 18 decimals is therefore admitted even though any nonzero balance is unpriceable.
consequence: Once any account transfers one unit of that admitted token to StrategyManager or the strategy, `totalNAVInETH()` reverts. AMM entry, exit pricing, queue pricing, and fee minting that depend on NAV are unavailable until SECURITY/ADMIN removes the supported token or governance removes/fixes the strategy.
trigger: Governance admits an Oracle-supported token with `decimals() > 18` (or registers a UniCL strategy paired with it); an unprivileged holder then dust-transfers the token to the admitted contract. Zero balances mask the incompatibility because the NAV loops return early before conversion.
severity: MEDIUM
rationale: Protocol-wide liveness loss is externally triggerable after an accepted configuration. The configuration prerequisite and immediate SECURITY removal path reduce likelihood/duration, but no documented/interface constraint restricts supported assets to at most 18 decimals. Confidence is high from the explicit `> 18` revert and missing admission check.
poc: Let token `T.decimals() == 24`, register its USD feed, call `addSupportedERC20(T)` (succeeds), then transfer `1` unit of T to StrategyManager. `totalNAVInETH()` calls `Oracle.convert(..., 24, 18)`, which reaches `Math.convertDecimals` and reverts `MathDecimalsTooHigh`. The same dust trigger applies to an admitted UniCL paired token.
evidence: Base `StrategyManager.sol` lines 477-485 check zero/code/Oracle support only; lines 965-968 pass live metadata decimals into `Oracle.convert`. Base `Math.sol` lines 40-43 reject `_fromDecimals > 18`. Base UniCL validation lines 1280-1296 omits token-decimal compatibility.
fix: Reject assets whose metadata precision exceeds `Math.DECIMALS_NORMALIZED` both in `addSupportedERC20` and the UniCL constructor, with a dedicated error. Prefer reading/validating metadata before asset admission and document the supported-decimal invariant.
related: External token metadata can also revert or change after admission; `removeSupportedERC20` is a useful circuit breaker but not preventive validation.

FINDING
file: `src/contracts/strategies/UniCLStrat.sol:536-563,688-703,801-821,1280-1300`
function: `setPositionWidth`, `setMaxTickDeviation`, `_validateConstructorParams`, `_isCalm`, `_setTicks`, `_setAltTicks`
mechanism: Constructor/setter validation checks only positivity. It does not bound `positionWidth` against the pool's `tickSpacing` and TickMath range, or `maxTickDeviation` against the observed tick domain. Accepted configuration is later evaluated in narrow signed types: `int24 positionWidth * tickSpacing`, `tickFloor +/- width`, and `int56 twapTick +/- maxTickDeviation`.
consequence: A configuration transaction succeeds but subsequent health checks, deposits, and rebalances deterministically revert. Because keeper `checkUpkeep` calls `isHealthy`, a bad deviation can also stop the strategy automation decision path until a timelocked repair executes.
trigger: With canonical `tickSpacing = 60`, set `positionWidth = 139,811`; the accepted multiplication is 8,388,660, above `type(int24).max`, so `_setTicks` reverts. Alternatively set `maxTickDeviation = type(int56).max`; one of `_twapTick - deviation` / `_twapTick + deviation` overflows for ordinary nonzero ticks.
severity: LOW
rationale: The failure is certain for concrete accepted values and can interrupt operations, but only ADMIN_ROLE (48-hour timelock in the stated production model) selects them and can repair them. Confidence is high; severity is limited by the privileged precondition.
poc: Pure arithmetic proof above; no stateful regression test was needed. The setters accept both examples, while Solidity 0.8 checked arithmetic reverts at `_setTicks` or `_isCalm`.
evidence: Base lines 536-552 and 1288-1294 enforce lower bounds only; base lines 696-697 and 803-821 perform the unguarded narrow arithmetic.
fix: On construction and every setter, derive safe bounds from `tickSpacing`, `TickMath.MIN_TICK/MAX_TICK`, and the maximum Uniswap tick magnitude. Compute intermediate tick arithmetic in `int256`, validate the result, then narrow explicitly.
related: `rebalanceTickThreshold` should also be bounded to a meaningful position-width/tick range; very large positive values do not overflow here but defeat intended health semantics.

FINDING
file: `script/DeployUniCLStrat.s.sol:91-119`; `script/DeployUniswapV3ConverterAdapter.s.sol:49-59`
function: `_deploymentConfig`, `DeployUniswapV3ConverterAdapter.run`
mechanism: Deployment environment integers are narrowed directly to `uint32`, `int24`, and `int56` before validation. Solidity explicit narrowing truncates/wraps rather than reverting, so the subsequent constructor/floor checks validate the truncated value instead of the operator-supplied value.
consequence: A typo or unit/range error can silently deploy immutable adapter/strategy bytecode with materially different TWAP windows, tick widths, thresholds, or deviation bounds. The post-deploy checks compare against the already-truncated values, so they do not detect the mismatch.
trigger: For example, `TWAP_INTERVAL = 2**32 + 1800` becomes `1800` and passes its floor; `POSITION_WIDTH = 2**24 + 1` becomes positive `1` and passes strategy construction.
severity: LOW
rationale: Silent truncation is proven and the resulting configuration can alter risk controls or require redeployment, but the input is supplied by a trusted deploy operator rather than an attacker. Confidence is high.
poc: Direct cast identities modulo `2**32`/`2**24`; base lines 92-99 and 113-115 show narrowing occurs before checks.
evidence: Base-only `git show` confirms all five UniCL env conversions and the adapter interval cast; neither script checks the original `uint256`/`int256` against target-type bounds.
fix: Read into `uint256`/`int256`, check `<= type(T).max` and signed min/max (plus semantic bounds), then cast. Log and post-verify the original intended values.
related: Runtime finding above makes wrapped tick configuration especially hazardous.

LEAD
file: `src/libraries/Math.sol:75-122`; `src/contracts/Oracle.sol:302-329`; `src/contracts/adapters/UniswapV3ConverterAdapter.sol:350-357`; `src/contracts/strategies/UniCLStrat.sol:1120-1130`
function: `convertAssets`, `convertAssetsInverse`, `basePrice`, `premiumPrice`, `isRelativelyLessThan`, `Oracle.convert`, `_checkDeviation`, `_enforceOracleBounds`
hypothesis: Multiple multiply-then-divide expressions use 256-bit intermediates rather than `mulDiv`, so an intermediate can overflow even when the final quotient fits. For NAV-bearing supported-token balances, an enormous permissionless token donation could turn this into a pricing DoS.
why_unresolved: The arithmetic condition is real, but reaching it with configured standard assets appears to require implausibly large balances/prices; no credible economic or token-supply bound violation was established from the supplied context.
next_step: Fuzz each formula against a 512-bit `mulDiv` oracle under explicit asset supply/price bounds, then model whether any supported/upgradable token permits an attacker to cross the smallest threshold.

LEAD
file: `src/contracts/automation/StrategyKeeperExecutor.sol:426-429`
function: `_idleExcess`
hypothesis: Unbounded `controllerReserveETH` is added to computed `_needsETH`; a sufficiently large admitted reserve makes `checkUpkeep` and multiple perform branches revert on overflow.
why_unresolved: Only timelocked ADMIN can set the reserve, making this another configuration-liveness issue; no unprivileged route to inflate `_needsETH` close enough to `type(uint256).max` was found under realistic ETH/EVE supply bounds.
next_step: Add a semantic reserve cap and use saturating comparison (`reserve >= balance` / subtraction ordering), then fuzz keeper decisions at boundary values.

CLEARED
area: User-facing amount/range/deadline inputs in AMM, Controller, ExitQueue, Converter, Whitelist, keeper executors, Registry, and strategy entry points.
evidence: Zero amounts, slippage/percentage ranges, deadlines, address/code checks, paired array lengths, and index ranges are checked before value-moving state transitions; caller-only oversize arithmetic reverts do not create cross-user loss.

CLEARED
area: Deposit/redemption and allocation rounding.
evidence: AMM mint/burn conversions floor in the protocol's favor; queued processing uses the priced token amount consistently; weighted allocations floor each leg and return undeployed remainder. No repeatable rounding gain or share-inflation path was found; bootstrap enforces 1,000e18 USD and locks dead supply.

CLEARED
area: Division denominators, fee rates, tick mean rounding, and checked casts in libraries.
evidence: Supply/price/feed values are nonzero on reachable value paths; performance fee is capped at 2,000 bps; negative tick means explicitly round toward negative infinity; `LiquidityAmounts.toUint128` verifies round-trip equality. Canonical `FullMath` unchecked arithmetic preserves its stated 512-bit invariant.

CLEARED
area: Dust and accumulated rounding.
evidence: UniCL fee settlement does not advance charged counters when ETH fee rounds to zero; batch EVE attribution assigns remainder to the last strategy; iteration counters in `unchecked` blocks are bounded by allocated array/count lengths. No attacker-profitable dust loop was established.

## Coverage and commands

- Input coverage: addresses/code, amounts/zero/max, arrays and paired lengths, percentages/rates, timestamps/deadlines, bytes/routes/signatures, enum/state selectors, constructors/initializers, setters, and financial entry points.
- Arithmetic coverage: division-before-multiplication, phantom overflow, rounding direction/accumulation, share-price/bootstrap inflation, decimal normalization, unsafe narrowing/signed arithmetic, unchecked blocks, dust, fee allocation, Uniswap fixed-point/tick math.
- Read commands: `wc -l` on the plugin and allowed bundle; `sed -n` over every plugin/reference/bundle line, with `source.md` reread in bounded chunks through line 9417.
- Validation commands: base-only `git show 734df96:PATH | nl -ba | sed -n ...` for StrategyManager, UniCLStrat, Math, and deployment scripts; base-only `git grep -nE ... 734df96 -- script src` for narrowing casts.
- Results: three concrete LOW/MEDIUM findings, two bounded leads, four cleared mechanism groups. No test file authored; no Foundry test run. No production files changed.

AGENT_STATUS: COMPLETE
