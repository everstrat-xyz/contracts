# Omega Pass R — historical regression matrix

Target: immutable `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`. This is status verification only; historical severity/status is treated as a lead, not authority. No discovery work was performed.

## Artifact and ID accounting

| Alias | Historical artifact (`commit:path`) | Explicit ID bodies |
|---|---|---:|
| P1 | `59553fe45e05d1e64d3be47ac033de9272ca7a4b:smart-contracts/x-ray/hackerhouse-pashov-ai-audit-report-20260416-110438.md` | 1 |
| P2 | `59553fe45e05d1e64d3be47ac033de9272ca7a4b:smart-contracts/x-ray/hackerhouse-pashov-ai-audit-report-20260416-111131.md` | 2 |
| Q | `67f4a3887e264538b34bff7525c6c3f5130c93eb:smart-contracts/x-ray/quillshield-multi-skill-audit-20260416.md` | 3 |
| A | `8af8d7fc32e2ee374968f8de9dae1bbc24156a4d:AUDIT.md` | 9 |
| PA | `522a3457ea160fc8d2cebad48891c94f7bb819c1:smart-contracts/audits/PASHOV-AUDIT.md` | 11 |
| PL | `129932038e120d0d793cc084af3e240c916046f9:smart-contracts/audits/PLAMEN-AUDIT.md` | 12 |
| PR | `397479a95f680d5db896ecfe56da12a42b688c24:smart-contracts/audits/PLAMEN-REAUDIT-staging.md` | 13 |
| MR1 | `a5a415043f70d3b955d32b6e46e976b2d63296ba:smart-contracts/audit/mainnet-readiness-review-2026-07-02.md` | 16 |
| MR2 | `fbda455d6b202842e1a3ec97b298060ff1d3f6d4:audit/mainnet-readiness-review-2026-07-02.md` | 6 |

Counts: **9/9 artifacts; 73 explicit ID occurrences; 51 unique raw ID labels**. No artifact or explicit-ID body was missing. No duplicate ID occurs within one artifact. Cross-artifact collisions are: numeric `1` (P1/P2/MR1), numeric `2` (P2/MR1), `F-1..F-3` (Q/A/MR2), `F-4..F-6` (A/MR2), and `PLM-1..7,9..11` (PL/PR); the artifact alias disambiguates them. PR's carried-findings table omits PLM-8 and PLM-12, but both exist and are classified under PL. Historical prose also contains unnumbered leads/informationals/assurances; no IDs were invented for them.

## Status table

Evidence keys resolve to exact current-base locations in the next section.

| Artifact | ID | Prior status | Current status | Current base evidence |
|---|---|---|---|---|
| P1 | 1 | Finding, confidence 88 | FIXED | E1 |
| P2 | 1 | Finding, confidence 90 | FIXED | E1 |
| P2 | 2 | Finding, confidence 72 | STILL OPEN | E2 |
| Q | F-1 | Medium | FIXED | E3 |
| Q | F-2 | Low / operational | FIXED | E4 |
| Q | F-3 | Low | FIXED | E5 |
| A | F-1 | Medium, 70% | FIXED | E6 |
| A | F-2 | Medium, conditional on L2 | CONTINGENT | E7: safe only under an L1-only deployment decision; no deployment proof is in scope |
| A | F-3 | Medium, 55% | FIXED | E8 |
| A | F-4 | Medium, 70% | STILL OPEN | E9 |
| A | F-5 | Low, 75% | FIXED | E10 |
| A | F-6 | Low, 60% | STILL OPEN | E11 |
| A | F-7 | Low, 60% | STILL OPEN | E12 |
| A | F-8 | Low, 80% | FIXED | E10 |
| A | F-9 | Low, 55% | FIXED | E13 |
| PA | M-1 | Medium, code-confirmed | FIXED | E6 |
| PA | M-2 | Medium, analytical | STILL OPEN | E14 |
| PA | M-3 | Medium, code-confirmed | FIXED | E13 |
| PA | L-1 | Low, code-confirmed | FIXED | E15 |
| PA | L-2 | Low, code-confirmed | STILL OPEN | E9/E16 |
| PA | L-3 | Low, analytical | FIXED | E17 |
| PA | L-4 | Low, code-confirmed | STILL OPEN | E12; capacity grief remains, old fee-skim limb is gone per E18 |
| PA | L-5 | Low, analytical | STILL OPEN | E19 |
| PA | L-6 | Low, code-confirmed | FIXED | E18 |
| PA | L-7 | Low, analytical | FIXED | E6 |
| PA | L-8 | Low, accepted design | STILL OPEN | E20 |
| PL | PLM-1 | High, confirmed | FIXED | E21 |
| PL | PLM-2 | Medium, confirmed | STILL OPEN | E11 |
| PL | PLM-3 | Medium, verified | FIXED | E22 |
| PL | PLM-4 | Medium, confirmed | FIXED | E6 |
| PL | PLM-5 | Medium, confirmed | STILL OPEN | E23 |
| PL | PLM-6 | Medium, confirmed | CONTINGENT | E24: neutralised only if executor-only KEEPER deployment still holds |
| PL | PLM-7 | Low, confirmed | FIXED | E21; low CW remains permitted, but cannot amplify redemption after base-price burn |
| PL | PLM-8 | Low, confirmed | STILL OPEN | E25 |
| PL | PLM-9 | Low, analytical | FIXED | E26 |
| PL | PLM-10 | Low, analytical | STILL OPEN | E27 |
| PL | PLM-11 | Low, confirmed | FIXED | E28 |
| PL | PLM-12 | Low, confirmed | STILL OPEN | E29; CW queue limb is gone, retroactive fee-rate limb remains |
| PR | PLM-1 | RESOLVED | FIXED | E21 |
| PR | PLM-2 | STILL-PRESENT, Medium | STILL OPEN | E11 |
| PR | PLM-3 | STILL-PRESENT, Low | FIXED | E22 |
| PR | PLM-4 | STILL-PRESENT, Low–Med | FIXED | E6 |
| PR | PLM-5 | STILL-PRESENT, reduced | STILL OPEN | E23; current base has no deviation clamp |
| PR | PLM-6 | STILL-PRESENT, Medium | CONTINGENT | E24: executor-only KEEPER deployment is required |
| PR | PLM-7 | STILL-PRESENT, Low | FIXED | E21 |
| PR | PLM-9 | STILL-PRESENT, Low | FIXED | E26 |
| PR | PLM-10 | STILL-PRESENT, Low/Info | STILL OPEN | E27 |
| PR | PLM-11 | STILL-PRESENT, Info | FIXED | E28 |
| PR | G-1 | Medium | STILL OPEN | E30 |
| PR | G-2 | Low | STILL OPEN | E31 |
| PR | G-3 | Info | FIXED | E32 |
| MR1 | 1 | Blocker | STILL OPEN | E33; emergency sweep landed, but the headline no-checkpoint condition remains |
| MR1 | 2 | Blocker | STILL OPEN | E23 |
| MR1 | 3 | Blocker | STILL OPEN | E34 |
| MR1 | 4 | Blocker | STILL OPEN | E9; force removal fixes residue/revert removal, not the pre-removal freeze |
| MR1 | 5 | Blocker | STILL OPEN | E35; required env/modular parity improved, but delay floor and chain-id guard remain absent |
| MR1 | 6 | Blocker | STILL OPEN | E36; real fork coverage landed, invariant suite remains absent |
| MR1 | A | Medium | STILL OPEN | E19 |
| MR1 | B | Medium, L2-only | CONTINGENT | E7: safe only if deployment remains L1-only; not provable from current scope |
| MR1 | C | Low | STILL OPEN | E37 |
| MR1 | D | Medium | STILL OPEN | E38 |
| MR1 | E | Medium | FIXED | E39 |
| MR1 | F | Low | STILL OPEN | E31 |
| MR1 | G | Medium | STILL OPEN | E40 |
| MR1 | H | Low | STILL OPEN | E41 |
| MR1 | I | Low | STILL OPEN | E42 |
| MR1 | J | Low | FIXED | E43 |
| MR2 | F-1 | High readiness blocker | UNVERIFIABLE | E36: fork tests exist; an independent external audit is outside source/test scope |
| MR2 | F-2 | Medium | STILL OPEN | E44; NAV accounting landed, but ERC-20 liquidation/recovery is explicitly deferred |
| MR2 | F-3 | Medium, intended design | FIXED | E18 |
| MR2 | F-4 | Medium, operational | UNVERIFIABLE | E9/E41 show fail-closed conditions; existence/quality of an incident runbook is out of scope |
| MR2 | F-5 | Low–Medium | FIXED | E45 |
| MR2 | F-6 | Informational composite | CONTINGENT | E7; all cited code nits were removed except the L2-only sequencer condition |

No prior item recorded as resolved is present again: **REGRESSED = 0**.

## Current-base evidence index

- **E1** — `src/libraries/Math.sol:134-137` rejects only `difference > 1e18`, so `1e18` evaluates without reverting; `src/contracts/AMM.sol:147` accepts the same domain.
- **E2** — `src/contracts/Oracle.sol:359-379` discards both round IDs and checks only `updatedAt`, sign, future time and staleness.
- **E3** — `src/contracts/StrategyManager.sol:940-950` sums strategy NAV, Manager/Controller ETH, `IAMM.freeBalance()` and supported ERC-20 NAV.
- **E4** — `src/contracts/Controller.sol:342-369` provides range and per-user processing; `src/contracts/automation/QueueKeeperExecutor.sol:68-74,209-215` caps each upkeep at 20 by default.
- **E5** — base `git grep` finds no `transferToken` or `transferETH`; Controller pause is symmetric at `src/contracts/Controller.sol:113-114`.
- **E6** — base `git grep` finds no `lastSettled`, `checkpointPrice` or deviation guard; `src/contracts/AMM.sol:408-423` and `:154-165` use live premium/base prices directly. Thus donation cannot trip the removed guard.
- **E7** — base `git grep` finds no sequencer-uptime or `block.chainid` guard in `src/`/`script/`; deployment-chain state is not supplied.
- **E8** — `src/contracts/strategies/UniCLStrat.sol:49-61` floors long/short TWAPs at 1800s/60s; adapter floor is `src/contracts/adapters/UniswapV3ConverterAdapter.sol:79-85`.
- **E9** — `src/contracts/StrategyManager.sol:940-943` still propagates any strategy NAV revert; `:250-266` force-removes only through ADMIN.
- **E10** — `src/contracts/StrategyManager.sol:90-94,152-172,838-859` owns and bounds deposit/withdrawal weights; base has no strategy `safetyLevel`/`priority` API.
- **E11** — `src/contracts/Oracle.sol:249-255,263-283` uses USD cross-rates and accepts runtime feed updates without denomination enforcement; `script/ProtocolDeployBase.sol:221-238` checks only script-supplied feeds.
- **E12** — `src/contracts/strategies/UniCLStrat.sol:199-203,679-685` counts raw balances and lets them consume `maxTotalNAV`; `src/contracts/StrategyManager.sol:947-950` also counts raw protocol balances.
- **E13** — `src/contracts/strategies/UniCLStrat.sol:623-645` sets pause first and catches pool-unwind failure.
- **E14** — `src/contracts/strategies/UniCLStrat.sol:665-675` derives LP composition at TWAP, then `:199-203` values each leg via `_tokenValueInETH` (Oracle).
- **E15** — `src/contracts/ExitQueue.sol:173-188` applies `whenNotPaused` to `priceBatch`.
- **E16** — `src/contracts/StrategyManager.sol:1000-1009,1090-1101,1177-1180` still makes uncaught `maxDeposit`/health, `maxWithdrawal`, and pause/health preflight calls in full-range loops.
- **E17** — `src/contracts/StrategyManager.sol:250-266` force-removes despite reverting or high reported NAV.
- **E18** — `src/contracts/strategies/UniCLStrat.sol:382-409` fees only uncharged LP fees; `src/contracts/StrategyManager.sol:688-696` mints EVE after strategy settlement. The old USD HWM/ETH-send path is absent.
- **E19** — `src/contracts/Oracle.sol:364-379` has no min/max-answer bound.
- **E20** — `src/contracts/adapters/UniswapV3ConverterAdapter.sol:79-85,347-356` and `src/contracts/strategies/UniCLStrat.sol:63-73,1123-1131` retain fixed ±2% quote bands.
- **E21** — `src/contracts/AMM.sol:154-165` always redeems at base NAV price; premium remains entry-only at `:408-412`.
- **E22** — `src/contracts/registry/client/RegistryClientUpgradeable.sol:17-24` now uses canonical slot `0xbd1f…fe00` matching its namespace.
- **E23** — `src/contracts/ExitQueue.sol:173-187,228-247` freezes `finalEvePrice` and has no on-chain processing expiry/reprice; `src/contracts/automation/QueueKeeperExecutor.sol:300-305` only makes the standard executor skip expired batches.
- **E24** — Controller retains raw KEEPER powers at `src/contracts/Controller.sol:137-256`, but `script/DeployAll.s.sol:20-22,98-101` assigns KEEPER only to re-validating executors. The mitigation is deployment-dependent.
- **E25** — `src/contracts/strategies/UniCLStrat.sol:593-614` validates route endpoints only; adapter route pool observation is a reverting `meanTick` at `src/contracts/adapters/UniswapV3ConverterAdapter.sol:288-297`.
- **E26** — `src/contracts/strategies/UniCLStrat.sol:285-345` spends idle native ETH first and can deliver it in withdrawal.
- **E27** — `src/contracts/AMM.sol:36-45,403-451` permanently mints dead supply and latches `bootstrapped`; no re-bootstrap path exists.
- **E28** — `src/contracts/Controller.sol:65-71` emits `ControllerInitialized`; `src/interfaces/IController.sol:28` declares that non-shadowing name.
- **E29** — `src/contracts/StrategyManager.sol:662-675` lets ADMIN change the rate before unharvested LP fees settle; no accrual-time rate snapshot exists.
- **E30** — `src/contracts/strategies/UniCLStrat.sol:460-494` permits SECURITY to pause then emergency-exit, while `src/interfaces/IStrategy.sol:207-220` still says ADMIN_ROLE.
- **E31** — `src/contracts/Converter.sol:334-336` keeps `pause()` ADMIN-only.
- **E32** — `src/contracts/registry/Registry.sol:44-54` sets each role admin once; the duplicate SECURITY assignment is gone.
- **E33** — E6 proves the guard is still absent; `src/contracts/StrategyManager.sol:449-463` now supplies the previously missing emergency ETH sweep.
- **E34** — `script/ProtocolDeployBase.sol:361-378,450-456` still grants and verifies SECURITY as timelock canceller; `src/contracts/registry/Registry.sol:275-295` lets it pause role mutations while only ADMIN can unpause.
- **E35** — `script/ProtocolDeployBase.sol:257-278` hard-requires critical addresses, but `:352-378` accepts any supplied timelock delay without a floor; base `git grep` finds no chain-id guard.
- **E36** — `test/fork/UniCLStratFork.t.sol:30-40,102-117` exercises real Uniswap/Chainlink on a mainnet fork; base tests outside `test/audit/` contain no `StdInvariant`, `targetContract`, or `invariant_` usage.
- **E37** — `script/DeployAll.s.sol:68,103` still registers the initial feed with exactly 3600s staleness.
- **E38** — `src/contracts/strategies/UniCLStrat.sol:199-203,665-675` reports TWAP/oracle mid NAV, while `:299-345` must realize swaps to withdraw.
- **E39** — `src/contracts/strategies/UniCLStrat.sol:828-835` now sizes mint liquidity at spot `_sqrtPrice()`.
- **E40** — `foundry.toml:1-7` enables `via_ir` by default, while CI at `:19-35` omits it.
- **E41** — `script/DeployUniCLStrat.s.sol:91-100` only comments that observation cardinality must cover TWAP; it neither checks nor bumps cardinality.
- **E42** — `src/contracts/ExitQueue.sol:253-268` lets a user close after expiry; `src/contracts/Controller.sol:418-426` processes the selected range atomically, so a front-run cancellation can revert it.
- **E43** — production queue automation always recomputes and processes prefix `[0,count)` at `src/contracts/automation/QueueKeeperExecutor.sol:209-215,336-363`, avoiding mutation-across-pages skipping.
- **E44** — `src/contracts/StrategyManager.sol:465-502,940-969` can whitelist/count or drop emergency ERC-20s, but explicitly defers their swap recovery (`:465-468`).
- **E45** — `script/ProtocolDeployBase.sol:257-287` removes address fallbacks; `script/DeployUniCLStrat.s.sol:11-50,65-88` deploys bytecode only and requires timelocked registration; `script/DeployUniswapV3ConverterAdapter.s.sol` exists.

## Commands and results

- Read completely: Omega workflow, Pass R prompt, bundle `scope.md`, all `source.md`, and `history.md`.
- Historical retrieval: nine exact `git show <artifact-commit>:<path>` commands in the predecessor repository; **9 succeeded, 0 missing**.
- Current verification: `git show 734df96a1391e95dd40843210997da0b9f3ab05e:<path> | nl -ba` and targeted `git grep ... 734df96a... -- src script test ':!test/audit'`; all evidence above is from the immutable base.
- Test inventory result: one mainnet-fork suite exists; no invariant-harness markers outside the prohibited `test/audit/` tree.
- No Forge regression was warranted or run; this pass made no production/test changes and used no network or live system.

AGENT_STATUS: COMPLETE
