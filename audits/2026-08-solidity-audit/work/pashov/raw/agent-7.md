# Reviewer 7 — first-principles software-correctness review

[Feynman: StrategyKeeperExecutor.checkUpkeep] It chooses exactly one next maintenance job. A job is actionable only if executing it will change protocol state; otherwise its higher priority can permanently hide useful lower-priority work.
[Socratic: src/contracts/automation/StrategyKeeperExecutor.sol:399 — why?] Why does “deposit capacity” ignore the manager-owned deposit weight when the downstream batch depositor treats weight zero as ineligible?
[Socratic: src/contracts/automation/StrategyKeeperExecutor.sol:379 — why?] Why does withdrawable capacity include a strategy whose manager-owned withdrawal weight is zero when the downstream batch withdrawal will allocate it nothing?
[Inversion: StrategyKeeperExecutor.checkUpkeep] Register one healthy strategy with depositWeight=0 and 1 ETH idle in Controller; make sync overdue while maxDeposit>0; execute DepositExcess repeatedly and observe Controller/strategy balances remain 1/0 ETH while Sync remains hidden.

[Feynman: UniCLStrat.deposit] It checks that the value visible before rearranging the position plus the incoming ETH fits the cap, then pokes the pool, collects everything, rebalances, and restores liquidity.
[Socratic: src/contracts/strategies/UniCLStrat.sol:234 — why?] Why is the cap checked before line 241 materializes fee growth that the checked NAV cannot yet see?
[Inversion: UniCLStrat.deposit] Put 80 ETH under a 100 ETH cap; accrue 10 ETH of unpoked pool fees while maxDeposit still reports 20 ETH; deposit that advertised 20 ETH so the later poke reveals a 110 ETH post-state.

[Feynman: AMM.exit] It prices a holder's shares from all currently reported assets, burns the shares, and pays that gross value even if part of those assets already backs an unminted treasury fee.
[Socratic: src/contracts/StrategyManager.sol:940 — why?] Why does share-pricing NAV include all fee-bearing earnings while the corresponding treasury dilution can be minted later against only the holders who remain?
[Inversion: AMM.exit] Accrue a 0.2 ETH fee against 11 ETH NAV; exit 1,000 of 10,000 EVE at the gross 1.1 ETH value; harvest only after exit so the remaining 9,000 EVE absorb the full 0.2 ETH dilution.

[Feynman: ProtocolDeployBase._verifyCriticalRoleGrants] It is the modular deployment's last completeness gate: every runtime-critical address and role must exist before the bootstrap administrator disappears.
[Socratic: script/ProtocolDeployBase.sol:490 — why?] Why are nine address-book keys resolved but WHITELIST omitted when both AMM entry paths resolve it unconditionally?
[Inversion: FinalizeProtocolDeploy.run] Run every checked modular step but skip DeployWhitelist; let finalization pass and renounce the bootstrap admin; call either enter path and hit RegistryContractNotRegistered until the timelock repairs the key.

FINDING | contract: StrategyKeeperExecutor | function: checkUpkeep | bug_class: zero-weight-noop-upkeep | group_key: StrategyKeeperExecutor | checkUpkeep | zero-weight-noop-upkeep
path: ordinary admin registers a strategy with an explicitly allowed zero allocation weight -> idle capital or redemption shortfall appears -> checkUpkeep selects the higher-priority DepositExcess or WithdrawShortfall action -> StrategyManager computes cumulative eligible weight zero and returns without moving funds -> unchanged state selects the same action forever
assumption: A healthy strategy with positive maxDeposit/maxWithdrawal necessarily gives the corresponding weighted batch operation non-zero capacity.
violation: Strategy weights are manager-owned and zero is explicitly valid, but _depositCapacityAvailable ignores depositWeight and _totalMaxWithdrawal ignores withdrawalWeight.
proof: Local regression with one healthy maxDeposit>0 strategy, depositWeight=0, 1 ETH in Controller, and overdue Sync: checkUpkeep returned DepositExcess; performUpkeep left Controller=1 ETH and strategy=0; the next check returned DepositExcess again. The symmetric withdrawal trace is pending needs=1 ETH, Controller=0, maxWithdrawal=1 ETH, withdrawalWeight=0: _totalMaxWithdrawal reports 1, while StrategyManager's cumulativeWithdrawalWeight is 0 and it withdraws 0.
expected_vs_actual: Expected actionability predicates to select only work that can progress, allowing lower-priority harvest/sync when weighted capacity is zero; actual predicates repeatedly select a no-op.
code_cause: StrategyKeeperExecutor.sol:379-385 and 399-408 do not consult StrategyManager.withdrawalWeight/depositWeight, while StrategyManager's batch paths allocate exclusively by those weights.
consequence: Automation funding is consumed without progress; deposits, queued-redemption funding, fee harvesting, and periodic sync can be starved indefinitely under a valid configuration.
description: Keeper eligibility diverges from the downstream allocator for zero-weight strategies.
fix: Require a positive corresponding manager weight in both capacity helpers (and retain the existing health/cooldown/max checks), with regression coverage for all-zero and mixed-weight sets.

FINDING | contract: UniCLStrat | function: deposit | bug_class: stale-nav-cap-bypass | group_key: UniCLStrat | deposit | stale-nav-cap-bypass
path: LP fee growth accrues without a position poke -> maxDeposit advertises stale headroom -> StrategyManager deposits that amount -> deposit checks stale NAV -> _removeLiquidityAndCollect pokes and materializes the hidden value -> post-deposit NAV exceeds maxTotalNAV
assumption: navInETH at the pre-mutation cap check contains every economically accrued pool asset that the same call can reveal.
violation: Uniswap fee growth is absent from positions().tokensOwed until burn(...,0), and deposit performs that poke only after its cap check.
proof: Isolated regression deposited 80 ETH under maxTotalNAV=100 ETH, accrued 10 ETH of pending WETH fees in the pool, observed unchanged advertised headroom, then deposited that headroom. The call succeeded and final strategy.navInETH() was greater than 100 ETH; both regression tests in Agent07.t.sol passed offline.
expected_vs_actual: Expected maxDeposit to bound the next accepted deposit and post-call NAV to remain <=100 ETH; actual accepted deposit reveals 10 ETH after validation and leaves NAV about 110 ETH.
code_cause: UniCLStrat.deposit validates navInETH at line 234 before _removeLiquidityAndCollect at line 241 performs the fee-materializing poke.
consequence: The strategy can exceed its governance risk cap by the full amount of unpoked LP fee growth.
description: A state-refreshing mutation occurs after, rather than before, the cap's supposedly complete NAV snapshot.
fix: Poke positions before validating the cap and recompute post-receipt NAV, or make NAV/maxDeposit include live fee growth conservatively.

FINDING | contract: AMM | function: exit | bug_class: pending-fee-liability-omitted | group_key: AMM | exit | pending-fee-liability-omitted
path: strategy earns fee-bearing value -> performance fee becomes pending but no treasury EVE is minted -> holder calls immediate exit -> AMM pays gross NAV per share -> later harvest mints the entire fee against only remaining holders
assumption: Gross NAV divided by current supply is the unencumbered redemption value of every outstanding share.
violation: A settled-but-unminted performance fee is an existing dilution claim, yet totalNAVInETH and AMM pricing do not subtract or crystallize it before supply changes.
proof: With NAV=11 ETH, supply=10,000 EVE, a holder owning 1,000 EVE, and pending fee=0.2 ETH, exit pays 1.1 ETH and burns 1,000 EVE. Fee-adjusted value is (11-0.2)/10,000*1,000=1.08 ETH, so the holder avoids 0.02 ETH. Remaining NAV/supply are 9.9 ETH/9,000 EVE; later harvest mints 0.2*9,000/(9.9-0.2)=185.567010309278350515 EVE, placing the full 0.2 ETH burden on remaining holders.
expected_vs_actual: Expected a holder present during accrual to bear its pro-rata fee before leaving; actual exit timing transfers that fee share to holders who remain.
code_cause: AMM.exit lines 151-165 prices from StrategyManager._totalNAVInETH, which sums gross assets at lines 940-950; fee dilution is applied only later by _mintPerformanceFeeEVE at lines 786-793.
consequence: Any holder can avoid already-accrued performance fees by exiting before harvest, and entrants before harvest can inherit fees accrued before they arrived.
description: Supply can change against gross NAV while a known fee claim remains outside both NAV and supply accounting.
fix: Atomically crystallize all visible fees before every AMM mint/burn price snapshot, or consistently price supply changes against NAV net of a complete pending-fee liability.

FINDING | contract: ProtocolDeployBase | function: _verifyCriticalRoleGrants | bug_class: omitted-critical-registration | group_key: ProtocolDeployBase | _verifyCriticalRoleGrants | omitted-critical-registration
path: modular deployment skips DeployWhitelist but completes every checked module/role -> FinalizeProtocolDeploy's completeness check passes -> deployer bootstrap ADMIN_ROLE is renounced -> users call enter/enterWithInvite -> Registry lookup for WHITELIST reverts
assumption: Resolving the listed Registry keys proves every runtime-critical module was deployed.
violation: Auth.WHITELIST is not in the list even though both AMM entry wrappers depend on it.
proof: Lines 490-498 resolve CONTROLLER, EXIT_QUEUE, ORACLE, EVE, AMM, STRATEGY_MANAGER, CONVERTER, and both keeper executors, but never WHITELIST. AMM.enter reaches _registry.whitelist() through _isWhitelisted; enterWithInvite resolves it directly. With all listed keys present and WHITELIST absent, finalization has no failing check, while either entry reverts RegistryContractNotRegistered(Auth.WHITELIST).
expected_vs_actual: Expected the advertised last modular step to reject a skipped entry-gating module before bootstrap teardown; actual it certifies an installation where no user can enter.
code_cause: _verifyCriticalRoleGrants omits `_registry.getContractByKey(Auth.WHITELIST)`.
consequence: A locally successful finalization can launch with all new entries unavailable until a 48-hour timelocked Registry repair executes.
description: The deployment completeness predicate excludes a mandatory runtime dependency.
fix: Resolve and verify the Whitelist registration/back-pointer in the modular finalizer before bootstrap access is finalized.

LEADS: none retained; ambiguous admin-policy and dust-only observations were not promoted.

CLEARED: Converter exact-input/output measured balance deltas, exact-output refund, and adapter route validation for standard ERC-20s.
CLEARED: ExitQueue request/set/total coupling, slippage closure, cancellation escape hatch, and AMM claim-lock accounting.
CLEARED: Controller/StrategyManager native-fund handoffs, partial-success refunds, deposit cooldown coupling, and fee-settlement math apart from pre-harvest share pricing.
CLEARED: Oracle supported-token/pair bookkeeping, inbound/outbound pair removal, staleness and positive-answer checks.
CLEARED: UniCL route direction, callback gating, fee snapshot/collect ordering, withdrawal idle-first flow, and emergency accounting apart from the stale cap snapshot.
CLEARED: Queue keeper cursor advancement, affordability prefix, stale performData revalidation, and post-commitment escape handling.
CLEARED: Registry address/role enumeration and one-shot deployment wiring apart from the modular Whitelist omission.

LOCAL_TEST: `FOUNDRY_OUT=out-pashov-agent-07 FOUNDRY_CACHE_PATH=cache-pashov-agent-07 forge test --match-path test/audit/candidates/pashov/Agent07.t.sol -vvv` -> 2 passed, 0 failed, 0 skipped; no fork/network.

AGENT_STATUS: COMPLETE
