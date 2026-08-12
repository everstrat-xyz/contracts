# Plamen P4 — Depth Edge Case

Target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`

## FINDING

id:           DE-1
file:         script/ProtocolDeployBase.sol
function:     _deployTimelocks
title:        An explicit zero delay silently removes the promised 48-hour governance window
mechanism:    `TIMELOCK_ADMIN_DELAY` is passed directly from `vm.envOr` to `TimelockController`; only the missing-variable case receives the 48-hour default, and no lower bound rejects `0..48 hours-1`.
consequence:  A deployment-operator mistake can leave every ADMIN_ROLE configuration change and UUPS upgrade executable immediately, denying users the documented reaction window before arbitrary implementation, oracle, registry, and strategy changes.
material_harm: Depositors lose the only on-chain notice period intended to let them exit before a malicious or erroneous privileged change can affect all protocol funds.
trigger:      deployment operator supplies `TIMELOCK_ADMIN_DELAY=0` (or any sub-policy value)
severity:     medium
rationale:    Low-likelihood deployment misconfiguration has protocol-wide high impact; the code and comments explicitly define 48 hours as the production minimum, so the missing bound is not merely policy ambiguity.
confidence:   high — direct constructor trace at the immutable SHA; no external behavior beyond standard constructor parameter forwarding is needed.
verdict:      CONFIRMED
step_execution: ✓1(devil's advocate: weak value supplied), ✓2(cross-domain deployment/access), ✗3(no prior-output inventory permitted), ✓4([CODE]), ✓5, ✓6(enablers: env input and modular/one-shot deploy)
rules_applied: R4:✓, R5:✗(single timelock), R6:✓, R8:✓, R10:✓, R11:✗(no token), R12:✓, R13:✓, R14:✓, R15:✗(no flash state), R16:✗(no oracle read)
depth_evidence: [BOUNDARY:TIMELOCK_ADMIN_DELAY absent→48h; 0→0; 1→1s; 48h-1→below policy; 48h→policy], [TRACE:env value→_deployTimelock(_minDelay)→new TimelockController(_minDelay,...)]
evidence:     `DEFAULT_ADMIN_TIMELOCK_DELAY = 48 hours` (line 39); `_deployTimelock(vm.envOr("TIMELOCK_ADMIN_DELAY", DEFAULT_ADMIN_TIMELOCK_DELAY), ...)` (lines 356-358); `new TimelockController(_minDelay, ...)` (line 376). No intervening comparison enforces the documented “never a weaker value” statement at lines 348-350.
poc:          none — base-SHA code trace and concrete boundary substitution
fix:          Read the environment value into a local and require it to be at least `DEFAULT_ADMIN_TIMELOCK_DELAY` before deploying the timelock.
related:      none

## LEAD

id:           DE-L1
file:         src/libraries/Math.sol
function:     basePrice / premiumPrice
suspicion:    Integer flooring can return a zero EVE price after near-total loss (`NAV * 1e18 < supply`), after which AMM conversions divide by zero. With bootstrap supply at least `1000e18`, the concrete zero-price region begins below `1000 wei` NAV before later supply growth; a force-removed strategy can move NAV sharply, but no economically material permissionless path to this residue was closed.
blocked_by:   Requires a realistic post-loss/force-removal state with non-negligible remaining user harm rather than only negligible residual backing.
next_step:    Stateful loss/force-removal regression varying NAV around `ceil(supply/1e18)` and checking AMM enter/exit liveness.

## LEAD

id:           DE-L2
file:         src/contracts/strategies/UniCLStrat.sol
function:     _setTicks / _setAltTicks
suspicion:    Positive `positionWidth` is not related to `tickSpacing` or TickMath bounds; checked `int24` multiplication/addition can revert for large accepted values or ticks near ±887272 and halt deposit/rebalance.
blocked_by:   Admin/deployment configuration is required and the exact feasible pool/config combination was not regression-tested.
next_step:    Instantiate boundary configs at `positionWidth={1,max}` and ticks `{MIN_TICK,MAX_TICK}` with actual pool tick spacing.

## CLEARED

area:         AMM bootstrap and return-to-zero boundaries
checked:      `MIN_INITIAL_DEPOSIT_USD=1000e18` makes the `tokensToMint-1e18` subtraction safe; the permanent `1e18` dead mint and irreversible `bootstrapped` flag keep total EVE supply nonzero after all user exits, so the classic supply-return-to-zero capture path is unavailable.

## CLEARED

area:         ExitQueue expiry equality
checked:      At `pricedAt+3 days`, user close remains rejected and keeper skip remains false; both switch only at `> MAX_BATCH_PROCESSING_TIME`, so the exact boundary does not create a gap or double-action window.

## CLEARED

area:         AMM numeric setters
checked:      Connector weight rejects `0`, accepts `1..1e18`, and rejects `1e18+1`; minimum queued exit accepts `0..0.05 ether` and rejects `0.05 ether+1`, matching the stated inclusive bounds.

## COVERAGE AND EXECUTION

- Instruction coverage: shared Plamen rules/format plus depth-edge-case, EVM generic rules, and zero-state-return read fully; all mandatory edge checks applied to the 39-file scope.
- Full fresh bundle read: `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `source.md` 9,417/9,417, `finding-format.md` 101/101 (10,045/10,045 lines).
- Constants substituted: 48 hours, 3 days, `1000e18`, `1e18`, `0.05 ether`, connector range `1..1e18`, TickMath ±887272.
- Cross-domain assumptions considered: deployment environment correctness, timelock authority, oracle/token behavior, pool tick behavior, and admin-set parameter coherence.
- Commands/results: bounded `sed` reads completed without truncation; `git show 734df96:script/ProtocolDeployBase.sol | nl -ba` confirmed DE-1 at base lines 36-39 and 348-378. No network, live system, production edit, prior-output read, or test execution.

AGENT_STATUS: COMPLETE
