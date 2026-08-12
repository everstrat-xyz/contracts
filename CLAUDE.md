# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a blockchain DeFi protocol called "Everything Strategy" that enables users to deposit native ETH and receive EVE tokens through a bonding curve mechanism. The protocol uses Chainlink oracles for ETH/USD price feeds and implements a sophisticated redemption queue system.

## Repository Structure

Standalone Foundry contracts repo for the EverStrat / "Everything Strategy" protocol (migrated from the `hackerhouse` monorepo `smart-contracts/` tree).

- `src/`: Solidity smart contracts
  - `contracts/AMM.sol`: Core AMM implementation (ETH-only)
  - `contracts/Whitelist.sol`: Invite-gated entry whitelist (static; EIP-712 vouchers)
  - `contracts/EVE.sol`: Protocol token (ERC20)
  - `contracts/Controller.sol`: Protocol controller
  - `contracts/ExitQueue.sol`: Redemption queue manager
  - `contracts/StrategyManager.sol`: Strategy and NAV management
  - `contracts/Oracle.sol`: Price feed oracle
  - `contracts/registry/Registry.sol`: Protocol address book and role authority
  - `contracts/strategies/UniCLStrat.sol`: Uniswap V3 concentrated liquidity strategy
  - `contracts/Converter.sol`: Shared DEX swap and WETH wrapping/unwrapping module
  - `contracts/adapters/UniswapV3ConverterAdapter.sol`: Uniswap V3 adapter for the Converter
  - `contracts/automation/KeeperExecutorBase.sol`: Shared base for Chainlink Automation keeper executors
  - `contracts/automation/QueueKeeperExecutor.sol`: Chainlink Automation executor for the redemption queue
  - `contracts/automation/StrategyKeeperExecutor.sol`: Chainlink Automation executor for strategy operations
  - `interfaces/`: Contract interfaces
    - `IStrategyManager.sol`: StrategyManager interface
    - `IStrategy.sol`: Strategy contract interface
    - `IOracle.sol`: Oracle interface
    - `IAMM.sol`: AMM interface
    - `IWhitelist.sol`: Whitelist interface
    - `IController.sol`: Controller interface
    - `IExitQueue.sol`: ExitQueue interface
    - `IConverter.sol`: Converter interface
    - `IConverterAdapter.sol`: Generic DEX adapter interface
    - `automation/IKeeperExecutorBase.sol`: Shared keeper executor interface (forwarder, pause)
    - `automation/IQueueKeeperExecutor.sol`: QueueKeeperExecutor interface
    - `automation/IStrategyKeeperExecutor.sol`: StrategyKeeperExecutor interface
    - `strategies/IUniCLStrat.sol`: UniCLStrat interface
    - `integrations/IWETH.sol`: WETH interface
    - `integrations/uniswap/IUniswapV3Router.sol`: Uniswap V3 SwapRouter interface
    - `integrations/IQuoter.sol`: Uniswap V3 quoter interface
  - `libraries/`: Utility libraries (Math, Auth)
    - `libraries/integrations/uniswap/`: Shared Uniswap V3 libraries (TickMath, FullMath, LiquidityAmounts, TickUtils, FixedPoint96, UniswapV3Path) used by UniCLStrat and the UniswapV3ConverterAdapter
- `test/`: Contract tests using Forge
- `script/`: Deployment and interaction scripts
- `lib/`: Dependencies
  - `forge-std`: Testing utilities
  - `openzeppelin-contracts-upgradeable`: Upgradeable contract implementations
  - `chainlink-evm`: Chainlink oracle contracts
- `docs/`: Protocol docs (`FREEZE_RUNBOOK.md`, `STRATEGY_GUARDRAILS.md`, `WHITELIST.md`)
- `mermaid/`: Architecture documentation and simple checker
  - `mermaid-smart-contracts.md`: Mermaid diagrams documenting current and future architecture
  - `scripts/`: Simple architecture checker
    - `simple-architecture-checker.ts`: Minimal tool to check PR changes against architecture
    - `package.json`: Node.js dependencies (just @octokit/rest)

## Product Requirements

The protocol implements the following user-facing features:

1. **Token Entry**: Users deposit native ETH to receive EVE tokens via bonding curve (ETH-first pricing, no oracle in hot path). Entry is gated by the protocol `Whitelist` while the invite period is active (`AMM.enter` requires `isWhitelisted`; first-time admission can use `AMM.enterWithInvite` with a server-signed EIP-712 voucher). `AMM.exit` is never gated.
2. **Token Exit**: Users can redeem EVE tokens for ETH (immediate or queued via ExitQueue with pull-over-push claim step) (ETH-first pricing, no oracle in hot path)
3. **Price Discovery**: Dynamic pricing based on NAV and connector weight (calculated in ETH terms)
4. **ETH Support**: Native ETH deposits with ETH-first calculations (oracle only used for bootstrap validation and USD price views)
5. **Redemption Queue**: Queued redemption system via ExitQueue for insufficient liquidity with slippage protection
6. **Portfolio View**: Users can view their stake amount and ownership share
7. **Price Chart**: Display EVE token price over time
8. **TVL Display**: Show total value locked in the protocol

## Common Commands

### Foundry

Run from the repository root:

- **Build contracts**: `forge build`
- **Run tests**: `forge test`
- **Run tests with gas report**: `forge test --gas-report`
- **Run specific test**: `forge test --match-test testFunctionName`
- **Format code**: `forge fmt`
- **Generate gas snapshots**: `forge snapshot`
- **Start local node**: `anvil`
- **Deploy script**: `forge script script/ScriptName.s.sol:ScriptName --rpc-url <rpc_url> --broadcast`

## Upgrade Pattern

The protocol uses the **UUPS (Universal Upgradeable Proxy Standard)** pattern for upgradeability:

- **Benefits**: Allows fixing bugs and adding features without redeploying
- **Security**: Only the contract owner can authorize upgrades
- **Implementation**: Uses OpenZeppelin's `UUPSUpgradeable` and `OwnableUpgradeable`
- **Proxy Pattern**: ERC1967Proxy delegates calls to implementation contracts
- **Storage Safety**: Includes storage gaps to prevent storage collisions in upgrades

When implementing new contracts that need upgradeability:
1. Inherit from `Initializable`, `UUPSUpgradeable`, and `OwnableUpgradeable`
2. Use `initialize()` instead of constructor
3. Add `_authorizeUpgrade()` function with `onlyOwner` modifier
4. Include storage gap: `uint256[50] private __gap;`
5. Mark overridable functions as `virtual`

## Governance Model (PL-003: Timelocked Privileged Actions)

All privileged actions authorize through Registry roles, and in production every privileged role is held by an OpenZeppelin `TimelockController` — no EOA or multisig can act on the protocol directly:

| Role | Holder | Delay | Scope |
|------|--------|-------|-------|
| `SECURITY_ROLE` | security multisig | none | Emergency response (no timelock): `pause()` on AMM, Controller, ExitQueue, StrategyManager, UniCLStrat, and Registry (a Registry pause also freezes role grants), plus the emergency capital-recovery paths `Controller.emergencyExitToAMM()` (sweep idle Controller ETH to the AMM), `StrategyManager.emergencyWithdrawToController()` (sweep idle StrategyManager ETH back to the Controller), and `UniCLStrat.emergencyExit()` (sweep a paused strategy's held funds back to StrategyManager; the pool unwind itself happens best-effort at `pause()` time), plus `StrategyManager.removeSupportedERC20()` (instant stale-feed / dust-NAV unfreeze; `addSupportedERC20` stays ADMIN-only), plus `Whitelist.removeSigner()` (instant revoke of a leaked invite-signing key; `addSigner` stays ADMIN-only). Cannot unpause, configure, or upgrade. |
| `ADMIN_ROLE` | 48h `TimelockController` | 48h | Configuration (`setConnectorWeight`, `setMinBatchExitETH`, StrategyManager `addStrategy` / weight setters / strategy remove), Oracle feed/token configuration, strategy add/remove, Whitelist invite-period admin (`addSigner`, `addToWhitelist`, `removeFromWhitelist`, irreversible `disable()`), Registry contract registration (address rewiring), role management, `unpause`, and UUPS upgrades. |
| `KEEPER_ROLE` / `MINTER_ROLE` | QueueKeeperExecutor + StrategyKeeperExecutor / AMM (+ StrategyManager for fee mint) | none | Operational roles, granted through the 48h timelock after finalize (or by deployer bootstrap before finalize). |

Design decisions:
- **No dedicated upgrader role** (team minimizes the role surface): UUPS upgrades share `ADMIN_ROLE`/48h. Longer upgrade delays (e.g. 72h) are enforced by scheduling policy — `TimelockController` only enforces the minimum, and the proposer schedules upgrades with a longer delay.
- **DAO multisig holds no direct protocol role.** It is the PROPOSER (and CANCELLER) on both timelocks; execution is open (`address(0)` executor) once the delay elapses.
- **Security = circuit breaker**: instant `pause()` everywhere and the emergency capital-recovery paths (`Controller.emergencyExitToAMM()`, `StrategyManager.emergencyWithdrawToController()`, `UniCLStrat.emergencyExit()`), plus `StrategyManager.removeSupportedERC20()` (stale-feed / dust-NAV escape hatch; add stays ADMIN-only), plus `Whitelist.removeSigner()` (instant invite-signer revoke; add stays ADMIN-only), plus CANCELLER_ROLE on both timelocks to kill malicious queued operations. It can never propose, execute, configure, or unpause.
- **Deployment** (`script/DeployAll.s.sol` / `ProtocolDeployBase`): the 48h admin timelock is deployed first, the Registry is constructed with it as its designated admin (the constructor rejects `_admin == msg.sender`, so the deployer key cannot be the designated admin), the deployer bootstraps wiring (including the initial Oracle feed, Whitelist, and both keeper executors) with its temporary Registry ADMIN grant and renounces everything at the end. The modular flow mirrors this: `DeployRegistry` deploys the admin timelock + Registry (timelock as designated admin, DAO as proposer); later steps read `TIMELOCK_ADDRESS`; `DeployWhitelist` registers `WHITELIST` and may seed `WHITELIST_SIGNER_ADDRESS`; `DeployKeeperExecutors` registers both executors under `QUEUE_KEEPER_EXECUTOR` / `STRATEGY_KEEPER_EXECUTOR`, grants them `KEEPER_ROLE`, and applies `EXIT_LIQUIDITY_TARGET_ETH` / `CONTROLLER_RESERVE_ETH` (required wei env; `0` is a valid explicit choice). Env (required, never defaulted to the deployer): `DAO_ADDRESS`, `SECURITY_ADDRESS`, `DAO_TREASURY_ADDRESS`, `EXIT_LIQUIDITY_TARGET_ETH`, `CONTROLLER_RESERVE_ETH`, `WHITELIST_SIGNER_ADDRESS` (explicit `address(0)` postpones invite-signer seeding); optional numeric: `TIMELOCK_ADMIN_DELAY` (default 48h), `PERFORMANCE_FEE_BPS` (default 0).
- Tests: `test/integration/TimelockGovernance.t.sol`.

## Smart Contract Architecture

The protocol implements the following core contracts:

0. **Registry Contract** (Registry)
   - Static (non-upgradeable) contract serving as the protocol's contract address book and role authority.
   - **Contract Registration**: Maps keccak256 hashed keys (e.g. `Auth.CONTROLLER`, `Auth.AMM`, `Auth.STRATEGY_MANAGER`) to contract addresses via `registerContract()`/`registerContracts()`. All protocol contracts resolve peers through the Registry.
   - **Role Management**: Extends OpenZeppelin `AccessControlEnumerable`. Role admin relationships are set in the constructor:
     - `ADMIN_ROLE`: Self-administered. Controls all other role admins.
     - `KEEPER_ROLE`: Admin is `ADMIN_ROLE`.
     - `MINTER_ROLE`: Admin is `ADMIN_ROLE`.
     - `SECURITY_ROLE`: Admin is `ADMIN_ROLE`. Emergency circuit breaker — immediate `pause()` everywhere plus the emergency capital-recovery paths `Controller.emergencyExitToAMM()`, `StrategyManager.emergencyWithdrawToController()`, and `UniCLStrat.emergencyExit()`, plus `StrategyManager.removeSupportedERC20()` and `Whitelist.removeSigner()` (see Governance Model).
     - `CONVERTER_CALLER_ROLE`: Admin is `CONVERTER_CALLER_MANAGER_ROLE` (held by the Converter).
     - `CONVERTER_CALLER_MANAGER_ROLE`: Admin is `ADMIN_ROLE`.
   - **Batch Role Operations**: `grantRoles()`/`revokeRoles()` perform per-entry `_checkRole(getRoleAdmin(_roles[i]))` — the caller must be the admin of every role in the batch or the entire call reverts. All four role mutators (`grantRole`, `grantRoles`, `revokeRole`, `revokeRoles`) reject `address(0)` with `RegistryZeroAddress`, so batch operations validate identically to their single-item counterparts.
   - **Pausable**: `pause` is callable by `ADMIN_ROLE` or `SECURITY_ROLE` (security pause is immediate and also freezes role grants); `unpause` is ADMIN-only so re-opening always routes through the admin timelock. `registerContract`, `deregisterContract`, `grantRole`, `revokeRole`, `grantRoles`, `revokeRoles` are gated by `whenNotPaused`. `renounceRole` is intentionally not pausable so holders can always voluntarily exit roles.
   - **Clients**: Protocol contracts inherit `RegistryClient` (static) or `RegistryClientUpgradeable` (ERC-7201 namespaced registry storage), from `src/contracts/registry/client/`. Modifiers: `onlyAuthRole`, `onlyEitherAuthRole` (either-of-two roles, used for ADMIN-or-SECURITY pause gates), `onlyAuthContract`.
   - **Role Registration**: Auto-registers/unregisters roles as their member count changes (for on-chain enumeration via `getRoles()`).
   - **UUPS Note**: The Registry is NOT upgradeable (static). It serves as a stable root of trust.
   - **Clients**: Protocol contracts inherit `RegistryClient` (static) or `RegistryClientUpgradeable` (ERC-7201 namespaced registry storage), from `src/contracts/registry/client/`. Modifiers: `onlyAuthRole`, `onlyEitherAuthRole` (either-of-two roles, used for ADMIN-or-SECURITY pause gates), `onlyAuthContract`.
   - Role: ADMIN_ROLE (constructor-granted to `_admin` — the designated admin, the admin timelock in production — and to `msg.sender` as a temporary bootstrap grant; the constructor reverts with `RegistryAdminIsDeployer` when `_admin == msg.sender`, so renouncing the bootstrap grant can never leave the Registry admin-less)
   - Errors: `RegistryZeroAddress`, `RegistryAdminIsDeployer`, `RegistryContractNotRegistered`, `RegistryContractNoCode`, `RegistryInvalidLength`
   - Version: 1.0.0
   - Location: `src/contracts/registry/Registry.sol`
   - Tests: `test/unit/Registry.t.sol`; tree: `test/trees/Registry.tree` (also exercised through all protocol unit and integration tests)

1. **Oracle Contract** (Oracle)
 - Upgradeable oracle using UUPS (Universal Upgradeable Proxy Standard)
 - **Token support = Token / USD feed registration.** There is no separate `addToken` API: the first `updateUsdFeedInfo(token, feed, staleness)` call validates the feed, stores `FeedInfo`, adds the token to the supported set, and emits `UsdFeedAdded`. Later calls update the feed/staleness (`UsdFeedUpdated` / `UsdStalenessIntervalUpdated`). `isTokenSupported(token)` is true iff that USD registration is present. `removeToken(token)` is the inverse (clears USD feed + outbound/inbound pair feeds, emits `PairFeedRemoved` then `TokenRemoved`). Native ETH = `address(0)`.
 - Chainlink `latestRoundData()` with fail-closed validation in `_getPriceWithStalenessCheck()`:
   - `OracleNoRoundData`: `updatedAt == 0`
   - `OracleInvalidTimestamp`: `updatedAt > block.timestamp`
   - `OracleStalePrice`: price older than staleness interval
   - `OracleInvalidPrice`: `answer <= 0`
   - `OracleInvalidFeedDecimals`: feed `decimals() > 18` on add/update
 - **Per-token storage (`TokenInfo`)**: required `usdFeedInfo` + optional `pairFeedInfo` map + `supportedPairs` set. Absolute USD APIs: `getUsdPrice`, `getUsdPriceWithStalenessCheck`, `getUsdFeedInfo`, `convertTokenToUSD`, `convertUsdToToken`.
 - **Optional Token A / Token B pair feeds** (overlay only): `updatePairFeedInfo` requires both tokens already USD-supported; feed quotes A in B terms. Views: `isPairSupported`, `getSupportedPairs`, `getPairFeedInfo`, `getPairPrice`, `getPairPriceWithStalenessCheck`. `removePairFeedInfo` does not affect USD support. Pair feeds alone never make a token supported.
 - **`convert(in, out, …)` preference**: (1) direct pair, (2) inverted pair, (3) USD cross-rate `amountIn * priceIn / priceOut` (one division). A registered but stale/invalid pair feed reverts — no silent USD fallback. Used by UniswapV3ConverterAdapter and UniCLStrat for WETH ↔ paired-token pricing.
 - **USD-quote invariant (PLM-2, issue #194)**: every feed registered via `updateUsdFeedInfo` MUST quote its token in USD ("<BASE> / USD"); the `convert()` USD cross-rate fallback routes through USD (two feeds, two staleness surfaces). Pair feeds are exempt — they quote base in quote-token terms by definition. NOT enforced on-chain — `description()` is advisory metadata (spoofable, and legitimate USD-quoted wrappers may not follow the naming convention). Deploy scripts fail closed via `ProtocolDeployBase._assertUsdQuotedFeed` (`description()` must end with `" / USD"`; used by `DeployOracle` / `DeployAll`); timelocked feed updates must be reviewed against the same checklist (USD quote, decimals <= 18, staleness interval matches feed heartbeat). Token-to-token conversions must use `convert()` (never chain `convertTokenToUSD` -> `convertUsdToToken`); all remaining `convertTokenToUSD` call sites are one-way ETH->USD (AMM pricing, StrategyManager USD NAV) — `convertUsdToToken` has no protocol call sites
 - Role: `ADMIN_ROLE` on Registry (feed/pair configuration and UUPS upgrades)
 - Version: 1.1.0
 - Location: `src/contracts/Oracle.sol`
 - Interface: `src/interfaces/IOracle.sol`
 - Tests: `test/unit/Oracle.t.sol`, `test/fuzz/OracleFuzz.t.sol`; tree: `test/trees/Oracle.tree`
 - Deployment: `script/DeployOracle.s.sol` (bootstrap ETH USD feed via temporary deployer ADMIN)

2. **Controller Contract** (Controller)
   - Upgradeable controller using UUPS (Universal Upgradeable Proxy Standard)
   - AccessControl-based permissions (ADMIN_ROLE, KEEPER_ROLE, DEPLOYER_ROLE). DEFAULT_ADMIN_ROLE is intentionally NOT granted in Controller — it gates no function and granting an inert role only creates cognitive overhead. Deploy scripts skip the Controller-side DEFAULT_ADMIN_ROLE teardown accordingly.
   - **ETH Receiver:** Receives ETH from AMM when users enter the protocol
   - **Keeper Functionality:** `KEEPER_ROLE` on Registry — deposit funds to strategies, withdraw from strategies, rebalance, provide exit liquidity, manage redemption queue
   - **AMM Operations:** `processRedemption()` on AMM — caller must be registered `CONTROLLER` on Registry
   - **ExitQueue Operations:** `priceBatch()` — caller must be registered `CONTROLLER` on Registry
   - **StrategyManager Coordination:** fund deposit/withdraw/rebalance — caller must be registered `CONTROLLER` on Registry
   - **Peer resolution:** AMM, StrategyManager, ExitQueue, EVE resolved via `Auth` at call time (no `setAMM` / `setStrategyManager`; no stored peer addresses)
   - **Deficit-Based Top-Up Pattern:** `depositToStrategies` and `depositToStrategy` call `_fundStrategyManagerIfNeeded(_amount)` before StrategyManager. Helper sends `deficit = _amount > address(strategyManager).balance ? _amount - address(strategyManager).balance : 0`. `_validateDeposit` reverts with `ControllerInsufficientBalance` only when `controller.balance < deficit`, not when `controller.balance < _amount`. Pre-existing ETH on SM reduces required Controller balance; excess on SM stays in NAV for later deposits
   - Keeper functions: `depositToStrategies`, `depositToStrategy`, `withdrawFromStrategies`, `withdrawFromStrategy`, `checkAndRebalanceStrategies`, `checkAndRebalanceStrategy`, `syncStrategies`, `syncStrategy`, `provideExitLiquidity`, `harvestPerformanceFeeFromStrategy`, `harvestPerformanceFeeFromStrategies`
   - Redemption queue functions: `priceBatch`, `processRequest`, `processRequests`
   - Performance fee harvest (`ADMIN_ROLE` or `KEEPER_ROLE` on Registry): delegates to StrategyManager; emits `DirectPerformanceFeeHarvestCompleted` / `PerformanceFeeHarvestCompleted`
   - Emergency functions: `emergencyExitToAMM()` (`ADMIN_ROLE` or `SECURITY_ROLE` on Registry — sweeps Controller ETH to AMM), `pause()` (`ADMIN_ROLE` or `SECURITY_ROLE`), `unpause()` (`ADMIN_ROLE`)
   - Events: `ControllerInitialized(registry)`, `DepositToStrategiesCompleted`, `DirectDepositCompleted`, `WithdrawalCompleted`, `DirectWithdrawalCompleted`, `ExitLiquidityProvided`, `EmergencyExitedToAMM`, `DirectPerformanceFeeHarvestCompleted`, `PerformanceFeeHarvestCompleted`
   - Errors: `ControllerZeroAmountRequested`, `ControllerInsufficientBalance` (interface may still list legacy `ControllerZeroAddress` / `ControllerNoCode` — wiring is on Registry, not Controller setters)
   - Version: 1.0.0
   - Location: `src/contracts/Controller.sol`
   - Tests: `test/unit/Controller.t.sol` (comprehensive test suite)
   - Deployment: `script/DeployController.s.sol`

3. **ExitQueue Contract** (ExitQueue)
   - Upgradeable redemption queue manager using UUPS (Universal Upgradeable Proxy Standard)
   - Implementation constructor calls `_disableInitializers()` (prevents initializing the implementation directly)
   - AccessControl-based permissions (ADMIN_ROLE, AMM_ROLE, CONTROLLER_ROLE, DEPLOYER_ROLE). `DEPLOYER_ROLE` is the admin of `AMM_ROLE` and `CONTROLLER_ROLE` (granted to the deployer in `initialize()` to grant those roles during deployment, then renounced); `DEFAULT_ADMIN_ROLE` is never granted, so `DEPLOYER_ROLE` can never be granted to anyone and those role assignments freeze after the deployer renounces. `ADMIN_ROLE` is self-administered for ongoing pause/unpause/upgrade
   - **Batch Management:** Groups redemption requests into batches for efficient processing
   - **Slippage Protection:** Price tolerance checks to protect users from unfavorable price movements
   - **Pausable:** Can be paused by ADMIN_ROLE or SECURITY_ROLE (`pushRequest`, `pullRequest`, and `priceBatch` are paused; `closeRequest` works when paused for emergency withdrawals)
   - **Request Closure Restriction:** After a batch is priced (`canBeProcessed == true`), requests cannot be closed **within** `MAX_BATCH_PROCESSING_TIME` of `pricedAt`. Within that window, all requests must be processed via `pullRequest()`. This ensures liquidity commitment and prevents users from gaming the system by canceling after seeing the final price.
   - **Upper Bound / Escape Hatch:** If more than `MAX_BATCH_PROCESSING_TIME` has passed since the batch was priced (`pricedAt`), users may close their requests via `closeRequest()`. This allows users to recover if the AMM/keeper does not process the batch in time.
  - **batchInfo()** returns `canBeProcessed`, `finalEvePrice`, `totalTokensToBurn`, `createdAt`, and **`pricedAt`** (timestamp when the batch was priced; zero if not yet priced).
  - AMM functions: pushRequest(), pullRequest(), closeRequest() returns (bool _viaEscapeHatch) — push/pull gated by `whenNotPaused`; closeRequest works when paused
  - Controller functions: priceBatch() — gated by `whenNotPaused`
  - View functions: batchInfo(), requestInfo(), requestCanBeClosed(), unprocessedUsersCount(), unprocessedUsers(), MAX_BATCH_PROCESSING_TIME()
  - Events: BatchPriced, RequestPushed, RequestPulled, RequestClosed(batchId, user, viaEscapeHatch)
   - Errors: ExitQueueZeroAddress, ExitQueueZeroPrice, ExitQueueBatchCannotBeProcessed, ExitQueueBatchIsEmpty, ExitQueueRequestNotInBatch, ExitQueueRequestAlreadyProcessed, ExitQueueRequestCannotBeClosed, ExitQueueRequestAlreadyInBatch, ExitQueueInvalidRange
   - Version: 1.0.0
   - Location: `src/contracts/ExitQueue.sol`
   - Interface: `src/interfaces/IExitQueue.sol`
   - Tests: `test/unit/ExitQueue.t.sol` (comprehensive test suite)
   - Deployment: `script/DeployAll.s.sol`

4. **EVE Token Contract** (EVE)
   - Static (immutable) ERC20 token contract
   - AccessControl-based permissions (MINTER_ROLE, DEPLOYER_ROLE). `DEPLOYER_ROLE` is the admin of `MINTER_ROLE` (granted to the deployer in the constructor to grant MINTER_ROLE to the AMM, then renounced); `DEFAULT_ADMIN_ROLE` is never granted, so `DEPLOYER_ROLE` can never be granted to anyone and MINTER_ROLE assignment freezes after the deployer renounces
   - Mintable and Burnable by MINTER_ROLE
   - Token name: "Everything Strategy", Symbol: "EVE"
   - Decimals: 18
   - Location: `src/contracts/EVE.sol`
   - Tests: `test/unit/EVE.t.sol` (comprehensive test suite)

5. **AMM Contract** (AMM)
   - Core protocol logic for ETH entry/exit
   - Implements bonding curve pricing mechanism
   - Native ETH support with ETH-first price calculations
   - **Oracle Usage**: Oracle is NOT used in enter/exit operations (hot path). Oracle is only used for:
     - Bootstrap minimum deposit validation (converts ETH to USD to check MIN_INITIAL_DEPOSIT_USD)
     - USD price view functions (`eveBasePriceInUSD()`, `evePremiumPriceInUSD()`)
   - ExitQueue integration for queued redemptions
   - **Batch Exit Minimum**: `minBatchExitETH` (default 0.001 ETH) enforced only on the queued exit path; immediate exit has no minimum. Admin-configurable via `setMinBatchExitETH()` (0 disables; capped at `MIN_BATCH_EXIT_ETH_UPPER_BOUND` = 0.05 ETH).
   - Connector weight-based pricing
   - **Split Pricing (inception spec)**: `enter()` (mint) prices at `premium_price = NAV/(supply·cw)` and `exit()` (burn) prices at `base_price = NAV/supply` (formulas in `Math.premiumPrice`/`Math.basePrice`). Minting pays the bonding-curve premium; burning redeems at the NAV-backed base price so EVE is always redeemed against its backing and the base price grows with supply as the retained premium accrues to remaining holders. `Controller.priceBatch()` settles queued batches at `eveBasePriceInETH()` (same base price as immediate exit). Views: `eveBasePriceInETH()`, `evePremiumPriceInETH()`, `eveBasePriceInUSD()`, `evePremiumPriceInUSD()`.
   - **No on-chain price deviation guard**: the base-price checkpoint guard (`lastSettledBasePrice` + `maxPriceDeviation` + once-per-block rule) was removed (#241) — its only rationale was catching NAV calculation bugs, at the cost of freezing the AMM on legitimate large NAV moves. Price protection relies on strategy-layer defenses (TWAP/slippage/tick bounds), premium pricing, user slippage params (`minTokensToMint`/`maxTokensToBurn`), and `SECURITY_ROLE` `pause()`. The strategy layer is now the sole on-chain defense boundary against NAV manipulation — every strategy must satisfy the Strategy Guardrail Standard (`docs/STRATEGY_GUARDRAILS.md`, #244): mandatory guardrails with per-item compliance status, pre-deployment audit checklist (gate for `addStrategy`), governance-attack mitigations, monitoring requirements, and incident response. Large-NAV-move anomaly detection is off-chain (indexer/dashboard monitoring — see `docs/FREEZE_RUNBOOK.md` §6).
   - Bootstrap mechanism for initial liquidity
   - **Enter CEI**: Post-bootstrap `_enter` mints EVE before `payable(controller).sendValue(msg.value)` (bootstrap already did); avoids a window where deposit ETH is already in Controller NAV but supply has not yet increased, which any `receive` observer could see
   - **Entry Whitelist Gate**: While the Registry `WHITELIST` contract's invite period is active, `enter()` requires `isWhitelisted(msg.sender)` and reverts with `AMMNotWhitelisted` otherwise. First-time admission can use `enterWithInvite(_minTokensToMint, _inviteId, _deadline, _signature)`, which redeems a server-signed EIP-712 voucher via `Whitelist.whitelist(msg.sender, …)` then mints in the same tx (voucher is bound to `msg.sender`). After `Whitelist.disable()`, both paths behave as open entry. `exit()` never consults the Whitelist.
   - **Pull-over-Push Redemption**: `processRedemption()` credits ETH to `claimableBalances[user]` instead of pushing directly, preventing malicious recipients from blocking batch processing. Users must call `claim()` to pull their ETH. Excess `msg.value` is always returned to the Controller.
   - **Free Balance Tracking**: `freeBalance()` returns `address(this).balance - lockedForClaims`. The `exit()` liquidity check uses `freeBalance()` so locked claim funds are never counted as available liquidity.
   - Storage: `claimableBalances` (mapping address→uint256), `lockedForClaims` (uint256), `minBatchExitETH` (uint256)
   - Access Control: ADMIN_ROLE for setConnectorWeight(), setMinBatchExitETH(), pause(), unpause(); CONTROLLER_ROLE for processRedemption()
   - Key Functions: enter(), enterWithInvite(), exit(), processRedemption(), cancelRedemption(), claim(), freeBalance(), setMinBatchExitETH()
   - Events: UserEntered, RedeemedImmediately, RedemptionQueued, RedemptionProcessed, RedemptionCancelled(user, batchId, viaEscapeHatch, timestamp), Claimed(user, claimableETH, timestamp), Bootstrapped, ConnectorWeightChanged(initial=0 on deploy), MinBatchExitETHChanged(initial=0 on deploy)
   - Errors: AMMNotWhitelisted (enter while invite gate active and caller not whitelisted), AMMNoClaimableBalance (thrown by claim() when claimableBalances[msg.sender] == 0), AMMTooLowBatchExitETH (queued exit below minBatchExitETH), AMMInvalidMinBatchExitETH (setMinBatchExitETH above MIN_BATCH_EXIT_ETH_UPPER_BOUND)
   - Version: 1.0.0
   - Location: `src/contracts/AMM.sol`
   - Tests: `test/unit/AMM.t.sol`, `test/unit/AMMWhitelist.t.sol`

6. **StrategyManager Contract** (StrategyManager)
   - Upgradeable manager using UUPS (Universal Upgradeable Proxy Standard)
   - Manages external investment strategies and NAV calculations
   - Role-based access control (ADMIN_ROLE, CONTROLLER_ROLE, DEPLOYER_ROLE). `DEPLOYER_ROLE` gates the one-time `setAMM()` wiring (granted to the deployer in `initialize()`, then renounced); `DEFAULT_ADMIN_ROLE` is never granted, so `DEPLOYER_ROLE` can never be granted to anyone and the AMM address freezes after the deployer renounces. `ADMIN_ROLE` is self-administered for ongoing strategy management
   - Strategy registration and management (add/remove strategies)
   - Fund deposit to strategies based on StrategyManager-owned deposit weights (receives ETH from Controller)
   - Fund withdrawal from strategies based on StrategyManager-owned withdrawal weights (withdraws to Controller; events and return values reflect net ETH received by Controller)
   - Remaining ETH handling: Returns unused ETH back to Controller if deposit is incomplete
   - **ETH-First NAV Calculation**: NAV in ETH first, USD via Oracle when needed. Total NAV = sum of `strategy.navInETH()` (any revert freezes protocol) + StrategyManager ETH balance + Controller ETH balance + AMM `freeBalance()` (excludes `lockedForClaims`) + ETH value of each whitelisted supported-ERC-20 balance (via `Oracle.convert(token, address(0), balance, IERC20Metadata.decimals(), 18)`). **`_totalNAVInETH()` reverts if any strategy's `navInETH()` reverts** — prevents minting EVE at a discount on under-reported NAV
   - **Supported-ERC-20 Whitelist**: EnumerableSet of ERC-20 tokens the StrategyManager may hold (e.g. paired tokens delivered by `UniCLStrat.emergencyExit()`). Whitelisted balances are priced into NAV so users never enter/exit at prices that ignore recoverable value. Zero balances skip the Oracle entirely (no gas, no freeze risk); a non-zero balance with a stale/invalid feed **freezes NAV** (fail-closed, same philosophy as a reverting strategy `navInETH()`) — runbook: `removeSupportedERC20()` is the escape hatch (`ADMIN_ROLE` or `SECURITY_ROLE`; allowed with a non-zero balance; drops that value out of NAV immediately; makes no external calls so a bricked token cannot block its own removal). `addSupportedERC20()` is `ADMIN_ROLE`-only (validates non-zero address, code presence, and Oracle priceability (`StrategyManagerERC20NotPriceable`)); whitelist a strategy's paired token when the strategy is added, not during the emergency. Both mutators work while paused. Views: `supportedERC20()`, `isSupportedERC20()`. **Future work:** on-chain swap recovery of stranded supported ERC-20s back to native ETH via the shared Converter (`recoverTokenToETH`) is deferred to a follow-up PR — this release ships ERC-20 accounting only.
   - **Strategy Removal Guards**: `removeStrategy()` requires a successful `navInETH()` read and reverts with `StrategyManagerStrategyNAVResidueTooHigh` if `nav > MAX_NAV_RESIDUE` (10 wei). A reverting `navInETH()` bubbles up. Emits `StrategyRemoved(strategy)`. Callable while paused (unlike `addStrategy()`). Both removal paths share `_deregisterStrategy()` (best-effort `revokeCallerRole` via Converter — emits `CallerRoleRevokeFailed` on failure; does **not** clear `lastStrategyWithdrawal`, so deposit cooldown survives remove → re-add). `forceRemoveStrategy()` (ADMIN_ROLE, 48h timelock in production) skips the residue check entirely — the escape hatch for a strategy whose `navInETH()` over-reports or reverts and could otherwise never be removed; reads NAV via `try/catch` for reporting only, emits `StrategyForceRemoved(strategy, reportedNAV, navReverted)`; capital recovery via `IStrategy.emergencyExit()`. Does not require the strategy to be paused.
     - **Performance Fees (StrategyManager-level)**: Strategy-local LP-fee accounting via `IStrategy.pendingPerformanceFeeInETH` / `settlePerformanceFee`. Settlement mints EVE to `daoTreasury` via bonding-curve dilution (`evesToMint = totalFeeETH * supply / (totalNAV - totalFeeETH)`) in **one mint per harvest batch** (explicit harvest or multi-strategy withdraw). Withdrawals batch-harvest accrued fees first. Paused strategies return zero pending/settled fees (internal counters preserved until unpaused); `emergencyExit()` writes off pending local fees (charged = earned after any best-effort accrue) after sweep. Fees disabled when `performanceFeeBps == 0`; treasury must always be non-zero (`FeeConfig` at init, `setDaoTreasury()`). Requires `MINTER_ROLE` on Registry for harvest paths. **Entry point:** `Controller.harvestPerformanceFeeFromStrategy(s)` (`ADMIN_ROLE` or `KEEPER_ROLE`); StrategyManager harvest is `CONTROLLER`-only.
   - **Constants**: `MAX_NAV_RESIDUE = 10 wei`, `MAX_PERFORMANCE_FEE_BPS = 2_000` (20%), `MAX_DEPOSIT_WEIGHT = 100`, `MAX_WITHDRAWAL_WEIGHT = 100`
   - **Allocation weights (#252)**: `depositWeight` / `withdrawalWeight` live as StrategyManager mappings (not on strategies). Proportional — need not sum to 100. Weight `0` is allowed (registered but excluded from batch allocation). Admin setters: `setDepositWeight`, `setWithdrawalWeight`, `setStrategyWeights` (atomic multi-strategy). Cleared on remove/force-remove.
   - Oracle integration for ETH/USD conversion (only when USD values are needed)
   - Version: 1.0.0
   - Location: `src/contracts/StrategyManager.sol`
   - Interface: `src/interfaces/IStrategyManager.sol`
   - Tests: `test/unit/StrategyManager.t.sol` (comprehensive test suite)
   - Key Functions:
     - `initialize(address _registry, FeeConfig _feeConfig)`: Wire registry and fee config (non-zero `daoTreasury`; `performanceFeeBps` may be 0)
     - `addStrategy(address, uint8 depositWeight, uint8 withdrawalWeight)`: Register strategy with allocation weights (`ADMIN_ROLE` on Registry). Reverts on zero address, no code, or weight > max
     - `setStrategyWeights(address[], uint8[], uint8[])` / `setDepositWeight` / `setWithdrawalWeight`: Admin rebalance of allocation weights (`ADMIN_ROLE`); prefer batch setter for multi-strategy changes
     - `removeStrategy(address)`: Remove strategy (`ADMIN_ROLE` on Registry). Requires successful dust-NAV read; residue guard; clears weight mappings; callable while paused. Reverting `navInETH()` bubbles — use `forceRemoveStrategy`
     - `forceRemoveStrategy(address)`: Force-remove a strategy without the NAV residue check (`ADMIN_ROLE` on Registry). Escape hatch for over-reporting or reverting strategies; callable while paused; clears weight mappings; emits `StrategyForceRemoved(strategy, reportedNAV, navReverted)`
     - `depositToStrategies(uint256 _amount)`: Deposit ETH to healthy strategies by `depositWeight`. Non-payable; Controller tops up SM deficit first (`CONTROLLER` caller). Reverts with `StrategyManagerNoStrategiesRegistered` when registry empty; returns `0` when none qualify (`isHealthy() && maxDeposit() > 0`) or all qualifying weights are 0. Batch path: `try/catch` on each `deposit()` — emits `StrategyDepositFailed(strategy, reason)` (`reason` is the revert data) and continues on failure
     - `depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)`: Paginated deposit [startIndex, endIndex); same batch `try/catch` semantics
     - `depositToStrategy(address _strategy, uint256 _amount)`: Deposit to one strategy (`CONTROLLER` caller). Returns `0` + refund when `maxDeposit() == 0`. Strict: reverts if `deposit()` fails
     - `withdrawFromStrategies(uint256 _amount)`: Withdraw proportionally by withdrawal priority (`CONTROLLER` caller). Reverts with `StrategyManagerNoStrategiesRegistered` when registry empty; returns `0` when no `maxWithdrawal() > 0`. Batch path: `try/catch` on each `withdraw()` — emits `StrategyWithdrawFailed(strategy, reason)` (`reason` is the revert data) and continues on failure
     - `withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)`: Paginated withdrawal; same batch `try/catch` semantics
     - `withdrawFromStrategy(address, uint256)`: Withdraw from one strategy (`CONTROLLER` caller). Strict: reverts if `withdraw()` fails
     - `checkAndRebalanceStrategies()`: Rebalance unhealthy, unpaused strategies (`CONTROLLER` caller). Batch path: `try/catch` on each `rebalance()` — emits `StrategyRebalanceFailed(strategy, reason)` (`reason` is the revert data) and continues on failure; skips paused strategies
     - `checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex)`: Paginated rebalance check; same batch semantics
     - `checkAndRebalanceStrategy(address)`: Rebalance one strategy if unhealthy and not paused (`CONTROLLER` caller). No-op when paused. Strict: reverts if `rebalance()` fails
     - `syncStrategies()`: Call `IStrategy.sync()` on all registered strategies (`CONTROLLER` caller); skips paused strategies. Batch path: `try/catch` on each `sync()` — emits `StrategySyncFailed(strategy, reason)` (`reason` is the revert data) and continues on failure
     - `syncStrategies(uint256 _startIndex, uint256 _endIndex)`: Paginated sync; skips paused strategies; same batch `try/catch` semantics
     - `syncStrategy(address)`: Sync one strategy (`CONTROLLER` caller); no-op when paused; strict: reverts if `sync()` fails
     - `emergencyWithdrawToController()`: Sweep idle StrategyManager native ETH back to the Controller (`ADMIN_ROLE` or `SECURITY_ROLE`, `nonReentrant`). Completes the recovery chain `IStrategy.emergencyExit()` → StrategyManager → `emergencyWithdrawToController()` → Controller → `Controller.emergencyExitToAMM()` → AMM. Reverts `StrategyManagerNoBalanceToRecover` when balance is zero
     - `addSupportedERC20(address _token)` / `removeSupportedERC20(address _token)`: Manage the supported-ERC-20 whitelist (`addSupportedERC20` is `ADMIN_ROLE`-only; `removeSupportedERC20` is `ADMIN_ROLE` or `SECURITY_ROLE` for instant stale-feed / dust unfreeze; both work while paused). See **Supported-ERC-20 Whitelist** above for validation, NAV effect, and the dead-feed escape hatch
     - `harvestPerformanceFeeFromStrategy(address)`: Harvest accrued performance fee for one strategy (`CONTROLLER` only). Returns `(eveAmount, feeETHEquivalent)`; emits `PerformanceFeePaid`
     - `harvestPerformanceFeeFromStrategies()`: Harvest all registered strategies in one EVE mint (`CONTROLLER` only). Batch path: `try/catch` on each `settlePerformanceFee()` — emits `StrategyHarvestFailed(strategy, reason)` (`reason` is the revert data) and continues on failure (failed strategies omitted from the mint sum)
     - `harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex)`: Paginated harvest `[startIndex, endIndex)` with one EVE mint (`CONTROLLER` only). Same batch `try/catch` semantics
     - `harvestPerformanceFeeFromStrategy(address)`: Harvest one strategy (`CONTROLLER` only). Strict: reverts if `settlePerformanceFee()` fails
     - `pendingPerformanceFeeInETH(address)`: View pending ETH-denominated LP fees via strategy delegate; returns 0 when strategy is paused; reverts when strategy is not registered
     - `setPerformanceFeeBps(uint256)`: Admin fee rate (0 disables harvesting; max `MAX_PERFORMANCE_FEE_BPS`)
     - `setDaoTreasury(address)`: Admin treasury recipient (non-zero)
   - Pagination: Range [startIndex, endIndex) exclusive end; `endIndex <= strategies.length()`, `startIndex < endIndex`
   - Validation: Deposit/withdrawal weights must be <= 100 (0 allowed)
   - NAV Functions: `totalNAVInETH()` (primary, used by AMM), `totalNAVInUSD()`, `strategyNAVInETH()`, `strategyNAVInUSD()`
   - Events: `StrategyAdded`, `DepositWeightUpdated`, `WithdrawalWeightUpdated`, `StrategyRemoved(strategy)`, `StrategyForceRemoved(strategy, reportedNAV, navReverted)`, `FundsDepositedToStrategy`, `FundsWithdrawnFromStrategy`, `StrategyRebalanced`, `StrategySynced`, `StrategyDepositFailed(strategy, reason)`, `StrategyWithdrawFailed(strategy, reason)`, `StrategyRebalanceFailed(strategy, reason)`, `StrategyHarvestFailed(strategy, reason)`, `StrategySyncFailed(strategy, reason)`, `CallerRoleRevokeFailed(strategy)`, `EmergencyWithdrawnToController(amount)`, `SupportedERC20Added(token)`, `SupportedERC20Removed(token)`, `PerformanceFeePaid(strategy, treasury, eveAmount, feeETHEquivalent)`, `PerformanceFeeBpsChanged(initial, current)` (initial=0 at initialize), `DaoTreasuryChanged(initial, current)` (initial=0 at initialize)
   - Errors: `StrategyManagerStrategyAlreadyRegistered`, `StrategyManagerStrategyNotRegistered`, `StrategyManagerInvalidNAVValue`, `StrategyManagerZeroAddress`, `StrategyManagerNoCode`, `StrategyManagerStrategyNAVResidueTooHigh`, `StrategyManagerNoStrategiesRegistered`, `StrategyManagerInvalidRange`, `StrategyManagerInvalidDepositWeight`, `StrategyManagerInvalidWithdrawalWeight`, `StrategyManagerInvalidLength`, `StrategyManagerNoBalanceToRecover`, `StrategyManagerERC20AlreadySupported`, `StrategyManagerERC20NotSupported`, `StrategyManagerERC20NotPriceable`, `StrategyManagerZeroDaoTreasury`, `StrategyManagerInvalidPerformanceFeeBps`, `StrategyManagerFeeMintOverflow`
   - Deployment: `script/DeployAMM.s.sol` / `DeployAll.s.sol` — `initialize(registry, FeeConfig)` with `DAO_TREASURY_ADDRESS` (required env, no default) and `PERFORMANCE_FEE_BPS` (default 0). `DeployAll` grants `MINTER_ROLE` to StrategyManager for fee minting

7. **IStrategy Interface** (IStrategy)
   - Standard interface for investment strategy contracts
   - **Non-Upgradeable**: Strategy contracts are static/immutable ("code is law")
   - Location: `src/interfaces/IStrategy.sol`
   - Key Functions:
     - `name()`: Returns strategy name
     - `version()`: Returns strategy version
     - `navInETH()`: Returns total strategy NAV in ETH (18 decimals) — primary NAV function used by StrategyManager
     - `paused()`: Returns whether the strategy is paused
     - `maxDeposit()`: Returns maximum ETH that can be deposited
     - `maxWithdrawal()`: Returns maximum ETH that can be withdrawn
     - `isHealthy()`: Returns true if strategy is healthy
     - `deposit()`: Deposits ETH into the strategy (StrategyManager path; deploys capital)
     - `investIdleETH()`: Admin-only; deploys idle native ETH (e.g. donations) without going through the keeper deposit path
     - `withdraw(address, uint256) returns (uint256)`: Withdraws ETH from the strategy (unwinds internally as needed). Returns the ETH actually delivered to the receiver, net of strategy-retained fees. The StrategyManager accounts for withdrawals via the Controller's ETH balance delta across the `withdraw()` call (mirroring the Converter's adapter accounting) rather than the return value
     - `rebalance()`: Rebalances the strategy if it is unhealthy (reverts if healthy)
     - `sync()`: Refreshes lazily-updated on-chain state via the keeper path; implementation-defined (may no-op). UniCLStrat pokes Uniswap V3 positions with `burn(..., 0)` so accrued LP fees materialize in `tokensOwed` (NAV and pending update) without removing liquidity, calling `collect()`, or flushing durable LP-fee counters
     - `pendingPerformanceFeeInETH(uint256)`: View pending ETH-denominated performance fee for dilution settlement. Returns 0 when paused or nothing is pending. UniCLStrat includes already-materialized fees via a live `tokensOwed - snapshot` delta; unpoked fee growth is invisible until `sync()` or a remove/collect poke
     - `settlePerformanceFee(uint256)`: StrategyManager-only settlement; marks fee base as charged and returns ETH fee amount. Returns 0 when paused or when the ETH fee rounds to zero under floor division (charged counters must not advance on dust). UniCLStrat accrues already-materialized fees only (no poke) so settlement matches `pendingPerformanceFeeInETH`
     - `emergencyExit()`: Transfers native ETH to StrategyManager and emits `EmergencyExited(ethAmount)`. Callable by `ADMIN_ROLE` or `SECURITY_ROLE`, not by StrategyManager. Only concerned with transferring funds the strategy already holds — implementations must not depend on external pool/DEX calls succeeding (position unwinding belongs to the `pause()` path). Writes off pending local performance fees (charged = earned after any best-effort accrue). Non-ETH inventory may be transferred to StrategyManager as ERC-20 and priced into NAV when whitelisted via `addSupportedERC20()`. May recover orphaned native ETH after removal from StrategyManager
   - Events:
     - `FundsDeposited(uint256 amount)`: Emitted when funds are deposited into the strategy
     - `FundsInvested(uint256 amount)`: Emitted when admin deploys idle native ETH via `investIdleETH()`; amount is idle native ETH at call start only (implementations may re-deploy collected liquidity without including it)
     - `FundsWithdrawn(uint256 amount)`: Emitted when funds are withdrawn from the strategy
     - `Rebalanced()`: Emitted when the strategy is rebalanced
     - `Synced()`: Emitted when the strategy completes a keeper-path sync
     - `EmergencyExited(uint256 ethAmount)`: Native ETH delivered to StrategyManager during `emergencyExit()`. Non-ETH inventory (e.g. paired tokens) may be transferred as ERC-20 and priced into NAV when whitelisted via `StrategyManager.addSupportedERC20()`
     - `PerformanceFeeSettled(uint256 feeETH)`: Emitted when StrategyManager settles the strategy's pending performance fee
   - Errors:
     - `StrategyIsHealthy`: Thrown when the strategy is healthy and rebalance is not needed
     - `StrategyMaxDepositExceeded`: Thrown when the amount to deposit exceeds the maximum deposit amount
     - `StrategyMaxWithdrawalExceeded`: Thrown when the amount to withdraw exceeds the maximum withdrawal amount
     - `StrategyZeroDeposit`: Thrown when the deposit amount is zero
     - `StrategyZeroWithdrawal`: Thrown when the withdrawal amount is zero
   - Note: Allocation weights (`depositWeight` / `withdrawalWeight`) live on StrategyManager (#252), not on `IStrategy`

8. **UniCLStrat Contract** (UniCLStrat)
   - Native-ETH IStrategy implementation deploying funds into a Uniswap V3-style WETH/paired-token concentrated liquidity pool
   - **Static/Non-Upgradeable**: "code is law" — immutable once deployed
   - Location: `src/contracts/strategies/UniCLStrat.sol`
   - Interface: `src/interfaces/strategies/IUniCLStrat.sol`
   - Tests: `test/unit/UniCLStrat.t.sol`, `test/fuzz/UniCLStratFuzz.t.sol`, `test/fork/UniCLStratFork.t.sol`; tree: `test/trees/UniCLStrat.tree`
   - Deployment: `script/DeployUniCLStrat.s.sol`
   - Access Control (via `RegistryClient`):
     - `ADMIN_ROLE` on Registry: Configure parameters, pause/unpause, `investIdleETH()`.
     - `ADMIN_ROLE` or `SECURITY_ROLE` on Registry: `pause()`, `emergencyExit()` (emergency response; `unpause()` stays `ADMIN_ROLE`-only).
     - Registered `STRATEGY_MANAGER` on Registry: `deposit()`, `withdraw()`, `rebalance()`, `sync()` (`onlyValidContract`).
   - Key Functions:
     - `deposit()`: Wraps ETH to WETH, pokes then accrues pending LP fees, removes existing liquidity, balances inventory, adds liquidity. Requires calm pool.
     - `investIdleETH()`: Admin-only; wraps idle native ETH and deploys to LP (same poke-then-accrue remove/collect path as deposit). Requires calm pool.
     - `withdraw(address, uint256) returns (uint256)`: Pays out up to `maxWithdrawal()` (= `navInETH()`, which includes idle native ETH), spending idle native ETH first. If idle ETH covers the request, the payout is sent directly from the native balance with no pool or Converter interaction (LP position untouched). Otherwise all idle ETH goes toward the payout and only the remainder is sourced from WETH (poke-then-accrue, liquidity removal, fee collection, paired-token conversion), of which exactly the needed amount is unwrapped — native ETH is never wrapped just to be unwrapped again. The receiver always gets a single native ETH transfer; the return value is the ETH actually delivered. Inventory rebalancing and liquidity re-addition only when liquidity was removed and the pool is calm.
     - `rebalance()`: Repositions liquidity around current tick when strategy is unhealthy. Requires calm pool. Remove/collect path pokes then accrues pending LP fees before unwinding.
     - `sync()`: Pokes Uniswap V3 positions with `burn(..., 0)` so accrued LP fees materialize in `tokensOwed` without removing liquidity or calling `collect()`. Does not flush durable LP-fee counters — `pendingPerformanceFeeInETH` already includes the live `tokensOwed - snapshot` delta. Keeper path (`STRATEGY_MANAGER` caller).
     - `pendingPerformanceFeeInETH` / `settlePerformanceFee`: Strategy-local LP-fee performance accounting. View includes materialized fees via the live delta; settle accrues then charges that same base (no poke). When `feeETH` floors to 0, charged counters are left unchanged so dust stays feeable. Unpoked fee growth waits for `sync()` or remove/collect. Return 0 when paused (counters preserved until unpause). Settlement is StrategyManager-only.
     - `pause()`: `ADMIN_ROLE` or `SECURITY_ROLE`. Flips the pause flag first (local state only, so a degraded pool can never block the circuit breaker), then attempts the pool unwind as a best-effort try/catch self-call (`selfRemoveLiquidityAndCollect()` — poke-then-accrue then remove/collect; a pool revert emits `LiquidityUnwindSkipped` instead of bubbling up), then revokes Converter token allowances directly (the pool tokens are standard assets like WETH/USDC whose `approve()` does not revert, so no guard there). `unpause()` (`ADMIN_ROLE` only) restores Converter allowances.
     - `emergencyExit()`: `ADMIN_ROLE` or `SECURITY_ROLE` (not StrategyManager). Requires pause. Transfers only what the strategy already holds — it never touches the pool: unwraps WETH and sends native ETH to `strategyManager` first (strict); best-effort transfers `pairedToken` to `strategyManager` as ERC-20 via try/catch on `transfer` (emits `PairedTokenTransferSkipped` on blacklist/pause failure — retry with a later `emergencyExit()`); writes off pending LP fees via `_resetLpFeeAccounting` (best-effort `_tryAccrueLpFees` with aggregate snapshot fallback if either `positions` read reverts, then `charged = earned`); emits `EmergencyExited(ethAmount)`. The paired token stays visible in NAV when whitelisted via `StrategyManager.addSupportedERC20()` (on-chain swap recovery via the shared Converter is deferred to a follow-up PR). If the pause-time pool unwind was skipped (degraded pool), the LP position stays in the pool and remains attributed to the strategy via `navInETH()`; once the pool functions again the admin recovers it via `unpause()` followed by normal withdrawals or a re-run of `pause()` (which performs the unwind) + `emergencyExit()`.
     - `navInETH()`: Returns strategy NAV in ETH including native ETH, WETH, paired token (via oracle), and pool positions.
     - `maxDeposit()`: Returns remaining capacity (maxTotalNAV - currentNAV), zero if pool is not calm or paused.
     - `maxWithdrawal()`: Returns navInETH, zero if paused.
     - `paused()`: Returns pause state (OpenZeppelin `Pausable`).
   - Calm-Period Guards: `_isCalm()` checks spot tick and short TWAP against long TWAP ± maxTickDeviation. Inventory swaps (`_balanceInventory()`) and liquidity provisioning (`_addLiquidity()`) are only executed when the pool is calm, protecting against price manipulation.
   - TWAP Window Floors: `MIN_TWAP_INTERVAL = 1800` (30 min) and `MIN_SHORT_TWAP_INTERVAL = 60` are enforced in the constructor and the `setTwapInterval()`/`setShortTwapInterval()` setters. The long TWAP anchors both the calm band and the LP-position composition in `navInETH()` (which feeds StrategyManager NAV and AMM pricing), so biasing it requires sustaining a skewed tick across ~150 blocks; mint sizing in `_liquidityForPosition()` uses spot (`slot0`) because Uniswap charges mint callbacks at the current price. The short floor matches the UniswapV3ConverterAdapter's `MIN_TWAP_INTERVAL` so a single-block flash-loan skew cannot pass the calm check. Deployment requirement: the pool's observation cardinality must cover the configured `twapInterval`, otherwise `navInETH()` reverts (freezing protocol pricing) until the observation buffer fills — `DeployUniCLStrat.s.sol` validates the env-supplied intervals against mirrored floors before deploying.
   - Swap Execution: all swaps route through the shared Converter with quote-derived slippage bounds and symmetric Chainlink oracle floor/ceiling checks (`MAX_QUOTE_DEVIATION_BPS = 200`, which must exceed the route's pool fee tier since adapter quotes are fee-net). A per-swap deadline (`block.timestamp + SWAP_DEADLINE_OFFSET`) is forwarded to the router but is NOT a defence layer — computed at execution time, it can never expire within the transaction; it only satisfies the router interface. `_convertToWeth()` (used by `withdraw`) uses an EXACT-OUTPUT swap (`_swapViaRouteExactOutput`) so the strategy receives precisely the missing WETH; if the slippage-padded required input exceeds the paired-token balance, it falls back to a best-effort exact-input swap of the whole balance.
   - Events: FundsDeposited, FundsInvested, FundsWithdrawn, Rebalanced, Synced, EmergencyExited, LiquidityUnwindSkipped (best-effort pool unwind on pause reverted and was skipped), PairedTokenTransferSkipped (best-effort paired-token transfer on emergencyExit reverted and was skipped)
   - Errors: UniCLStratZeroAddress, UniCLStratInvalidPool, UniCLStratInvalidConfig, UniCLStratNotCalm, UniCLStratNotPaused, UniCLStratInsufficientWETH, UniCLStratTransferFailed, UniCLStratCallerNotPool, UniCLStratCallerNotSelf, UniCLStratInvalidMintCallback

9. **Converter Contract** (Converter)
   - Upgradeable shared protocol module using UUPS (Universal Upgradeable Proxy Standard)
 - Centralises WETH wrapping, unwrapping, and DEX swap execution for all strategies
 - **Adapter Pattern**: DEX-specific logic is delegated to whitelisted `IConverterAdapter` implementations. The Converter never hard-casts to a DEX-specific router. Swap execution (`swapExactAmountIn`/`swapExactAmountOut`) is dispatched via **DELEGATECALL** — the adapter code runs in the Converter's context, so input tokens stay on the Converter and the adapter approves the DEX router directly (no double approve/transferFrom round-trip through the adapter). Quotes and route views (`quoteExactAmountIn`/`quoteExactAmountOut`/`validateRoute`/`routeTokens`) use regular CALLs. **Route encoding contract**: every adapter entry point — exact-input AND exact-output — takes the same FORWARD route encoding (input token first); if the underlying DEX consumes a different encoding for one direction (e.g. Uniswap V3's reverse-ordered `exactOutput()` paths), the adapter translates internally — callers never reverse paths.
 - **Stateless Adapter Requirement**: because swaps execute via delegatecall in the Converter's storage context, adapters MUST be stateless — configuration only via immutables/constants, no storage reads or writes. A storage-touching adapter would read/corrupt the Converter's storage.
 - **Adapter Allowlist**: Adapters must be explicitly whitelisted by ADMIN_ROLE via `setAllowedAdapter()`. Only whitelisted adapters can be used for swaps and quotes. SECURITY: whitelisted adapters run with full access to the Converter's storage and balances during swaps — only audited, stateless adapters may be whitelisted.
   - **Role-Based Access Control**:
     - `ADMIN_ROLE`: Self-administered. Can configure adapters, pause/unpause, authorize upgrades.
     - `CONVERTER_CALLER_ROLE`: Required to call `wrapETH()`, `unwrapWETH()`, and `executeSwapExactAmountIn()`. Granted to strategies by StrategyManager.
     - `CONVERTER_CALLER_MANAGER_ROLE`: Admin of `CONVERTER_CALLER_ROLE` on the Registry. Held by the Converter so that `grantCallerRole()`/`revokeCallerRole()` can administer `CONVERTER_CALLER_ROLE` on behalf of individual strategies. Granted at deployment in `_grantProtocolRoles`.
     - `STRATEGY_MANAGER_ROLE`: Registry contract key for the StrategyManager. Used by `onlyAuthContract` gates on `grantCallerRole()`/`revokeCallerRole()`. Admin is `ADMIN_ROLE`.
   - **WETH Functions**:
     - `wrapETH()`: Wraps native ETH to WETH and transfers WETH to caller. `payable`.
     - `unwrapWETH(uint256, address)`: Pulls WETH from caller, unwraps to native ETH, sends ETH to receiver.
 - **Swap Functions**:
 - `executeSwapExactAmountIn(address, bytes, uint256, uint256, uint256)`: Executes a swap through a whitelisted adapter (exact-input). Pulls input tokens from caller, dispatches via delegatecall to the adapter (tokens stay on the Converter; single approval to the DEX router, cleared after), enforces `_minAmountOut` and `_deadline`.
 - `executeSwapExactAmountOut(address, bytes, uint256, uint256, uint256)`: Executes a swap for an exact output amount through a whitelisted adapter (exact-output). Takes the same FORWARD path encoding as `executeSwapExactAmountIn` (the adapter handles any DEX-specific reversal internally). Pulls the full `_amountInMaximum` from the caller upfront (the DEX router pulls payment mid-swap, so the maximum must be available), dispatches via delegatecall to the adapter, refunds unused input (which never leaves the Converter under delegatecall), enforces `_deadline`. The input spent is measured from the actual `_tokenIn` balance delta — not the adapter-reported amount — so a misreporting adapter cannot strand input or skew the refund, and `ConverterExcessiveInput` is enforceable even against an adapter spending pre-existing Converter balance. Returns the measured input spent.
 - `quoteSwapExactAmountIn(address, bytes, uint256)`: On-chain quote via adapter (exact-input, regular CALL). Declared non-view at the interface level (some DEX quoters write transient storage); individual adapters may implement it as `view` (the UniswapV3 adapter quotes from TWAP + Chainlink and is `view`). Permissionless (no access control, no pause check).
 - `quoteSwapExactAmountOut(address, bytes, uint256)`: On-chain quote via adapter (exact-output, regular CALL). Same non-view rationale as `quoteSwapExactAmountIn`. Permissionless.
   - **Pausable**: Can be paused by ADMIN_ROLE (all operations revert when paused).
   - **Key Principles**:
     - Routing is caller-owned: strategies supply the adapter and route bytes at call time.
     - Slippage is caller-supplied (no on-chain quote in execution path).
     - Adding a new DEX requires only whitelisting its adapter — no Converter change.
   - Events: ETHWrapped, WETHUnwrapped, SwapExecuted, AdapterUpdated, ConverterInitialized
   - Errors: ConverterZeroAddress, ConverterNoCode, ConverterAdapterNotAllowed, ConverterAdapterAlreadyAllowed, ConverterInsufficientOutput, ConverterExcessiveInput, ConverterDeadlineExpired, ConverterSwapFailed, ConverterAdapterCallFailed, ConverterETHTransferFailed, ConverterInvalidRoute
   - Version: 1.0.0
   - Location: `src/contracts/Converter.sol`
   - Interface: `src/interfaces/IConverter.sol`
   - Tests: `test/unit/Converter.t.sol` (comprehensive test suite); tree: `test/trees/Converter.tree`
   - Deployment: `script/DeployAll.s.sol`

10. **UniswapV3ConverterAdapter Contract** (UniswapV3ConverterAdapter)
 - Non-upgradeable (static/immutable) IConverterAdapter implementation for Uniswap V3-style routers
 - **Adapter Pattern**: Implements the `IConverterAdapter` interface so the Converter can dispatch Uniswap V3 swaps without DEX-specific code. Stateless by design (immutables only) — swaps are executed via delegatecall in the Converter's context.
 - **Path Encoding**: Uniswap V3 packed path encoding `(tokenIn, fee, tokenOut)` via the shared `UniswapV3Path` library (`src/libraries/integrations/uniswap/UniswapV3Path.sol` — single source of truth for path validation/decoding/reversal). Minimum valid path is 43 bytes (single hop). Multi-hop paths are structurally valid but rejected at the application level — `MAX_PATH_LENGTH = 1` enforces single-hop only for the initial release. Multi-hop support can be added later via a separate or updated adapter. ALL adapter entry points take the FORWARD encoding; `swapExactAmountOut` reverses the path internally (`UniswapV3Path.reverseSingleHop`) before calling `router.exactOutput()`, since Uniswap consumes exact-output paths in reverse order.
 - **TWAP + Chainlink Quotes (flash-loan resistant)**: quotes do NOT use the Uniswap Quoter (spot-state simulation, manipulable with a flash loan inside one block). Instead the mid-price is derived from the pool's TWAP over `twapInterval` (arithmetic mean tick via `pool.observe()`, pool resolved through the factory), then cross-checked against an independent Chainlink-based amount via the protocol Oracle. If the two deviate by more than `MAX_ORACLE_DEVIATION_BPS` (200 = 2%), the quote reverts. The deviation check compares GROSS (pre-fee) amounts, so the fee tier does not consume any of the deviation budget; the pool fee is applied only to the returned amount — net (exact-input) / gross (exact-output) of the pool fee. The Chainlink leg uses `Oracle.convert()` (direct token-to-token cross-rate). Both quote functions are `view`.
 - **Key Functions**:
 - `name()`: Returns "UniswapV3ConverterAdapter"
 - `validateRoute(bytes)`: Validates the packed path format (single-hop only)
 - `routeTokens(bytes)`: Decodes input/output tokens from the path
 - `quoteExactAmountIn(bytes, uint256)`: TWAP-implied output net of pool fee, Chainlink cross-checked (`view`)
 - `quoteExactAmountOut(bytes, uint256)`: TWAP-implied input grossed up by pool fee, Chainlink cross-checked (`view`)
 - `swapExactAmountIn(bytes, uint256, uint256, address, uint256)`: Delegatecalled by the Converter — input tokens already on `address(this)`; approves the router, executes `router.exactInput()`, clears residual approval
 - `swapExactAmountOut(bytes, uint256, uint256, address, uint256)`: Delegatecalled by the Converter — takes the FORWARD path, reverses it internally for `router.exactOutput()`; approves the router, clears residual approval; unspent input stays on the Converter, which refunds the caller
 - Constants: `MAX_ORACLE_DEVIATION_BPS = 200`, `MIN_TWAP_INTERVAL = 60`
 - Constructor arguments: `_router` (Uniswap V3 swap router), `_factory` (Uniswap V3 factory for pool resolution), `_oracle` (protocol Oracle), `_weth` (WETH address, mapped to address(0) for Oracle lookups), `_twapInterval` (TWAP window in seconds, >= MIN_TWAP_INTERVAL)
 - Errors: UniswapV3ConverterAdapterZeroAddress, UniswapV3ConverterAdapterInvalidRoute, UniswapV3ConverterAdapterMultiHopNotSupported, UniswapV3ConverterAdapterInvalidTwapInterval, UniswapV3ConverterAdapterPoolNotFound, UniswapV3ConverterAdapterQuoteDeviation
   - Location: `src/contracts/adapters/UniswapV3ConverterAdapter.sol`
   - Interface: `src/interfaces/adapters/IUniswapV3ConverterAdapter.sol` (extends the generic `src/interfaces/IConverterAdapter.sol`; the contract inherits the dedicated interface and the adapter-specific errors are declared there)
   - Tests: (tested indirectly through Converter and UniCLStrat unit tests)
   - Deployment: `script/DeployAll.s.sol`

11. **Keeper Executor Contracts** (QueueKeeperExecutor, StrategyKeeperExecutor)
   - Static (non-upgradeable) Chainlink Automation executors under `src/contracts/automation/`, sharing the abstract `KeeperExecutorBase` (RegistryClient + OZ Pausable + ReentrancyGuard + `AutomationCompatibleInterface`)
   - **Trust model**: `Chainlink Automation → Forwarder → KeeperExecutor → Controller`. The executors are the ONLY accounts holding `KEEPER_ROLE` in the automated setup; Chainlink infrastructure (registry/registrar/forwarder) never receives a protocol role. `performUpkeep` is callable only by the Chainlink Forwarder registered via `setForwarder()` (ADMIN_ROLE; obtained after registering the upkeep). While the forwarder is unset the executor is inert
   - **performData is untrusted** (per Chainlink guidance): it only selects the action; every condition and amount is re-validated/recomputed from current state in `performUpkeep`, reverting with `KeeperExecutorNoUpkeepNeeded` on stale data
   - **Pausable**: `pause()` (ADMIN or SECURITY), `unpause()` (ADMIN). `checkUpkeep` also reports no work while the involved protocol contracts (Controller, ExitQueue, AMM / StrategyManager) are paused
   - **QueueKeeperExecutor** (`QueueAction`: PriceBatch, ProcessRequests, AdvanceCursor):
     - `checkUpkeep`: peeks past empty and post-commitment batches (`pricedAt + MAX_BATCH_PROCESSING_TIME`) from `nextBatchIdToProcess` (peek + process window each `MAX_BATCH_SCAN = 25`) for one whose unprocessed requests the Controller can afford → `ProcessRequests(batchId)`; otherwise, if the current batch is non-empty and at least `minBatchAge` old → `PriceBatch(currentBatchId)`; otherwise, if the stored cursor can advance past skippable batches → `AdvanceCursor`. Fairness tradeoff: if the oldest live batch is unaffordable but a later one (within the window) is affordable, the later batch is processed first — spending Controller liquidity on a newer batch rather than blocking on the oldest, presumably longer-waiting one; the oldest batch is revisited once Controller liquidity recovers, or skipped once past `MAX_BATCH_PROCESSING_TIME`
     - Affordability mirrors `Controller._processRequest`: out-of-tolerance requests cost 0; others cost `convertAssets(tokensToBurn, finalEvePrice)`; the longest affordable prefix is processed, capped at `maxUsersPerUpkeep` (default 20, `setMaxUsersPerUpkeep`, must be in `[1, MAX_USERS_PER_UPKEEP_UPPER_BOUND = 100]`). `affordableRequests(batchId)` view exposes the computation
     - `minBatchAge` (default `MIN_BATCH_AGE_LOWER_BOUND = 1 day`, floor `MIN_BATCH_AGE_LOWER_BOUND`, cap `MIN_BATCH_AGE_UPPER_BOUND = 7 days`, `setMinBatchAge`) lets requests accumulate instead of pricing a batch per request
     - The processing cursor `nextBatchIdToProcess` advances past empty and post-commitment batches on every `performUpkeep` (and via `AdvanceCursor` when that is the only work). `nextLiveBatchIdToProcess()` exposes the peek. Governance can still force-advance via `advanceBatchCursor(toBatchId)` (ADMIN_ROLE) for batches stuck *inside* the commitment window; skipped requests remain in the ExitQueue for owners to close via `closeRequest`. Emits `BatchCursorAdvanced(from, to)` for the admin path
   - **StrategyKeeperExecutor** (`StrategyAction`, priority order: Rebalance, WithdrawShortfall, ProvideExitLiquidity, DepositExcess, HarvestPerformanceFees, Sync):
     - Rebalance: any registered strategy unhealthy and not paused → `Controller.checkAndRebalanceStrategies()`
     - WithdrawShortfall: `pendingRedemptionNeedsETH()` (cost of unprocessed requests in priced batches scanned **forward from `QueueKeeperExecutor.nextLiveBatchIdToProcess`** — window `MAX_BATCH_SCAN = 25` batches / `MAX_USERS_COST_SCAN = 50` requests per batch; post-commitment batches contribute 0 — plus the current unpriced batch estimated at the AMM base price) exceeds the Controller balance by ≥ `minWithdrawETH` → `Controller.withdrawFromStrategies(shortfall)`. Anchoring at the live queue cursor ensures the oldest live liabilities are always covered
     - ProvideExitLiquidity: `AMM.freeBalance()` (immediate-exit float) below `exitLiquidityTargetETH` (default `0` = disabled until admin-set, same pattern as `controllerReserveETH`) → `Controller.provideExitLiquidity(topUp)` tops the float up to the target, capped at the idle Controller excess above `controllerReserveETH` + pending redemption needs (partial top-ups allowed; minimum top-up `minExitLiquidityTopUpETH`, default 0.01 ETH, filters dust). Outranks DepositExcess so serving user exits comes before putting idle capital to work
     - DepositExcess: Controller balance above `controllerReserveETH` + pending redemption needs by ≥ `minDepositETH` and a healthy strategy has capacity → `Controller.depositToStrategies(excess)`. (Renamed from `DepositIdle` to avoid collision with the admin `IStrategy.investIdleETH()`.)
     - HarvestPerformanceFees: view-estimated accrued fees (`pendingPerformanceFeeInETH` sum) ≥ `minHarvestETH` (default 0.01 ETH, non-zero via `setMinHarvestETH`; no-op when `performanceFeeBps == 0`) → `Controller.harvestPerformanceFeeFromStrategies()` mints accrued fees to the DAO treasury. Snapshot-before-execution emits the estimate on `StrategyUpkeepPerformed`; exact settlement amounts live on `PerformanceFeeHarvestCompleted` / `PerformanceFeePaid`. Covers periods of no other keeper activity (deposits/withdrawals harvest fees inline)
     - Sync: `syncInterval` elapsed since `lastSyncAt` (0 disables) → `Controller.syncStrategies()`
     - Config setters (all ADMIN_ROLE): `setControllerReserveETH` (default 0), `setMinDepositETH` (non-zero), `setMinWithdrawETH` (0 allowed — react to any shortfall), `setMinHarvestETH` (non-zero), `setSyncInterval`, `setExitLiquidityTargetETH` (default 0 disables the action), `setMinExitLiquidityTopUpETH` (non-zero)
   - Events: `ForwarderChanged`, `QueueUpkeepPerformed(action, batchId, processedUsers)`, `BatchCursorAdvanced(fromBatchId, toBatchId)`, `StrategyUpkeepPerformed(action, amount)`, config `*Changed` events
   - Errors (in `IKeeperExecutorBase`): `KeeperExecutorOnlyForwarder`, `KeeperExecutorZeroAddress`, `KeeperExecutorNoUpkeepNeeded`, `KeeperExecutorUnknownAction`, `KeeperExecutorInvalidConfig`; queue-specific (in `IQueueKeeperExecutor`): `QueueKeeperExecutorBatchCursorPrecedesCurrent`, `QueueKeeperExecutorBatchCursorPastCurrent`
   - Version: 1.0.0
   - Location: `src/contracts/automation/`
   - Interfaces: `src/interfaces/automation/`
   - Tests: `test/unit/QueueKeeperExecutor.t.sol`, `test/unit/StrategyKeeperExecutor.t.sol`; trees: `test/trees/QueueKeeperExecutor.tree`, `test/trees/StrategyKeeperExecutor.tree`
   - Deployment: `script/DeployKeeperExecutors.s.sol` / `DeployAll` via shared `ProtocolDeployBase._deployKeeperExecutors` (deploy both executors → register `QUEUE_KEEPER_EXECUTOR` and `STRATEGY_KEEPER_EXECUTOR` on the Registry → grant `KEEPER_ROLE` to both → apply `EXIT_LIQUIDITY_TARGET_ETH` / `CONTROLLER_RESERVE_ETH` from required wei env). Modular step requires `REGISTRY_ADDRESS` and must run before `FinalizeProtocolDeploy` (or schedule registration/grants through the 48h admin timelock). Then register upkeeps in Chainlink Automation → `setForwarder(forwarder)`.

12. **Whitelist Contract** (Whitelist)
   - Static (non-upgradeable) invite gate for protocol **entry** only — resolved via Registry key `Auth.WHITELIST`
   - **EIP-712 vouchers**: typed data domain `EverStratWhitelist` / `1`; struct `Invite(address user, bytes32 inviteId, uint256 deadline)` with `INVITE_TYPEHASH`
   - **`inviteId`**: opaque server-chosen identifier (never the human invite code, nor a direct hash of it) so on-chain state does not leak the code space
   - **Permissionless `whitelist()`**: any relayer can sponsor gas; already-whitelisted users (and everyone after `disable()`) are a no-op that leaves the invite unconsumed — so `AMM.enterWithInvite` stays safe without an AMM-side disabled check
   - **`isWhitelisted`**: returns `true` for everyone once `disabled`; while the gate is active, banned addresses return `false`, otherwise local `_whitelisted` mapping only. Redeploys start empty (no previous-Whitelist fallback) — migrate via `addToWhitelist` or open with `disable()`
   - **Bans**: `removeFromWhitelist` clears whitelist membership and sets `_banned` for the invite period only; `addToWhitelist` clears `_banned` so admin re-admit restores entry. After `disable()`, bans no longer block entry (`isBanned` may still report the historical flag)
   - **Signers**: `addSigner` (`ADMIN_ROLE` only); `removeSigner` (`ADMIN_ROLE` or `SECURITY_ROLE`) for instant revoke of a leaked invite key
   - **`disable()`**: irreversible (`ADMIN_ROLE`); opens entry to everyone; invite-period admin mutators then revert with `WhitelistIsDisabled`
   - Access: Registry roles via `RegistryClient` (not local AccessControl)
   - Key Functions: `whitelist`, `addToWhitelist`, `removeFromWhitelist`, `addSigner`, `removeSigner`, `disable`, views `isWhitelisted` / `isBanned` / `isSigner` / `isInviteUsed` / `disabled`
   - Events: `UserWhitelisted`, `UserWhitelistedByAdmin`, `UserRemovedFromWhitelist`, `SignerAdded`, `SignerRemoved`, `WhitelistDisabled`
   - Errors: `WhitelistZeroAddress`, `WhitelistIsDisabled`, `WhitelistInviteAlreadyUsed`, `WhitelistSignatureExpired`, `WhitelistInvalidSignature`, `WhitelistSignerAlreadyAdded`, `WhitelistSignerNotFound`, `WhitelistUserBanned`
   - Version: 1.0.0
   - Location: `src/contracts/Whitelist.sol`
   - Interface: `src/interfaces/IWhitelist.sol`
   - Tests: `test/unit/Whitelist.t.sol`, `test/unit/AMMWhitelist.t.sol`; trees: `test/trees/Whitelist.tree` (also covered via AMM whitelist trees)
   - Deployment: `script/DeployWhitelist.s.sol` / `DeployAll` via `ProtocolDeployBase._deployWhitelist` (register `WHITELIST`; seed `WHITELIST_SIGNER_ADDRESS` when non-zero)

13. **Supporting Libraries**
   - `Math.sol`: Decimal conversion, asset conversion utilities, and slippage protection (isRelativelyLessThan)
   - `Auth.sol`: Registry contract keys (including `WHITELIST`) and role identifiers

## Simple Architecture Checker

The project includes a minimal tool that checks if PR changes are documented in the Mermaid architecture diagram.

### Features
- **Simple Mermaid Parsing**: Extracts component names from architecture diagram
- **PR Analysis**: Checks if new contracts are documented in the diagram
- **GitHub Integration**: Posts simple comments with results
- **No Configuration**: Uses GitHub Actions environment variables directly

### Usage
```bash
# Check a specific PR (runs automatically in GitHub Actions)
cd mermaid/scripts
npx ts-node simple-architecture-checker.ts <PR_NUMBER>
```

### How It Works
1. Extracts component names from `mermaid/mermaid-smart-contracts.md`
2. Checks if new contracts in PR are documented in the diagram
3. Posts a simple comment with pass/fail results
4. No `.env` file needed - uses GitHub Actions environment

## Development Status

### Completed
- ✅ Foundry project initialized
- ✅ OpenZeppelin Contracts Upgradeable v5.1.0 installed
- ✅ Chainlink contracts for oracle integration
- ✅ **Oracle contract implemented with UUPS upgradeability pattern**
  - Centralized price feed management
  - Chainlink `latestRoundData()` integration with round data validation, invalid timestamp check, feed decimals cap at 18
  - Staleness protection
  - Unit and fuzz test suites (`Oracle.t.sol`, `OracleFuzz.t.sol`)
- ✅ Controller contract implemented with UUPS upgradeability pattern
- ✅ Controller comprehensive test suite (14 tests, 100% passing)
- ✅ EVE Token contract implemented with UUPS upgradeability pattern
- ✅ EVE Token comprehensive test suite (31 tests, 100% passing)
- ✅ BondingCurve contract implemented with full functionality
- ✅ BondingCurve comprehensive test suite (46 tests, 100% passing)
- ✅ Math and Types utility libraries
- ✅ Complete interface definitions (including IOracle interface)
- ✅ **Simple Architecture Checker**: Minimal tool for PR validation
  - Mermaid diagram parsing (component name extraction)
  - GitHub integration for posting comments
  - PR analysis against architecture diagram
  - No configuration files needed
- ✅ **Architecture Documentation**: Comprehensive Mermaid diagrams
  - Current architecture visualization
  - Future architecture roadmap
  - Component relationships and dependencies
- ✅ **GitHub Workflow Integration**: Automated architecture checks
  - Modified `.github/workflows/claude-code-review.yml`
  - Runs automatically on PR events

### In Progress
- Frontend application development
- Deployment scripts

### Contracts Ready for Use
- **Oracle**: Fully tested upgradeable oracle contract
  - Run tests: `forge test --match-contract OracleTest`; fuzz: `forge test --match-contract OracleFuzzTest`
  - Deploy: `forge script script/DeployOracle.s.sol --rpc-url <rpc_url> --broadcast`
  - Features: UUPS upgradeability, Chainlink round data validation, feed decimals cap at 18, invalid timestamp check, staleness checks, token management
  - Interface: `IOracle` interface defines the standard oracle methods and errors

- **Controller**: Fully tested upgradeable controller contract
  - Run tests: `forge test --match-contract ControllerTest`
  - Deploy: `forge script script/DeployController.s.sol --rpc-url <rpc_url> --broadcast`
  - Features: UUPS upgradeability, owner access control

- **EVE Token**: Fully tested upgradeable ERC20 token contract
  - Run tests: `forge test --match-contract EVETest`
  - Features: Standard ERC20, Ownable, Mintable (owner only), Burnable

- **AMM**: Fully tested core protocol contract
  - Run tests: `forge test --match-contract AMMTest`; whitelist gate: `forge test --match-contract AMMWhitelistTest`
  - Features: Native ETH support, ETH-first pricing (no oracle in enter/exit), redemption queue, bonding curve pricing, invite whitelist gate (`enter` / `enterWithInvite`)

- **Whitelist**: Fully tested static invite gate
  - Run tests: `forge test --match-contract WhitelistTest`
  - Deploy: `forge script script/DeployWhitelist.s.sol --rpc-url <rpc_url> --broadcast`
  - Features: EIP-712 invite vouchers, permissionless redeem, asymmetric signer admin, irreversible `disable()`, entry-only gating (exit never checked)
  - Interface: `IWhitelist`

- **UniCLStrat**: Fully tested static strategy contract
  - Run tests: `forge test --match-contract UniCLStratTest`; fuzz: `forge test --match-contract UniCLStratFuzzTest`
  - Deploy: `forge script script/DeployUniCLStrat.s.sol --rpc-url <rpc_url> --broadcast`
  - Features: Uniswap V3 concentrated liquidity, TWAP-based NAV composition with spot-based mint sizing, calm-period guards on swaps and liquidity, emergency exit. Performance fees use strategy-local LP-fee accounting with StrategyManager dilution settlement
  - Interface: `src/interfaces/strategies/IUniCLStrat.sol`
  - Access: ADMIN_ROLE (self-administered), STRATEGY_MANAGER_ROLE (permanently frozen, consistent with immutable strategyManager address). DEFAULT_ADMIN_ROLE is never granted.

### Key Features Implemented
- **Native ETH Support**: Users deposit and redeem native ETH (no ERC20 tokens)
- **ETH-First Pricing**: Price calculations use ETH-based NAV (no oracle in enter/exit hot path)
- **Oracle Usage**: Chainlink ETH/USD oracle only used for bootstrap validation and USD price view functions; reads validate round data presence, feed decimals (≤ 18), and timestamp bounds
- **Bonding Curve Pricing**: Dynamic pricing based on NAV and connector weight (calculated in ETH terms)
- **Redemption Queue**: Queued redemption system for insufficient liquidity
- **Bootstrap Mechanism**: Initial liquidity provision with dead supply lock
- **Upgradeability**: Management contracts use UUPS pattern for future upgrades

### Simple Architecture Checker Ready for Use
- **Automated PR Checks**: Architecture compliance checking
  - Runs automatically in GitHub Actions on PR events
  - Manual check: `cd mermaid/scripts && npx ts-node simple-architecture-checker.ts <PR_NUMBER>`
  - No configuration needed - uses GitHub Actions environment
- **Mermaid Diagrams**: Architecture visualization
  - Current state: `mermaid/mermaid-smart-contracts.md`
  - Future roadmap: Included in mermaid file

## Code Quality Rules

### Magic Value Cleanup Rules

When working with test files or any code containing magic values, follow these rules:

#### 1. **Identify Magic Values**
- Look for hardcoded numbers like `1000`, `500e6`, `1e18`, etc.
- Search for patterns: `[0-9]+e[0-9]+` (scientific notation) and `\b[0-9]{2,}\b` (multi-digit numbers)
- Focus on test amounts, gas limits, token amounts, and configuration values

#### 2. **Create Named Constants**
- Add constants at the top of the file or in a dedicated constants section
- Use descriptive names that explain the purpose: `MINT_AMOUNT`, `TRANSFER_AMOUNT`, `BURN_AMOUNT`
- Group related constants together with comments
- Use appropriate data types and add comments explaining the values

#### 3. **Constant Naming Conventions**
```solidity
// Good examples:
uint256 public constant MINT_AMOUNT = 1000;
uint256 public constant TRANSFER_AMOUNT = 100;
uint256 public constant BOOTSTRAP_USDC_DEPOSIT = 2000e6; // $2000 USDC
uint256 public constant DEAD_SUPPLY = 1e18;
uint256 public constant INVALID_PRICE_TOLERANCE = 2e18; // > 1e18

// Bad examples:
uint256 public constant AMOUNT = 1000; // Too generic
uint256 public constant VALUE = 500; // Not descriptive
```

#### 4. **Replace Magic Values Systematically**
- Use `search_replace` with `replace_all=true` for common patterns
- Replace specific values in context to avoid incorrect substitutions
- Verify replacements make sense in context
- Fix any circular dependencies that arise

#### 5. **Avoid Circular Dependencies**
```solidity
// BAD - Circular dependency:
uint256 public constant MINT_AMOUNT = MINT_AMOUNT;

// GOOD - Use literal values:
uint256 public constant MINT_AMOUNT = 1000;
```

#### 6. **Test After Cleanup**
- Always run tests after magic value cleanup: `forge test`
- Verify all tests still pass
- Check for compilation errors
- Ensure fuzz tests still work correctly

#### 7. **What NOT to Replace**
- Version strings: `"1.0.0"`, `"2.0.0"`
- Contract constants: `MIN_INITIAL_DEPOSIT_USD()`, `SCALE_FACTOR`
- External values: Oracle prices, chain IDs
- Mathematical constants: `type(uint256).max`, `keccak256` hashes
- Test-specific values with clear context: `6e17` (0.6 connector weight)

#### 8. **Benefits of Magic Value Cleanup**
- **Readability**: Code is self-documenting
- **Maintainability**: Easy to update values in one place
- **Consistency**: Same values used across related tests
- **Debugging**: Clear understanding of test scenarios
- **Documentation**: Constants serve as test documentation

#### 9. **Implementation Checklist**
- [ ] Identify all magic values in the file
- [ ] Create descriptive constants with proper naming
- [ ] Replace magic values systematically
- [ ] Fix any circular dependencies
- [ ] Run tests to verify functionality
- [ ] Check for compilation errors
- [ ] Verify fuzz tests still work

#### 10. **Example Implementation**
```solidity
// Before cleanup:
function test_Transfer() public {
    token.mint(owner, 1000);
    token.transfer(user, 100);
    assertEq(token.balanceOf(owner), 900);
    assertEq(token.balanceOf(user), 100);
}

// After cleanup:
uint256 public constant MINT_AMOUNT = 1000;
uint256 public constant TRANSFER_AMOUNT = 100;
uint256 public constant REMAINING_AMOUNT = 900;

function test_Transfer() public {
    token.mint(owner, MINT_AMOUNT);
    token.transfer(user, TRANSFER_AMOUNT);
    assertEq(token.balanceOf(owner), REMAINING_AMOUNT);
    assertEq(token.balanceOf(user), TRANSFER_AMOUNT);
}
```

This approach has been successfully applied to all test files in the project, resulting in cleaner, more maintainable code while preserving 100% test functionality.

### Code Organization Rules

When organizing code structure, follow these rules for optimal readability and maintainability:

#### 1. **Storage Variable Organization**

Group storage variables by type for gas efficiency and readability:

```solidity
// ============ Constants ============
uint256 private constant DEAD_SUPPLY = 1e18;
uint256 public constant MIN_INITIAL_DEPOSIT_USD = 1000e18;

// ============ Storage Variables ============

// uint256 variables (packed together)
uint256 private _lastRedemptionRequestId;
uint256 public connectorWeight;
uint256 public NAV;

// bool variables (packed together)
bool private _bootstrapped;

// address variables (packed together)
address public controller;
EVE public eve;

// complex types (mappings and sets)
EnumerableSet.AddressSet private _allowedTokens;
mapping(address token => CollateralInfo) private _collateralInfo;
mapping(uint256 requestId => RedemptionRequest) public exitQueue;
```

#### 2. **Function Organization**

Group functions by purpose and access level:

```solidity
// ============ Initialization ============
function initialize(...) public initializer { ... }

// ============ User Functions ============
function enter(...) external whenNotPaused { ... }
function exit(...) external whenNotPaused { ... }
function cancelRedemption(...) external whenNotPaused { ... }

// ============ Owner/Controller Functions ============
function processRedemption(...) external onlyController whenNotPaused { ... }
function addToken(...) external onlyController { ... }
function setConnectorWeight(...) external onlyController { ... }
function pause() external onlyController { ... }
function unpause() external onlyController { ... }

// ============ Internal Functions ============
function _checkTokenIsAllowed(...) internal { ... }
function _premiumPriceInTokenNormalized(...) internal view returns (uint256) { ... }
function _basePriceInTokenNormalized(...) internal view returns (uint256) { ... }
```

#### 3. **Grouping Principles**

**By Type (Storage Variables):**
- Group variables of the same type together
- Place smaller types before larger types for optimal packing
- Use comments to separate groups
- Place constants at the top

**By Purpose (Functions):**
- **User Functions**: Public-facing functions that users can call
- **Owner/Controller Functions**: Admin functions restricted to specific roles
- **Internal Functions**: Helper functions used internally
- **View Functions**: Pure and view functions for data access

**By Access Level:**
- **External**: Public interface functions
- **Public**: Functions accessible from outside the contract
- **Internal**: Functions only accessible within the contract and derived contracts
- **Private**: Functions only accessible within the current contract

#### 4. **Section Headers**

Use clear section headers with consistent formatting:

```solidity
/*//////////////////////////////////////////////////////////////
                        SECTION NAME
//////////////////////////////////////////////////////////////*/
```

#### 5. **Gas Efficiency Considerations**

**Storage Variable Packing:**
- Group variables of the same type together
- Place smaller types (bool, uint8) before larger types (uint256, address)
- This allows Solidity to pack multiple variables into a single storage slot

**Function Ordering:**
- Place frequently called functions earlier in the contract
- Group related functions together to improve code locality
- Keep internal helper functions near the functions that use them

#### 6. **Interface Compliance**

When implementing interfaces:
- Group interface functions together
- Maintain the same order as defined in the interface
- Add clear comments indicating interface compliance

```solidity
// ============ IBondingCurve Interface Implementation ============

/**
 * @inheritdoc IBondingCurve
 */
function tokens() external view returns (address[] memory) { ... }

/**
 * @inheritdoc IBondingCurve
 */
function premiumPriceInToken(address _token) external view returns (uint256) { ... }
```

#### 7. **Modifier Organization**

Place modifiers after storage variables but before functions:

```solidity
// ============ Modifiers ============
modifier onlyController() {
    require(msg.sender == controller, BondingCurveCallerNotController());
    _;
}

modifier whenNotPaused() {
    require(!paused(), "Pausable: paused");
    _;
}
```

#### 8. **Event Organization**

Group events by purpose:

```solidity
// ============ Events ============
event UserEntered(address indexed user, address indexed asset, uint256 deposit, uint256 tokensMinted, uint256 timestamp);
event RedeemedImmediately(address indexed user, address indexed asset, uint256 redeemedCollateral, uint256 tokensBurned, uint256 timestamp);
event RedeemQueued(address indexed user, uint256 indexed requestId, uint256 timestamp);
```

#### 9. **Error Organization**

Group custom errors by category:

```solidity
// ============ Errors ============
error BondingCurveZeroAddress();
error BondingCurveTokenNotAllowed();
error BondingCurveInvalidRange();
error BondingCurveInsufficientDeposit();
```

#### 10. **Implementation Checklist**

- [ ] Group storage variables by type
- [ ] Place constants at the top
- [ ] Organize functions by purpose and access level
- [ ] Use clear section headers
- [ ] Group related functions together
- [ ] Place modifiers after storage variables
- [ ] Group events and errors by category
- [ ] Maintain interface compliance order
- [ ] Consider gas efficiency in variable ordering
- [ ] Add comments for complex groupings

#### 11. **Benefits of Proper Organization**

- **Readability**: Easy to find specific functionality
- **Maintainability**: Clear structure makes updates easier
- **Gas Efficiency**: Proper variable packing reduces gas costs
- **Code Review**: Reviewers can quickly understand the contract structure
- **Debugging**: Related functions are grouped together
- **Documentation**: Structure serves as implicit documentation

#### 12. **Example: Complete Contract Structure**

```solidity
contract ExampleContract is IExample, Initializable, UUPSUpgradeable, PausableUpgradeable {
    // ============ Constants ============
    uint256 private constant MAX_SUPPLY = 1000000e18;
    
    // ============ Storage Variables ============
    // uint256 variables
    uint256 public totalSupply;
    uint256 public maxSupply;
    
    // bool variables
    bool public initialized;
    
    // address variables
    address public owner;
    address public treasury;
    
    // complex types
    mapping(address => uint256) public balances;
    EnumerableSet.AddressSet private _allowedTokens;
    
    // ============ Modifiers ============
    modifier onlyOwner() { ... }
    modifier whenNotPaused() { ... }
    
    // ============ Events ============
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Mint(address indexed to, uint256 amount);
    
    // ============ Errors ============
    error InsufficientBalance();
    error ExceedsMaxSupply();
    
    // ============ Initialization ============
    function initialize(...) public initializer { ... }
    
    // ============ User Functions ============
    function transfer(...) external { ... }
    function mint(...) external { ... }
    
    // ============ Owner Functions ============
    function setMaxSupply(...) external onlyOwner { ... }
    function pause() external onlyOwner { ... }
    
    // ============ Internal Functions ============
    function _mint(...) internal { ... }
    function _transfer(...) internal { ... }
}
```

This organization approach has been successfully applied to the BondingCurve contract, resulting in improved readability, maintainability, and gas efficiency.

## Code Styling Guidelines 

This project follows the following code styling standards for Solidity development. All code must adhere to these guidelines for consistency, readability, and maintainability.

### Solhint Configuration

The project uses a simplified solhint configuration based on the following standards:

```json
{
  "extends": "solhint:recommended",
  "rules": {
    "compiler-version": ["warn"],
    "quotes": "off",
    "func-visibility": ["warn", { "ignoreConstructors": true }],
    "no-inline-assembly": "off",
    "no-empty-blocks": "off",
    "private-vars-leading-underscore": ["warn", { "strict": false }],
    "ordering": "warn",
    "avoid-low-level-calls": "off",
    "named-parameters-mapping": "warn"
  }
}
```

### Code Organization

#### 1. **Interface Separation**
Always separate interfaces from contracts.

#### 2. **Import Syntax**
Always use named imports to avoid inadvertently bringing into scope all names defined in a package:

✅ **Do:**
```solidity
import {IERC20, ERC20} from '@libraries/ERC20.sol';
```

❌ **Don't:**
```solidity
import '@libraries/ERC20.sol';
```

#### 3. **Import Organization**
Minimize imports by grouping related items from a single file.
Use remappings for clarity and maintainability instead of relative paths.

✅ **Do:**
```solidity
import {IERC20, ERC20} from '@libraries/ERC20.sol';
```

❌ **Don't:**
```solidity
// No remappings, not grouped imports
import {IERC20} from '../../@libraries/ERC20.sol';
import {ERC20} from '../../@libraries/ERC20.sol';
```

#### 4. **Import Order**
1. External Libraries
2. Internal Libraries
3. Local Interfaces
4. Local Contracts

### Naming Conventions

#### 1. **Variable Naming**

**State Variables:**
- **Immutable and Constant Variables**: Use `UPPERCASE_SNAKE_CASE`
- **Public and External Variables**: Use `camelCase`
- **Private and Internal Variables**: Use `_camelCase`, prefixed with an underscore `_`

**Local Variables:**
- Use `_camelCase`, starting with an underscore `_`

**Function Arguments and Return Values:**
- Function arguments and return value names should use `_camelCase` and always start with an underscore `_`

#### 2. **Interface Naming**
Interfaces must always start with the letter `I` (e.g., `IUserRegistry`)

#### 3. **Events**
- **Naming**: Events should always be named in the past tense
- **Definition**: Always define events in the contract interface
- **Standard**: Always emit events when storage or state is changed

#### 4. **Errors**
- **Naming**: Errors should be prefixed with the contract name and use CapWords style
- **Definition**: Errors must be defined in interfaces whenever possible

#### 5. **Structs & Enums**
- **Naming**: Structs and Enums should be named using the CapWords style
- **Definition**: Always define Structs and Enums in the interface

### Code Formatting

#### 1. **Indentation**
- Use 4 spaces per indentation level
- Avoid mixing tabs and spaces

#### 2. **Blank Lines**
- Surround top-level declarations with two blank lines
- Within a contract, separate function declarations with a single blank line

#### 3. **Function Declarations**
- For short functions, place the opening brace on the same line as the function declaration
- For long function declarations, list each argument on its own line, aligning with the function body
- Order function modifiers as follows:
  1. Visibility (e.g., `public`, `internal`)
  2. Mutability (`pure`, `view`, `payable`)
  3. Virtual
  4. Override
  5. Custom modifiers

#### 4. **Mappings and Arrays**
- Do not separate the `mapping` keyword from its type with a space
- Avoid spaces between the type and brackets in array declarations

#### 5. **Strings and Operators**
- Use double quotes for string literals
- Surround operators with a single space on both sides

### Contract Structure Order

Organize your contract in the following order:

1. **Pragma statements**
2. **Import statements**
3. **Interfaces**
4. **Libraries**
5. **Contracts**

Within each contract, order elements as:

1. **State variables**
2. **Events**
3. **Modifiers**
4. **Functions** (constructor, external, public, internal, private)

### Example Implementation

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import {IUserRegistry} from '../interfaces/IUserRegistry.sol';
import {UserRegistry} from './UserRegistry.sol';

contract ExampleContract is IExampleContract {
    // ============ Constants ============
    uint256 public constant MAX_SUPPLY = 1000000e18;
    uint256 private constant _INITIAL_SUPPLY = 100000e18;

    // ============ State Variables ============
    // Public variables (camelCase)
    address public owner;
    uint256 public totalSupply;

    // Private variables (_camelCase)
    mapping(address => uint256) private _balances;
    bool private _initialized;

    // ============ Events ============
    event UserRegistered(address indexed _user, uint256 _timestamp);
    event SupplyUpdated(uint256 _oldSupply, uint256 _newSupply);

    // ============ Errors ============
    error ExampleContract_InvalidAddress();
    error ExampleContract_ExceedsMaxSupply();

    // ============ Modifiers ============
    modifier onlyOwner() {
        if (msg.sender != owner) revert ExampleContract_InvalidAddress();
        _;
    }

    modifier whenNotInitialized() {
        if (_initialized) revert ExampleContract_InvalidAddress();
        _;
    }

    // ============ Constructor ============
    constructor(address _owner) {
        if (_owner == address(0)) revert ExampleContract_InvalidAddress();
        owner = _owner;
    }

    // ============ External Functions ============
    function registerUser(address _user) external onlyOwner {
        if (_user == address(0)) revert ExampleContract_InvalidAddress();
        emit UserRegistered(_user, block.timestamp);
    }

    // ============ Public Functions ============
    function getBalance(address _user) public view returns (uint256) {
        return _balances[_user];
    }

    // ============ Internal Functions ============
    function _updateSupply(uint256 _newSupply) internal {
        uint256 _oldSupply = totalSupply;
        totalSupply = _newSupply;
        emit SupplyUpdated(_oldSupply, _newSupply);
    }

    // ============ Private Functions ============
    function _validateAmount(uint256 _amount) private pure returns (bool) {
        return _amount > 0 && _amount <= MAX_SUPPLY;
    }
}
```

### Implementation Checklist

When writing or reviewing code, ensure:

- [ ] Interfaces are separated from contracts
- [ ] Named imports are used consistently
- [ ] Import order follows the specified sequence
- [ ] Variable naming follows the specified conventions
- [ ] Events are named in past tense and defined in interfaces
- [ ] Errors are prefixed with contract name and defined in interfaces
- [ ] Structs and Enums use CapWords style and are defined in interfaces
- [ ] Function modifiers are ordered correctly
- [ ] Contract structure follows the specified order
- [ ] Code is properly indented with 4 spaces
- [ ] Blank lines are used appropriately
- [ ] All code passes solhint validation

### Benefits of Following These Guidelines

- **Consistency**: All code follows the same patterns
- **Readability**: Clear naming and structure make code easy to understand
- **Maintainability**: Well-organized code is easier to modify and extend
- **Team Collaboration**: Consistent standards improve code review efficiency
- **Professional Quality**: Adherence to industry best practices
- **Reduced Bugs**: Clear structure and naming reduce the likelihood of errors

This styling approach ensures that all Solidity code in the project maintains high quality, consistency, and professional standards.

## Testing Guidelines

This project follows the given testing methodology for comprehensive smart contract testing. All code must be properly tested with meaningful unit and integration tests before merging.

### Testing Philosophy

Testing is everyone's responsibility. We do not merge pull requests that aren't properly tested, "properly" as in "having relevant and meaningful tests." During a project's implementation, we write two types of tests: unit tests and integration tests.

### Unit Testing

#### Definition
A "unit" is defined as the smallest piece of logic in a system. In a protocol built from smart contracts, we define functions as units. A unit test's purpose is to test the behaviour of this unit in every possible scenario.

#### Approach
- **Isolate the unit** by mocking any external dependencies (solitary testing)
- **Study and test every branch** - the number of branches tested is expressed as test coverage
- **Use mocking** to create arbitrary values when external dependencies are used

#### Mocking with Forge

We use `vm.mockCall(target address, calldata, returned value)` for mocking:

```solidity
// Mock an external call
vm.mockCall(
    targetAddress,
    abi.encodeCall(IERC20.balanceOf, (user)),
    abi.encode(balance)
);

// Expect the call to be made
vm.expectCall(targetAddress, abi.encodeCall(IERC20.balanceOf, (user)));
```

**Helper Library Example:**
```solidity
library Halp {
    Vm constant _vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

    function mockExpect(address _target, bytes memory _callData, bytes memory _returnData) internal {
        _vm.etch(_target, new bytes(0x1));
        _vm.mockCall(_target, _callData, _returnData);
        _vm.expectCall(_target, _callData);
    }
}

// Usage
contract UnitTest {
    using {Halp.mockExpect} for address;

    function test_GetTokenBalance(address _caller, uint256 _balance) public {
        address(_token).mockExpect(abi.encodeCall(IERC20.balanceOf, (_caller)), abi.encode(_balance));

        uint256 _readBalance = _token.balanceOf(_caller);
        assertEq(_balance, _readBalance);
    }
}
```

#### Branch and Path Coverage

Every function can be represented as a directed connected graph. A set of edges going from the entry point to a given end-state is called a branch or path.

**Example:**
```solidity
function foo(bool x, bool y) returns (bool) {
    if (x && y) {
        return true;
    }
    return false;
}
```

**Control Flow Chart:**
```
foo
├── x && y (true)
│   └── return true
└── x && y (false)
    └── return false
```

**Coverage Types:**
- **Branch Coverage**: Tests each decision point
- **Path Coverage**: Tests every possible execution path
- **Statement Coverage**: Tests each line of code
- **Function Coverage**: Tests each function

**When to use each:**
- **Path Coverage**: When there are no independent control structures
- **Branch Coverage**: When there are independent conditions

#### Coverage Measurement

We use `forge coverage` to measure coverage across 4 metrics:

1. **% Lines**: Portion of lines seen in tests
2. **% Statements**: Portion of statements seen
3. **% Branches**: Portion of branches seen
4. **% Funcs**: Portion of functions seen

**Commands:**
```bash
# Basic coverage
forge coverage

# Export to lcov format
forge coverage --report lcov

# Coverage with specific path
forge coverage --match-path "src/**/*.sol"
```

**Target**: 100% branch coverage by end of development phase.

#### Bulloak for Test Organization

We use Bulloak to create systematic test trees that list all branches/paths to explore.

**Tree File Example** (`Foo::myFunc.tree`):
```
Foo::myFunc()
├── Given sender is owner
│   ├── When sending eth
│   │   ├── It should wrap the eth
│   │   ├── It should update the vault
│   │   └── It should call _claim
│   └── When not sending eth
│       └── It should revert
└── When sender is not the owner
    └── It should revert
```

**Generate Test Skeleton:**
```bash
# Generate test from tree
bulloak scaffold path/to/file.tree -S

# Generate all tests
bulloak scaffold *.tree -S

# Update existing tests
bulloak check --fix
```

**Generated Test Structure:**
```solidity
contract FoomyFunc is Test {
    modifier WhenSenderIsOwner() {
        _;
    }

    function test_WhenSendingEth() external WhenSenderIsOwner {
        // It should wrap the eth
        // It should update the vault
        // It should call _claim
        vm.skip(true);
    }

    function test_WhenNotSendingEth() external WhenSenderIsOwner {
        // It should revert
        vm.skip(true);
    }

    function test_GivenSenderIsNotTheOwner() external {
        // It should revert
        vm.skip(true);
    }
}
```

#### Internal Function Testing

Internal functions are tested via a dedicated contract that exposes them:

```solidity
contract TestableContract is OriginalContract {
    function exposedInternalFunction() external {
        return _internalFunction();
    }
}
```

### Integration Testing

Integration tests study how units interact with each other or with external dependencies.

#### Approach
- **Focus on interactions** between multiple units
- **Don't focus on branch coverage** (unit tests provide this)
- **Use happy and sad paths**

#### Happy Path vs Sad Path
- **Happy Path**: Normal, intended way of working
- **Sad Path**: Most common errors and edge cases

**Example:**
```solidity
contract Foo {
    function foo() external {
        if(!Bar(address).prepareBar) revert();
        doSomething();
    }
}

contract Bar {
    bool prepareBar;

    function bar() external {
        if(!prepareBar) revert();
        doSomeStuff();
        Foo(address).foo();
    }

    function baz() external {
        prepareBar = true;
    }
}

// Happy path: baz() -> bar()
// Sad path: bar() only or foo() only
```

### Fuzzing

We use fuzzed variables to cover a range of values corresponding to a single branch or path.

#### Basic Fuzzing
```solidity
function test_foo(uint256 fuzzMeDaddy) external {
    // test some stuff, with fuzzMeDaddy taking different values
}
```

#### Bounded Fuzzing
```solidity
function test_foo(uint256 fuzzMeDaddy) external {
    // Restrict to values between 0 and 100
    fuzzMeDaddy = bound(fuzzMeDaddy, 0, 100);
    // test some stuff
}
```

#### Type-based Bounding
```solidity
function test_foo(uint8 fuzzMeDaddy) external {
    // Automatically bounded to uint8 range (0-255)
    // test some stuff
}
```

#### Fuzzing Best Practices
- **Use `bound()` instead of `vm.assume()`** to avoid dropped runs
- **Test one branch per fuzzed test** - don't test multiple branches based on fuzzed values
- **Avoid complex conditions** that would drop too many runs

### Test-Driven Development (TDD)

We adopt a TDD approach using the "3 Laws of TDD":

1. **You are not allowed to write any production code unless it is to make a failing unit test pass**
2. **You are not allowed to write any more of a unit test than is sufficient to fail, and compilation failures are failures**
3. **You are not allowed to write any more production code than is sufficient to pass the one failing unit test**

#### TDD Process
1. Start by writing the tree of the unit
2. Pick one of the tree branches
3. Write a single test that fails (compilation error counts as failing)
4. Write the code that makes that test pass, and nothing more
5. If not covering every branch, go to step 2

### Testing Commands

#### Basic Testing
```bash
# Run all tests
forge test

# Run tests with gas report
forge test --gas-report

# Run specific test
forge test --match-test testFunctionName

# Run tests for specific contract
forge test --match-contract ContractName
```

#### Coverage Analysis
```bash
# Basic coverage
forge coverage

# Coverage with lcov export
forge coverage --report lcov

# Coverage for specific files
forge coverage --match-path "src/**/*.sol"
```

#### Fuzzing Configuration
```bash
# Run with more fuzz runs
forge test --fuzz-runs 1000

# Run specific fuzz test
forge test --match-test testFuzz_FunctionName
```

### Test File Organization

```
test/
├── unit/                    # Unit tests
│   ├── AMM.t.sol
│   ├── Controller.t.sol
│   ├── EVE.t.sol
│   ├── ExitQueue.t.sol
│   ├── Oracle.t.sol
│   └── StrategyManager.t.sol
├── fuzz/                    # Fuzz tests
│   └── OracleFuzz.t.sol
├── fork/                    # Mainnet fork tests (skip when MAINNET_RPC_URL unset)
│   └── UniCLStratFork.t.sol
├── integration/             # Integration tests
│   ├── DeploymentTest.t.sol
│   ├── ETHFlowTest.t.sol
│   └── UpgradeSimulation.t.sol
├── trees/                   # Bulloak tree files
│   ├── AMM.tree
│   ├── Controller.tree
│   ├── EVE.tree
│   ├── ExitQueue.tree
│   ├── Oracle.tree
│   └── StrategyManager.tree
├── helpers/                 # Helper libraries
│   └── Halp.sol
└── mocks/                   # Mock contracts
    ├── IERC20.sol
    ├── MockController.sol
    ├── MockERC20.sol
    ├── MockPriceFeed.sol
    └── MockStrategy.sol
```

### Test Naming Conventions

Tests follow a consistent naming pattern for clarity and maintainability:

**Standard Tests:**
- `test_FunctionName()` - Basic functionality test
- `test_FunctionName_Condition()` - Specific scenario test
  - Examples: `test_DistributeToStrategies_RespectsMaxDeposit`, `test_Enter_InvalidInputs`

**Access Control Tests:**
- `test_FunctionName_AccessControl()` - Tests role-based access control
  - Examples: `test_DistributeToStrategies_AccessControl`, `test_Pause_AccessControl`

**Invalid Input Tests:**
- `test_FunctionName_InvalidInputs()` - Tests invalid parameter validation
- `test_FunctionName_InvalidConditions()` - Tests invalid state conditions
  - Examples: `test_AddStrategy_InvalidConditions`, `test_Exit_InvalidInputs`

**Pause Tests:**
- `test_FunctionName_WhenPaused()` - Tests behavior when contract is paused
  - Examples: `test_DistributeToStrategies_WhenPaused`, `test_Operations_WhenPaused`

**Fuzz Tests:**
- `testFuzz_FunctionName_Description()` - Property-based fuzz tests
  - Examples: `testFuzz_Enter_WithValidAmounts`, `testFuzz_AddStrategy`

**Benefits of This Convention:**
- Groups related tests together in test output
- Makes test purpose immediately clear from the name
- Reduces redundancy by consolidating similar tests
- Improves maintainability and readability

### Testing Checklist

#### Unit Tests
- [ ] All functions have corresponding unit tests
- [ ] External dependencies are properly mocked
- [ ] All branches/paths are covered
- [ ] Edge cases are tested
- [ ] Error conditions are tested
- [ ] Events are properly tested with `vm.expectEmit()`
- [ ] Internal functions are tested via testable contracts

#### Integration Tests
- [ ] Happy paths are covered
- [ ] Sad paths are covered
- [ ] Cross-contract interactions work
- [ ] External protocol integrations work
- [ ] End-to-end user flows work

#### Coverage
- [ ] Branch coverage is maximized
- [ ] Coverage gaps are identified and addressed
- [ ] Unreachable code is documented
- [ ] Coverage reports are generated and reviewed

#### Fuzzing
- [ ] Appropriate functions are fuzzed
- [ ] Fuzzed values are properly bounded
- [ ] `vm.assume()` is avoided in favor of `bound()`
- [ ] One branch per fuzzed test

### Example Test Implementation

#### Unit Test Example
```solidity
contract AMMEnterTest is Test {
    using {Halp.mockExpect} for address;

    AMM public amm;
    MockERC20 public token;
    address public user = makeAddr("user");

    function setUp() public {
        // Setup contracts
        amm = new AMM(controller, strategyManager, 6e17, eve);
        token = new MockERC20("Test Token", "TT");
        
        // Setup mocks
        vm.mockCall(
            address(strategyManager),
            abi.encodeCall(IStrategyManager.totalNAVInUSD, ()),
            abi.encode(1000e18)
        );
    }

    function test_Enter() public {
        // Basic functionality test
        uint256 deposit = 1 ether;
        uint256 minTokens = 50e18;
        
        amm.enter{value: deposit}(minTokens);
        
        assertTrue(amm.bootstrapped());
        assertGt(eve.balanceOf(user), 0);
    }

    function test_Enter_InvalidInputs() public {
        // Invalid input validation
        // Zero min tokens
        vm.expectRevert(IAMM.AMMInvalidTokensToMintAmount.selector);
        amm.enter{value: 1 ether}(0);

        // Insufficient deposit
        vm.expectRevert(IAMM.AMMInsufficientDeposit.selector);
        amm.enter{value: 0.1 ether}(50e18);
    }

    function test_Enter_WhenPaused() public {
        // Pause behavior
        amm.pause();
        
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        amm.enter{value: 1 ether}(50e18);
    }
}
```

#### Integration Test Example
```solidity
contract ProtocolIntegrationTest is Test {
    AMM public amm;
    Controller public controller;
    StrategyManager public strategyManager;
    EVE public eve;

    function setUp() public {
        // Deploy all contracts
        controller = new Controller();
        strategyManager = new StrategyManager();
        amm = new AMM(address(controller), address(strategyManager), 6e17, address(eve));
        eve = new EVE();
        
        // Setup roles and permissions
        controller.grantRole(controller.ADMIN_ROLE(), address(this));
        strategyManager.grantRole(strategyManager.ADMIN_ROLE(), address(this));
    }

    function test_CompleteUserFlow_ShouldWork() public {
        // Happy path: User enters protocol, waits, then exits
        // 1. User enters with ETH
        amm.enter{value: 1 ether}(1 ether, 500e18);
        
        // 2. User waits for price appreciation
        vm.warp(block.timestamp + 1 days);
        
        // 3. User exits with profit
        amm.exit(1 ether, 500e18, 1e18);
        
        // Verify final state
        assertGt(address(this).balance, 1 ether);
    }

    function test_UserFlow_WhenPaused_ShouldRevert() public {
        // Sad path: User tries to enter when paused
        controller.pause();
        
        vm.expectRevert();
        amm.enter{value: 1 ether}(1 ether, 500e18);
    }
}
```
