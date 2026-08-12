# Agent 2 — Access-control raw working output

Scope: immutable local bundle at commit `734df96a1391e95dd40843210997da0b9f3ab05e`; access-control review only. All traces below are local state/call reasoning. No network, wallet, deployed-contract, credential, or transaction access was used.

## Permission map

- `ADMIN_ROLE` is self-administered on `Registry`; it controls Registry address changes, all ordinary protocol role grants, Oracle/feed and strategy configuration, unpause, and UUPS authorization. The intended post-deploy holder is only the 48-hour `TimelockController`.
- `SECURITY_ROLE` is directly held by the security multisig. It can pause most protocol modules and the Registry, cancel timelock operations, execute the three emergency capital-movement paths, remove supported ERC-20 accounting entries, and revoke Whitelist signers. It cannot unpause or upgrade.
- `KEEPER_ROLE` is intended to be held only by `QueueKeeperExecutor` and `StrategyKeeperExecutor`; it reaches the Controller's allocation, withdrawal, rebalance, sync, fee-harvest, and queue-settlement deputies.
- `MINTER_ROLE` is intended for AMM (entry/exit supply changes) and StrategyManager (performance-fee minting).
- `CONVERTER_CALLER_MANAGER_ROLE` is held by Converter; it administers `CONVERTER_CALLER_ROLE`. Converter exposes the actual grant/revoke deputies only to the Registry's current StrategyManager address.
- Contract-key authentication is dynamic: AMM trusts the current Controller key; ExitQueue trusts AMM/Controller; StrategyManager and each strategy trust Controller/StrategyManager; all such checks resolve the Registry at call time.

## Mandatory mental-tool working log

[Feynman: DeployAMM.run] This deploy step creates the strategy manager and market maker, records both in the shared address book, and gives each the supply-changing permission it needs; it deliberately leaves the deployer's temporary administrator permission for the final step.

[Inversion: DeployAMM.run] (1) Pre-register either key and see whether replacement is blocked; (2) omit the StrategyManager minter grant and see whether verification catches it; (3) point at a Registry whose administrator is not the expected timelock and see whether this step notices—it does not, relying on finalization.

[Feynman: DeployAll.run] This is the full bootstrap: it creates the delayed administrator, deploys and registers every core module, assigns operational permissions, configures keepers and feeds, seeds an optional invite signer, then removes the deployer's administrator permission.

[Feynman: DeployAll._toDeploymentResult] This packages deployed addresses and reads each upgradeable module's implementation slot for reporting.

[Feynman: DeployAll._verifyDeployment] This checks that the just-created modules point to the same Registry and that named expected role holders are present.

[Feynman: DeployAll._verifyModuleRegistryBackpointers] This checks every module resolves the same authority contract rather than an accidentally different Registry.

[Inversion: DeployAll._verifyDeployment] (1) Give an unexpected EOA an additional administrator role; (2) deploy a timelock whose delay is zero but whose role memberships are correct; (3) grant an extra minter and observe that all current checks still pass.

[Socratic: script/DeployAll.s.sol:_verifyDeployment — why?] Why is the role holder checked but the timelock delay and role-member count not checked? The implicit belief is that construction inputs and the clean bootstrap path are themselves sufficient to establish exclusivity and delay.

[Feynman: DeployController.run] This deploys an initialized Controller proxy, records it under the Controller key, and checks the proxy points back to the chosen Registry.

[Feynman: DeployConverter.run] This deploys an initialized Converter proxy, records it, and gives that proxy permission to administer strategy caller permissions.

[Feynman: DeployEVE.run] This creates the protocol token and records it in the Registry; minting permission is assigned by a later step.

[Feynman: DeployExitQueue.run] This creates and initializes the queue proxy and records it under the exit-queue key.

[Feynman: DeployKeeperExecutors.run] This deploys both automation deputies, records them, optionally grants their keeper permissions, and applies required liquidity policy values.

[Feynman: DeployOracle.run] This creates the Oracle proxy, records it, installs the native-asset USD feed, and checks that the configured timelock has Registry administrator permission.

[Feynman: DeployRegistry.run] This creates the governance timelock and the Registry, gives emergency permission to the security address, and intentionally leaves the deployer with temporary bootstrap administration.

[Inversion: DeployRegistry.run] (1) Set the governance delay to `0`; (2) set the proposer to `address(0)`; (3) use a proposer address that is merely an EOA rather than the documented multisig. The first two pass the helper's own parameter handling.

[Socratic: script/ProtocolDeployBase.sol:_deployTimelocks — why?] Why does the comment call 48 hours a minimum while the supplied environment value is forwarded without comparison? The hidden assumption is that an operator will never supply a weaker explicit value.

[Feynman: DeployUniCLStrat.run] This deploys strategy bytecode only after checking converter routes and the manager's Registry entry; a later timelocked call registers it.

[Feynman: DeployUniCLStrat._deploymentConfig] This reads all pool, route, and strategy settings from the environment and enforces the two TWAP-window floors before construction.

[Feynman: DeployUniswapV3ConverterAdapter.run] This deploys a fixed adapter using Registry-resolved Oracle configuration and checks all immutable addresses and the quote window.

[Feynman: DeployWhitelist.run] This creates the invite gate, records it, and optionally installs an initial signer while bootstrap administration still exists.

[Feynman: FinalizeProtocolDeploy.run] This removes the deployer's temporary administrator permission and then checks the configured administrator and expected operational grants.

[Inversion: FinalizeProtocolDeploy.run] (1) Leave an additional administrator besides the timelock; (2) leave an additional EOA minter; (3) remove the DAO's proposer role from the timelock while keeping the Registry grants correct. The finalizer does not reject any of these states.

[Feynman: ProtocolDeployBase._deployRegistry] This creates a Registry whose lasting administrator is the supplied address and whose constructor also gives the transaction sender temporary bootstrap power.

[Feynman: ProtocolDeployBase._deployExitQueue] This creates an implementation that cannot be initialized directly and an atomically initialized proxy tied to the Registry.

[Feynman: ProtocolDeployBase._deployController] This creates and atomically initializes the Controller proxy and returns both proxy and implementation addresses.

[Feynman: ProtocolDeployBase._deployOracle] This creates and atomically initializes the Oracle proxy against the common Registry.

[Feynman: ProtocolDeployBase._deployStrategyManager] This creates and atomically initializes the manager proxy with Registry and treasury/fee configuration.

[Feynman: ProtocolDeployBase._deployConverter] This creates and atomically initializes the Converter proxy with Registry and WETH.

[Feynman: ProtocolDeployBase._deployWhitelist] This creates the static invite gate against the Registry.

[Feynman: ProtocolDeployBase._deployProtocolInstances] This assembles all core modules around one newly created Registry before any addresses are registered.

[Feynman: ProtocolDeployBase._protocolDaoTreasury] This requires the operator to supply the fee recipient address.

[Feynman: ProtocolDeployBase._protocolFeeConfig] This combines the required treasury with the explicitly supplied fee rate.

[Feynman: ProtocolDeployBase._registerProtocolContracts] This writes all module keys and addresses to the Registry in one ordered batch.

[Feynman: ProtocolDeployBase._requireUnregistered] This asks the Registry for a key and deliberately fails if an address already exists; only the Registry's own missing-key failure is accepted.

[Feynman: ProtocolDeployBase._registerAndVerify] This requires a fresh key, writes it, and reads it back to confirm the same address.

[Feynman: ProtocolDeployBase._assertUsdQuotedFeed] This asks a feed to describe itself and rejects descriptions that do not end in the expected USD quote suffix.

[Feynman: ProtocolDeployBase._endsWith] This compares the tail bytes of two pieces of text.

[Feynman: ProtocolDeployBase._implementationAddress] This reads the standard implementation slot of a proxy for deployment reporting.

[Feynman: ProtocolDeployBase._protocolDao] This returns the explicitly supplied timelock proposer address, including zero if zero was explicitly supplied.

[Feynman: ProtocolDeployBase._protocolSecurity] This returns the explicitly supplied emergency-role address; a later Registry grant rejects zero.

[Feynman: ProtocolDeployBase._protocolAdminTimelock] This returns the explicitly supplied address that modular scripts expect to hold administrator permission.

[Feynman: ProtocolDeployBase._protocolWhitelistSigner] This returns the explicitly supplied signer, with zero deliberately meaning no initial signer.

[Feynman: ProtocolDeployBase._deployKeeperExecutors] This creates both deputies, records them, optionally grants keeper permissions, and has the strategy deputy store the required liquidity settings.

[Feynman: ProtocolDeployBase._deployTimelocks] This reads the desired delay and forwards it unchanged to the single timelock constructor.

[Feynman: ProtocolDeployBase._deployTimelock] This gives the DAO proposal/cancellation power, lets anyone execute a mature operation, gives security cancellation power, and removes the deployer's temporary timelock administration.

[Inversion: ProtocolDeployBase._deployTimelock] (1) Use `_minDelay = 0` and schedule plus execute in the same block; (2) use `_proposer = address(0)` and leave no callable proposer; (3) alias proposer and security and test the later role assertions.

[Feynman: ProtocolDeployBase._grantTieredProtocolRoles] This gives the timelock Registry administration, security its emergency role, AMM and manager supply-changing permission, and Converter caller-role administration.

[Feynman: ProtocolDeployBase._finalizeDeployerTieredAccess] This voluntarily removes the deployer's Registry administrator permission if it still exists.

[Feynman: ProtocolDeployBase._verifyTimelockWiring] This checks named role relationships among timelock, deployer, DAO, and security, but does not enumerate all possible administrator holders or inspect the delay.

[Feynman: ProtocolDeployBase._verifyTimelockRoles] This checks proposer, canceller, and open-executor membership and confirms the deployer/security do not hold two specifically forbidden timelock roles.

[Feynman: ProtocolDeployBase._verifyDeployerTieredAccess] This checks the configured administrator remains and the deployer is gone; it does not prove that the configured administrator is the only one.

[Feynman: ProtocolDeployBase._verifyCriticalRoleGrants] This resolves each mandatory module and checks every expected operational role is present.

[Feynman: ProtocolDeployBase._verifyRegistryWiring] This reads every core Registry key and confirms it equals the newly deployed instance.

[Feynman: ProtocolDeployBase._verifyKeeperExecutors] This confirms executor registrations/back-pointers and, when requested, their keeper permissions, then reports policy settings.

[Feynman: Registry] This is the mutable protocol address book and central permission ledger; all sensitive modules ask it who may call and which peer address is current.

[Feynman: Registry.constructor] This installs a lasting administrator, makes the custom administrator role control itself and the other roles, and gives the deployer a second temporary administrator grant.

[Feynman: Registry.getContractByKey/getContractsByKeys/getContractsAndKeys] These public readers return registered peer addresses and fail for a missing requested key.

[Feynman: Registry.getRoles] This lists roles that currently have at least one recorded member.

[Feynman: Registry.registerContract/registerContracts] These let an administrator add or replace one or several live peer addresses while the Registry is open.

[Feynman: Registry.deregisterContract/deregisterContracts] These let an administrator remove peer addresses while the Registry is open.

[Feynman: Registry.grantRole/grantRoles] These add accounts to roles only when the caller manages each requested role; zero recipients are rejected.

[Feynman: Registry.revokeRole/revokeRoles] These remove accounts from roles only when the caller manages each requested role; zero targets are rejected.

[Feynman: Registry.renounceRole] This lets only the confirmed caller voluntarily drop its own role even while Registry mutations are paused.

[Inversion: Registry.grantRole] (1) Have a caller-role holder try to grant itself caller-manager; (2) call the batch version with one unauthorized role after an authorized one and verify atomic rollback; (3) grant to zero and verify rejection. All three attempts fail.

[Inversion: Registry.renounceRole] (1) Try to name another account as the confirmation; (2) renounce the last administrator; (3) do it while paused. The first fails, while the latter two are deliberate authority-holder actions.

[Feynman: Registry._getAddress] This distinguishes a missing key from a key that returns an address.

[Feynman: Registry._registerContract] This rejects zero and code-less destinations, then adds or replaces the address and reports old/new values.

[Feynman: Registry._deregisterContract] This requires an existing key and removes it.

[Feynman: Registry._grantRole/_revokeRole] These update enumerable membership and keep the auxiliary role list synchronized.

[Feynman: Registry._registerRoleIfNeeded/_unregisterRoleIfNeeded] These add a role to the visible list on first membership and remove it after the last member leaves.

[Feynman: Registry.pause] This lets administrator or security freeze registrations and role changes immediately.

[Feynman: Registry.unpause] This lets only the delayed administrator reopen those mutations.

[Inversion: Registry.pause] (1) Call as a keeper; (2) call as a minter; (3) call as security and then attempt a role grant while paused. The first two fail and the third freezes the grant as intended.

[Feynman: RegistryClientBase.onlyAuthRole] This asks the Registry whether the immediate caller owns one named role.

[Feynman: RegistryClientBase.onlyEitherAuthRole] This accepts the immediate caller when it owns either of two named roles.

[Feynman: RegistryClientBase.onlyAuthContract] This accepts only the immediate caller whose address equals the Registry's current address for one contract key.

[Inversion: RegistryClientBase.onlyAuthContract] (1) Call through an EOA that owns a similarly named role; (2) call through an old module after its key is replaced; (3) call through a proxy whose implementation has the key but whose proxy does not. Each fails because exact immediate-caller address equality is used.

[Feynman: RegistryClient.constructor/registry] This stores a nonzero authority contract once for a static module and returns it to every guard.

[Feynman: RegistryClientUpgradeable.__RegistryClient_init/registry] This stores the nonzero authority contract during proxy initialization in a dedicated storage namespace and later returns it.

[Feynman: EVE] This token lets only Registry minters create supply, destroy their own balance, or destroy an approved holder's balance.

[Feynman: EVE.mint/burn/burnFrom] These supply operations all use the same Registry minter check; third-party burning additionally consumes the holder's allowance.

[Inversion: EVE.burnFrom] (1) Call as an unprivileged holder; (2) call as AMM without user allowance; (3) call as a minter with sufficient allowance. Only the third reaches the burn, as intended.

[Feynman: AMM] This is the user entry/redemption module; it prices against total protocol value, changes EVE supply through its minter role, and delegates queued exits to Controller and ExitQueue.

[Feynman: AMM.enter] This accepts value only from an already admitted user while open, then performs bootstrap or premium-priced minting.

[Feynman: AMM.enterWithInvite] This first redeems a voucher for the caller, then performs the same entry operation.

[Feynman: AMM.exit] This prices a requested withdrawal at backing value, burns immediately when the market maker has free native currency, or escrows tokens into a queue request.

[Feynman: AMM.cancelRedemption] This lets a user close its own eligible queue request and returns that request's escrowed EVE.

[Feynman: AMM.claim] This lets a user pull only its own recorded native-currency claim.

[Feynman: AMM.processRedemption] This lets only the current Controller finalize one queue request, return tokens on excessive slippage, or burn them and record a claim.

[Inversion: AMM.processRedemption] (1) Call directly as the user; (2) replace the Controller key and call from the old Controller; (3) call from the current Controller with a nonexistent request. The first two fail at authority and the third fails in ExitQueue.

[Feynman: AMM.setConnectorWeight/setMinBatchExitETH] These let only an administrator change the entry premium and queued-exit minimum inside fixed bounds.

[Feynman: AMM.pause/unpause] Security or administrator can stop entry/exit/processing, while only administrator can reopen them.

[Feynman: AMM._navInETH/_navInETHPendingTransfer/_freeBalance] These read total counted value, remove the current caller's not-yet-owned deposit from entry pricing, and exclude reserved claims from spendable balance.

[Feynman: AMM._enter/_bootstrap] These create EVE at the premium price after bootstrap, or on the first deposit mint one USD-valued supply while permanently locking the first token.

[Inversion: AMM._enter] (1) Donate value before another user's entry; (2) change a NAV component immediately before entry; (3) remove a counted supported token while AMM remains open. The third creates the live-accounting window in Finding 2.

[Feynman: Controller] This is a keeper-gated deputy that moves native currency between idle balances, strategies, the AMM, and exit claims; its upgrades are administrator-gated.

[Feynman: Controller.initialize] This atomically sets upgrade, Registry, pause, and reentrancy state for the proxy.

[Feynman: Controller.provideExitLiquidity] This lets a keeper move a requested amount of idle Controller currency to the AMM.

[Feynman: Controller.emergencyExitToAMM] This lets administrator or security sweep all idle Controller currency to the AMM without requiring the Controller to be open.

[Feynman: Controller.pause/unpause] Security or administrator can stop normal keeper operations; only administrator can reopen them.

[Feynman: Controller.depositToStrategies/depositToStrategy] These let a keeper fund the manager and ask it to allocate all or part of a requested amount, with any unused value returned.

[Feynman: Controller.withdrawFromStrategies/withdrawFromStrategy] These let a keeper ask registered strategies to return value to the Controller.

[Feynman: Controller.checkAndRebalanceStrategies/checkAndRebalanceStrategy] These let a keeper ask the manager to repair unhealthy strategies.

[Feynman: Controller.syncStrategies/syncStrategy] These let a keeper refresh strategy accounting.

[Feynman: Controller.harvestPerformanceFeeFromStrategy/harvestPerformanceFeeFromStrategies] These let administrator or keeper settle strategy fee claims and mint the corresponding EVE to treasury.

[Feynman: Controller.priceBatch/processRequests/processRequest] These let a keeper lock the current queue price and settle eligible queued users using Controller liquidity.

[Inversion: Controller keeper surface] (1) Call each function directly as an ordinary user; (2) call through a contract with no keeper role; (3) use a valid keeper but choose arbitrary registered strategy/user inputs. The first two fail; the third remains bounded to registered strategies and Controller/AMM destinations.

[Feynman: Controller._authorizeUpgrade] This allows implementation replacement only when the immediate proxy caller has Registry administrator permission.

[Feynman: ExitQueue] This records one redemption request per user in each batch and accepts state changes only from the current AMM or Controller.

[Feynman: ExitQueue.initialize] This starts batch numbering at one and connects the proxy to the Registry.

[Feynman: ExitQueue.priceBatch] This lets only Controller fix a nonempty current batch's price and open the next batch.

[Feynman: ExitQueue.pushRequest/pullRequest/closeRequest] These let only AMM add escrow records, settle them, or close user-owned cancellable requests.

[Inversion: ExitQueue authority surface] (1) Push as a user; (2) price as a keeper without going through Controller; (3) pull as an old AMM after Registry replacement. Exact contract-key checks reject all three.

[Feynman: ExitQueue.pause/unpause] Security or administrator can stop pricing/push/pull, while only administrator can reopen; close remains an intentional escape path.

[Feynman: Oracle] This is an administrator-managed list of price feeds; every conversion reads a positive, timely value before using it.

[Feynman: Oracle.initialize/_authorizeUpgrade] This connects the proxy to Registry and limits implementation replacement to the Registry administrator.

[Feynman: Oracle.updateUsdFeedInfo/updatePairFeedInfo] These let only administrator add or update feeds after parameter and decimal validation.

[Feynman: Oracle.removeToken/removePairFeedInfo] These let only administrator remove feed configuration and clean dependent pair entries.

[Inversion: Oracle mutation surface] (1) Call as security; (2) call as keeper; (3) call through a feed callback. None has administrator membership, so configuration does not change.

[Feynman: Converter] This is a shared wrapping and swap deputy; only registered strategy callers may move their own approved tokens, only StrategyManager can ask it to grant/revoke caller status, and only administrator chooses adapters or upgrades.

[Feynman: Converter.initialize] This connects the proxy to Registry and stores a nonzero WETH address.

[Feynman: Converter.wrapETH/unwrapWETH] These let a caller-role holder exchange its supplied native currency or approved WETH and send the result to the requested receiver.

[Feynman: Converter.executeSwapExactAmountIn/executeSwapExactAmountOut] These let a caller-role holder swap its pulled input through an administrator-approved adapter, measuring actual balance changes before paying/refunding the caller.

[Feynman: Converter.quoteSwapExactAmountIn/quoteSwapExactAmountOut] These public quote relays call only an approved adapter and do not use Converter's caller permission.

[Feynman: Converter.grantCallerRole/revokeCallerRole] These accept instructions only from the Registry's current StrategyManager, then exercise Converter's caller-manager permission on Registry.

[Inversion: Converter.grantCallerRole] (1) Call as an existing caller-role strategy; (2) call as administrator directly; (3) replace StrategyManager and call from the old one. Exact contract-key authentication rejects all three.

[Feynman: Converter.setAllowedAdapter] This lets only administrator add a code-bearing adapter or remove an existing one.

[Feynman: Converter.pause/unpause] Only administrator can stop or reopen wrapping and swapping; security cannot pause this module by design.

[Inversion: Converter delegate dispatch] (1) Choose a non-approved adapter; (2) use an approved code-less/self-destructed destination; (3) use the in-scope adapter with attacker-selected route tokens. The allowlist/return-length/route checks prevent an unapproved code path; the approved adapter remains the trust boundary.

[Feynman: StrategyManager] This owns the strategy list, routes Controller instructions, totals all counted value, manages performance-fee dilution, and controls which stranded ERC-20 balances remain in NAV.

[Feynman: StrategyManager.initialize/_authorizeUpgrade] This atomically sets Registry and fee configuration and limits later implementation replacement to administrator.

[Feynman: StrategyManager.addStrategy] This lets only administrator register a code-bearing strategy, set its weights, and grant it Converter caller permission as one all-or-nothing operation.

[Feynman: StrategyManager.removeStrategy/forceRemoveStrategy] These let only administrator remove a clean strategy or forcibly drop a broken strategy, then best-effort revoke Converter caller permission.

[Inversion: StrategyManager strategy registration] (1) Add as keeper; (2) add a code-less address; (3) make the Converter role grant fail. The first two reject and the third rolls the whole addition back.

[Feynman: StrategyManager deposit/withdraw/rebalance/sync entry points] These accept operational instructions only from the Registry's current Controller and keep direct users/keepers from bypassing that deputy.

[Feynman: StrategyManager.emergencyWithdrawToController] This lets administrator or security move all native currency held by the manager to the registered Controller; the value remains counted.

[Feynman: StrategyManager.addSupportedERC20] This lets only administrator add a code-bearing Oracle-priceable token balance to total NAV accounting.

[Feynman: StrategyManager.removeSupportedERC20] This lets administrator or security delete a token from NAV accounting without checking its balance, feed state, or whether user pricing is paused.

[Socratic: src/contracts/StrategyManager.sol:removeSupportedERC20 — why?] Why can the immediate security tier make a material asset disappear from NAV while AMM entry and exit remain live? The implicit belief is that operators will manually pause first whenever the balance is material.

[Inversion: StrategyManager.removeSupportedERC20] (1) Remove a zero-balance stale token; (2) remove a one-wei grief token; (3) remove a fresh token worth 10 ETH while AMM is open, buy EVE before a visible timelocked re-add, then redeem after re-add. The third defeats the economic isolation expected from SECURITY_ROLE.

[Feynman: StrategyManager.pause/unpause] Security or administrator can stop operational manager entry points; only administrator can reopen them. NAV views remain callable while paused.

[Feynman: StrategyManager.harvestPerformanceFeeFromStrategy/harvestPerformanceFeeFromStrategies] These accept harvest instructions only from Controller, settle registered strategies, and mint once to the configured treasury.

[Feynman: StrategyManager.setPerformanceFeeBps/setDaoTreasury/setStrategyDepositCooldown/setStrategyWeights] These configuration changes are administrator-only and bounded where applicable.

[Feynman: StrategyManager._totalNAVInETH] This totals every registered strategy, native currency at manager/controller/AMM, and every currently supported ERC-20 balance; removing a support entry removes that balance from the price immediately.

[Feynman: StrategyManager._supportedERC20sNAVInETH] This skips zero balances and asks the Oracle to convert every nonzero supported balance to native-currency value.

[Feynman: StrategyManager._mintPerformanceFeeEVE] This converts a settled ETH fee claim into treasury-owned EVE dilution using the current total supply and NAV.

[Feynman: Whitelist] This is an invite gate whose administrator manages users/signers and whose security tier may only revoke signers; signed vouchers bind user, opaque invite identifier, deadline, chain, and contract.

[Feynman: Whitelist.whitelist] This permissionless relay verifies an unused, unexpired voucher from a current signer and admits the voucher's named user; already admitted users are a no-op.

[Inversion: Whitelist.whitelist] (1) Front-run another user's voucher; (2) change the user field; (3) replay the same invite for a second user. The first only admits the intended user and the signature/used-id checks defeat the others.

[Feynman: Whitelist.addToWhitelist/removeFromWhitelist] Administrator can admit addresses or ban one address while the gate is still active.

[Feynman: Whitelist.addSigner/removeSigner] Administrator can add signers; administrator or security can revoke a signer immediately.

[Feynman: Whitelist.disable] Administrator can irreversibly open entry for everyone.

[Feynman: KeeperExecutorBase] This is a keeper-role-holding deputy that only accepts automated execution from one administrator-configured forwarder.

[Feynman: KeeperExecutorBase.setForwarder] This lets administrator replace the one nonzero address allowed to call `performUpkeep`.

[Feynman: KeeperExecutorBase.pause/unpause] Security or administrator can stop a deputy; only administrator can restart it.

[Inversion: KeeperExecutorBase.onlyForwarder] (1) Call before a forwarder is set; (2) call from the old forwarder after replacement; (3) call from a keeper-role EOA. All fail exact caller equality.

[Feynman: QueueKeeperExecutor.checkUpkeep/performUpkeep] This deputy proposes queue work from current state and, when its forwarder calls, recomputes eligibility before asking Controller to price or process.

[Feynman: QueueKeeperExecutor.setMinBatchAge/setMaxUsersPerUpkeep/advanceBatchCursor] Administrator alone controls queue timing/caps and may deliberately advance the processing cursor within the live range.

[Inversion: QueueKeeperExecutor.performUpkeep] (1) Forge a live-batch price action too early; (2) forge an unaffordable process action; (3) forge a cursor target beyond what current state permits. Revalidation rejects each.

[Feynman: StrategyKeeperExecutor.checkUpkeep/performUpkeep] This deputy chooses among six strategy actions and recomputes every amount/condition when its configured forwarder executes.

[Feynman: StrategyKeeperExecutor policy setters] Administrator alone controls reserves, action thresholds, sync interval, and AMM-float target.

[Inversion: StrategyKeeperExecutor.performUpkeep] (1) Encode a withdrawal without a shortfall; (2) encode a deposit with no eligible capacity; (3) encode a fee harvest below threshold. Each branch recomputes and rejects stale data.

[Feynman: UniswapV3ConverterAdapter] This fixed adapter validates a single-hop path, quotes from TWAP checked against Oracle, and when run inside Converter approves only its immutable router for the requested swap.

[Feynman: UniswapV3ConverterAdapter.validateRoute/routeTokens] These public readers accept only a structurally valid single-hop path and return its endpoints.

[Feynman: UniswapV3ConverterAdapter.quoteExactAmountIn/quoteExactAmountOut] These compute a time-averaged pool quote, compare it to Oracle value, and account for the fee in the returned bound.

[Feynman: UniswapV3ConverterAdapter.swapExactAmountIn/swapExactAmountOut] These approve the fixed router for a bounded input, perform the route, and clear the approval; they are intended to run in Converter's context.

[Inversion: UniswapV3ConverterAdapter direct calls] (1) Call the adapter directly with no adapter-held balance; (2) choose a multi-hop path; (3) choose a nonexistent pool. There is no protocol asset path in the first and the latter two revert.

[Feynman: UniCLStrat] This registered strategy holds native currency and a WETH pair, trusts only StrategyManager for normal fund operations, lets administrator configure it, and lets administrator/security pause and sweep emergency inventory to StrategyManager.

[Feynman: UniCLStrat.deposit/withdraw/rebalance/sync] These accept normal capital operations only from the Registry's current StrategyManager and return withdrawals only to the manager-selected receiver.

[Feynman: UniCLStrat.investIdleETH] This lets only administrator deploy donated idle native currency within the strategy cap.

[Feynman: UniCLStrat.settlePerformanceFee] This lets only StrategyManager mark local LP fees charged and report their ETH value for a manager-side mint.

[Feynman: UniCLStrat configuration setters] These let only administrator change position, TWAP, cap, route, and slippage settings.

[Feynman: UniCLStrat.pause/unpause] Security or administrator can stop the strategy and attempt an unwind; only administrator can restore approvals and reopen it.

[Feynman: UniCLStrat.emergencyExit] This lets administrator or security, once the strategy itself is paused, move native currency and best-effort paired-token inventory to StrategyManager and write off pending fee accounting.

[Socratic: src/contracts/strategies/UniCLStrat.sol:emergencyExit — why?] Why is pausing this strategy considered sufficient when transferring an unsupported paired token out of the registered strategy can lower protocol NAV while the separate AMM remains open? The hidden assumption is that deployment already whitelisted the token or operators separately paused AMM.

[Inversion: UniCLStrat.emergencyExit] (1) Exit with only WETH/native currency and preserve NAV; (2) exit with a supported paired token and preserve NAV through manager accounting; (3) exit with an unsupported paired token while AMM is live, then trade around the later support addition. The third creates the accounting discontinuity in Finding 3.

[Feynman: UniCLStrat.selfRemoveLiquidityAndCollect] This external hook performs pool cleanup only when the immediate caller is the strategy itself.

[Feynman: UniCLStrat.uniswapV3MintCallback] This pays the immutable pool only during an active mint and closes the one-use callback flag.

[Inversion: UniCLStrat.uniswapV3MintCallback] (1) Call from an EOA; (2) call from the pool outside minting; (3) have the pool call twice. Exact pool identity and the one-use flag reject all three unauthorized/duplicate paths.

## Structured results

FINDING | contract: ProtocolDeployBase | function: _deployTimelocks | bug_class: timelock-delay-bypass | group_key: ProtocolDeployBase | _deployTimelocks | timelock-delay-bypass
severity: high
path: deployment operator supplies `TIMELOCK_ADMIN_DELAY=0` (or any value below 48 hours) -> `_deployTimelocks` forwards it unchanged -> `_deployTimelock` constructs `TimelockController` with that minimum -> Registry gives that timelock `ADMIN_ROLE` and bootstrap finalization removes the deployer -> DAO proposer schedules and executes an administrator call without the documented reaction window.
guard_gap: `DEFAULT_ADMIN_TIMELOCK_DELAY` and the comments define 48 hours as a minimum, and `_verifyTimelockRoles` checks five role invariants, but neither the constructor path nor the verifier checks `getMinDelay() >= DEFAULT_ADMIN_TIMELOCK_DELAY`.
proof: With environment value `0`, `vm.envOr` returns the explicit zero rather than the fallback, so the local constructor call is `new TimelockController(0, [dao], [address(0)], deployer)`. The DAO can call `schedule(registry, 0, abi.encodeCall(Registry.registerContract, (Auth.ORACLE, replacement)), 0, 0, 0)` because the requested delay `0 >= getMinDelay() == 0`; because `EXECUTOR_ROLE` is open, the scheduled call is ready at the same timestamp and can immediately be executed. The same path reaches Oracle setters and each proxy's UUPS upgrade authorization because the timelock is the Registry administrator.
root_cause: The deploy helper treats the 48-hour value only as an unset-variable default, not as an enforced lower bound on an explicitly supplied delay.
consequence: A compromised or malicious DAO proposer can replace modules, change feeds/configuration, grant roles, or upgrade implementations immediately, defeating the protocol's advertised on-chain delay and user reaction period.
description: An explicit sub-48-hour `TIMELOCK_ADMIN_DELAY` silently turns the promised minimum-delay administrator into a weaker or zero-delay administrator while all deployment verification passes.
fix: Resolve the environment value once, require it to be at least `DEFAULT_ADMIN_TIMELOCK_DELAY`, and assert `timelock.getMinDelay()` against the same floor during both one-shot and modular finalization.

FINDING | contract: StrategyManager | function: removeSupportedERC20 | bug_class: lower-tier-nav-manipulation | group_key: StrategyManager | removeSupportedERC20 | lower-tier-nav-manipulation
severity: high
path: `SECURITY_ROLE` calls `removeSupportedERC20(materialToken)` while AMM is not paused -> `_supportedERC20s.remove` immediately excludes the manager's existing token balance from `_totalNAVInETH` -> a whitelisted public user enters at the reduced premium price -> the visible timelocked recovery re-adds the token -> the user exits at the restored base price and captures value from existing holders.
guard_gap: `forceRemoveStrategy`, the parallel operation that can drop a material NAV component, is `ADMIN_ROLE`-only, while the immediate SECURITY path here has neither an `AMM.paused()` precondition nor a zero/material-balance distinction; the runbook's “prefer pausing first if material” is purely operational.
proof: Use a valid reachable state with `connectorWeight=1e18`, `totalSupply=100e18`, 20 ETH free on AMM, 80 ETH on Controller, and a supported manager-held token worth 10 ETH, so NAV is 110 ETH. Security removes the token while AMM remains open, making NAV 100 ETH and premium price exactly 1 ETH/EVE. An already-whitelisted user deposits 10 ETH and `_enter` mints `10e18` EVE; counted NAV/supply become 110 ETH/110 EVE. After the DAO's scheduled `addSupportedERC20` executes, NAV becomes 120 ETH and base price is `floor(120e18 * 1e18 / 110e18) = 1.090909090909090909e18`. Requesting `Math.convertAssets(10e18, basePrice) = 10.909090909090909090 ETH` burns exactly the attacker's 10 EVE and can settle from the pre-existing 20-ETH AMM float, yielding about 0.90909 ETH profit. All calls satisfy local guards; no privileged collusion is needed once the security removal and later recovery are public.
root_cause: A no-delay emergency role can delete a balance-bearing NAV entry without first stopping the AMM functions that mint and burn against that NAV.
consequence: A normal stale-feed recovery or a compromised security signer can create a permissionless buy-low/redeem-high window that dilutes existing EVE holders and transfers liquid backing to entrants around the timelocked re-add.
description: `SECURITY_ROLE` can make material assets disappear from live EVE pricing even though that role is intended as a circuit breaker rather than an economic configuration authority.
fix: For the SECURITY path, require the AMM (and preferably the full pricing/settlement surface) to be paused before removal; retain the existing unrestricted-in-pause escape hatch and let only the timelocked ADMIN path remove while live if that behavior is truly required.

FINDING | contract: UniCLStrat | function: emergencyExit | bug_class: emergency-role-untracked-asset-transfer | group_key: UniCLStrat | emergencyExit | emergency-role-untracked-asset-transfer
severity: medium
path: a paired token was not pre-added to StrategyManager's supported set -> `SECURITY_ROLE` pauses UniCLStrat but leaves AMM open -> `emergencyExit` transfers the paired balance from the registered strategy (where `navInETH` counted it) to StrategyManager (where unsupported ERC-20s are not counted) -> public entry occurs at the lower NAV -> the later timelocked `addSupportedERC20` restores NAV -> entrant redeems at the higher price.
guard_gap: The function checks only `UniCLStrat.paused()`, which protects strategy actions but not AMM pricing; it neither requires `StrategyManager.isSupportedERC20(pairedToken)` before moving the token nor requires the separate AMM to be paused. By comparison, WETH/native transfers remain counted at both endpoints.
proof: In a valid live state set `connectorWeight=1e18`, `totalSupply=100e18`, liquid protocol ETH=50 ETH (at least 20 ETH on AMM), and the registered strategy's paired-token inventory=50 ETH with a valid Oracle feed but no StrategyManager support entry, so NAV=100 ETH. Security calls `pause()` then `emergencyExit()`: the 50-ETH token moves to StrategyManager, strategy NAV becomes zero, and manager NAV remains only 50 ETH. A whitelisted user deposits 10 ETH at the resulting 0.5-ETH premium/base price and receives 20 EVE; counted NAV/supply become 60 ETH/120 EVE. When the scheduled `addSupportedERC20` later counts the stranded token, NAV becomes 110 ETH and base price becomes `110/120 = 0.916666...` ETH/EVE; the 20 EVE redeem for about 18.333 ETH, an 8.333-ETH gain, with the AMM float able to settle it. The strategy-pause requirement is satisfied throughout and AMM entry/exit never pauses.
root_cause: Emergency exit moves non-native inventory across an accounting boundary without proving the destination will count that inventory or freezing the independent mint/redemption module.
consequence: An emergency action available to the immediate security tier can create a large, externally arbitrageable NAV discontinuity and dilute existing holders.
description: Pausing only UniCLStrat does not make its SECURITY-triggered paired-token sweep safe when the destination does not yet count that token and AMM remains live.
fix: Keep unsupported paired tokens on the registered strategy until StrategyManager support exists, or require AMM to be paused before SECURITY can transfer them; deployment/finalization should also require every registered UniCL paired token to be supported before go-live.

LEAD | contract: ProtocolDeployBase | function: _protocolDao | bug_class: zero-proposer-governance-lock | group_key: ProtocolDeployBase | _protocolDao | zero-proposer-governance-lock
code_smells: `DAO_ADDRESS` is required but an explicitly supplied zero address is not rejected; TimelockController grants `PROPOSER_ROLE`/`CANCELLER_ROLE` to zero, `_verifyTimelockRoles` sees `hasRole(PROPOSER_ROLE, address(0)) == true`, the deployer renounces the only external timelock administrator, and `schedule` uses strict `onlyRole(PROPOSER_ROLE)` rather than the open-role executor rule.
description: The complete local state trace leaves the Registry governed by a timelock no transaction sender can propose through, but this is retained as a lead because the only known trigger is deployment-operator configuration (self-bricking rather than an unprivileged exploit); confirm whether explicit zero must be rejected as part of release assurance.

LEAD | contract: ProtocolDeployBase | function: _verifyDeployerTieredAccess | bug_class: incomplete-role-exclusivity-check | group_key: ProtocolDeployBase | _verifyDeployerTieredAccess | incomplete-role-exclusivity-check
code_smells: Production finalization checks only “configured admin present” and “deployer absent,” while the deployment test separately asserts `getRoleMemberCount(ADMIN_ROLE) == 1`; an additional administrator or minter present before finalization survives and the finalizer reports success.
description: An extra holder can bypass the timelock after finalization, but every identified way to introduce that holder already requires bootstrap/timelock administration, so this is an assurance-postcondition gap rather than a confirmed unprivileged escalation path.

CLEARED | area: Registry role-admin graph and batch role mutations
details: Checked `ADMIN`, `KEEPER`, `MINTER`, `SECURITY`, caller-manager, and caller roles; batch loops re-check each role admin and revert atomically, zero recipients are rejected, and no caller-role-to-manager escalation path was found.

CLEARED | area: Upgradeable initialization and UUPS authorization
details: Controller, Converter, ExitQueue, Oracle, and StrategyManager implementations disable initialization; deployment proxies initialize atomically; every `_authorizeUpgrade` consults Registry `ADMIN_ROLE`; no public reinitializer or implementation-takeover path was found.

CLEARED | area: Exact contract-key deputies
details: AMM/Controller/ExitQueue/StrategyManager/Converter/UniCLStrat use immediate-caller equality against current Registry keys; old modules and role-bearing EOAs cannot impersonate a registered peer.

CLEARED | area: Converter caller-role administration and token movement
details: Only the current StrategyManager can invoke Converter's grant/revoke deputies, Registry requires Converter's manager role, and in-scope swaps pull caller input and pay measured output deltas; no caller could spend another strategy's approved balance or Converter pre-existing balance.

CLEARED | area: Keeper forwarder boundary and performData
details: Both executors reject calls until a nonzero forwarder is configured, old/direct callers fail exact equality, and every action/amount is recomputed before Controller invocation; no performData privilege bypass was found.

CLEARED | area: Whitelist relaying and signer tiers
details: Permissionless voucher relay binds the admitted user and only helps that user; replay and substitution fail; SECURITY can revoke but not add signers or reopen/disable the gate.

CLEARED | area: EVE mint/burn boundary
details: All supply-changing entry points require Registry `MINTER_ROLE`, and third-party burning also consumes allowance; expected AMM/StrategyManager role grants were traced.

CLEARED | area: Pause/unpause asymmetry
details: AMM, Controller, ExitQueue, StrategyManager, Registry, keepers, and UniCLStrat allow immediate security pause but administrator-only unpause; Converter's administrator-only pause is documented and in-scope strategies revoke its allowances on security pause. No concrete shared-fund access path through the still-live Converter was found.

CLEARED | area: Emergency native-currency sweeps
details: StrategyManager-to-Controller and Controller-to-AMM sweeps are destination-fixed and NAV-neutral; they cannot redirect value to the emergency caller. The non-native UniCL transfer is separately reported.

AGENT_STATUS: COMPLETE
