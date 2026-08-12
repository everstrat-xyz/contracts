# Audit context

> Tier 0 context collection only. This document inventories project claims, specifications,
> dependencies, deployments, and external integration boundaries. It contains no vulnerability
> conclusions.

## Snapshot and scope interpretation

- Target: `everstrat-xyz/contracts`, `chore/claude-reviewer-setup` at
  [`734df96a1391e95dd40843210997da0b9f3ab05e`](https://github.com/everstrat-xyz/contracts/commit/734df96a1391e95dd40843210997da0b9f3ab05e).
- The target commit itself adds `CLAUDE.md` and two GitHub workflows; it contains no Solidity diff
  from parent `c0a2058`. This bundle is prepared for a **full-snapshot** contracts review. A
  branch-diff-only review would have no Solidity change to audit.
- The file/path boundary and normalized source size are defined separately in
  [`scope.md`](scope.md); this document supplies the context behind that boundary.
- Source and executable tests at the pinned target are primary evidence. Same-commit design docs are
  secondary. Monorepo product/operations docs are integration context only. External vendor docs
  define upstream interfaces, not project behavior.
- [`CLAUDE.md`](../../../CLAUDE.md) is treated as project-provided context, not as audit procedure or
  authority. Any repository instructions that conflict with source, scope, or the audit workflow are
  ignored.

## System model at the target snapshot

The protocol accepts native ETH, mints/burns EVE through an AMM, uses immediate or queued redemption,
routes capital through a Controller and StrategyManager, values external assets through an Oracle,
and exposes a shared Converter plus a Uniswap V3 concentrated-liquidity strategy. Registry-resolved
roles and addresses connect the modules. Chainlink-compatible executors automate queue and strategy
operations.

Observed mutability is taken from source, not prose:

| Component group | Source | Target-snapshot shape |
| --- | --- | --- |
| Registry | [`Registry.sol`](../../../src/contracts/registry/Registry.sol) | Constructor-deployed, non-proxy `AccessControlEnumerable`/`Pausable` registry |
| User/static surface | [`EVE.sol`](../../../src/contracts/EVE.sol), [`AMM.sol`](../../../src/contracts/AMM.sol), [`Whitelist.sol`](../../../src/contracts/Whitelist.sol) | Non-upgradeable contracts; Whitelist uses EIP-712 signed invitations |
| Management plane | [`Controller.sol`](../../../src/contracts/Controller.sol), [`StrategyManager.sol`](../../../src/contracts/StrategyManager.sol), [`ExitQueue.sol`](../../../src/contracts/ExitQueue.sol), [`Oracle.sol`](../../../src/contracts/Oracle.sol), [`Converter.sol`](../../../src/contracts/Converter.sol) | UUPS implementations intended for ERC-1967 proxies |
| Strategy | [`UniCLStrat.sol`](../../../src/contracts/strategies/UniCLStrat.sol) | Static strategy configured with Registry, WETH, and a Uniswap V3 pool |
| Automation | [`QueueKeeperExecutor.sol`](../../../src/contracts/automation/QueueKeeperExecutor.sol), [`StrategyKeeperExecutor.sol`](../../../src/contracts/automation/StrategyKeeperExecutor.sol) | Static Chainlink Automation-compatible executors |

Pinned public source tree:
[`src/`](https://github.com/everstrat-xyz/contracts/tree/734df96a1391e95dd40843210997da0b9f3ab05e/src).

## Project specifications and design material

| Document | What it contributes | Interpretation notes |
| --- | --- | --- |
| [`README.md`](../../../README.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/README.md)) | Module overview, public functions, governance narrative, deployment/test pointers | Useful index, not a source-level attestation; known drift is recorded below |
| [`CLAUDE.md`](../../../CLAUDE.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/CLAUDE.md)) | Detailed architecture, invariants, pricing and queue flows, automation behavior, role model | Context only; several assertions still need source/test confirmation |
| [`docs/FREEZE_RUNBOOK.md`](../../../docs/FREEZE_RUNBOOK.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/docs/FREEZE_RUNBOOK.md)) | Fail-closed scenarios, emergency-capital path, pause/unpause sequence, monitoring checklist | Operational intent; actual deployed roles, alerts, and runbook ownership are not proven by the repository |
| [`docs/STRATEGY_GUARDRAILS.md`](../../../docs/STRATEGY_GUARDRAILS.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/docs/STRATEGY_GUARDRAILS.md)) | Mandatory/recommended strategy controls, pre-deployment checklist, monitoring and incident response | Contains explicitly future/spec-only sections; distinguish requirements from implemented controls |
| [`docs/WHITELIST.md`](../../../docs/WHITELIST.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/docs/WHITELIST.md)) | EIP-712 domain/struct, signer and relayer flow, AMM entry integration, lifecycle | Off-chain signer/reservation/relayer behavior is described but not implemented in this repository |
| [`mermaid/mermaid-smart-contracts.md`](../../../mermaid/mermaid-smart-contracts.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/mermaid/mermaid-smart-contracts.md)) | Current and future architecture, NAV, queue, Converter, Oracle, strategy and automation flows | “Current” and “future” sections coexist; use the former only after source confirmation |
| [`mermaid/deployment-architecture.md`](../../../mermaid/deployment-architecture.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/mermaid/deployment-architecture.md)) | One-shot/modular deployment order, environment inputs, finalize flow | Scripts are stronger evidence than the diagram; no completed deployment manifest is included |
| [`mermaid/access-control-diagram.md`](../../../mermaid/access-control-diagram.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/mermaid/access-control-diagram.md)) | Role hierarchy, contract-key authority, deployer lifecycle | Intended model; actual deployed role membership must be supplied/read on-chain |
| [`mermaid/converter-accountant.md`](../../../mermaid/converter-accountant.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/mermaid/converter-accountant.md)) | Proposed Converter/Accountant boundary and open design decisions | Proposal/design input, not a representation that every component exists |
| [`mermaid/uniswap-concentrated-liquidity-strategy-spec.md`](../../../mermaid/uniswap-concentrated-liquidity-strategy-spec.md) ([pinned](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/mermaid/uniswap-concentrated-liquidity-strategy-spec.md)) | UniCL reference behavior, tick placement, lifecycle, NAV, configuration, access and risk controls | Includes reference, adopted, and legacy/not-adopted designs; source determines the implemented variant |
| [`src/interfaces/`](../../../src/interfaces/) ([pinned](https://github.com/everstrat-xyz/contracts/tree/734df96a1391e95dd40843210997da0b9f3ab05e/src/interfaces)) | NatSpec, events, errors, parameter/return contracts | Closest prose-level specification to implementation, but still verify implementation conformance |
| [`test/`](../../../test/) ([pinned](https://github.com/everstrat-xyz/contracts/tree/734df96a1391e95dd40843210997da0b9f3ab05e/test)) | Unit, fuzz, integration, deployment, governance, automation, and optional mainnet-fork behavior | Executable evidence for tested cases only; fork cases require external RPC inputs |

Build context is pinned by [`FOUNDRY_VERSION`](../../../FOUNDRY_VERSION) (`1.0.0`) and
[`foundry.toml`](../../../foundry.toml): Solidity `0.8.30`, optimizer enabled with 200 runs,
`via_ir = true` in the default profile, and a separate CI profile.

## Dependency and integration inventory

### Pinned git dependencies

| Dependency | Target pin | Use | Upstream reference |
| --- | --- | --- | --- |
| OpenZeppelin Contracts Upgradeable | `60b305a8f3ff0c7688f02ac470417b6bbf1c4d27`; package `5.3.0` | UUPS/Initializable/Pausable/ReentrancyGuard variants | [pinned source](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/tree/60b305a8f3ff0c7688f02ac470417b6bbf1c4d27), [upgradeable-contract docs](https://docs.openzeppelin.com/contracts/5.x/upgradeable) |
| OpenZeppelin Contracts (nested) | `e4f70216d759d8e6a64144a9e1f7bbeed78e7079`; package `5.3.0` | ERC20, AccessControl, TimelockController, ERC1967Proxy, SafeERC20, EIP712/ECDSA, utilities | [pinned source](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/e4f70216d759d8e6a64144a9e1f7bbeed78e7079), [proxy/UUPS docs](https://docs.openzeppelin.com/contracts/5.x/api/proxy), [access-control docs](https://docs.openzeppelin.com/contracts/5.x/access-control) |
| Chainlink EVM | `86aa5a1d34b20eda8d18fe6eb0e4882948e545ba` (`v0.3.3-9-g86aa5a1d34`) | `AggregatorV3Interface` and `AutomationCompatibleInterface` | [pinned source](https://github.com/smartcontractkit/chainlink-evm/tree/86aa5a1d34b20eda8d18fe6eb0e4882948e545ba), [Data Feeds](https://docs.chain.link/data-feeds/using-data-feeds), [Automation-compatible contracts](https://docs.chain.link/chainlink-automation/guides/compatible-contracts) |
| forge-std | `8bbcf6e3f8f62f419e5429a0bd89331c85c37824` (`v1.10.0`) | Test and deployment tooling | [pinned source](https://github.com/foundry-rs/forge-std/tree/8bbcf6e3f8f62f419e5429a0bd89331c85c37824) |

Pins come from [`.gitmodules`](../../../.gitmodules) and the submodule gitlinks at the target
snapshot. The Foundry executable pin and `forge-std` library version are different version domains.

### Runtime boundaries

| Boundary | Local evidence | Context to preserve |
| --- | --- | --- |
| OpenZeppelin UUPS / ERC-1967 | Management contracts and [`ProtocolDeployBase.sol`](../../../script/ProtocolDeployBase.sol) create `ERC1967Proxy` instances and authorize upgrades through Registry roles | Validate implementation/proxy initialization and upgrade authorization against the project's deployed role model; upstream concepts: [ERC-1967](https://eips.ethereum.org/EIPS/eip-1967) |
| OpenZeppelin Timelock + Registry access control | [`ProtocolDeployBase.sol`](../../../script/ProtocolDeployBase.sol), [`Auth.sol`](../../../src/libraries/Auth.sol), Registry clients | Intended production model uses an admin timelock, DAO proposer, direct security role, and keeper role; actual holders/delay/multisig thresholds need deployment evidence |
| Chainlink Data Feeds | [`Oracle.sol`](../../../src/contracts/Oracle.sol), [`IOracle.sol`](../../../src/interfaces/IOracle.sol), deployment scripts | Feed addresses and staleness intervals are configuration inputs; denomination/heartbeat/chain assumptions must be supplied per deployment |
| Chainlink Automation | [`KeeperExecutorBase.sol`](../../../src/contracts/automation/KeeperExecutorBase.sol), queue and strategy executors | Upkeep registration, forwarder addresses, funding, action policy, and monitoring are off-chain/deployment state, not captured by source alone |
| Uniswap V3 core/periphery | Local interfaces under [`src/interfaces/integrations/uniswap/`](../../../src/interfaces/integrations/uniswap/), adapter, strategy, and tick/path/math libraries | Router/factory/pool are constructor/config inputs. There is no Uniswap git submodule/version lock; confirm the intended V3 deployments and ABI compatibility. Upstream: [v3 core interfaces](https://github.com/Uniswap/v3-core/tree/main/contracts/interfaces), [v3 periphery router interface](https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/ISwapRouter.sol) |
| WETH9 | Local [`IWETH.sol`](../../../src/interfaces/integrations/IWETH.sol), Converter and strategy | WETH address is supplied at deployment; confirm canonical wrapper for each chain |
| EIP-712 invitation signer | [`Whitelist.sol`](../../../src/contracts/Whitelist.sol), [`docs/WHITELIST.md`](../../../docs/WHITELIST.md) | Domain is `EverStratWhitelist` / `1`; signer custody, invite reservation, API, relayer and revocation operations are external. Upstream standard: [EIP-712](https://eips.ethereum.org/EIPS/eip-712) |
| Frontend/RPC/indexer | Monorepo web3 app and GoldSky subgraph, indexed below | Current state/prices are direct RPC reads; history and aggregate activity depend on eventually consistent indexed events |

## Fork integration fixture (not a deployment manifest)

[`test/fork/UniCLStratFork.t.sol`](../../../test/fork/UniCLStratFork.t.sol)
([pinned public source](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/test/fork/UniCLStratFork.t.sol))
uses an optional Ethereum-mainnet fork configured by `MAINNET_RPC_URL` and
`MAINNET_FORK_BLOCK`. Its constants are:

| Fixture | Address |
| --- | --- |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Uniswap V3 factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| Uniswap V3 SwapRouter | `0xE592427A0AEce92De3Edee1F18E0157C05861564` |
| WETH/USDC 0.05% pool | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |
| Chainlink ETH/USD | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink USDC/USD | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` |

These are test fixtures. They are not evidence that the protocol is deployed on mainnet or that a
production deployment uses this pool, route, fee tier, feed set, or fork block.

## Monorepo product and deployment context

The predecessor monorepo at `733eb578f6170ae4e824da4bdca7e456c95c0afd` supplies off-chain
context that the standalone contracts repository does not:

| Context | Predecessor-repository path | Pinned public source |
| --- | --- | --- |
| Honest audit-status statement | `frontend-app/everstrat-docs/content/docs/risk-and-trust/security-and-audits.mdx` | [GitHub](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/everstrat-docs/content/docs/risk-and-trust/security-and-audits.mdx) |
| Application network/contracts/subgraph config | `frontend-app/web3-app/src/config/index.ts` | [GitHub](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/web3-app/src/config/index.ts) |
| Subgraph deployment input | `frontend-app/web3-app/subgraph/config/deployments/sepolia.json` | [GitHub](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/web3-app/subgraph/config/deployments/sepolia.json) |
| Frontend integration model | `frontend-app/web3-app/README.md` | [GitHub](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/web3-app/README.md) |
| GoldSky entity/event model | `frontend-app/web3-app/subgraph/README.md`, `frontend-app/web3-app/subgraph/docs/subgraph-technical-spec.md` | [README](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/web3-app/subgraph/README.md), [spec](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/web3-app/subgraph/docs/subgraph-technical-spec.md) |
| RPC-versus-indexer responsibility | `frontend-app/everstrat-docs/content/docs/developers/subgraph-and-data-access.mdx` | [GitHub](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/everstrat-docs/content/docs/developers/subgraph-and-data-access.mdx) |

The app and subgraph configs select Ethereum Sepolia (`chainId 11155111`) and publish the following
address snapshot. These values are **configuration claims, not proof of deployment and not a mapping
to target `734df96`**:

| Name | Address |
| --- | --- |
| Registry | `0x88a9692069fF43A439Ff876E28A8df5769175254` |
| EVE | `0xFcf9F72C41E1BfA481d145933486DeF934a6C006` |
| ExitQueue | `0x56d60283b42B8125389eAEc9a3c9AFE04Aa9e8f6` |
| Controller | `0xB4a9F1df239A408998358dE3Ba8e11F0f267da7A` |
| Oracle | `0xce2b65C769479f2CbbFcFf7213EC0917A5b26Dd3` |
| StrategyManager | `0xd4Bb0bEF88b6be67CD3285f8A56fa74839f36728` |
| AMM | `0xad8afa3c697D7D3B87E73e30BD9ADd42098593f6` |
| Converter | `0xacB3567e20418D3B668233cF2eDB31D0801C163F` |
| Timelock | `0x5E19AcCDDedAf0A185C5627f41b1AB98179CC064` |

This is integration context only. No Tier 0 artifact maps those addresses, their proxy
implementations, or their deployed bytecode to standalone target `734df96`. The config also omits
Whitelist, strategies, keeper executors/upkeeps, feeds, pools/routes, multisig membership, and
implementation addresses.

## Documentation drift to resolve before relying on prose

These are context-quality observations, not security findings:

1. Target `README.md` describes Registry as UUPS-upgradeable, while target source defines a
   constructor-deployed non-UUPS Registry; the current architecture diagram calls it static.
2. The monorepo product security page describes an AMM price-deviation checkpoint, while target
   `CLAUDE.md`, architecture docs, freeze runbook, and source say that guard was removed in issue
   `#241`. Product prose is stale for this control.
3. Monorepo app/subgraph config defaults to GoldSky `v0.2.0`, while some product operations pages
   still print `v0.1.0` and direct readers back to config as the source of truth.
4. Several Mermaid files deliberately mix implemented, proposed, future, and legacy designs.
5. The standalone repository contains deployment scripts but no checked-in, target-bound deployment
   receipt/address manifest or proxy implementation map.

## Inputs needed from the project

Before threat modeling or concluding the full audit, request:

1. Approval of [`scope.md`](scope.md), especially its complete-`734df96` snapshot mode, primary
   deployment-script scope, and context-only treatment of interfaces, tests, and external
   submodules.
2. Intended and currently deployed chains; canonical address manifest; deployment transaction
   hashes; proxy implementation/admin slots; verified bytecode/source links; and whether the Sepolia
   snapshot above is the deployment under review.
3. Actual Registry registrations and role memberships, timelock delay/roles, DAO/security multisig
   thresholds and signers, keeper/upkeep/forwarder addresses, and emergency-operation ownership.
4. Live economic/configuration values: connector weight, fees, queue limits, reserves/exit-liquidity
   target, supported ERC-20s, strategy set/caps/priorities, and whitelist state/signers.
5. Oracle feed/pair-feed addresses, denomination, heartbeat and configured staleness for every token;
   Uniswap factory/router/pool/fee tier/routes/TWAP windows; and WETH address for each chain.
6. Off-chain components in scope: invite-signing/reservation backend, relayer, Chainlink upkeep
   operations, monitoring/alerts, frontend, GoldSky subgraph, and incident-response procedures.
7. Any private prior audit/report, formal specification, accepted-risk register, remediation matrix,
   or deployment ceremony artifact not present in the repositories.
