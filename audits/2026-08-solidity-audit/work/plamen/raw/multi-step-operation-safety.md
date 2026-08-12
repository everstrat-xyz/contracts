# Plamen Raw Pass — multi-step-operation-safety

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full immutable primary scope, 39/39 files
methodology: Plamen multi-step-operation-safety; CHECK 1-2 enumerate/process/coverage gates completed
read_counts: orchestrator-rules 79/79; finding-output-format 114/114; skill 175/175; direct required refs 0; scope 139/139; profile 207/207; context 181/181; source 9417/9417; bundle finding-format 101/101
constraints: base-only; no prior audit outputs/history/test-audit/post-base source; no network/live deployment
result: 1 FINDING, 0 LEAD, 4 CLEARED

FINDING
id:           MSS-1
title:        Replacing the Registry Converter desynchronizes UniCL allowances from its runtime call target
file:         src/contracts/strategies/UniCLStrat.sol:1266
function:     _giveConverterAllowances / _removeConverterAllowances
mechanism:    UniCL grants permanent token allowances to the Converter address resolved at construction/unpause, but every later operation resolves `Registry.CONVERTER` afresh; Registry can overwrite that key, and UniCL stores no prior spender with which to revoke or atomically migrate the allowance.
consequence:  After an address-level Converter migration, swaps and WETH unwrapping through the new Converter can revert for zero allowance, blocking normal deposit/rebalance/withdraw paths until governance performs a pause/unpause repair; that repair targets only the new address and leaves the old Converter's maximum allowances outstanding.
trigger:      ADMIN_ROLE overwrites `Auth.CONVERTER` while an active UniCL strategy has allowances to the prior Converter, then a strategy operation requires the newly registered Converter to pull token0/token1.
severity:     low
rationale:    the impact is user-facing strategy liveness and stale authorization, but the trigger is a privileged, uncommon address migration and the pause/emergency-exit path remains available; low likelihood dominates.
poc:          none — direct cross-contract state trace
evidence:     Registry L225 executes `_registeredAddresses.set(_key, _address)` for an existing key. UniCL L1267-1268 approves `address(_registry.converter())` to `type(uint256).max`; L1275-1276 revokes that same *current* lookup. After replacement, L338 calls the new Converter's `unwrapWETH`, whose L107 executes `_weth.safeTransferFrom(msg.sender, address(this), _amount)` against an allowance granted only to the old address.
fix:          Store the currently approved Converter address and expose/use an atomic sync that first zeroes both token allowances for the stored old address, then approves the current Registry Converter and updates the stored address; require this migration before normal Converter-dependent operations.
related:      none
confidence:   high — address replacement, dynamic runtime resolution, spender-specific allowance state, and the failed consumption point are all explicit in immutable source.
verdict:      CONFIRMED
step_execution: ✓1(authorization sequence conflicts), ✓2(infrastructure targeting)
rules_applied: [R4:✗(evidence clear), R5:✓(old/new spender pair), R6:✓(ADMIN migration), R8:✓(cached authorization vs dynamic Registry state), R10:✓, R11:✓(ERC-20 allowances), R12:✓, R13:✗(not normalized as design), R14:✓(Registry setter/allowance coherence), R15:✗(no flash-accessible precondition), R16:✗(no oracle dependency)]
preferred_tag: CODE-TRACE
depth_evidence: [TRACE:approve(C_old,max)→Registry.CONVERTER=C_new→unwrap via C_new→transferFrom allowance=0→revert], [TRACE:pause after switch→approve(C_new,0)→C_old allowance remains max]
material_harm: Users relying on strategy capital for redemptions can have normal withdrawals delayed until governance repairs or emergency-unwinds the migrated strategy.
postconditions_created: old spender retains max token allowances; new runtime spender has zero allowance; Converter-dependent strategy operations are inconsistent.
postcondition_types: [ACCESS, STATE]
who_benefits: no necessary beneficiary; a compromised deprecated spender gains a persistent authorization opportunity, while ordinary users bear the liveness impact.

CLEARED
area:         per-swap router authorization sequences
checked:      Both adapter paths perform `forceApprove(router, exact bound) → router call → forceApprove(router, 0)`. Converter `nonReentrant` prevents overlapping swaps, each approval is limited to that swap, successful calls clear residue, and a revert rolls the whole allowance change back.

CLEARED
area:         strategy role grant sequence
checked:      `StrategyManager.addStrategy` adds/weights the strategy then calls `Converter.grantCallerRole`; failure bubbles and atomically rolls back every preceding write, so no registered strategy is left without its required caller role.

CLEARED
area:         best-effort role revocation after strategy removal
checked:      A failed `CONVERTER_CALLER_ROLE` revoke can leave an orphaned role, but current Converter functions only wrap/unwrap/swap the caller's own supplied balances. It cannot target another strategy/account, and Converter can be paused while cleanup is retried.

CLEARED
area:         permissionless infrastructure-address targeting
checked:      No `depositFor`, `stakeFor`, `delegateTo`, `mintFor`, `withdrawFor`, or `claimFor` surface exists. The only permissionless arbitrary-user write is signed Whitelist admission; a valid voucher binds the target and merely grants that address entry eligibility, imposing no lock/cooldown/counter on infrastructure.

CHECK_1_AUTHORIZATION_SEQUENCE_COVERAGE
1: adapter exact-input approve/router/clear — DONE, no overlap or stale residue
2: adapter exact-output approve/router/clear — DONE, no overlap or stale residue
3: UniCL constructor/unpause token0+token1 max approvals — DONE, MSS-1 on dynamic spender migration
4: UniCL pause token0+token1 revocations — DONE, MSS-1 old-spender mismatch
5: StrategyManager add + Converter caller-role grant — DONE, atomic rollback
6: StrategyManager remove + best-effort caller-role revoke — DONE, bounded to caller-owned assets
7: Registry/deployment batched role grants/revokes — DONE, length checks and transaction-wide revert semantics
coverage_gate_1: 7 enumerated / 7 processed; conflicts: 1 stale authorization/migration mismatch

CHECK_2_TARGET_FUNCTION_COVERAGE
1: `Whitelist.whitelist(user,...)` and admin whitelist/signer mutators — signed or role-gated; DONE
2: `AMM.processRedemption(batch,user)` — Controller-only and backed by ExitQueue membership; DONE
3: ExitQueue `pushRequest/pullRequest/closeRequest(...,user)` — AMM-only; DONE
4: EVE mint/burnFrom and inherited transfers — role/allowance/owner-authorized simple balances; no target lock/timer; DONE
5: Controller target-strategy/user forwarding — KEEPER-only with StrategyManager/ExitQueue validation; DONE
6: StrategyManager strategy-keyed weights/cooldown/registration — ADMIN or registered Controller only; DONE
7: Registry contract/role target writes — ADMIN/role-admin only; DONE
8: Oracle token/pair-keyed writes — ADMIN only and parameter validated; DONE
9: Converter caller-role writes — registered StrategyManager only; DONE
10: UniCL/Converter receiver parameters — privileged caller, payout only, no receiver-keyed state; DONE
coverage_gate_2: 10 enumerated / 10 processed; permissionless harmful infrastructure pairs 0

INFRASTRUCTURE_CROSS_REFERENCE
- Tested targets: Registry/timelock, AMM, Controller, StrategyManager, ExitQueue, Oracle, Converter, Whitelist, both keeper executors, UniCL strategy, pool/router/adapter, DAO treasury.
- Whitelist target: only signer-authorized admission flag; does not alter the target contract's own state or callable paths.
- EVE transfer target: attacker must spend its own EVE; only recipient balance changes, with no cooldown/lock/iteration side effect.
- All other keyed writes require protocol role/registered-contract authority or validate the target against a registered set/request.

COMMANDS_AND_TESTS
- `git -C contracts grep -n -E 'approve\\(|forceApprove|safeApprove|increaseAllowance|permit|allowance\\(' 734df96 -- script src/contracts src/libraries` — enumerated all token authorization calls.
- `git -C contracts grep -n -E 'function [A-Za-z0-9_]+\\([^)]*address|mapping\\(address' 734df96 -- src/contracts src/libraries` — enumerated address-keyed state targets.
- `git -C contracts grep -n -E 'depositFor|stakeFor|delegateTo|mintFor|withdrawFor|OnBehalf|claimFor|for_user|on_behalf' 734df96 -- script src/contracts src/libraries` — no literal on-behalf surface.
- `git -C contracts show 734df96:{src/contracts/registry/Registry.sol,src/contracts/strategies/UniCLStrat.sol,src/contracts/Converter.sol}` with numbered slices — confirmed MSS-1 trace.
- tests: not run; spender-specific allowance mismatch follows directly from the address-keyed ERC-20 authorization model and source trace.

CHAIN_SUMMARY
| Finding ID | Location | Root Cause | Verdict | Severity | Precondition Type | Postcondition Type |
|---|---|---|---|---|---|---|
| MSS-1 | UniCLStrat.sol:1266 / Registry.sol:218 | dynamic peer replacement is not synchronized with cached spender approvals | CONFIRMED | Low | ACCESS/STATE | ACCESS/STATE |

AGENT_STATUS: COMPLETE
