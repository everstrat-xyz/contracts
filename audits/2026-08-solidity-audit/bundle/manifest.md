# Tier 0 Routing Manifest Draft

> Coverage claim prepared before audit dispatch. This lists every routed skill and every deliberate exclusion. It contains no findings and does not claim that Tier 1/Tier 2 execution has completed.

```text
PLATFORM: evm     SCOPE: full snapshot @ 734df96a1391e95dd40843210997da0b9f3ab05e

TRIGGERS FIRED:
  upgradeability, oracles, signatures/meta-transactions,
  vault/receipt-token accounting (semantic), permissioned gating,
  time-indexed/snapshot state (weak), external calls/token integration,
  queues/batches/user loops, DEX/AMM, governance/timelock,
  off-chain deployment automation, economic mechanism,
  staking/rewards-like fee state (weak)

TRIGGERS NOT FIRED:
  rebasing/index accounting, flash-loan callback/API, cross-chain/bridge,
  lending, NFT, account abstraction

TIER 0:
  pashov x-ray completed for architecture/profile/history weighting
  plamen audit-prep required as the complementary readiness pass

TIER 1 / 2 PLANNED:
  pashov       12 attacker agents
  omega         5 independent passes, each applying all 11 lenses,
                plus 1 historical-regression verification pass
  quillshield  11 topic plugins
  plamen        EVM pack (18 skills) + 10 feature/depth skills

REDUCTIONS: none authorized or applied
ACTUAL AGENT CENSUS: pending dispatch; record completions/failures in final report
```

Skill count is not identical to agent count: the Plamen orchestrator may bundle several loaded skills into one leaf prompt. Including the historical-regression pass, the orchestrator's expected run size is approximately 39–46 leaf agents across four methodologies; the final number must be measured after dispatch rather than guessed here.

## Tier 0 pre-audit skills

| Skill | Status | Purpose |
|---|---|---|
| `[P] sources/pashov/x-ray` | Completed for this draft | Scope enumeration, architecture, entry points, history shape and candidate invariants |
| `[L] sources/plamen/skills/audit-prep` | Required / complementary Tier 0 task | Readiness score, toolchain/test/coverage/general-section evidence |
| `[O] omega-repo-hygiene-sweep` | Loaded in Omega set | Dependency pinning, CI, coverage, warning and documentation drift review |

## Always-on Pashov attacker set — 12

Load all twelve, once each:

1. `access-control-agent`
2. `asymmetry-agent`
3. `boundary-agent`
4. `economic-security-agent`
5. `execution-trace-agent`
6. `first-principles-agent`
7. `flow-gap-agent`
8. `invariant-agent`
9. `math-precision-agent`
10. `numerical-gap-agent`
11. `periphery-agent`
12. `trust-gap-agent`

`shared-rules.md` is common context, not a thirteenth leaf agent.

## Always-on Omega set — 11 lenses × 5 independent passes + 1 regression pass

Each of five independent generalist passes loads the following eleven lenses:

1. `omega-accounting-consistency`
2. `omega-asset-exit-paths`
3. `omega-enforceability-check`
4. `omega-external-data-trust`
5. `omega-ordering-and-approval-races`
6. `omega-repo-hygiene-sweep`
7. `omega-share-and-index-accounting`
8. `omega-standard-conformance`
9. `omega-time-indexed-state`
10. `omega-transfer-restriction-hooks`
11. `omega-upgrade-diff-review`

`omega-audit-workflow` is the methodology/reporting orchestrator, not a twelfth audit lens. No tracked prior audit report exists in the current target/current tree. Side-branch internal/AI artifacts indexed in `history.md` are not independent external audit coverage, but they do require **one separate historical-regression verification pass**: re-test every historical root-cause hypothesis against `734df96` without inheriting its old status or severity.

## QuillShield plugins — all 11 routed

The broad protocol surface activates every plugin currently present in the collection:

| Plugin | Routing basis |
|---|---|
| `behavioral-state-analysis` | Always-on |
| `state-invariant-detection` | Always-on |
| `semantic-guard-analysis` | Always-on; also permissioned-gating trigger |
| `proxy-upgrade-safety` | Five UUPS modules and ERC1967 deployment scripts |
| `oracle-flashloan-analysis` | Chainlink and Uniswap TWAP/spot inputs; loaded even without a flash-loan callback |
| `signature-replay-analysis` | EIP-712 invites and Chainlink Forwarder/meta-caller boundary |
| `input-arithmetic-safety` | EVE/NAV receipt-token and fee-dilution accounting |
| `external-call-safety` | Native calls, token transfers, pool/router calls and adapter dispatch |
| `reentrancy-pattern-analysis` | External callbacks/calls and multiple stateful fund flows |
| `dos-griefing-analysis` | Redemption batches, bounded scans, strategy/token loops |
| `defender` | Deployment scripts and CI/deployment configuration in scope |

## Plamen EVM language pack — all 18

The platform rule loads the complete EVM pack even where a narrower feature row did not independently fire:

1. `evm/centralization-risk`
2. `evm/cross-chain-message-integrity`
3. `evm/cross-chain-timing`
4. `evm/economic-design-audit`
5. `evm/event-correctness`
6. `evm/external-precondition-audit`
7. `evm/flash-loan-interaction`
8. `evm/fork-ancestry`
9. `evm/migration-analysis`
10. `evm/oracle-analysis`
11. `evm/semi-trusted-roles`
12. `evm/share-allocation-fairness`
13. `evm/staking-receipt-tokens`
14. `evm/storage-layout-safety`
15. `evm/temporal-parameter-staleness`
16. `evm/token-flow-tracing`
17. `evm/verification-protocol`
18. `evm/zero-state-return`

The presence of cross-chain and flash-loan skills in this list is a consequence of the complete EVM language pack; it does not mean those feature triggers fired.

## Plamen depth and feature injectables — 10

| Skill | Routing basis |
|---|---|
| `agents/depth-edge-case.md` | Always-on EVM boundary sweep |
| `agents/depth-state-trace.md` | Always-on cross-function state mutation tracing |
| `agents/depth-external.md` | Foundry deployment automation, external feeds/keepers/signers |
| `injectable/vault-accounting` | EVE as semantic NAV-backed receipt token |
| `injectable/dex-integration-security` | Converter, Uniswap adapter and concentrated-liquidity strategy |
| `injectable/governance-attack-vectors` | TimelockController and tiered role design; also weak time-index trigger |
| `niche/signature-verification-audit` | EIP-712 invite verification |
| `niche/callback-receiver-safety` | Uniswap mint callback, native receivers and external token/pool calls |
| `niche/multi-step-operation-safety` | Enter/allocate/exit/queue/claim and deploy/finalize sequences |
| `niche/stableswap-compliance` | Routed by the generic DEX/AMM row; expected to clear quickly because the integration is Uniswap V3 concentrated liquidity, not a stableswap invariant |

## Trigger-to-load traceability

Always-on loads above are not repeated in this table unless the trigger adds emphasis. Multiple triggers deduplicate to one skill load.

| Trigger | Evidence count | Added/emphasized routes |
|---|---:|---|
| Upgradeability | 72 matches / 9 files | `[Q] proxy-upgrade-safety`; `[O] upgrade-diff`; `[L] storage-layout-safety`, `migration-analysis` |
| Oracles | 181 / 8 | `[Q] oracle-flashloan`; `[O] external-data-trust`; `[L] oracle-analysis`, `external-precondition`; `[P] economic-security` |
| Signatures/meta | 24 / 6 | `[Q] signature-replay`; `[L] signature-verification`; `[O] standard-conformance`, `ordering-and-approval-races` |
| Receipt token/vault semantics | 0 literal, semantic fire | `[O] share-and-index`; `[Q] input-arithmetic`; `[L] vault-accounting`, `share-allocation-fairness`, `zero-state-return`, `staking-receipt-tokens` |
| Permissioned gating | 167 / 13 | `[O] transfer-restriction-hooks`, `enforceability`; `[Q] semantic-guard` |
| Time-indexed/snapshot | 35 / 3, weak | `[O] time-indexed-state`; `[L] temporal-parameter-staleness`, `governance-attack-vectors`; `[P] invariant` |
| External calls/tokens | 78 / 7 | `[Q] external-call`, `reentrancy`; `[P] boundary`; `[L] callback-receiver`, `external-precondition`; `[O] standard-conformance` |
| Queues/batches/user loops | 220 / 13; 33 loops / 9 | `[Q] dos-griefing`; `[O] asset-exit-paths`; `[L] multi-step-operation`; `[P] asymmetry` |
| DEX/AMM | 99 / 8 | `[L] dex-integration-security`, `stableswap-compliance` |
| Governance/timelock | 148 / 17 | `[L] governance-attack-vectors`; `[O] time-indexed-state` |
| Deployment automation | 68 / 14 | `[O] external-data-trust §7`; `[Q] defender`; `[L] depth-external` |
| Economic mechanism | 9 / 2 | `[P] economic-security`; `[L] economic-design`; `[O] accounting-consistency §7` |
| Staking/rewards-like fee state | 6 / 1, weak | `[O] time-indexed-state`, `accounting-consistency`; `[L] staking-receipt-tokens` |

### Ambiguous triggers deliberately fired

- **Receipt token:** literal ERC-4626/share API count is zero, but EVE represents pooled protocol NAV and supply changes on deposits/redemptions/performance-fee minting. Share/accounting routes are therefore relevant.
- **Permissioned token:** Whitelist gates AMM entry and does not hook EVE transfers. Transfer-hook/enforceability lenses are still loaded so they can explicitly clear the mismatch between gate intent and enforcement points.
- **Time-indexed state:** matches are LP-fee snapshots rather than voting checkpoints/epochs. The state is nevertheless temporally advanced and reset, so the route remains loaded.
- **Staking/rewards:** the only exact `earned` signal is UniCL LP-fee accounting, not staking. The narrow staking-receipt-token lens is already in the EVM pack and will cover/clear this surface.
- **Stableswap:** the generic DEX row mandates it even though the target is concentrated liquidity. Record a clear result rather than silently omitting the mandated route.

## Deliberately skipped feature packs

| Skipped pack/skill | Reason |
|---|---|
| Solana, Sui, Aptos, Soroban and DAML language packs | EVM-only primary source |
| L1 node-client pack, `depth-consensus-invariant`, `depth-network-surface` | No consensus/P2P/mempool client |
| `injectable/lending-protocol-security` | No borrow/repay/collateral/liquidation model |
| `injectable/nft-protocol-security` | No ERC-721/1155/token URI/receiver surface |
| `injectable/account-abstraction-security` | No EntryPoint/UserOperation surface |
| `injectable/cross-vm-serialization-conformance` | No cross-chain/cross-VM message surface |
| `niche/dimensional-analysis` feature injection | No rebase/index/multiplier accounting trigger; ordinary precision remains covered by Pashov math/numerical and Quill input-arithmetic |
| Diff-scope modifier | Review is a full snapshot, not a commit range. Upgrade/fork-ancestry skills are already loaded through always-on/platform/upgrade routes |

Flash-loan and cross-chain **feature rows** did not fire, but their EVM-pack skills remain loaded because platform routing explicitly selects the whole 18-skill pack.

## Dispatch requirements

- Provide all agents the same immutable SHA, `scope.md`, `profile.md`, source bundle, integration context and common finding format.
- Do not reduce weak-trigger routes unless an explicit budget constraint is introduced; no such constraint exists.
- Record every leaf completion, failure, timeout and cleared area. Replace the planned census above with the actual census in the final report.
- This manifest is the pre-dispatch coverage claim; it must not be retroactively edited to hide a failed agent.
