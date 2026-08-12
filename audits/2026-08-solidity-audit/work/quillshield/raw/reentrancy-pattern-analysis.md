# QuillShield Q3 — reentrancy-pattern-analysis

target: `734df96a1391e95dd40843210997da0b9f3ab05e`
mode: independent, read-only, base-SHA validation
scope: 39 Solidity files

## Read coverage

- Plugin instructions: `SKILL.md` 328/328 lines.
- Plugin references: `case-studies.md` 264/264 and `reentrancy-variants.md` 385/385; total 977/977 plugin lines.
- Bundle: `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `finding-format.md` 101/101, and `source.md` 9,417/9,417; total 10,045/10,045 lines.
- Applied to the full scope: classic, cross-function, cross-contract, read-only, callback, and transitive reentrancy; CEI ordering; shared-state entry points; guard coverage; ETH/ERC-20 callbacks; Uniswap mint callback; Converter delegatecall; and deployment-time trust boundaries.

## Findings

No reentrancy finding met the mechanism + feasible trigger + demonstrated consequence threshold in this pass.

LEAD
file:         src/contracts/Converter.sol:155-209,371-406; src/contracts/strategies/UniCLStrat.sol:199-202; src/contracts/StrategyManager.sol:940-950; src/contracts/AMM.sol:397-423
function:     executeSwapExactAmountOut; _executeSwapExactAmountIn; navInETH; totalNAVInETH; _enter
suspicion:    During a strategy swap, input tokens are transferred from UniCLStrat into Converter, but protocol NAV counts neither Converter balances nor assets in transit. A callback-capable paired token or router could therefore call `AMM.enter` while NAV is temporarily understated and receive EVE at a depressed premium price; contract-local `nonReentrant` guards do not cover this cross-contract/read-only window.
blocked_by:   A standard ERC-20/Uniswap route supplies no attacker callback at this point, and a standard ERC-777 sender hook for `from = UniCLStrat` is not attacker-controlled unless the strategy registered the hook. Exploitability therefore depends on governance admitting a nonstandard token/router with an attacker-reachable callback, the callback address being whitelisted and funded, and the in-flight value being large enough to overcome the connector-weight premium; no isolated proof closed all of those preconditions. Confidence: medium in the transient undercount, low in production exploitability.
next_step:    Build an isolated hook-token/router test that calls `AMM.enter` during Converter input custody, use the deployed connector weight and realistic maximum swap size, and compare the attacker's post-swap redemption value with deposited ETH and fees.

CLEARED
area:         AMM user exits and claims
checked:      `exit` is `nonReentrant` and burns EVE before the only attacker-directed ETH send. `claim` zeroes the user's liability and decrements `lockedForClaims` before sending ETH. Confidence is high from direct CEI and shared guard coverage.

CLEARED
area:         AMM entry and bootstrap re-entry
checked:      Both entry wrappers share the AMM guard. The normal path fixes price before sending ETH to the registered Controller, and bootstrap mints supply before its Controller send; a callback cannot re-enter any guarded AMM asset path. Confidence is high under the registered-Controller trust boundary.

CLEARED
area:         Queued-redemption state transitions
checked:      ExitQueue mutators are callable only by registered AMM/Controller and make no attacker-controlled calls. AMM cancellation/process paths obtain queue effects before returning EVE or assigning claim credit, and the AMM guard covers their shared state. Confidence is high.

CLEARED
area:         Controller and StrategyManager cross-contract loops
checked:      Controller asset/keeper entry points and StrategyManager strategy actions are globally `nonReentrant` within each contract; registry caller gates prevent a strategy callback from invoking Controller/StrategyManager privileged entry points. Balance-delta accounting occurs before calls return. Confidence is high for reentrancy safety (failure isolation is a separate concern).

CLEARED
area:         Converter state-changing asset paths
checked:      Wrap, unwrap, and both swap executions share the upgradeable reentrancy guard. Caller-role checks prevent arbitrary callback callers, and swap accounting relies on post-call balance deltas. Confidence is high for same-contract/cross-function reentrancy; transient system-wide NAV is retained as the lead above.

CLEARED
area:         UniCL strategy state-changing surface
checked:      Deposit, withdrawal, rebalance, sync, fee settlement, pause, and emergency exit share one guard. Withdrawal increments `_totalWithdrawn` before ETH delivery; emergency exit requires pause. Admin configuration cannot be reached by token/pool callbacks without Registry roles. Confidence is high.

CLEARED
area:         Uniswap mint callback authentication
checked:      `uniswapV3MintCallback` requires both the immutable pool as caller and an active `_minting` flag; token callbacks cannot spoof `msg.sender == pool`. The in-scope Uniswap pool is trusted to issue the canonical single callback per mint. Confidence is high under that explicit pool-code assumption.

CLEARED
area:         Keeper executor re-entry
checked:      Both `performUpkeep` paths require the configured Forwarder and are `nonReentrant`; action conditions and amounts are recomputed before the downstream Controller call. `lastSyncAt` is written before the sync interaction. Confidence is high.

CLEARED
area:         ERC-721/ERC-1155/ERC-777 receiver hooks
checked:      Scope contains no NFT transfers or receiver entry points. EVE is plain OpenZeppelin ERC-20; WETH and the intended paired token are treated as configured external dependencies. No protocol-owned ERC-777 sender/receiver hook registration was found. Confidence is high for in-scope code, conditional for configured tokens as captured by the lead.

## Commands and tests

- Full reads used bounded `sed -n` ranges; `wc -l` established the counts above.
- Base validation used `git grep -n -E 'function ...|safeTransfer...' 734df96... -- src/contracts` and `git show 734df96...:<path> | nl -ba | sed -n ...`.
- Tests: not run; no test file created. The unresolved callback hypothesis remains a LEAD as required.
- Production files were not edited; no network or live-system calls were made; no commit was created.

AGENT_STATUS: COMPLETE
