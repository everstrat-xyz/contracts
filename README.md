# Smart Contracts

Smart contracts for the Everything Strategy DeFi protocol - a blockchain-based platform that enables users to deposit native ETH to the treasury and receive EVE tokens using a bonding curve mechanism.

## Overview

This project uses [Foundry](https://book.getfoundry.sh/) for development, testing, and deployment. The protocol implements a bonding curve AMM where users can enter by depositing native ETH and exit by burning EVE tokens to receive ETH.

## Operational Runbooks

The protocol is deliberately **fail-closed**: several failure modes (stale oracle, reverting strategy NAV, uncalm Uniswap pool, pauses) freeze pricing or operations instead of settling at an untrusted price. Step-by-step instructions for the DAO and security multisig for each freeze scenario — including the quick-reference incident matrix, emergency capital-recovery chain, full-freeze / staged un-freeze procedures, and the monitoring/alerting appendix — live in [`docs/FREEZE_RUNBOOK.md`](docs/FREEZE_RUNBOOK.md).

## Governance (Timelocked Privileged Actions)

Every privileged role is held by an OpenZeppelin `TimelockController` in production — no EOA or multisig acts on the protocol directly (audit finding PL-003):

| Role | Holder | Delay | Scope |
|------|--------|-------|-------|
| `SECURITY_ROLE` | security multisig | none | Emergency `pause()` (all pausable modules + Registry), emergency capital unwind, `StrategyManager.removeSupportedERC20()` (stale-feed / dust-NAV unfreeze), and `Whitelist.removeSigner()` (instant invite-signer revoke). Cannot unpause, configure, or upgrade. Also CANCELLER on the timelock. |
| `ADMIN_ROLE` | 48h timelock | 48h | Config, Oracle feed / token configuration, strategy set, Whitelist invite-period admin (`addSigner`, `addToWhitelist`, `removeFromWhitelist`, irreversible `disable()`), Registry wiring, role management, unpause, UUPS upgrades (schedule upgrades with a longer delay by policy) |

The DAO multisig is the PROPOSER on the timelock and holds no direct protocol role; execution is open once the delay elapses. Wiring lives in `script/DeployAll.s.sol` / `script/ProtocolDeployBase.sol`; behaviour is verified in `test/integration/TimelockGovernance.t.sol`.

## Contracts

### Registry

**Location:** `src/contracts/registry/Registry.sol`

UUPS upgradeable hub for protocol contract addresses (`Auth`) and operational roles (`Auth`). All core modules use `RegistryClient` mixins to resolve peers and check roles at runtime.

**Features:**
- Register / unregister contracts (`registerContract`, `registerContracts`, …)
- Grant / revoke roles (`grantRole`, `grantRoles`, …) — `ADMIN_ROLE` on Registry
- `initialize(_admin)` grants `ADMIN_ROLE` to the admin (the 48h timelock in production) and deployer; the deployer renounces after wiring
- Pausable (`pause` by `ADMIN_ROLE` or `SECURITY_ROLE`; `unpause` by `ADMIN_ROLE` only); UUPS upgradeable

**Deployment:** `script/DeployRegistry.s.sol`, or first step of `script/DeployAll.s.sol`. See `mermaid/deployment-architecture.md` for modular order and `FinalizeProtocolDeploy.s.sol`.

**Tests:** `test/unit/Registry.t.sol`, `test/integration/DeployerAdminAccessTest.t.sol`

### EVE Token

**Location:** `src/contracts/EVE.sol`

A static (immutable) ERC20 token contract for the EVE protocol token.

**Features:**
- **Static Contract:** Immutable "code is law" implementation
- **ERC20 Standard:** Full implementation of ERC20 token standard
- **RegistryClient:** Immutable registry reference in constructor
- **Mintable / Burnable:** Holders of `MINTER_ROLE` on Registry (typically the AMM)

**Key Functions:**
```solidity
// Requires MINTER_ROLE on Registry
function mint(address to, uint256 amount) external
function burn(uint256 amount) external
function burnFrom(address account, uint256 amount) external
```

**Testing:**
- Comprehensive test suite in `test/unit/EVE.t.sol`

### AMM (Automated Market Maker)

**Location:** `src/contracts/AMM.sol`

A static (immutable) bonding curve contract that handles ETH deposits and EVE token minting/burning.

**Features:**
- **Static Contract:** Immutable "code is law" implementation
- **Native ETH Support:** Users deposit and redeem native ETH (no ERC20 tokens)
- **Bonding Curve Pricing:** Dynamic pricing based on NAV and connector weight
- **Dual Pricing:** Base price (`liveNAV / liveSupply`) and Premium price (`liveNAV / (liveSupply · cw)`) — live NAV excludes in-window priced ExitQueue liability; live supply excludes in-window escrowed EVE. Unpriced queued tokens stay in the denominator.
- **Oracle Usage:** Oracle is NOT used in enter/exit operations (hot path). Oracle is only used for:
  - Bootstrap minimum deposit validation (converts ETH to USD to check MIN_INITIAL_DEPOSIT_USD)
  - USD price view functions (`eveBasePriceInUSD()`, `evePremiumPriceInUSD()`)
- **Redemption Queue:** Queued redemption system via ExitQueue for insufficient liquidity. Unpriced queued EVE is still cancellable equity (NAV/supply unchanged). After `priceBatch`, live NAV deducts `liabilityETH` and live supply deducts escrowed tokens until pull, slippage close, or the 3-day window lapses
- **Batch Exit Minimum:** `minBatchExitETH` (default 0.001 ETH) enforced on the queued exit path only; immediate exit has no minimum. Admin-configurable via `setMinBatchExitETH()` (0 disables the check; capped at `MIN_BATCH_EXIT_ETH_UPPER_BOUND` = 0.05 ETH).
- **Pull-over-Push Redemption:** Processed redemptions credit ETH to `claimableBalances` rather than pushing directly to the user, preventing malicious recipients from blocking batch processing
- **Free Balance Tracking:** `freeBalance()` returns `address(this).balance - lockedForClaims`, used for liquidity checks so locked claim funds are never double-counted
- **Bootstrap Mechanism:** Initial liquidity provision with dead supply lock
- **Enter CEI:** Post-bootstrap `enter` mints EVE before forwarding ETH to the Controller (`sendValue`), matching bootstrap — keeps NAV/supply consistent for any observer during the Controller `receive` callback
- **Entry Whitelist Gate:** While the Registry `WHITELIST` invite period is active, `enter()` requires the caller to be whitelisted (`AMMNotWhitelisted` otherwise). First-time admission can use `enterWithInvite(...)` (redeems an EIP-712 voucher then mints in one tx). `exit()` is never gated. After `Whitelist.disable()`, entry is open to everyone.
- **RegistryClient:** `constructor(address _registry, uint256 _connectorWeight)`
- **Access:** `ADMIN_ROLE` on Registry for connector weight and pause; registered `CONTROLLER` for `processRedemption()`

**Key Functions:**
```solidity
function enter(uint256 _minTokensToMint) external payable
function enterWithInvite(uint256 _minTokensToMint, bytes32 _inviteId, uint256 _deadline, bytes calldata _signature) external payable
function exit(uint256 _requestedETH, uint256 _maxTokensToBurn, uint256 _priceTolerance) external returns (uint256)
function processRedemption(uint256 _batchId, address _user) external payable
function cancelRedemption(uint256 _batchId) external
function claim() external                              // Pull claimable ETH after processRedemption
function freeBalance() external view returns (uint256) // address(this).balance - lockedForClaims
function setMinBatchExitETH(uint256 _minBatchExitETH) external // ADMIN_ROLE; 0 disables; max MIN_BATCH_EXIT_ETH_UPPER_BOUND
```

**Constants:**
- `DEFAULT_MIN_BATCH_EXIT_ETH = 1e15` (0.001 ETH) — initial value for `minBatchExitETH`
- `MIN_BATCH_EXIT_ETH_UPPER_BOUND = 5e16` (0.05 ETH) — maximum allowed value for `setMinBatchExitETH()`

**Storage (pull-over-push accounting):**
- `claimableBalances` (mapping): ETH owed to each user after their queued redemption is processed
- `lockedForClaims` (uint256): Total ETH currently held for pending claims (excluded from free balance)

**Events:**
- `UserEntered(address indexed user, uint256 deposit, uint256 tokensMinted, uint256 timestamp)`
- `RedeemedImmediately(address indexed user, uint256 redeemedETH, uint256 tokensBurned, uint256 timestamp)`
- `RedemptionQueued(address indexed user, uint256 indexed redemptionBatchId, uint256 timestamp)` — emitted when a redemption is queued to ExitQueue
- `RedemptionProcessed(address indexed user, uint256 indexed redemptionBatchId, uint256 timestamp)` — emitted when a queued redemption is processed (both successful and slippage-closed cases)
- `RedemptionCancelled(address indexed user, uint256 indexed redemptionBatchId, bool viaEscapeHatch, uint256 timestamp)` — emitted when a user cancels a queued redemption; `viaEscapeHatch` is true when cancelled after `MAX_BATCH_PROCESSING_TIME` exceeded
- `Claimed(address indexed user, uint256 claimableETH, uint256 timestamp)` — emitted when a user pulls their claimable ETH via `claim()`
- `Bootstrapped(address indexed user, uint256 deposit, uint256 userTokensMinted, uint256 timestamp)`
- `ConnectorWeightChanged(uint256 initial, uint256 current)` — emitted on deployment (`initial = 0`) and on `setConnectorWeight()`
- `MinBatchExitETHChanged(uint256 initial, uint256 current)` — emitted on deployment (`initial = 0`, `current = DEFAULT_MIN_BATCH_EXIT_ETH`) and on `setMinBatchExitETH()`

**Errors:**
- `AMMNotWhitelisted` — thrown by `enter()` when the invite gate is active and the caller is not whitelisted
- `AMMNoClaimableBalance` — thrown by `claim()` when `claimableBalances[msg.sender] == 0`
- `AMMTooLowBatchExitETH` — thrown when `ethToRedeem` is below `minBatchExitETH` on the queued exit path
- `AMMInvalidMinBatchExitETH` — thrown when `setMinBatchExitETH()` value exceeds `MIN_BATCH_EXIT_ETH_UPPER_BOUND`

**Testing:**
- Comprehensive test suite in `test/unit/AMM.t.sol`
- Whitelist gate coverage in `test/unit/AMMWhitelist.t.sol`
- Integration tests in `test/integration/ETHFlowTest.t.sol`

### Whitelist

**Location:** `src/contracts/Whitelist.sol`

Static (immutable) invite gate for protocol **entry**. The AMM resolves it via Registry key `WHITELIST`. Exit is never checked.

Full overview and off-chain integration flow: [`docs/WHITELIST.md`](docs/WHITELIST.md).

**Features:**
- **EIP-712 vouchers:** domain `EverStratWhitelist` / `1`; struct `Invite(address user, bytes32 inviteId, uint256 deadline)`
- **Opaque `inviteId`:** server-chosen; not the human invite code (and not a direct on-chain hash of it)
- **Permissionless `whitelist()`:** relayers can sponsor gas; already-whitelisted / post-`disable()` is a no-op that leaves the invite unconsumed
- **Asymmetric signers:** `addSigner` is `ADMIN_ROLE` only; `removeSigner` is `ADMIN_ROLE` or `SECURITY_ROLE` (instant revoke)
- **Irreversible `disable()`:** opens entry to everyone; invite-period admin mutators then revert with `WhitelistIsDisabled`
- **Invite-period bans:** `removeFromWhitelist` bans for the gate-active period only; `addToWhitelist` clears the ban so admin re-admit restores entry. After `disable()`, bans no longer block entry
- **Empty redeploys:** no previous-Whitelist fallback — migrate with `addToWhitelist` or open with `disable()`

**Key Functions:**
```solidity
function whitelist(address _user, bytes32 _inviteId, uint256 _deadline, bytes calldata _signature) external
function addToWhitelist(address[] calldata _users) external          // ADMIN_ROLE; also clears invite-period ban
function removeFromWhitelist(address _user) external                 // ADMIN_ROLE (ban for invite period)
function addSigner(address _signer) external                         // ADMIN_ROLE
function removeSigner(address _signer) external                      // ADMIN_ROLE or SECURITY_ROLE
function disable() external                                          // ADMIN_ROLE; irreversible
function isWhitelisted(address _user) external view returns (bool)
```

**Deployment:** `script/DeployWhitelist.s.sol` (requires `REGISTRY_ADDRESS`, `WHITELIST_SIGNER_ADDRESS`; zero signer postpones seeding), or included in `DeployAll`.

**Testing:** `test/unit/Whitelist.t.sol`, `test/unit/AMMWhitelist.t.sol`

### Controller

**Location:** `src/contracts/Controller.sol`

An upgradeable controller contract that orchestrates protocol operations, receives ETH from AMM, and coordinates fund distribution to strategies via keeper functionality.

**Features:**
- **Upgradeable Pattern:** Uses UUPS (Universal Upgradeable Proxy Standard)
- **RegistryClientUpgradeable:** `initialize(address _registry)`
- **Access:** `KEEPER_ROLE` and `ADMIN_ROLE` on Registry; resolves AMM, StrategyManager, ExitQueue, and EVE via `Auth`
- **Keeper Functionality:** Deposit/withdraw/rebalance, redemption queue, `provideExitLiquidity`
- **AMM / ExitQueue / StrategyManager:** Caller must be the registered `CONTROLLER` address on Registry for cross-contract ops
- **Exit Liquidity:** KEEPER_ROLE can route Controller ETH to the AMM via `provideExitLiquidity()`; in the automated trust model the `CREStrategyExecutor` does this via its `ProvideExitLiquidity` action, which tops the AMM immediate-exit float up to `exitLiquidityTargetETH` (default `0` = disabled until admin-set, same pattern as `controllerReserveETH`) from idle Controller ETH above the reserve and pending redemption needs; ADMIN_ROLE can sweep all Controller ETH to the AMM via `emergencyExitToAMM()` during emergencies
- **Version Tracking:** Returns "1.0.0"
- **Upgrade Safety:** Includes storage gaps to prevent storage collisions
- **Security:** Only ADMIN_ROLE can authorize upgrades

**Key Functions:**
```solidity
// Keeper Functions (KEEPER_ROLE)
function depositToStrategies(uint256 _amount) external
function depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount) external
function depositToStrategy(address _strategy, uint256 _amount) external
function withdrawFromStrategies(uint256 _amount) external
function withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount) external
function withdrawFromStrategy(address _strategy, uint256 _amount) external
function checkAndRebalanceStrategies() external
function checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex) external
function checkAndRebalanceStrategy(address _strategy) external
function harvestPerformanceFeeFromStrategy(address _strategy) external
function harvestPerformanceFeeFromStrategies() external
function harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex) external
function provideExitLiquidity(uint256 _amount) external

// Redemption Queue Functions (KEEPER_ROLE)
function priceBatch() external
function processRequest(uint256 _batchId, address _user) external
function processRequests(uint256 _batchId) external
function processRequests(uint256 _batchId, uint256 _startIndex, uint256 _endIndex) external

// Emergency Functions (ADMIN_ROLE on Registry)
function emergencyExitToAMM() external
function pause() external
function unpause() external
```

Peers (AMM, StrategyManager, ExitQueue, EVE) are resolved via Registry at call time — no `setAMM` / `setStrategyManager`.

**Keeper Operations:**
- `depositToStrategies(uint256 _amount)`: Funds SM with the deficit (`_amount > SM.balance ? _amount - SM.balance : 0`) then deposits `_amount` to all healthy strategies proportionally by safety level
- `depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)`: Same deficit-top-up pattern; deposits to a range of strategies [startIndex, endIndex)
- `depositToStrategy(address _strategy, uint256 _amount)`: Funds SM with the deficit then deposits `_amount` to a specific strategy (strategy handles capacity validation)
- `withdrawFromStrategies(uint256 _amount)`: Withdraws ETH from all strategies proportionally by withdrawal priority to Controller
- `withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)`: Withdraws from a range of strategies [startIndex, endIndex) proportionally by withdrawal priority
- `withdrawFromStrategy()`: Withdraws ETH from a specific strategy to Controller (strategy handles capacity validation)
- `checkAndRebalanceStrategies()`: Checks all strategies and rebalances any that are unhealthy
- `checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex)`: Checks and rebalances strategies in range [startIndex, endIndex)
- `checkAndRebalanceStrategy()`: Checks a specific strategy and rebalances it if unhealthy
- `syncStrategies()`: Calls `IStrategy.sync()` on all registered strategies (implementation-defined; may no-op)
- `syncStrategies(uint256 _startIndex, uint256 _endIndex)`: Syncs strategies in range [startIndex, endIndex)
- `syncStrategy(address _strategy)`: Syncs a specific strategy
- `harvestPerformanceFeeFromStrategy(address _strategy)`: Harvests accrued performance fees for one strategy via StrategyManager; emits `DirectPerformanceFeeHarvestCompleted`
- `harvestPerformanceFeeFromStrategies()`: Harvests all registered strategies in one EVE mint; emits `PerformanceFeeHarvestCompleted(0, strategyCount, …)`
- `harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex)`: Paginated harvest with one EVE mint; emits `PerformanceFeeHarvestCompleted(startIndex, endIndex, …)`
- `provideExitLiquidity(uint256 _amount)`: Sends ETH from Controller to the AMM to fund immediate redemptions; reverts with `ControllerInsufficientBalance` when `_amount > controller.balance`. Driven automatically by the `CREStrategyExecutor`'s `ProvideExitLiquidity` action (AMM float below `exitLiquidityTargetETH` → top up from idle Controller ETH, minimum top-up `minExitLiquidityTopUpETH`)

**Redemption Queue Operations:**
- `priceBatch()`: Prices the current batch using AMM's live base EVE price (`eveBasePriceInETH()`, already net of previously priced in-window batches; this batch is still equity at the read), making it processable
- `processRequest(uint256 _batchId, address _user)`: Processes a single redemption request, handling slippage protection
- `processRequests(uint256 _batchId)`: Processes all unprocessed requests in a batch
- `processRequests(uint256 _batchId, uint256 _startIndex, uint256 _endIndex)`: Processes requests in a specific range within a batch

**Pagination:**
- Range parameters use exclusive end index: `[startIndex, endIndex)` - processes strategies from startIndex up to but not including endIndex
- Range validation: `endIndex` must be <= `strategies.length()` and `startIndex` must be < `endIndex`
- Useful for gas optimization when dealing with many strategies

**Emergency Operations:**
- `emergencyExitToAMM()`: Transfers the full Controller ETH balance to the AMM (works while paused)
- `pause()` / `unpause()`: Halt or resume keeper and liquidity provisioning operations

**Events:**
- `DepositToStrategiesCompleted(uint256 requestedAmount, uint256 actualAmount)`
- `DirectDepositCompleted(address indexed strategy, uint256 requestedAmount, uint256 actualAmount)`
- `WithdrawalCompleted(uint256 requestedAmount, uint256 actualAmount)`
- `DirectWithdrawalCompleted(address indexed strategy, uint256 requestedAmount, uint256 actualAmount)`
- `DirectPerformanceFeeHarvestCompleted(address indexed strategy, uint256 eveAmount, uint256 feeETHEquivalent)`
- `PerformanceFeeHarvestCompleted(uint256 startIndex, uint256 endIndex, uint256 eveAmount, uint256 feeETHEquivalent)`
- `ExitLiquidityProvided(uint256 amount)`
- `EmergencyExitedToAMM(uint256 amount)`

**Testing:**
- Comprehensive test suite in `test/unit/Controller.t.sol`

**Deployment:** Requires `REGISTRY_ADDRESS`. Registers `CONTROLLER` on Registry.
```bash
export REGISTRY_ADDRESS=<registry_proxy>
forge script script/DeployController.s.sol:DeployController --rpc-url <your_rpc_url> --broadcast --private-key <your_private_key>
```

### ExitQueue

**Location:** `src/contracts/ExitQueue.sol`

An upgradeable contract that manages queued redemption requests, allowing users to exit the protocol even when immediate liquidity is insufficient.

**Features:**
- **Upgradeable Pattern:** Uses UUPS (Universal Upgradeable Proxy Standard)
- **Implementation Safety:** Constructor calls `_disableInitializers()` to prevent direct initialization of the implementation contract
- **RegistryClientUpgradeable:** `initialize(address _registry)`
- **Callers:** Registered `AMM` for push/pull/close; registered `CONTROLLER` for `priceBatch`
- **Access:** `ADMIN_ROLE` on Registry for pause/unpause/upgrade
- **Slippage Protection:** Price tolerance checks to protect users from unfavorable price movements
- **Pausable:** Can be paused by ADMIN_ROLE or SECURITY_ROLE (`pushRequest`, `pullRequest`, and `priceBatch` are paused; `closeRequest` works when paused for emergency withdrawals)
- **Live share-price offsets:** `liveRedemptionOffsets()` returns `(liabilityETH, escrowedSupply)` for in-window priced, unfinished batches. StrategyManager deducts liability from NAV; AMM and fee mint deduct escrowed supply. Unpriced requests and batches past `MAX_BATCH_PROCESSING_TIME` contribute `(0, 0)` — liability lapses on the clock with no reset tx. Scan window is `[liveScanFromBatchId, currentBatchId)` (equals `currentBatchId` when empty, including at init). Do not use the CRE batch cursor for NAV.
- **Live-priced batch cap:** `MAX_LIVE_PRICED_BATCHES = 25` from `ExitQueueLimits` (aliased by ExitQueue and both CRE `MAX_BATCH_SCAN` constants). `priceBatch` reverts `ExitQueueTooManyLivePricedBatches` if the live-scan width would exceed it. A DoS / `enter()` gas bound, not a cadence target — CRE `minBatchAge` vs the 3-day window implies ~3 overlapping batches.
- **Version Tracking:** Returns "1.0.0"
- **Upgrade Safety:** Includes storage gaps to prevent storage collisions

**Key Functions:**
```solidity
// Callable by registered AMM on Registry
function pushRequest(...) external returns (uint256 batchId_)
function pullRequest(uint256 _batchId, address _user) external
function closeRequest(uint256 _batchId, address _user) external returns (bool _viaEscapeHatch)

// Callable by registered CONTROLLER on Registry
function priceBatch(uint256 _evePrice) external

// View Functions
function batchInfo(uint256 _batchId) external view returns (bool canBeProcessed, uint256 finalEvePrice, uint256 totalTokensToBurn, uint256 createdAt, uint256 pricedAt)
function requestInfo(uint256 _batchId, address _user) external view returns (bool processed, bool closedDueToSlippage, uint256 evePriceAtRequestTime, uint256 tokensToBurn, uint256 priceTolerance)
function requestCanBeClosed(uint256 _batchId, address _user) external view returns (bool)
function liveRedemptionOffsets() external view returns (uint256 liabilityETH, uint256 escrowedSupply)
function liveScanFromBatchId() external view returns (uint256)
function MAX_BATCH_PROCESSING_TIME() external pure returns (uint256)
function MAX_LIVE_PRICED_BATCHES() external pure returns (uint256)
function unprocessedUsersCount(uint256 _batchId) external view returns (uint256)
function unprocessedUsers(uint256 _batchId) external view returns (address[] memory)
function unprocessedUsers(uint256 _batchId, uint256 _startIndex, uint256 _endIndex) external view returns (address[] memory)
```

**Batch Lifecycle:**
1. **Request Creation:** AMM calls `pushRequest()` to queue a redemption request in the current batch (EVE is transferred to the AMM, not burned — still cancellable equity). Reverts `ExitQueueTokensOverflow` if `totalTokensToBurn` would exceed `uint128`.
2. **Batch Pricing:** Controller calls `priceBatch()` to set the final EVE price and `pricedAt` timestamp, and make the batch processable (not callable while ExitQueue or Controller is paused). From this moment live NAV deducts `remainingTokens * finalEvePrice` and live supply deducts remaining escrowed EVE. Reverts `ExitQueueTooManyLivePricedBatches` if `[liveScanFromBatchId, currentBatchId)` already has `MAX_LIVE_PRICED_BATCHES` ids.
3. **Request Processing (in-window only):** AMM calls `pullRequest()` to process individual requests, with slippage checks. After `MAX_BATCH_PROCESSING_TIME`, `pullRequest` reverts `ExitQueueBatchExpired` — live NAV has already dropped the liability.
4. **Manual Cancellation:** AMM calls `closeRequest()` to allow users to cancel requests (works even when paused)
   - **Request closure restriction:** After a batch is priced (`canBeProcessed == true`), requests cannot be closed **within** `MAX_BATCH_PROCESSING_TIME` of `pricedAt`. Within that window they must be settled via `pullRequest()` (or wait out the window). This prevents users from gaming the system by canceling after seeing the final price.
   - **Upper bound / escape hatch:** If more than `MAX_BATCH_PROCESSING_TIME` has passed since the batch was priced, `pullRequest` is forbidden and users may close via `closeRequest()`. Liability has already lapsed in `liveRedemptionOffsets()` with no reset tx. Use `batchInfo()` for `pricedAt` and `requestCanBeClosed(batchId, user)` to check before calling `cancelRedemption()`.

**Slippage Protection:**
- When `pullRequest()` is called, the contract checks if the final price has dropped below the user's tolerance threshold
- If slippage exceeds tolerance, `closedDueToSlippage` flag is set to true
- Users receive their tokens back instead of ETH when slippage is too high

**Errors:**
- `ExitQueueZeroAddress`: Thrown when provided address is zero
- `ExitQueueZeroPrice`: Thrown when provided price is zero
- `ExitQueueBatchCannotBeProcessed`: Thrown when batch cannot be processed at the moment (`batch.canBeProcessed` is false)
- `ExitQueueBatchIsEmpty`: Thrown when batch is empty and cannot be priced
- `ExitQueueRequestNotInBatch`: Thrown when request is not in batch
- `ExitQueueRequestAlreadyProcessed`: Thrown when request is already processed
- `ExitQueueRequestCannotBeClosed`: Thrown when request cannot be closed (batch is priced and still within `MAX_BATCH_PROCESSING_TIME` of `pricedAt`)
- `ExitQueueRequestAlreadyInBatch`: Thrown when request is already in batch
- `ExitQueueInvalidRange`: Thrown when invalid range is provided
- `ExitQueueBatchExpired`: Thrown when `pullRequest` is called after `MAX_BATCH_PROCESSING_TIME` (live NAV has already dropped the liability)
- `ExitQueueTooManyLivePricedBatches`: Thrown when pricing would leave more than `MAX_LIVE_PRICED_BATCHES` ids in the live-scan window
- `ExitQueueTokensOverflow`: Thrown when adding to `totalTokensToBurn` would exceed `uint128`

**Events:**
- `BatchPriced(uint256 indexed batchId)`
- `RequestPushed(uint256 indexed batchId, address indexed user)`
- `RequestPulled(uint256 indexed batchId, address indexed user, bool isWithinTolerance)`
- `RequestClosed(uint256 indexed batchId, address indexed user, bool viaEscapeHatch)` — `viaEscapeHatch` is true when the request was closed because `MAX_BATCH_PROCESSING_TIME` was exceeded

**Testing:**
- Comprehensive test suite in `test/unit/ExitQueue.t.sol`

**Deployment:** Requires `REGISTRY_ADDRESS`. Registers `EXIT_QUEUE` on Registry. Or use `DeployAll`.
```bash
export REGISTRY_ADDRESS=<registry_proxy>
forge script script/DeployExitQueue.s.sol:DeployExitQueue --rpc-url <your_rpc_url> --broadcast --private-key <your_private_key>
```

### StrategyManager

**Location:** `src/contracts/StrategyManager.sol`

An upgradeable contract that manages external investment strategies and NAV calculations.

**Features:**
- **Upgradeable Pattern:** Uses UUPS (Universal Upgradeable Proxy Standard)
- **Registry-Centric Access:** `ADMIN_ROLE` on Registry for strategy management; registered `CONTROLLER` for fund operations
- **ETH-First NAV Calculation:** NAV is calculated in ETH terms first (via `strategy.navInETH()`), then converted to USD when needed via Oracle. Total NAV includes NAV from all registered strategies (any reverting `navInETH()` freezes the protocol), StrategyManager's ETH balance (in-flight funds), the Controller's ETH balance (undistributed funds), the AMM's free balance (ETH available for immediate redemptions; excludes `lockedForClaims`), and the ETH value of every whitelisted supported-ERC-20 balance (priced via `Oracle.convert()` with decimals normalized through `IERC20Metadata.decimals()`), **minus in-window priced ExitQueue liability** (`liveRedemptionOffsets().liabilityETH`). Unpriced queued EVE is still equity. Liability lapses after `MAX_BATCH_PROCESSING_TIME` with no reset tx. Reverts `StrategyManagerQueuedLiabilityExceedsNAV` if liability exceeds gross NAV.
- **NAV Fail-Closed:** If any registered strategy's `navInETH()` reverts, `totalNAVInETH()` reverts and enter/exit/pricing halt until the strategy is fixed or force-removed via `forceRemoveStrategy()` (escape hatch for reverting or over-reporting `navInETH()`). Clean removal of an emptied strategy uses `removeStrategy()` (requires a successful dust-NAV read). Supported-ERC-20 pricing follows the same philosophy: a stale/invalid Oracle feed for a whitelisted token with a non-zero balance freezes NAV (escape hatch: `removeSupportedERC20()` by `ADMIN_ROLE` or `SECURITY_ROLE`); zero balances skip the Oracle entirely
- **Supported-ERC-20 Whitelist:** EnumerableSet of ERC-20 tokens the StrategyManager may hold — e.g. the paired token `UniCLStrat.emergencyExit()` transfers here during an emergency unwind. Whitelisting keeps that value counted in NAV so users cannot enter/exit at prices that ignore recoverable assets. `addSupportedERC20()` is `ADMIN_ROLE`-only (validates non-zero address, code presence, and Oracle priceability); `removeSupportedERC20()` is `ADMIN_ROLE` or `SECURITY_ROLE` (instant stale-feed / dust-NAV escape hatch — allowed even with a non-zero balance; the value drops out of NAV immediately) and makes no external calls so a bricked token cannot block its own removal. Both work while paused. **Future work:** on-chain swap recovery of stranded supported ERC-20s back to native ETH via the shared Converter (`recoverTokenToETH`) is deferred to a follow-up PR — this release ships ERC-20 accounting only.
- **Strategy Removal:** `removeStrategy()` requires a successful `navInETH()` read and reverts if `nav > MAX_NAV_RESIDUE` (10 wei). A reverting `navInETH()` bubbles up — use `forceRemoveStrategy()` instead. Emits `StrategyRemoved(strategy)`. Callable while paused (unlike `addStrategy()`). Both removal paths share `_deregisterStrategy()`: best-effort `revokeCallerRole` via the Converter (emits `CallerRoleRevokeFailed` on failure); does **not** clear `lastStrategyWithdrawal` (cooldown is wall-clock on the strategy address and must survive remove → re-add); strategy-local LP-fee accounting lives on the strategy, so there is no SM-side fee counter to clear. Strategies must include pending underlying withdrawals in `navInETH()` — see `IStrategy`
- **Force Removal:** `forceRemoveStrategy()` (`ADMIN_ROLE`, 48h timelock in production) skips the NAV residue check — escape hatch for strategies whose `navInETH()` over-reports or reverts. Reads NAV via `try/catch` for observability only; emits `StrategyForceRemoved(strategy, reportedNAV, navReverted)`; capital recovery via `IStrategy.emergencyExit()`. Does not require the strategy to be paused. Callable while paused.
- **Performance Fees:** Strategy-local LP-fee accounting (`IStrategy.pendingPerformanceFeeInETH` / `settlePerformanceFee`); StrategyManager orchestrates harvest and mints EVE to `daoTreasury` (bonding-curve dilution, no ETH extraction from strategies). **One EVE mint per harvest batch** at `totalFeeETH * liveSupply / (totalNAV - totalFeeETH)` (`liveSupply = totalSupply - escrowedSupply`; reverts `StrategyManagerEscrowExceedsSupply` if escrow exceeds supply; `totalNAV` is already net of in-window priced liability). Batch harvest wraps each `settlePerformanceFee()` in `try/catch` (`StrategyHarvestFailed` + continue; failed strategies omitted from the mint sum); single-strategy harvest is strict. Keeper/admin entry: `Controller.harvestPerformanceFeeFromStrategy(s)` (`ADMIN_ROLE` or `KEEPER_ROLE`); StrategyManager delegate is registered `CONTROLLER` only. Paginated overload `[startIndex, endIndex)`. Withdrawals batch-harvest accrued fees before withdrawal (same try/catch). Paused strategies report zero pending fees and skip settlement until unpaused; `emergencyExit()` writes off pending local fees (charged = earned after any best-effort accrue) after sweep. `pendingPerformanceFeeInETH` reverts for unregistered strategies. Fees accrue only when `performanceFeeBps > 0`; treasury must be non-zero at init and in `setDaoTreasury()`. Requires `MINTER_ROLE` on Registry.
- **Peer resolution:** AMM, Controller, Oracle addresses from Registry (`Auth`); `totalNAVInETH()` reverts if `AMM` key not registered
- **Oracle Integration:** Uses Oracle contract for ETH/USD conversion (only when USD values are needed)
- **Fund Deposit:** Deposits ETH to strategies proportionally based on safety levels (healthy strategies with `maxDeposit() > 0` only)
- **Fund Withdrawal:** Withdraws ETH from strategies proportionally based on withdrawal priorities to Controller; events and return values reflect **net ETH received** by Controller (after strategy fees)
- **Strategy Deposit Cooldown (keeper cycling mitigation):** Optional per-strategy cooldown between a withdrawal from a strategy and the next deposit into it (`strategyDepositCooldown`, seconds; default `0` = disabled; `ADMIN_ROLE` settable up to `MAX_STRATEGY_DEPOSIT_COOLDOWN` = 1 day). Bounds NAV bleed from a compromised/buggy keeper cycling capital between strategies (DEX fees + slippage per round trip) to at most one round trip per strategy per cooldown window. Every withdrawal records `lastStrategyWithdrawal[strategy]`; while cooling down, `depositToStrategy()` reverts with `StrategyManagerStrategyInDepositCooldown` and the batch `depositToStrategies()` paths skip the strategy (partial-success design), returning unused ETH to the Controller. **`lastStrategyWithdrawal` survives `removeStrategy` / `forceRemoveStrategy`** — a remove → re-add while still inside the window keeps deposits blocked (cooldown is wall-clock on the address, not a per-registration epoch; avoids coupling correctness to admin-timelock delay vs `MAX_STRATEGY_DEPOSIT_COOLDOWN`). **Withdrawals are never gated** — exit-liquidity provisioning for user redemptions (`Controller.withdrawFromStrategies` → `provideExitLiquidity`) and the emergency paths (`IStrategy.emergencyExit()` chain, `emergencyWithdrawToController()`) are always exempt. Off-chain monitoring should alert on abnormal frequency of `FundsDepositedToStrategy`/`FundsWithdrawnFromStrategy` events for the same strategy (deposit→withdraw→deposit patterns) and on `WithdrawalCompleted`/`DirectWithdrawalCompleted` amounts materially below the requested amount (fee/slippage bleed). Full rate limiting is targeted for v2.
- **Controller Integration:** Registered `CONTROLLER` on Registry invokes fund operations
- **Remaining ETH Handling:** Returns unused ETH back to Controller if deposit is incomplete
- **Version Tracking:** Returns "1.0.0"
- **Upgrade Safety:** Includes storage gaps to prevent storage collisions

**Key Functions:**
```solidity
// Initialization (FeeConfig: non-zero daoTreasury, performanceFeeBps may be 0)
function initialize(address _registry, FeeConfig calldata _feeConfig) external

// Strategy Management (ADMIN_ROLE on Registry)
function addStrategy(address _strategy, uint8 _depositWeight, uint8 _withdrawalWeight) external
function setStrategyWeights(address[] calldata _strategies, uint8[] calldata _depositWeights, uint8[] calldata _withdrawalWeights) external
function setDepositWeight(address _strategy, uint8 _depositWeight) external
function setWithdrawalWeight(address _strategy, uint8 _withdrawalWeight) external
function depositWeight(address _strategy) external view returns (uint8)
function withdrawalWeight(address _strategy) external view returns (uint8)
function removeStrategy(address _strategy) external
function forceRemoveStrategy(address _strategy) external  // escape hatch for over-reporting strategies

// Performance fees (registered CONTROLLER only; call via Controller.harvestPerformanceFeeFromStrategy(s))
function harvestPerformanceFeeFromStrategy(address _strategy) external returns (uint256 eveAmount, uint256 feeETHEquivalent)
function harvestPerformanceFeeFromStrategies() external returns (uint256 eveAmount, uint256 feeETHEquivalent)
function harvestPerformanceFeeFromStrategies(uint256 _startIndex, uint256 _endIndex) external returns (uint256 eveAmount, uint256 feeETHEquivalent)
function pendingPerformanceFeeInETH(address _strategy) external view returns (uint256)
function setPerformanceFeeBps(uint256 _feeBps) external  // ADMIN_ROLE
function setDaoTreasury(address _treasury) external      // ADMIN_ROLE, non-zero

// Strategy cooldown (keeper cycling mitigation)
function setStrategyDepositCooldown(uint256 _cooldown) external  // ADMIN_ROLE, <= MAX_STRATEGY_DEPOSIT_COOLDOWN (1 day); 0 disables (default)
function strategyDepositCooldown() external view returns (uint256)
function lastStrategyWithdrawal(address _strategy) external view returns (uint256)  // wall-clock; survives remove/forceRemove
function isStrategyInDepositCooldown(address _strategy) external view returns (bool)

// Fund operations (registered CONTROLLER on Registry)
function depositToStrategies(uint256 _amount) external
function depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount) external
function depositToStrategy(address _strategy, uint256 _amount) external

// Fund Withdrawal (registered CONTROLLER)
function withdrawFromStrategies(uint256 _amount) external
function withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount) external
function withdrawFromStrategy(address _strategy, uint256 _amount) external

// Rebalance (registered CONTROLLER)
function checkAndRebalanceStrategies() external
function checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex) external
function checkAndRebalanceStrategy(address _strategy) external

// Emergency (ADMIN_ROLE or SECURITY_ROLE on Registry)
function emergencyWithdrawToController() external

// NAV Queries (View)
function totalNAVInETH() external view returns (uint256)  // Primary: NAV in ETH (used by AMM)
function totalNAVInUSD() external view returns (uint256)  // Secondary: NAV in USD (converts ETH NAV via oracle)
function strategyNAVInETH(address _strategy) external view returns (uint256)  // Primary: Strategy NAV in ETH
function strategyNAVInUSD(address _strategy) external view returns (uint256)  // Secondary: Strategy NAV in USD (converts ETH NAV via oracle)
function isStrategyRegistered(address _strategy) external view returns (bool)
function strategies() external view returns (address[] memory)
function strategyCount() external view returns (uint256)
```

**Deposit Logic:**
- **ETH Flow:** All three functions below are **non-payable**. Before calling them the Controller executes `_fundStrategyManagerIfNeeded(_amount)`, which transfers only the **deficit** (`_amount > address(strategyManager).balance ? _amount - address(strategyManager).balance : 0`). If SM already holds ETH, the Controller sends less — it never over-funds. If SM balance exceeds `_amount`, the excess remains on SM, is included in NAV, and can be absorbed by a later deposit. `_validateDeposit` enforces this consistently: it reverts with `ControllerInsufficientBalance` only when `controller.balance < deficit`. The StrategyManager's `receive() external payable {}` accepts the inbound transfer and any donated ETH.
- `depositToStrategies(uint256 _amount)`: Deposits `_amount` of ETH proportionally based on each strategy's StrategyManager-owned `depositWeight` (0–100; 0 = no share). Reverts with `StrategyManagerNoStrategiesRegistered` when the registry is empty. Returns `0` when strategies exist but none qualify (`isHealthy() && maxDeposit() > 0`) or all qualifying weights are 0; unused ETH is returned to Controller.
- `depositToStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)`: Deposits `_amount` to a range of strategies [startIndex, endIndex) proportionally by `depositWeight`. Same empty-registry revert and zero-return behavior.
- **Deposit Weight:** Owned by StrategyManager (`depositWeight` mapping); set via `addStrategy` / `setDepositWeight` / `setStrategyWeights`. Weights are proportional (need not sum to 100). Values `> 100` are rejected at the setter; `0` is allowed (exclude from batch allocation).
- **Health Check:** Only healthy strategies (where `isHealthy() == true`) with `maxDeposit() > 0` are included
- **Deposit Cooldown Check:** When `strategyDepositCooldown > 0`, strategies withdrawn from within the last `strategyDepositCooldown` seconds are skipped by the batch deposit paths; `depositToStrategy()` reverts with `StrategyManagerStrategyInDepositCooldown`
- Strategies with `maxDeposit() == 0` or unhealthy strategies are excluded
- Only strategies that receive funds (depositAmount > 0) trigger deposits and emit events
- Actual deposit may be less than requested if strategies hit their `maxDeposit()` limits
- Remaining ETH is returned to Controller if deposit is incomplete
- `depositToStrategy(address _strategy, uint256 _amount)`: Deposits `_amount` of ETH to a specific strategy. Zero-amount validation is handled by the strategy itself.

**Withdrawal Logic:**
- `withdrawFromStrategies(uint256 _amount)`: Withdraws ETH proportionally based on each strategy's StrategyManager-owned `withdrawalWeight` (0–100; 0 = no share) to Controller. Reverts with `StrategyManagerNoStrategiesRegistered` when the registry is empty. Returns `0` when no strategy has `maxWithdrawal() > 0` or all qualifying weights are 0.
- `withdrawFromStrategies(uint256 _startIndex, uint256 _endIndex, uint256 _amount)`: Withdraws from a range of strategies [startIndex, endIndex) proportionally by `withdrawalWeight`. Same empty-registry revert and zero-return behavior.
- **Withdrawal Weight:** Owned by StrategyManager (`withdrawalWeight` mapping); set via `addStrategy` / `setWithdrawalWeight` / `setStrategyWeights`. Same proportional semantics as deposit weights.
- Only strategies that can withdraw (withdrawalAmount > 0) trigger withdrawals and emit events
- Strategies with `maxWithdrawal() == 0` are excluded from withdrawal
- **Actual amounts:** `FundsWithdrawnFromStrategy` events and return values use net ETH received by Controller (controller balance delta)
- `withdrawFromStrategy()`: Withdraws ETH from a specific strategy to Controller. Zero-amount validation is handled by the strategy itself.
- **Deposit Cooldown Exempt:** Withdrawals are never blocked by the strategy deposit cooldown (user-redemption exit liquidity must always be reachable); each withdrawal records `lastStrategyWithdrawal[strategy]`, starting the deposit cooldown window

**Rebalance Logic:**
- `checkAndRebalanceStrategies()`: Checks all registered strategies and rebalances any that are unhealthy
- `checkAndRebalanceStrategies(uint256 _startIndex, uint256 _endIndex)`: Checks and rebalances strategies in range [startIndex, endIndex)
- `checkAndRebalanceStrategy()`: Checks a specific strategy and rebalances it if unhealthy
- Only unhealthy strategies are rebalanced (where `isHealthy() == false`); paused strategies are skipped
- Batch paths (`checkAndRebalanceStrategies`) wrap each `rebalance()` in `try/catch` for fault isolation — a reverting strategy emits `StrategyRebalanceFailed` and does not block the rest of the batch. The single-strategy `checkAndRebalanceStrategy()` is unguarded and reverts on failure
- Rebalanced strategies emit `StrategyRebalanced` events

**Sync Logic:**
- `syncStrategies()`: Calls `IStrategy.sync()` on all registered strategies
- `syncStrategies(uint256 _startIndex, uint256 _endIndex)`: Syncs strategies in range [startIndex, endIndex)
- `syncStrategy(address _strategy)`: Syncs a specific strategy (strict: reverts on failure)
- Sync semantics are implementation-defined (not required to affect NAV); all non-paused registered strategies are invoked regardless of health
- Batch paths wrap each `sync()` in `try/catch` — a reverting strategy emits `StrategySyncFailed` and does not block the rest of the batch
- Synced strategies emit `StrategySynced` events

**Pagination:**
- Range parameters use exclusive end index: `[startIndex, endIndex)` - processes strategies from startIndex up to but not including endIndex
- Range validation: `endIndex` must be <= `strategies.length()` and `startIndex` must be < `endIndex`
- Useful for gas optimization when dealing with many strategies or avoiding block gas limits

**Events:**
- `StrategyAdded(address indexed strategy)`
- `StrategyRemoved(address indexed strategy)`
- `StrategyForceRemoved(address indexed strategy, uint256 reportedNAV, bool navReverted)`
- `FundsDepositedToStrategy`, `FundsWithdrawnFromStrategy`, `StrategyRebalanced`, `StrategySynced`
- `StrategyDepositFailed(address indexed strategy, bytes reason)`, `StrategyWithdrawFailed(address indexed strategy, bytes reason)`, `StrategyRebalanceFailed(address indexed strategy, bytes reason)`, `StrategyHarvestFailed(address indexed strategy, bytes reason)`, `StrategySyncFailed(address indexed strategy, bytes reason)` (batch keeper paths only; `reason` is the revert data)
- `CallerRoleRevokeFailed(address indexed strategy)` (best-effort Converter role cleanup on removal)
- `PerformanceFeePaid(address indexed strategy, address indexed treasury, uint256 eveAmount, uint256 feeETHEquivalent)`
- `PerformanceFeeBpsChanged(uint256 initial, uint256 current)` — emitted at initialize (initial=0) and by `setPerformanceFeeBps()`
- `DaoTreasuryChanged(address initial, address current)` — emitted at initialize (initial=0) and by `setDaoTreasury()`
- `EmergencyWithdrawnToController(uint256 amount)`
- `StrategyDepositCooldownUpdated(uint256 oldCooldown, uint256 newCooldown)`
- `SupportedERC20Added(address indexed token)`, `SupportedERC20Removed(address indexed token)`

**Errors:**
- `StrategyManagerStrategyAlreadyRegistered`, `StrategyManagerStrategyNotRegistered`, `StrategyManagerInvalidNAVValue`
- `StrategyManagerZeroAddress`, `StrategyManagerNoCode`, `StrategyManagerStrategyNAVResidueTooHigh`
- `StrategyManagerNoStrategiesRegistered`, `StrategyManagerInvalidRange`, `StrategyManagerInvalidDepositWeight`, `StrategyManagerInvalidWithdrawalWeight`, `StrategyManagerInvalidLength`
- `StrategyManagerZeroDaoTreasury`, `StrategyManagerInvalidPerformanceFeeBps`, `StrategyManagerFeeMintOverflow`, `StrategyManagerQueuedLiabilityExceedsNAV`, `StrategyManagerEscrowExceedsSupply`, `StrategyManagerStrategyInDepositCooldown`, `StrategyManagerInvalidStrategyDepositCooldown`
- `StrategyManagerNoBalanceToRecover`, `StrategyManagerERC20AlreadySupported`, `StrategyManagerERC20NotSupported`, `StrategyManagerERC20NotPriceable`
- Unregistered `AMM` on Registry: `RegistryContractNotRegistered` when aggregating NAV

**Testing:**
- Comprehensive test suite in `test/unit/StrategyManager.t.sol`

### Oracle

**Location:** `src/contracts/Oracle.sol` · **Interface:** `src/interfaces/IOracle.sol`

Upgradeable Chainlink oracle. **Supporting a token means registering its Token / USD feed** — there is no separate add-token API.

**Mental model:**
- `updateUsdFeedInfo(token, feed, staleness)` — first call registers the token (`UsdFeedAdded`, `isTokenSupported` becomes true); later calls update feed/staleness
- `updatePairFeedInfo(tokenA, tokenB, feed, staleness)` — optional A/B overlay; both tokens must already be USD-supported; does not by itself make a token supported
- `convert(in, out, …)` prefers direct pair → inverted pair → USD cross-rate (registered but stale pair feeds fail closed; no silent USD fallback)
- Native ETH is `address(0)`. Prices are 18-decimal normalized.

**Features:**
- **Upgradeable Pattern:** UUPS; implementation constructor calls `_disableInitializers()`
- **RegistryClientUpgradeable:** `initialize(address _registry)`; mutators / upgrades need `ADMIN_ROLE` on Registry
- **Chainlink safety:** `latestRoundData()` with staleness, `updatedAt == 0`, future-timestamp, and `answer <= 0` checks; feed decimals capped at 18
- **Version:** `1.1.0`

**USD Quote Currency Assumption (PLM-2, issue #194):**

Every feed registered via `updateUsdFeedInfo` MUST quote its token in USD (Chainlink `"<BASE> / USD"` convention). All USD-denominated conversion paths assume this homogeneous quote currency:

- `convertTokenToUSD` / `convertUsdToToken` read the feed as a plain token/USD rate
- `convert(tokenIn, tokenOut, …)` prefers a registered direct pair feed (or its inverse); with no pair feed registered it falls back to a token-to-token **cross-rate through USD** from the two tokens' USD feeds (`amountOut = amountIn * priceIn / priceOut`, a single rounding division) — that fallback is correct only if both USD feeds quote in USD, and it carries the risk surface of two feeds (either leg being stale or invalid reverts)
- Registering a USD feed with a different quote asset (e.g. ETH / BTC) does **not** revert and silently corrupts every conversion involving that token

The invariant is intentionally **not** enforced on-chain: a feed's `description()` is advisory, free-form metadata (a misconfigured or malicious feed controls the string, and legitimate USD-quoted `AggregatorV3` wrappers may not follow the Chainlink naming convention, which would brick a timelocked feed replacement during an incident). Instead:

- Deploy scripts fail closed if `description()` does not end with `" / USD"` (`ProtocolDeployBase._assertUsdQuotedFeed`, used by `DeployOracle` and `DeployAll`)
- Feed changes scheduled through the admin timelock must be reviewed against the same checklist: USD quote currency, feed decimals ≤ 18, staleness interval matching the feed's heartbeat
- Token-to-token conversions must use `convert()` — never chain `convertTokenToUSD` → `convertUsdToToken`, which incurs a second rounding division

Optional direct Token A / Token B pair feeds (`updatePairFeedInfo`) are exempt from the USD-quote invariant — they quote the base token in quote-token terms by definition — and, where registered, take precedence over the USD cross-rate in `convert()`.

**Key Functions:**
```solidity
function updateUsdFeedInfo(address token, address priceFeed, uint256 stalenessInterval) external // token registration; feed MUST quote token / USD
function removeToken(address token) external // clears USD + related pair feeds
function getUsdPrice(address token) external view returns (uint256 price, uint256 timestamp)
function getUsdPriceWithStalenessCheck(address token, uint256 maxStaleness) external view returns (uint256 price)
function convertTokenToUSD(address token, uint256 amount, uint8 inputDecimals) external view returns (uint256)
function convertUsdToToken(address token, uint256 amount, uint8 outputDecimals) external view returns (uint256)
function updatePairFeedInfo(address tokenA, address tokenB, address priceFeed, uint256 stalenessInterval) external
function getPairPrice(address tokenA, address tokenB) external view returns (uint256 price, uint256 timestamp)
function convert(address tokenIn, address tokenOut, uint256 amountIn, uint8 inputDecimals, uint8 outputDecimals) external view returns (uint256) // pair feed preferred, else single-division USD cross-rate
```

**Errors:**
- `OracleInvalidPrice`: Price answer is zero or negative
- `OracleInvalidTimestamp`: Feed `updatedAt` is in the future
- `OracleStalePrice`: Price exceeds configured staleness interval
- `OracleNoRoundData`: No round data (`updatedAt == 0`)
- `OracleInvalidFeedDecimals`: Feed decimals exceed 18
- `OracleTokenNotSupported`, `OraclePairNotRegistered`, `OracleIdenticalTokens`
- `OracleZeroAddress`, `OracleZeroStalenessInterval`, `OracleNothingToUpdate`

**Testing:**
- Unit tests: `test/unit/Oracle.t.sol` (includes Chainlink safety check suite)
- Fuzz tests: `test/fuzz/OracleFuzz.t.sol` (timestamp boundaries, staleness intervals, feed decimals)
- Test tree: `test/trees/Oracle.tree`

**Deployment:** Requires `REGISTRY_ADDRESS` and `PRICE_FEED` (Chainlink ETH/USD). Registers `ORACLE` on Registry. The script asserts the feed's `description()` ends with `" / USD"` (USD quote currency assumption) and fails otherwise.
```bash
export REGISTRY_ADDRESS=<registry_proxy>
export PRICE_FEED=<chainlink_eth_usd_feed>
forge script script/DeployOracle.s.sol:DeployOracle --rpc-url <your_rpc_url> --broadcast --private-key <your_private_key>
```

### IStrategy Interface

**Location:** `src/interfaces/IStrategy.sol`

Standard interface that all investment strategy contracts must implement.

**Features:**
- **Strategy Metadata:** Name, version, and genesis timestamp
- **NAV Reporting:** Returns strategy NAV in ETH (18 decimals) via `navInETH()` function
- **Deposit/Withdraw Limits:** `maxDeposit()` and `maxWithdrawal()` functions
- **Health Monitoring:** `isHealthy()` function for strategy health checks
- **Fund Management:** `deposit()`, `withdraw()`, and admin-only `investIdleETH()` (deploys idle native ETH, e.g. donations)
- **Rebalancing:** `rebalance()` function (called by StrategyManager when strategy is unhealthy)
- **Sync:** `sync()` function (called by StrategyManager via keeper; refreshes implementation-defined on-chain state, may no-op)
- **Allocation weights:** Live on StrategyManager (`depositWeight` / `withdrawalWeight`), not on the strategy (#252)

**Key Functions:**
```solidity
// Metadata
function name() external view returns (string memory)
function version() external view returns (string memory)
function genesisTimestamp() external view returns (uint256)

// NAV & Limits
function navInETH() external view returns (uint256)  // NAV in ETH (18 decimals) - primary NAV function
function maxDeposit() external view returns (uint256)
function maxWithdrawal() external view returns (uint256)

// Health & Statistics
function isHealthy() external view returns (bool)
function totalDeposited() external view returns (uint256)
function totalWithdrawn() external view returns (uint256)

// Fund Operations
function deposit() external payable
function investIdleETH() external returns (uint256 invested)
function withdraw(address _receiver, uint256 _amount) external returns (uint256 _withdrawn)  // returns ETH actually sent (net of fees)

// Maintenance
function rebalance() external
function sync() external
```

**Events:**
- `FundsDeposited(uint256 amount)`, `FundsInvested(uint256 amount)`, `FundsWithdrawn(uint256 amount)`, `Rebalanced()`, `Synced()`, `EmergencyExited(uint256 ethAmount)`

**Errors:**
- `StrategyIsHealthy`: Thrown when the strategy is healthy and rebalance is not needed
- `StrategyMaxDepositExceeded`: Thrown when the amount to deposit exceeds the maximum deposit amount
- `StrategyMaxWithdrawalExceeded`: Thrown when the amount to withdraw exceeds the maximum withdrawal amount
- `StrategyZeroDeposit`: Thrown when the deposit amount is zero
- `StrategyZeroWithdrawal`: Thrown when the withdrawal amount is zero

**Usage:**
Strategy contracts implementing this interface are registered with StrategyManager and receive funds based on their safety levels and withdrawal priorities.

## Source layout conventions

- **`src/libraries/`** — shared by core protocol contracts (AMM, Controller, StrategyManager, Oracle, Registry).
- **`src/libraries/strategies/<name>/`** — libraries used by a single strategy implementation only. UniCL math lives under `uni-cl-strategy/` (adapted from Uniswap V3 Core/Periphery).
- **`src/interfaces/integrations/`** — minimal ABIs for external protocols strategies call (not part of the core interface surface).
- **`src/contracts/strategies/`** — static strategy contracts; each strategy may import from its matching `libraries/strategies/…` folder.

## Project Structure

```
smart-contracts/
├── src/                           # Smart contract source files
│   ├── contracts/                 # Main contracts
│   │   ├── registry/             # Registry + RegistryClient mixins
│   │   ├── AMM.sol               # Bonding curve AMM (static)
│   │   ├── Whitelist.sol         # Invite-gated entry whitelist (static)
│   │   ├── EVE.sol               # Protocol token (static)
│   │   ├── Controller.sol        # Protocol controller (upgradeable)
│   │   ├── ExitQueue.sol         # Redemption queue manager (upgradeable)
│   │   ├── StrategyManager.sol   # Strategy and NAV manager (upgradeable)
│   │   ├── Oracle.sol            # Price feed oracle (upgradeable)
│   │   └── strategies/           # Strategy implementations (e.g. UniCLStrat)
│   ├── interfaces/               # Contract interfaces
│   │   ├── IRegistry.sol, IRegistryClient.sol, IAMM.sol, IWhitelist.sol, …
│   │   ├── strategies/         # IUniCLStrat, …
│   │   └── integrations/       # IUniswapV3Pool, IUniswapV3Router, IQuoter, IWETH
│   └── libraries/
│       ├── Math.sol              # Protocol-wide math (decimals, slippage)
│       ├── Auth.sol              # Registry contract keys and role identifiers
│       ├── ExitQueueLimits.sol   # Shared live-priced batch cap (ExitQueue + CRE scanners)
│       └── strategies/
│           └── uni-cl-strategy/  # UniCL-only V3 math (TickMath, LiquidityAmounts, …)
├── test/                          # Test files
│   ├── unit/                     # Unit tests
│   │   ├── AMM.t.sol
│   │   ├── AMMWhitelist.t.sol
│   │   ├── Whitelist.t.sol
│   │   ├── Controller.t.sol
│   │   ├── EVE.t.sol
│   │   ├── ExitQueue.t.sol
│   │   ├── StrategyManager.t.sol
│   │   ├── Registry.t.sol
│   │   └── Oracle.t.sol
│   ├── fuzz/                     # Fuzz tests
│   │   └── OracleFuzz.t.sol
│   ├── integration/              # Integration tests
│   │   ├── DeploymentTest.t.sol
│   │   ├── DeployerAdminAccessTest.t.sol
│   │   ├── ETHFlowTest.t.sol
│   │   └── UpgradeSimulation.t.sol
│   ├── fork/                     # Mainnet fork tests (skip when MAINNET_RPC_URL unset)
│   │   ├── UniCLStratFork.t.sol
│   │   └── helpers/
│   │       └── UniswapV3ForkHelpers.sol
│   ├── trees/                    # Bulloak test trees
│   │   ├── Registry.tree
│   │   ├── ProtocolDeploy.tree
│   │   ├── AMM.tree
│   │   ├── Whitelist.tree
│   │   ├── Controller.tree
│   │   ├── EVE.tree
│   │   ├── ExitQueue.tree
│   │   ├── Oracle.tree
│   │   └── StrategyManager.tree
│   ├── helpers/                  # Test helper libraries
│   │   └── Halp.sol
│   └── mocks/                    # Mock contracts for testing
│       ├── MockController.sol
│       ├── MockERC20.sol
│       ├── MockPriceFeed.sol
│       └── MockStrategy.sol
├── script/                        # Deployment scripts
│   ├── ProtocolDeployBase.sol   # Shared Registry-centric helpers
│   ├── DeployRegistry.s.sol
│   ├── DeployAll.s.sol          # Full protocol deployment
│   ├── DeployEVE.sol
│   ├── DeployExitQueue.s.sol
│   ├── DeployController.s.sol
│   ├── DeployAMM.s.sol
│   ├── DeployWhitelist.s.sol
│   ├── DeployOracle.s.sol
│   ├── DeployConverter.s.sol
│   ├── DeployUniswapV3ConverterAdapter.s.sol  # Optional UniCL path (not in DeployAll)
│   ├── DeployCREExecutors.s.sol
│   ├── DeployUniCLStrat.s.sol
│   └── FinalizeProtocolDeploy.s.sol
├── lib/                          # Dependencies
│   ├── forge-std/               # Foundry testing utilities
│   ├── openzeppelin-contracts-upgradeable/ # OpenZeppelin upgradeable contracts
│   └── chainlink-evm/          # Chainlink oracle contracts
└── foundry.toml                 # Foundry configuration
```

## Dependencies

- **OpenZeppelin Contracts Upgradeable**: Provides battle-tested upgradeable contract implementations
- **OpenZeppelin Contracts**: Provides static contract implementations (ERC20, AccessControl, etc.)
- **Chainlink Contracts**: Provides oracle price feed interfaces and utilities
- **Forge Standard Library**: Testing utilities and utilities for Foundry

## Setup

1. Install [Foundry](https://book.getfoundry.sh/getting-started/installation):
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

2. Install dependencies:
```bash
forge install
```

3. Build contracts:
```bash
forge build
```

## Testing

### Test Structure

Tests are organized into unit and integration tests:

- **Unit Tests** (`test/unit/`): Test individual contracts in isolation with mocked dependencies
- **Integration Tests** (`test/integration/`): Test cross-contract interactions and complete workflows
- **Fork Tests** (`test/fork/`): Ethereum mainnet fork tests exercising UniCLStrat and the Converter/UniswapV3ConverterAdapter path against the real Uniswap V3 WETH/USDC 0.05% pool and real Chainlink feeds. They skip when `MAINNET_RPC_URL` is unset (`vm.envExists`); when set, `MAINNET_FORK_BLOCK` is required (`0` = tip) so plain `forge test` stays green offline without `envOr`
- **Test Trees** (`test/trees/`): Bulloak tree files that guide comprehensive test coverage

### Test Naming Conventions

Tests follow a consistent naming pattern for clarity and organization:

- `test_FunctionName()` - Basic functionality test
- `test_FunctionName_Condition()` - Specific scenario test (e.g., `test_DepositToStrategies_RespectsMaxDeposit`)
- `test_FunctionName_AccessControl()` - Access control and authorization tests
- `test_FunctionName_InvalidInputs()` or `test_FunctionName_InvalidConditions()` - Invalid input validation tests
- `test_FunctionName_WhenPaused()` - Pause-related behavior tests
- `testFuzz_FunctionName_Description()` - Fuzz tests for property-based testing

This naming convention groups related tests together and makes test output more readable.

### Running Tests

Run all tests:
```bash
forge test
```

Run tests with verbosity:
```bash
forge test -vvv
```

Run specific test contract:
```bash
forge test --match-contract AMMTest
forge test --match-contract ControllerTest
forge test --match-contract EVETest
forge test --match-contract StrategyManagerTest
```

Run integration tests:
```bash
forge test --match-path "test/integration/**"
```

Run mainnet fork tests (skipped when `MAINNET_RPC_URL` is unset; when set, `MAINNET_FORK_BLOCK` is required — `0` = tip):
```bash
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com MAINNET_FORK_BLOCK=0 forge test --match-path "test/fork/*"
# or pin a block for determinism and RPC-cache reuse
MAINNET_RPC_URL=<archive_rpc> MAINNET_FORK_BLOCK=<block> forge test --match-path "test/fork/*"
```

Run tests with gas report:
```bash
forge test --gas-report
```

Run specific test by name pattern:
```bash
forge test --match-test "test_DepositToStrategies"
forge test --match-test "testFuzz_"
```

## Code Formatting

This project uses Foundry's `forge fmt` for code formatting, configured to match GitHub Actions CI.

**Format all code:**
```bash
FOUNDRY_PROFILE=ci forge fmt src/ test/
```

**Check formatting (like CI does):**
```bash
FOUNDRY_PROFILE=ci forge fmt --check src/ test/
```

### Configuration

The project uses a `[profile.ci]` configuration in `foundry.toml` that matches GitHub Actions CI settings. This ensures local formatting is identical to what's expected in CI.

GitHub Actions installs the Foundry version in `FOUNDRY_VERSION` (currently **1.0.0**). Match that locally so `forge fmt` agrees with CI: `foundryup --version 1.0.0` (or keep Homebrew’s `forge` if `forge --version` reports 1.0.0). Newer toolchains use a different formatter and will disagree with this pin.

**Note:** Make sure to run formatting before committing to avoid CI failures.

## Deployment

Registry-centric deployment is documented in [`mermaid/deployment-architecture.md`](../mermaid/deployment-architecture.md).

### Environment variables

| Variable | Used by | Purpose |
|----------|---------|---------|
| `PRIVATE_KEY` | All broadcast scripts | Deployer signer |
| `RPC_URL` | CLI `--rpc-url` | Network endpoint |
| `DAO_ADDRESS` | `DeployRegistry`, `DeployAll` | **Required.** DAO multisig — timelock proposer/canceller |
| `SECURITY_ADDRESS` | `DeployRegistry`, `DeployAll`, `FinalizeProtocolDeploy` | **Required.** Security multisig — SECURITY_ROLE + timelock canceller |
| `DAO_TREASURY_ADDRESS` | `DeployAll`, `DeployAMM` | **Required.** Performance-fee EVE recipient |
| `PERFORMANCE_FEE_BPS` | `DeployAll`, `DeployAMM` | **Required.** Initial fee rate in bps; `0` disables fees |
| `TIMELOCK_ADMIN_DELAY` | `DeployRegistry`, `DeployAll` | Optional. Admin timelock min delay in seconds; defaults to 48h (sole `envOr` exception) |
| `EXIT_LIQUIDITY_TARGET_ETH` | `DeployAll`, `DeployCREExecutors` | **Required** (wei). AMM free-balance target for ProvideExitLiquidity; `0` disables immediate exits |
| `CONTROLLER_RESERVE_ETH` | `DeployAll`, `DeployCREExecutors` | **Required** (wei). ETH kept idle on the Controller; `0` means no reserve |
| `KEYSTONE_FORWARDER` | `DeployAll`, `DeployCREExecutors` | **Required.** Chainlink-managed KeystoneForwarder (immutable on CRE receivers) |
| `CHAIN_SELECTOR` | `DeployAll`, `DeployCREExecutors` | **Required** (uint64). CCIP chain selector for the CRE Envelope |
| `MAX_REPORT_AGE` | `DeployAll`, `DeployCREExecutors` | **Required** (uint64, > 0). Max Envelope `observedAt` age in seconds |
| `GRANT_KEEPER_ROLE` | `DeployCREExecutors` | **Required** bool. `true` grants KEEPER_ROLE in-script; `false` defers to timelock |
| `PRICE_FEED` | `DeployAll`, `DeployOracle` | Chainlink ETH/USD feed — must be USD-quoted; scripts assert `description()` ends with `" / USD"` |
| `WHITELIST_SIGNER_ADDRESS` | `DeployAll`, `DeployWhitelist` | **Required.** Initial invite-signer key; explicit `address(0)` postpones seeding |
| `WETH_ADDRESS` | `DeployAll`, `DeployConverter`, … | **Required.** WETH |
| `REGISTRY_ADDRESS` | Modular scripts after Registry | Registry address (static; logged by DeployRegistry) |

### Full protocol (`DeployAll.s.sol`)

```bash
export PRIVATE_KEY=<your_private_key>
export RPC_URL=<your_rpc_url>
export PRICE_FEED=<chainlink_eth_usd_feed>
export DAO_ADDRESS=<dao_multisig>
export SECURITY_ADDRESS=<security_multisig>
export DAO_TREASURY_ADDRESS=<treasury_multisig>
export PERFORMANCE_FEE_BPS=0         # 0 = fees disabled
# optional: export TIMELOCK_ADMIN_DELAY=172800  # defaults to 48h
export EXIT_LIQUIDITY_TARGET_ETH=0   # wei; 0 = immediate exits disabled
export CONTROLLER_RESERVE_ETH=0      # wei; 0 = no Controller float
export KEYSTONE_FORWARDER=<keystone_forwarder>
export CHAIN_SELECTOR=<ccip_chain_selector>
export MAX_REPORT_AGE=<max_report_age_seconds>
export WHITELIST_SIGNER_ADDRESS=<invite_signer_or_zero>
export WETH_ADDRESS=<weth>

forge script script/DeployAll.s.sol:DeployAll --rpc-url $RPC_URL --broadcast
```

Deploys Registry, EVE, ExitQueue, Controller, Oracle, StrategyManager, Converter, Whitelist, and AMM; registers all `Auth` (including `WHITELIST`); grants `KEEPER_ROLE`, `MINTER_ROLE` (AMM + StrategyManager), and `CONVERTER_CALLER_MANAGER_ROLE`; initializes StrategyManager with fee config; configures the ETH/USD feed; seeds the initial Whitelist invite signer when `WHITELIST_SIGNER_ADDRESS` is non-zero; applies CREStrategyExecutor policy knobs from required env; renounces the deployer's bootstrap Registry admin (ADMIN_ROLE ends held only by the admin timelock). **Core-only:** does not deploy DEX adapters or strategies (`DeployUniswapV3ConverterAdapter` / `DeployUniCLStrat` are modular follow-ups).

### Modular deployment order

1. `DeployRegistry.s.sol` — deploys the admin timelock + Registry, grants `SECURITY_ROLE` to the security multisig; deployer keeps Registry `ADMIN_ROLE` for later steps
2. `DeployEVE.s.sol` → `DeployExitQueue.s.sol` → `DeployController.s.sol` → `DeployOracle.s.sol` (each requires `REGISTRY_ADDRESS`)
3. `DeployConverter.s.sol` — registers the Converter, grants `CONVERTER_CALLER_MANAGER_ROLE` (required by `StrategyManager.addStrategy`). Does **not** call `setAllowedAdapter`
4. `DeployWhitelist.s.sol` — registers `WHITELIST`, optionally seeds `WHITELIST_SIGNER_ADDRESS` (required env; `address(0)` postpones seeding)
5. `DeployAMM.s.sol` — registers StrategyManager + AMM, grants `MINTER_ROLE` to BOTH (deployer keeps ADMIN for remaining steps)
6. `DeployCREExecutors.s.sol` — deploys CRE receivers with `KEYSTONE_FORWARDER` / `CHAIN_SELECTOR` / `MAX_REPORT_AGE`, registers both under `QUEUE_KEEPER_EXECUTOR` / `STRATEGY_KEEPER_EXECUTOR`, applies `EXIT_LIQUIDITY_TARGET_ETH` / `CONTROLLER_RESERVE_ETH`; required `GRANT_KEEPER_ROLE` (`true` grants in-script, `false` defers grants to the admin timelock before finalize)
7. `FinalizeProtocolDeploy.s.sol` — required final step; unconditionally renounces the deployer's bootstrap Registry ADMIN and VERIFIES every critical grant (`SECURITY_ROLE` → security multisig, `MINTER_ROLE` → AMM + StrategyManager, `CONVERTER_CALLER_MANAGER_ROLE` → Converter, `KEEPER_ROLE` → both executors), failing loudly on any skipped or mis-granted step
8. Optional UniCL path (same after `DeployAll`):
   - `DeployUniswapV3ConverterAdapter.s.sol` — adapter bytecode only (needs Oracle; no ADMIN); export `SWAP_ADAPTER_ADDRESS`
   - Admin timelock: `Converter.setAllowedAdapter`, paired-token `Oracle.updateUsdFeedInfo`, optional `addSupportedERC20(pairedToken)`
   - `DeployUniCLStrat.s.sol` — strategy bytecode only (constructor requires the adapter already allowed); does **not** call `addStrategy`
   - Admin timelock: `StrategyManager.addStrategy` — see `DeployUniCLStrat` NatSpec / `docs/STRATEGY_GUARDRAILS.md`

```bash
# After DeployRegistry: export REGISTRY_ADDRESS and TIMELOCK_ADDRESS from logs.
# Also required for later steps: PRICE_FEED, WETH_ADDRESS, DAO_TREASURY_ADDRESS,
# PERFORMANCE_FEE_BPS, EXIT_LIQUIDITY_TARGET_ETH, CONTROLLER_RESERVE_ETH,
# WHITELIST_SIGNER_ADDRESS, GRANT_KEEPER_ROLE, SECURITY_ADDRESS (finalize).

forge script script/DeployRegistry.s.sol:DeployRegistry --rpc-url $RPC_URL --broadcast
forge script script/DeployEVE.s.sol:DeployEVE --rpc-url $RPC_URL --broadcast
forge script script/DeployExitQueue.s.sol:DeployExitQueue --rpc-url $RPC_URL --broadcast
forge script script/DeployController.s.sol:DeployController --rpc-url $RPC_URL --broadcast
forge script script/DeployOracle.s.sol:DeployOracle --rpc-url $RPC_URL --broadcast
forge script script/DeployConverter.s.sol:DeployConverter --rpc-url $RPC_URL --broadcast
forge script script/DeployWhitelist.s.sol:DeployWhitelist --rpc-url $RPC_URL --broadcast
forge script script/DeployAMM.s.sol:DeployAMM --rpc-url $RPC_URL --broadcast
forge script script/DeployCREExecutors.s.sol:DeployCREExecutors --rpc-url $RPC_URL --broadcast
forge script script/FinalizeProtocolDeploy.s.sol:FinalizeProtocolDeploy --rpc-url $RPC_URL --broadcast
# UniCL: DeployUniswapV3ConverterAdapter → timelock setAllowedAdapter (+ paired feed /
# optional addSupportedERC20) → DeployUniCLStrat → timelock addStrategy
```

## Protocol Architecture

### Contract Types

- **Static Contracts (Immutable):**
  - Registry: Central contract addresses and operational roles (constructor-deployed; not a proxy)
  - EVE Token: Protocol token with role-based minting
  - AMM: Bonding curve for ETH/EVE trading
  - Whitelist: Invite-gated entry (EIP-712 vouchers)
  - Strategies / DEX adapters (e.g. UniCLStrat, UniswapV3ConverterAdapter)
  
- **Upgradeable Contracts (UUPS):**
  - Controller: ETH receiver and keeper coordinator
  - ExitQueue: Redemption request queue manager
  - StrategyManager: Strategy and NAV management
  - Oracle: Price feed management
  - Converter: Shared wrap/unwrap/swap module

### Access Control (Registry)

- **Registry ADMIN_ROLE**: Register contracts (`Auth`), grant/revoke roles, Oracle feed configuration, Whitelist invite-period admin, pause/upgrade modules
- **SECURITY_ROLE** (on Registry): Instant pause / emergency unwind / `Whitelist.removeSigner`
- **KEEPER_ROLE** (on Registry): Controller keeper automation. Deployment grants it to `CREQueueExecutor` and `CREStrategyExecutor` and to nothing else. A manual break-glass keeper multisig is **opt-in only** — its rationale, risk surface, containment path, and signer policy live in [`docs/FREEZE_RUNBOOK.md` §0.1](docs/FREEZE_RUNBOOK.md)
- **MINTER_ROLE** (on Registry): EVE mint/burn (granted to AMM)
- **Registered callers**: ExitQueue accepts registered AMM/Controller; StrategyManager accepts registered Controller; AMM resolves registered `WHITELIST` for entry gating
- **Deployer cleanup**: Registry constructor grants temporary ADMIN to deployer; always renounced via `FinalizeProtocolDeploy` or `DeployAll` so ADMIN_ROLE ends held only by the admin timelock

### Pricing Mechanism

- **ETH-First Calculation**: AMM uses ETH-based NAV for price calculations, then converts to USD when needed
- **NAV Source**: StrategyManager provides total NAV in ETH via `totalNAVInETH()`:
  - Sum of all registered strategy NAVs (`strategy.navInETH()`)
  - Controller balance (undistributed ETH awaiting strategy allocation)
  - AMM free balance (ETH available on AMM; excludes `lockedForClaims` committed to pending claims)
  - ETH value of each whitelisted supported-ERC-20 balance
  - **Minus** in-window priced ExitQueue liability (`liveRedemptionOffsets().liabilityETH`). Unpriced queued EVE is still equity; liability lapses after `MAX_BATCH_PROCESSING_TIME` with no reset tx. Reverts `StrategyManagerQueuedLiabilityExceedsNAV` if liability exceeds gross NAV.
- **NAV During Enter**: AMM subtracts `msg.value` from the StrategyManager NAV before pricing. The incoming deposit is already counted in `amm.freeBalance()` at the time of the NAV read; subtracting it ensures the depositor is priced against pre-deposit NAV (i.e., their deposit moves the price for the *next* buyer, not themselves).
- **Base Price in ETH**: `liveNAV / liveSupply` where `liveSupply = totalSupply - escrowedSupply` (in-window priced escrow). Unpriced queued tokens stay in the denominator. Reverts `AMMEscrowExceedsSupply` if escrow exceeds supply.
- **Premium Price in ETH**: `liveNAV / (liveSupply * connector_weight)` (same live NAV / live supply)
- **Enter/Exit Operations**: Use ETH prices directly (`_evePremiumPriceInETH()` for enter, `_eveBasePriceInETH()` for exit) - **NO oracle calls in hot path**
- **USD Prices**: Base and premium prices in USD are derived by converting ETH prices via Oracle (only for view functions)
- **Oracle Usage**: Chainlink ETH/USD price feed is only used for:
  - Bootstrap minimum deposit validation (USD check)
  - USD price view functions (`eveBasePriceInUSD()`, `evePremiumPriceInUSD()`)
  - **NOT used in enter/exit operations** (hot path is oracle-free)
  - When read, validates round data (`updatedAt != 0`), feed decimals (≤ 18), timestamp not in future, and staleness

### User Flows

1. **Enter Protocol:**
   - While the invite period is active, the caller must already be whitelisted, or use `AMM.enterWithInvite{value: ethAmount}(minTokens, inviteId, deadline, signature)` to redeem a server-signed voucher and mint in one transaction
   - Already-whitelisted users (or everyone after `Whitelist.disable()`) call `AMM.enter{value: ethAmount}(minTokens)`
   - AMM calculates tokens to mint based on premium price in ETH (`_evePremiumPriceInETH()`) - **no oracle call**
   - ETH is sent to Controller (accumulates here until keeper deposits to strategies)
   - EVE tokens are minted to user
   - Keeper (KEEPER_ROLE) can call `Controller.depositToStrategies()` to deposit funds to strategies

2. **Exit Protocol:**
   - User calls `AMM.exit(requestedETH, maxTokens, priceTolerance)` — **never** gated by Whitelist
   - AMM calculates tokens to burn based on base price in ETH (`_eveBasePriceInETH()`) - **no oracle call**
   - If sufficient free balance (`freeBalance() >= ethToRedeem`): immediate redemption (returns 0; no `minBatchExitETH` check)
   - If insufficient: reverts with `AMMTooLowBatchExitETH` when `ethToRedeem < minBatchExitETH` (default 0.001 ETH, admin-tunable up to 0.05 ETH); otherwise queues to ExitQueue (returns batchId)
   - Keeper (KEEPER_ROLE) calls `Controller.priceBatch()` to price the current batch (settles at live `eveBasePriceInETH()`, which is already net of previously priced in-window batches; this batch is still equity at the read)
   - Keeper calls `Controller.processRequest()` or `Controller.processRequests()` to process queued redemptions **only while the batch is inside `MAX_BATCH_PROCESSING_TIME`**. After that window `pullRequest` reverts `ExitQueueBatchExpired` and live NAV has already dropped the liability.
   - AMM credits `claimableBalances[user]` with `ethToRedeem` (**pull-over-push**); excess `msg.value` is returned to Controller
   - User calls `AMM.claim()` to pull their ETH 
   - If price slippage exceeds tolerance, request is closed, tokens are refunded, and all `msg.value` is returned to Controller
   - Users may cancel a queued redemption via `AMM.cancelRedemption(batchId)` before the batch is priced, or after `MAX_BATCH_PROCESSING_TIME` has passed since the batch was priced (escape hatch — the only remaining path once pull is forbidden)

## Upgrading Contracts

Upgradeable modules (ExitQueue, Controller, StrategyManager, Oracle, Converter) authorize upgrades via `ADMIN_ROLE` on Registry:

1. Deploy the new implementation (e.g., ControllerV2)
2. Call `upgradeToAndCall()` on the proxy:
```bash
cast send <PROXY_ADDRESS> "upgradeToAndCall(address,bytes)" <NEW_IMPLEMENTATION> 0x --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

**Note:** EVE, AMM, Whitelist, and strategy contracts (e.g. UniCLStrat) are static and cannot be upgraded.

## Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [OpenZeppelin Upgradeable Contracts](https://docs.openzeppelin.com/contracts/4.x/upgradeable)
- [UUPS Proxy Pattern](https://eips.ethereum.org/EIPS/eip-1822)
- [Chainlink Price Feeds](https://docs.chain.link/data-feeds)
- [Solidity Documentation](https://docs.soliditylang.org/)

## License

MIT
