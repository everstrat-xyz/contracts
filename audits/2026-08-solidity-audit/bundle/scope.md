# Tier 0 Scope Draft

> Pre-audit scope artifact only. This document fixes the review boundary; it does not contain vulnerability findings.

## Immutable target

| Field | Value |
|---|---|
| Repository | `https://github.com/everstrat-xyz/contracts` |
| Requested branch | `chore/claude-reviewer-setup` |
| Audited snapshot | [`734df96a1391e95dd40843210997da0b9f3ab05e`](https://github.com/everstrat-xyz/contracts/tree/734df96a1391e95dd40843210997da0b9f3ab05e) |
| Local audit branch | `audit/solidity-audit-skills-734df96` |
| Scope mode | **Full source snapshot**, not `main...branch` diff |
| Primary platform | EVM / Solidity / Foundry |

The requested branch-tip commit itself adds `CLAUDE.md` and two Claude-review workflows. The security review boundary is nevertheless the full protocol source at the immutable SHA above. Findings must cite the SHA and an in-scope path, not a moving branch name.

## Counting method

Normalized LOC (nSLOC) is the number of non-blank lines after removing `/* ... */` blocks and `// ...` tails. The portable command used for each file was:

```sh
perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$file" | awk 'NF { n++ } END { print n+0 }'
```

This method is deterministic for this snapshot and avoids counting NatSpec and blank lines. It is a sizing signal, not a parser or semantic code metric.

## Primary source scope — implementation and local libraries

All implementation contracts and all locally maintained/internalized libraries under `src/` are in scope: **25 files / 3,884 nSLOC**.

| nSLOC | Path | Scope reason |
|---:|---|---|
| 228 | `src/contracts/AMM.sol` | User entry, immediate/queued redemption, EVE pricing, claim accounting |
| 261 | `src/contracts/Controller.sol` | Keeper-controlled capital and redemption orchestration; UUPS |
| 260 | `src/contracts/Converter.sol` | WETH and token routing; allowlisted adapter `delegatecall`; UUPS |
| 22 | `src/contracts/EVE.sol` | NAV-backed ERC-20 receipt token mint/burn surface |
| 184 | `src/contracts/ExitQueue.sol` | Redemption request/batch state machine; UUPS |
| 267 | `src/contracts/Oracle.sol` | Chainlink-backed USD/pair pricing and conversions; UUPS |
| 634 | `src/contracts/StrategyManager.sol` | Strategy registry, allocation, NAV and performance-fee accounting; UUPS |
| 84 | `src/contracts/Whitelist.sol` | EIP-712 invite-based entry gate |
| 169 | `src/contracts/adapters/UniswapV3ConverterAdapter.sol` | Uniswap V3 route execution and TWAP/Oracle quote adapter |
| 33 | `src/contracts/automation/KeeperExecutorBase.sol` | Shared Chainlink Forwarder authorization and circuit breaker |
| 169 | `src/contracts/automation/QueueKeeperExecutor.sol` | Automated batch pricing/processing/cursor progression |
| 243 | `src/contracts/automation/StrategyKeeperExecutor.sol` | Automated rebalance, liquidity, deposit, fee and sync actions |
| 164 | `src/contracts/registry/Registry.sol` | Address book and protocol role authority |
| 13 | `src/contracts/registry/client/RegistryClient.sol` | Static Registry binding |
| 24 | `src/contracts/registry/client/RegistryClientBase.sol` | Shared role/registered-contract authorization modifiers |
| 23 | `src/contracts/registry/client/RegistryClientUpgradeable.sol` | ERC-7201 Registry binding for proxies |
| 751 | `src/contracts/strategies/UniCLStrat.sol` | Concentrated-liquidity strategy, NAV, fee and emergency paths |
| 50 | `src/libraries/Auth.sol` | Canonical Registry keys and role identifiers |
| 48 | `src/libraries/Math.sol` | Normalization, conversion and relative-comparison math |
| 5 | `src/libraries/integrations/uniswap/FixedPoint96.sol` | Internalized/adapted Uniswap V3 fixed-point constants |
| 44 | `src/libraries/integrations/uniswap/FullMath.sol` | Internalized/adapted Uniswap V3 full-precision math |
| 89 | `src/libraries/integrations/uniswap/LiquidityAmounts.sol` | Internalized/adapted Uniswap V3 liquidity math |
| 34 | `src/libraries/integrations/uniswap/TickMath.sol` | Internalized/adapted Uniswap V3 tick math |
| 38 | `src/libraries/integrations/uniswap/TickUtils.sol` | Protocol-authored tick/TWAP helpers |
| 47 | `src/libraries/integrations/uniswap/UniswapV3Path.sol` | Protocol-authored route validation/decoding helpers |
| **3,884** | **25 files** | **Implementation/library subtotal** |

The four files marked “adapted” are still primary scope: they are copied into `src/`, compiled into the protocol, and can diverge from upstream. Their provenance comments do not make them external dependencies.

## Primary deployment scope

All Foundry deployment and finalization scripts are in scope: **14 files / 965 nSLOC**. They determine proxy initialization, Registry wiring, timelock roles, feed selection, keeper authorization, adapter/strategy go-live ordering, and bootstrap-role teardown.

| nSLOC | Path |
|---:|---|
| 50 | `script/DeployAMM.s.sol` |
| 144 | `script/DeployAll.s.sol` |
| 27 | `script/DeployController.s.sol` |
| 34 | `script/DeployConverter.s.sol` |
| 25 | `script/DeployEVE.sol` |
| 27 | `script/DeployExitQueue.s.sol` |
| 28 | `script/DeployKeeperExecutors.s.sol` |
| 36 | `script/DeployOracle.s.sol` |
| 32 | `script/DeployRegistry.s.sol` |
| 62 | `script/DeployUniCLStrat.s.sol` |
| 48 | `script/DeployUniswapV3ConverterAdapter.s.sol` |
| 32 | `script/DeployWhitelist.s.sol` |
| 24 | `script/FinalizeProtocolDeploy.s.sol` |
| 396 | `script/ProtocolDeployBase.sol` |
| **965** | **14 files** |

## Scope totals

| Slice | Files | nSLOC |
|---|---:|---:|
| Implementation contracts and internal/local libraries | 25 | 3,884 |
| Deployment/finalization scripts | 14 | 965 |
| **Primary audit scope** | **39** | **4,849** |

Architecture-oriented grouping of the 3,884 runtime/library nSLOC:

| Subsystem | Included source | nSLOC |
|---|---|---:|
| Entry and redemption | AMM, EVE, ExitQueue, Whitelist | 518 |
| Coordination and accounting | Controller, StrategyManager | 895 |
| Registry and access | Registry, three Registry clients, Auth | 274 |
| Oracle and shared math | Oracle, Math | 315 |
| Converter, strategy and Uniswap math/path code | Converter, adapter, UniCLStrat, six Uniswap libraries | 1,437 |
| Automation | KeeperExecutorBase, QueueKeeperExecutor, StrategyKeeperExecutor | 445 |
| **Total** |  | **3,884** |

## Context-only and excluded paths

The following remain readable to auditors and may be used to understand intent or write proofs of concept, but they are not primary finding locations unless an in-scope defect depends on them.

| Path | Treatment | Reason |
|---|---|---|
| `src/interfaces/**` | Context-only | 21 interface files; declarations and integration shapes, no implementation logic |
| `test/**` | Context/PoC harness | 40 test files, including unit, integration, fuzz and fork suites |
| `test/mocks/**`, `test/helpers/**`, `test/trees/**` | Context-only | Test scaffolding and generated/specification trees |
| `lib/**` | External dependency context | Git submodules; review integration assumptions and pinning, not vendored upstream internals as protocol findings |
| `mermaid/**` | Documentation/tooling context | Architecture diagrams and their TypeScript checker are outside the requested Solidity/deployment scope |
| `.github/workflows/**` | Repo-readiness context | Claude workflows do not build or test the contracts; not production protocol logic |
| `CLAUDE.md`, `README.md`, `docs/**` | Specification context | Intent and operational assumptions only |
| `out/**`, `cache/**`, `broadcast/**` | Generated/excluded | Build and broadcast artifacts; no tracked production deployment was supplied |
| `audits/2026-08-solidity-audit/**` | Audit output | Generated during this engagement; never audit input and never a finding source |

No tracked prior audit report exists in the current target/current tree. Historical side-branch internal and AI-assisted artifacts are indexed in `history.md` as regression context; they are not an independent external audit and do not establish assurance for `734df96`. Do not treat outputs created later in this engagement as prior history.

## Deployment-state boundary

This is a source audit. No production chain ID, deployment addresses, proxy implementations, initializer calldata, Registry entries, role membership, Timelock operations, Chainlink feed addresses, upkeep Forwarders, strategy configurations, Uniswap pools or bytecode/source matches were supplied.

An on-chain/configuration review requires, at minimum:

- chain ID and RPC endpoint;
- every proxy and implementation address plus initialization transaction/calldata;
- Registry key/address table and complete role membership/admin graph;
- Timelock minimum delay, proposer, executor and canceller membership;
- Oracle feed addresses/staleness intervals and supported-token/pair sets;
- Converter adapter allowlist and strategy route bytes;
- strategy pool, TWAP windows, tick settings, weights, NAV caps and supported ERC-20s;
- Chainlink Automation upkeep IDs and Forwarder addresses;
- deployed-bytecode-to-source/constructor-argument verification.

Until those inputs exist, configuration or deployment-state assertions must be labeled `unknown`, not inferred from scripts.
