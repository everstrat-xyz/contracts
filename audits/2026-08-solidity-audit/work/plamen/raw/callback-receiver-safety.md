# Plamen Raw Pass — callback-receiver-safety

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full immutable primary scope, 39/39 files
methodology: Plamen callback-receiver-safety; CHECK 1-3 enumerate/process/coverage gates completed
read_counts: orchestrator-rules 79/79; finding-output-format 114/114; skill 158/158; direct required refs 0; scope 139/139; profile 207/207; context 181/181; source 9417/9417; bundle finding-format 101/101
constraints: base-only; no prior audit outputs/history/test-audit/post-base source; no network/live deployment
result: 0 FINDING, 1 LEAD, 4 CLEARED

LEAD
id:           CBS-L1
file:         src/contracts/strategies/UniCLStrat.sol:524
function:     constructor / uniswapV3MintCallback
suspicion:    Callback authorization is sound only if immutable `pool` is the intended canonical Uniswap V3 pool. The constructor checks its token pair/tick surface but neither it nor `DeployUniCLStrat` proves factory provenance/code identity; a fake configured pool could call back during `pool.mint` with arbitrary payment amounts.
blocked_by:   no target-bound pool/factory address, constructor arguments, bytecode match, or deployment transaction was supplied; pool choice is a privileged deployment/go-live decision.
next_step:    Before strategy admission, prove `POOL_ADDRESS` is the canonical factory result for the expected pair/fee, verify runtime bytecode and constructor arguments, and simulate mint-callback amounts against the configured pool.

CLEARED
area:         callback handler access control
checked:      Enumerated 11 inbound handlers. Five `receive()` functions only accept ETH; two `checkUpkeep` functions are view-only; two `performUpkeep` functions require the configured Forwarder and revalidate live state; `selfRemoveLiquidityAndCollect` requires `msg.sender == address(this)`; `uniswapV3MintCallback` requires both `msg.sender == pool` and `_minting == true`.

CLEARED
area:         permissionless callback state inflation
checked:      Repeated `receive()` calls only aggregate native balance and do not append entries, increment protocol counters, set timestamps, or toggle authorization flags. Donations to AMM/Controller/StrategyManager/UniCLStrat are included in balance/NAV flows and enrich existing EVE holders; Converter donations remain isolated. Call count does not increase subsequent iteration cost.

CLEARED
area:         callback-driven collection inflation
checked:      No enumerated handler grows any iterated collection or external position count. The only pool positions read are two fixed tick-range keys; no ERC-721/1155/777/1363 receiver, flash-loan callback, staking-on-behalf, or external position enumeration exists.

CLEARED
area:         selective-revert exploitation
checked:      All recipient-controlled payouts are deterministic native ETH or plain ERC-20 transfers with full rollback on failure; there is no randomness, rarity, reward selection, or retry-varying assignment. AMM uses pull claims for queued ETH, and a recipient revert cannot preserve an advantageous partial state.

CHECK_1_HANDLER_COVERAGE
1: `AMM.receive()` — anyone; modifies only native balance/free balance; DONE
2: `Controller.receive()` — anyone; modifies only native balance; DONE
3: `Converter.receive()` — anyone/WETH unwrap; modifies only native balance; DONE
4: `StrategyManager.receive()` — anyone/Controller; modifies only native balance; DONE
5: `UniCLStrat.receive()` — anyone/Converter unwrap; modifies only native balance; DONE
6: `UniCLStrat.uniswapV3MintCallback` — immutable pool during `_minting`; token payments + flag reset; DONE
7: `QueueKeeperExecutor.checkUpkeep` — anyone, view-only; DONE
8: `QueueKeeperExecutor.performUpkeep` — only Forwarder, live revalidation, non-reentrant; DONE
9: `StrategyKeeperExecutor.checkUpkeep` — anyone, view-only; DONE
10: `StrategyKeeperExecutor.performUpkeep` — only Forwarder, amounts/live predicates recomputed, non-reentrant; DONE
11: `UniCLStrat.selfRemoveLiquidityAndCollect` — self only; DONE
coverage_gate_1: 11 enumerated / 11 processed

CHECK_2_COLLECTION_COVERAGE
1: Registry `_registeredAddresses` — admin growth; iterated by getters; not callback sourced; DONE
2: Registry `_registeredRoles` — role-admin growth; values getter; not callback sourced; DONE
3: Oracle `_supportedTokens` — admin growth; NAV/removal loops; not callback sourced; DONE
4: Oracle per-token `supportedPairs` — admin growth; removal loops; not callback sourced; DONE
5: Converter `_allowedAdapters` — admin growth; enumeration only; not callback sourced; DONE
6: StrategyManager `_strategies` — admin growth; operational loops; not callback sourced; DONE
7: StrategyManager `_supportedERC20s` — admin growth; NAV loop; not callback sourced; DONE
8: ExitQueue per-batch `unprocessedUsers` — user exit growth through AMM with escrow/one-entry-per-user, not a callback; keeper processing is capped; DONE
9: UniCL external pool positions — exactly two strategy-computed keys, never externally appended/enumerated; DONE
coverage_gate_2: 9 enumerated / 9 processed; callback-inflatable collections 0; gas-at-100/1000/10000 N/A because callback count never changes collection length

CHECK_3_OUTBOUND_COVERAGE
1: AMM immediate exit and `claim` native payout — user controlled, deterministic, full rollback; DONE
2: AMM cancellation/slippage EVE return — plain ERC-20 transfer, no receiver hook; DONE
3: AMM/Controller/StrategyManager ETH routing to registered protocol modules — fixed recipients and deterministic amounts; DONE
4: Converter `unwrapWETH` payout — authorized caller chooses recipient, exact amount, revert rolls all state back; DONE
5: Converter swap refunds/outputs — plain ERC-20 transfers and measured deltas; no receiver callback; DONE
6: StrategyManager calls to registered strategies — governance-selected target; batch failures are caught and skipped, no random outcome; DONE
7: UniCL `withdraw`/`emergencyExit` payouts — registered StrategyManager/Controller path, deterministic, full rollback or explicit best-effort token transfer; DONE
8: UniCL pool mint/burn/collect and callback payment — pool-gated; no recipient-selected outcome; DONE
9: Adapter router calls — Converter is the production recipient and amounts are bounded/measured; DONE
10: Oracle/feed and Registry-resolved view calls — no prior value-bearing assignment for a recipient to accept/reject; N/A
coverage_gate_3: 10 categories enumerated / 10 processed; economically rational retry vectors 0

rules_applied: [R4:✓(pool provenance lead), R5:✓, R6:✓(pool/Forwarder/admin boundaries), R8:✓(_minting and stored external identities), R10:✓, R11:✓(unsolicited ETH and token callbacks), R12:✓, R13:✓(pull-payment mitigation checked), R14:✗(no callback-set aggregate/limit), R15:✗(no flash callback/precondition), R16:✗(no callback finding depends on oracle)]
confidence: high for handler/collection/selective-revert source behavior; medium for external pool authenticity because deployment state is absent.

COMMANDS_AND_TESTS
- `git -C contracts grep -n -E 'receive\\(|fallback\\(|Callback|callback|Receiver|Hook|onERC721Received|onERC1155|tokensReceived|onTransferReceived|onFlashLoan|executeOperation|checkUpkeep|performUpkeep|selfRemoveLiquidityAndCollect' 734df96 -- script src/contracts src/libraries` — enumerated 11 handlers and no fallback/token/flash receiver.
- `git -C contracts show 734df96:src/contracts/strategies/UniCLStrat.sol | nl -ba | sed -n '158,180p;518,535p;738,758p'` — traced `_minting` window and dual callback gates.
- `git -C contracts show 734df96:src/contracts/automation/KeeperExecutorBase.sol | nl -ba | sed -n '30,80p'` — confirmed Forwarder authorization and inert zero state.
- tests: not run; no in-scope callback exploit mechanism survived the coverage gates.

CHAIN_SUMMARY
| Finding ID | Location | Root Cause | Verdict | Severity | Precondition Type | Postcondition Type |
|---|---|---|---|---|---|---|
| none | — | — | — | — | — | — |

AGENT_STATUS: COMPLETE
