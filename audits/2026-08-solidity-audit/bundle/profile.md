# Tier 0 Target Profile Draft

> Pre-audit routing input. Counts and classifications below describe the target; they are not vulnerability findings.

```text
TARGET      https://github.com/everstrat-xyz/contracts/tree/chore/claude-reviewer-setup
COMMIT      734df96a1391e95dd40843210997da0b9f3ab05e
SCOPE       full source snapshot at COMMIT (not a branch diff)
PLATFORM    EVM / Solidity / Foundry                  OTHER: Foundry deployment automation
SIZE        39 primary files, 4,849 normalized LOC
            runtime implementation/local libraries: 25 files, 3,884 nSLOC
            deployment/finalization scripts:         14 files,   965 nSLOC
BUILD       compiles: yes (solc 0.8.30, optimizer 200, via_ir=true under default profile)
            audit tests: 1,169 pass / 0 fail / 15 fork skips, excluding gas benchmarks
            full offline preflight: 1,176 pass / 0 fail / 15 skips (1,191 test functions; 43 suites)
            coverage: reliable-with-caveat under --ir-minimum: 93.13% lines / 79.39% branches /
                      97.09% functions across primary scope; IR-minimum source maps may be inaccurate
            static readiness: baseline collection in progress; no triaged-survivor count frozen yet
SIGNALS     upgradeability(72/9f) oracles(181/8f) signatures(24/6f)
            vault-literals(0/0f; semantic receipt-token signal fires) rebasing(0/0f)
            permissioned(167/13f) time-indexed(35/3f) external-calls(78/7f)
            flash-loans(0/0f) cross-chain(0/0f) queues/batches(220/13f)
            lending(0/0f) dex/amm(99/8f) nft(0/0f) governance(148/17f)
            account-abstraction(0/0f) staking/rewards(6/1f, weak)
            deployment-automation(68/14f) economic-mechanism(9/2f)
CALLBACKS   uniswapV3MintCallback; Queue/Strategy checkUpkeep + performUpkeep;
            receive() on AMM, Controller, Converter, StrategyManager and UniCLStrat;
            permissionless EIP-712 whitelist redemption/relay surface; no fallback()
INTEGRATES  OpenZeppelin contracts/timelock/proxies -> pinned source + official docs indexed in context.md
            Chainlink AggregatorV3 + Automation      -> pinned source + official docs indexed in context.md
            Uniswap V3 pool/router/factory           -> local interfaces/adapted libraries + upstream refs in context.md
OFFCHAIN    14 Foundry scripts read env and sign/broadcast with PRIVATE_KEY: in scope
            Chainlink Automation nodes/Forwarders and whitelist signer service: external, code not supplied
PRIOR       no tracked prior report in current target/current tree;
            side-branch internal/AI artifacts are indexed in history.md, not independent external audit coverage
EXCLUDED    interfaces/tests/mocks/helpers/lib/mermaid/workflows/docs/generated artifacts; see scope.md
```

`N/Mf` means N raw case-insensitive regex matches across M primary-scope files. Counts include comments and identifiers and are routing evidence, not semantic issue counts.

## Snapshot and repository shape

- Immutable tree: [`734df96a1391e95dd40843210997da0b9f3ab05e`](https://github.com/everstrat-xyz/contracts/tree/734df96a1391e95dd40843210997da0b9f3ab05e).
- The audit branch points at the requested branch tip; its tip commit contains only `CLAUDE.md` and two Claude workflows. Scope is still the full protocol at this SHA.
- X-ray history classification: `normal_dev`, but with very shallow history—5 commits total, 2 source-touching commits, 7 calendar days of history.
- Approximately 11,116 source lines arrived in the monorepo-import commit `b67fcad`; the only later source-touching commit (`533f842`) changes 6 lines in `UniCLStrat.sol` and tests. Git weighting therefore supplies little independent design ancestry and must not be mistaken for a finding oracle.
- No tracked prior audit report exists in the current target/current tree. Historical side-branch internal/AI artifacts are indexed in `history.md` for regression context and are not independent external audit coverage for this SHA.

## Toolchain and dependencies

| Item | Snapshot fact | Audit prerequisite/impact |
|---|---|---|
| Foundry | Repository pin `FOUNDRY_VERSION` = `1.0.0`; local preflight used `forge 1.7.1` | Re-run formatting/build/test on 1.0.0 for release-grade reproducibility; retain 1.7.1 result as a secondary comparison |
| Solidity | `solc_version = "0.8.30"` | Compiler is configured in `foundry.toml`; individual pragmas range from `^0.8.0`/`^0.8.13` to `^0.8.30` |
| Optimizer | enabled, 200 runs | Default profile uses `via_ir = true`; CI profile omits explicit `via_ir`, so both profiles should be compared |
| EVM version | not explicitly pinned | Record the compiler default or pin it before a production bytecode comparison |
| Chainlink | submodule `86aa5a1d34b20eda8d18fe6eb0e4882948e545ba` (`v0.3.3-9-g86aa5a1d34`) | Exact integration version is available locally |
| forge-std | submodule `8bbcf6e3f8f62f419e5429a0bd89331c85c37824` (`v1.10.0`) | Test/script dependency |
| OpenZeppelin Upgradeable | submodule `60b305a8f3ff0c7688f02ac470417b6bbf1c4d27` | Remapped as upgradeable package; its nested OZ contracts revision is `e4f70216...` |
| Hardhat | absent | Foundry-only Solidity project |
| Static/formal tools | Slither, Echidna, Medusa, Halmos and Certora executables not present | Installation or a containerized toolchain is required for those passes |

All submodules were present recursively in the local checkout. The nested dependency tree contains additional test dependencies, but only imported runtime/library code is relevant to the protocol build.

## Build and test posture

- Audit test selection under Foundry 1.7.1, excluding gas-benchmark contracts: **1,169 passing, 0 failing, 15 skipped**. The broader offline preflight including seven gas-benchmark tests is **1,176 passing, 0 failing, 15 skipped**. The 15 skipped tests are the mainnet-fork suite, so the live Uniswap/Chainlink integration surface was not exercised by the offline baseline.
- Fork execution requires both `MAINNET_RPC_URL` and a deliberately pinned `MAINNET_FORK_BLOCK`. A zero/tip block makes results time-dependent.
- The repository has 40 Solidity test files and 1,191 `test*` functions. Unit, integration and named fuzz tests exist; no Foundry invariant test, Echidna corpus, Medusa campaign, Certora spec, Halmos run or HEVM proof was detected.
- A normal `forge coverage` run encounters stack-too-deep at `script/DeployAll.s.sol:119`. The `--ir-minimum` run completes and gives a usable primary-scope aggregate: **93.13% lines / 79.39% branches / 97.09% functions**. Foundry warns that IR-minimum source mappings may be inaccurate, so this is `reliable-with-caveat`; later review must inspect named uncovered paths rather than infer completeness from percentages.
- The two tracked GitHub workflows run Claude/architecture review but do not compile or test the Solidity project. A clean Forge CI gate is therefore a pre-audit/release prerequisite.
- `forge build --offline` is cached and succeeds. Foundry 1.7.1 also emits lint diagnostics; this profile intentionally does not promote untriaged lints to findings.

## Runtime shape

The deployable runtime surface comprises **13 concrete contracts**:

- five UUPS/ERC1967 proxies: Controller, Converter, ExitQueue, Oracle and StrategyManager;
- eight static deployments: Registry, AMM, EVE, Whitelist, UniswapV3ConverterAdapter, QueueKeeperExecutor, StrategyKeeperExecutor and UniCLStrat.

ABI census across those 13 artifacts:

| Surface | Count | Notes |
|---|---:|---|
| ABI function selectors | 362 | Counted per deployed contract, so shared/inherited selectors on different contracts count separately |
| ABI non-view/payable function selectors | 155 | Includes 5 inherited UUPS `upgradeToAndCall` selectors and 3 inherited ERC-20 transfer/approval selectors; Converter quote calls are nominally non-view too |
| View/pure selectors | 207 | Includes generated public getters and inherited interfaces |
| Protocol-source-defined non-view/payable selectors | 147 | 155 minus the 8 inherited selectors above |
| Payable `receive()` entry points | 5 | AMM, Controller, Converter, StrategyManager, UniCLStrat |
| Source-defined non-view/payable functions plus receives | 152 | Primary call-entrypoint census |
| `fallback()` entry points | 0 | None in primary scope |

State-changing selector counts by concrete ABI:

| Contract | Mutating/payable selectors |
|---|---:|
| AMM | 10 |
| Controller | 25 |
| Converter | 13 |
| EVE | 6 |
| ExitQueue | 8 |
| Oracle | 6 |
| StrategyManager | 31 |
| Whitelist | 6 |
| UniswapV3ConverterAdapter | 2 |
| QueueKeeperExecutor | 7 |
| StrategyKeeperExecutor | 11 |
| Registry | 11 |
| UniCLStrat | 19 |
| **Total** | **155** |

### Externally driven callbacks and unusual entry points

| Entry point | Expected caller/trust boundary |
|---|---|
| `UniCLStrat.uniswapV3MintCallback(uint256,uint256,bytes)` | Configured Uniswap V3 pool only, while the local `_minting` flag is set |
| `QueueKeeperExecutor.checkUpkeep(bytes)` | Simulated off-chain by Chainlink Automation; public view |
| `QueueKeeperExecutor.performUpkeep(bytes)` | Configured Chainlink Forwarder only; `performData` is untrusted and revalidated |
| `StrategyKeeperExecutor.checkUpkeep(bytes)` | Simulated off-chain by Chainlink Automation; public view |
| `StrategyKeeperExecutor.performUpkeep(bytes)` | Configured Chainlink Forwarder only; action and live conditions revalidated |
| `Whitelist.whitelist(...)` | Permissionless user or relayer; authorization comes from EIP-712 signer and invite state |
| `UniCLStrat.selfRemoveLiquidityAndCollect()` | External self-call only, used to put pool unwind behind `try/catch` during pause |
| `initialize(...)` on five UUPS modules | Intended to execute atomically through each ERC1967 proxy constructor |
| Five `receive()` functions | Native ETH can be received without calldata; downstream accounting differs by holder |

## Roles, identities and actors

| Actor/authority | Source-defined power |
|---|---|
| Permissionless user | Enter/exit AMM, queue/cancel redemption, claim ETH, redeem an invite, transfer/approve EVE |
| `ADMIN_ROLE` | Registry wiring/roles, configuration, Oracle feeds, strategy set, adapter allowlist, unpause and UUPS upgrades; deployment intends a 48-hour TimelockController holder |
| `SECURITY_ROLE` | Immediate pause/circuit-breaker actions, Controller/strategy emergency capital recovery, supported-token removal; cannot unpause or upgrade |
| `KEEPER_ROLE` | Controller strategy/redemption operations; intended holders are the two executor contracts, not Chainlink infrastructure |
| `MINTER_ROLE` | EVE mint/burn; intended grants to AMM and StrategyManager |
| `CONVERTER_CALLER_ROLE` | Converter wrap/unwrap/swap operations; intended for registered strategies |
| `CONVERTER_CALLER_MANAGER_ROLE` | Administers converter callers; intended holder is Converter, which accepts requests only from registered StrategyManager |
| Registered-contract identities | `CONTROLLER`, `AMM`, `STRATEGY_MANAGER`, `EXIT_QUEUE`, `ORACLE`, `EVE`, `CONVERTER`, two keeper executors and `WHITELIST` are authorization/address-resolution keys |
| Chainlink Forwarder | Non-role allowlisted caller of each `performUpkeep`; executor itself holds `KEEPER_ROLE` |
| Whitelist signer | Off-chain EIP-712 invite authority stored in Whitelist; signer service/KMS code is not supplied |
| DAO multisig | Timelock proposer/canceller in scripts; intended to hold no direct protocol role |
| Security multisig | Direct `SECURITY_ROLE` holder and Timelock canceller |
| Timelock executor | Open (`address(0)`) in scripts after the minimum delay; anyone may execute a ready operation |
| Deployment EOA | Temporary bootstrap `ADMIN_ROLE`; finalization script must renounce it |
| Uniswap V3 pool | External liquidity/state oracle and the sole valid mint-callback caller |

## Assets and accounting units

- native ETH held by AMM, Controller, StrategyManager and UniCLStrat;
- EVE ERC-20 supply, user balances, AMM escrow, dead bootstrap supply and performance-fee dilution mints;
- WETH and a paired ERC-20 held by Converter/UniCLStrat, plus arbitrary admin-supported ERC-20 balances held by StrategyManager;
- AMM `lockedForClaims` and per-user `claimableBalances` (pull-payment liabilities);
- queued EVE burn obligations and priced ETH redemption obligations;
- Uniswap V3 liquidity positions and `tokensOwed` fee balances keyed to UniCLStrat/tick ranges;
- strategy NAV, controller/AMM idle liquidity, allocation weights/cooldowns and DAO fee accounting;
- Chainlink/USD prices and Uniswap tick/TWAP values (external data, not owned assets).

All protocol prices and NAVs normalize to 18 decimals; integrated ERC-20s retain their native decimals at transfer boundaries.

## Integrations and external assumptions

| Integration | Use in target | Documentation status for downstream bundle |
|---|---|---|
| OpenZeppelin Contracts | ERC-20, AccessControlEnumerable, Pausable, ReentrancyGuard, SafeERC20, EIP-712/ECDSA, TimelockController, ERC1967Proxy | Exact local source pin and official proxy/access references indexed in `context.md` |
| OpenZeppelin Upgradeable | Initializable/UUPS and upgradeable guards | Exact local source pin and official upgradeable-contract references indexed in `context.md` |
| Chainlink Data Feeds | `AggregatorV3Interface.latestRoundData`, decimals and description | Exact interface source plus official Data Feeds reference indexed; deployed feed metadata not supplied |
| Chainlink Automation | `checkUpkeep`/`performUpkeep` and per-upkeep Forwarders | Exact interface source plus official compatible-contract reference indexed; upkeep/Forwarder deployment state not supplied |
| Uniswap V3-compatible pool | `slot0`, `observe`, `positions`, `mint`, `burn`, `collect` | Local interface/adapted math and upstream V3 references indexed; exact pool deployment and observation-cardinality state not supplied |
| Uniswap V3 router/factory | Exact-input/output swaps and pool lookup | Local interfaces and upstream interface references indexed; deployed router/factory addresses not supplied |
| WETH | Deposit/withdraw and ERC-20 behavior | Interface and WETH boundary indexed; network-specific address/code not supplied |

## Feature-signal evidence and routing decision

Raw counts use the routing-table regex families over the 39 primary files. Comments are included to preserve reproducibility; semantic disposition is explicit.

| Signal | Hits / files | Example evidence | Decision |
|---|---:|---|---|
| Upgradeability | 72 / 9 | `Converter.sol` UUPS and adapter `delegatecall`; `ProtocolDeployBase.sol` ERC1967Proxy | Fire |
| Oracles/prices | 181 / 8 | `Oracle.sol` `latestRoundData`; adapter/strategy TWAP, `observe`, `slot0` | Fire |
| Signatures/meta | 24 / 6 | `Whitelist.sol` ECDSA/typehash; keeper Forwarders | Fire |
| Vault/share literals | 0 / 0 | No ERC4626/share API literal | **Fire semantically:** EVE is a pooled-NAV receipt token and fee dilution changes supply |
| Rebase/index | 0 / 0 | Stored ERC-20 balances; no computed balance index | Do not fire |
| Permissioned/compliance | 167 / 13 | Whitelist contract and AMM entry gate | Fire with caveat: entry gating, not transfer restriction |
| Time-indexed state | 35 / 3 | UniCL LP-fee snapshots; keeper snapshot-before-execution comments | Fire weakly under ambiguous-trigger rule |
| External calls/tokens | 78 / 7 | SafeERC20, native calls and nonReentrant boundaries | Fire |
| Flash-loan callbacks | 0 / 0 | No flash-loan API/callback | Do not fire feature row; oracle-flashloan plugin still routes via Oracle row |
| Cross-chain | 0 / 0 | No bridge/message surface | Do not fire |
| Queues/batches | 220 / 13 | ExitQueue and both executors; 33 `for (uint...)` loops in 9 files | Fire |
| Lending | 0 / 0 | No borrow/repay/liquidation model | Do not fire |
| DEX/AMM | 99 / 8 | bonding curve, swap adapter, concentrated liquidity | Fire |
| NFT | 0 / 0 | No ERC-721/1155 surface | Do not fire |
| Governance | 148 / 17 | Foundry scripts deploy/configure TimelockController | Fire |
| Account abstraction | 0 / 0 | No EntryPoint/UserOperation | Do not fire |
| Staking/rewards | 6 / 1 | `earned` appears only in UniCL LP-fee accounting | Fire weakly to cover reward/fee state under ambiguity rule; no staking archetype claim |
| Off-chain/deployment | 68 / 14 | `vm.env*`, `startBroadcast`, `PRIVATE_KEY` in all deployment scripts | Fire |
| Economic mechanism | 9 / 2 | AMM bonding-curve premium; StrategyManager fee schedule | Fire |

The complete resulting skill load is recorded in `manifest.md`.

## Pre-audit prerequisites

1. Freeze the immutable SHA and confirm the 39-file primary scope.
2. Re-run build, format and the full test suite under repository-pinned Foundry 1.0.0.
3. Supply `MAINNET_RPC_URL` and a fixed `MAINNET_FORK_BLOCK`, then run the 15 fork tests.
4. Preserve the `--ir-minimum` coverage artifact and source-map caveat, then inspect named uncovered paths; do not rely on aggregate percentages alone.
5. Finish and freeze the static-readiness baseline; install/pin any additional static/fuzz tools before claiming their passes ran.
6. Use the pinned/official OpenZeppelin, Chainlink, Uniswap, WETH and EIP-712 references already indexed in `context.md`; add only network/deployment-specific evidence that remains missing.
7. If deployment state is in scope, supply the complete address/configuration/role evidence listed in `scope.md`.
