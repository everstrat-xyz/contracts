# Plamen P3 — verification-protocol

snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: 39/39 primary files
method_read: `SKILL.md` 395/395; `references/advanced.md` 322/322; Plamen rules 79/79; Plamen finding format 114/114
bundle_read: scope 139/139; profile 207/207; context 181/181; source 9417/9417; finding-format 101/101
verification_mode: immutable `[CODE]` evidence only; no mocks, RPC, fork, or live deployment

## Evidence Audit

| Claim | Evidence source | Tag | Valid for REFUTED? |
|---|---|---|---|
| Implementations are locked and proxies initialize atomically | constructors + ProtocolDeployBase at 734df96 | [CODE] | YES |
| NAV includes unsolicited ETH held by AMM/Controller/StrategyManager/strategy | StrategyManager/AMM/UniCLStrat at 734df96 | [CODE] | YES |
| EVE supply includes permanently held dead bootstrap supply | AMM `_bootstrap` at 734df96 | [CODE] | YES |
| Converter exact-output spend/output are checked with balance deltas and bounds | Converter at 734df96 | [CODE] | YES |
| Deployed feed/pool/router behavior and configuration are correct | no deployment manifest/source match supplied | [EXT-UNV] | NO |

LEAD
id:           VP-1
file:         src/contracts/{Oracle.sol,adapters/UniswapV3ConverterAdapter.sol,strategies/UniCLStrat.sol}
function:     deployed external integration behavior
suspicion:    Source defenses depend on the actually configured Chainlink feeds, Uniswap-compatible pool/factory/router and WETH implementing the assumed behavior; no target-bound addresses, bytecode matches, feed metadata, observation state, or fork block were supplied.
blocked_by:   Verification Protocol forbids REFUTED when decisive external evidence is `[EXT-UNV]`; assignment also forbids network/live deployment access.
next_step:    Supply the deployment manifest and fixed fork block, verify bytecode/source and config, then run fork tests for feed staleness/decimals, pool observation coverage, route direction, callback, exact-input and exact-output behavior.
verdict:      CONTESTED
step_execution: evidence audit✓ Q1✓ Q2? Q3? F1? F2? production verification✗
rules_applied: R4✓ R10✓ R16✓
preferred_tag: DEPLOYMENT
confidence:   high that verification is incomplete; no claim that deployed integrations are faulty

CLEARED
area:         hypothesis VP-H1 — initializer takeover
checked:      Exact bug hypothesis: an attacker initializes a UUPS implementation or proxy and gains upgrade authority. Observable/assertion: attacker-controlled Registry would be stored. Reachability fails: each implementation constructor disables initializers, while each proxy constructor executes the correct initializer calldata atomically.
evidence:     [CODE] `_disableInitializers()` at Controller:49, Converter:52, ExitQueue:53, Oracle:59, StrategyManager:113; proxy initializer calldata at ProtocolDeployBase:70-120.
verdict:      REFUTED
step_execution: Q1✓ Q2✓ Q3✓ F1✗ (blocked before attacker write) F2 N/A
rules_applied: R4✓ R10✓
preferred_tag: CODE-TRACE
confidence:   high — no mock/external assumption supports the verdict

CLEARED
area:         hypothesis VP-H2 — profitable flash-funded NAV donation
checked:      Exact bug hypothesis: donate flash-borrowed ETH to a NAV-counted holder, then redeem EVE at the inflated base price and repay with profit. Observable/assertion: incremental redemption proceeds exceed donation. For attacker holdings A and total supply S, donation D increases redemption proceeds by exactly `D*A/S`; because A<S (including the dead bootstrap balance), net is `D*(A/S-1)<0` before flash fee/gas. Example: even at 99% ownership, donating 100 ETH recovers at most 99 incremental ETH and loses at least 1 ETH.
evidence:     [CODE] StrategyManager `_totalNAVInETH` includes holder balances at :940-950; AMM base exit uses NAV/supply at :145-166 and Math `basePrice`; `_bootstrap` mints dead supply at AMM:429-430.
verdict:      REFUTED
step_execution: Q1✓ Q2✓ Q3✓ F1✓ F2✗ (profit bound never positive); attacker-holding case✓
rules_applied: R10✓ R11✓ R15✓
preferred_tag: ECONOMIC
confidence:   high — symbolic bound holds for every D>0 and A<S; no mock/external behavior needed

CLEARED
area:         hypothesis VP-H3 — exact-output adapter spends Converter reserves
checked:      Exact bug hypothesis: an adapter spends more input than the caller supplied or produces less output, with Converter reserves covering the difference. Observable/assertion: caller receives requested output while reserve balance falls beyond `_amountInMaximum`. The code snapshots both balances; input delta above the maximum and output delta below the request revert the entire delegatecall transaction.
evidence:     [CODE] Converter exact-output path snapshots at :166-168, measures spend at :191, bounds at :193, and requires output delta at :199-201 before transfers.
verdict:      REFUTED
step_execution: Q1✓ Q2✓ Q3✓ F1 restricted (`CONVERTER_CALLER_ROLE`) F2✗ (state change rolls back)
rules_applied: R8✓ R10✓ R11✓
preferred_tag: CODE-TRACE
confidence:   high — verdict rests entirely on atomic checked arithmetic in audited code

CLEARED
area:         hypothesis VP-H4 — malformed ERC-7201 namespace
checked:      Exact bug hypothesis: RegistryClientUpgradeable stores the Registry in a wrong/colliding slot. Observable/assertion: recomputed ERC-7201 slot differs from the constant. Deterministic recomputation exactly matched, so the proving assertion cannot be satisfied.
evidence:     [CODE] `RegistryClientUpgradeable.sol:21-29`; `cast index-erc7201 everstrat.storage.RegistryClientUpgradeable` → `0xbd1fcda84d3854fffab59d162ed55717edaf79b73401f77c755ab4e42954fe00`.
verdict:      REFUTED
step_execution: Q1✓ Q2✓ Q3✓ F1✗ F2 N/A
rules_applied: R8✓ R10✓
preferred_tag: CODE-TRACE
confidence:   high — deterministic source computation, no mock evidence

## Halt/coverage checks

- No REFUTED verdict relies on `[MOCK]` or `[EXT-UNV]`; the external-integration hypothesis remains CONTESTED as VP-1.
- All in-scope callers of the checked mechanisms were traced from the full bundle; no prior findings inventory was read, per the independence constraint.
- No semi-trusted-role hypothesis was dismissed here; bidirectional keeper timing is assessed only where both role→user and user→role paths are source-visible.
- No HIGH/CRITICAL candidate survived the feasibility gates, so prohibited network RAG and fork-PoC steps were not invoked.

commands:
- `git grep -n -E 'totalNAVInETH|freeBalance\\(|address\\(this\\)\\.balance|_navInETHPendingTransfer|_basePriceFromNAV|_premiumPriceFromNAV|latestRoundData|\\.observe\\(|\\.slot0\\(' 734df96 -- <target files>`
- immutable initializer/storage greps recorded above
- `cast index-erc7201 everstrat.storage.RegistryClientUpgradeable`
tests: no test file added; every rejected hypothesis failed a pre-PoC gate with `[CODE]` evidence, while external behavior remains a LEAD
finding_count: 0
lead_count: 1
cleared_count: 4
AGENT_STATUS: COMPLETE
