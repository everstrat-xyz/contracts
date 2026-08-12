# QuillShield Q1 — semantic-guard-analysis

snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full frozen 39-file primary scope (25 runtime/library + 14 deployment)
input_read: `SKILL.md` 251/251 lines; references 2/2 files, 360/360 lines; bundle `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `source.md` 9,417/9,417, `finding-format.md` 101/101
workflow: state-interaction matrix built for every writable variable; explicit/modifier/transitive guards mapped; guard-to-state frequencies evaluated; cross-contract dependencies and deployment validation included; constructor/view/emergency and intentional liveness exceptions privilege-filtered
guard_families: auth roles/contracts/forwarder/pool/self; pause/disabled/emergency; amount/range/cap/deadline/cooldown/expiry; registration/membership/code/route/feed; balance-delta/slippage/oracle/TWAP; initializer/UUPS/timelock/finalization
tests: none; anomalies were closed with base-SHA guard-path comparisons

FINDING
file:         src/contracts/automation/QueueKeeperExecutor.sol
function:     performUpkeep
mechanism:    The `ProcessRequests` branch accepts untrusted `performData` after checking only affordability; it omits the post-commitment expiry guard used by discovery, cursor advancement, and liability reservation.
consequence:  A stale Forwarder transaction can process a request after the user is entitled to cancel, paying the frozen price from current holders' backing instead of rejecting stale work.
trigger:      registered Forwarder submits or mines `ProcessRequests` after `pricedAt + MAX_BATCH_PROCESSING_TIME`
severity:     medium
rationale:    Plugin guard confidence 75% (3/4 related paths reject or exclude expired work) — financial impact is partial and the timing/Forwarder boundary limits likelihood.
poc:          none — reasoning only
evidence:     The contract says `performData is untrusted and re-validated` (lines 185-187). Discovery invokes `_isBatchSkippable` (157-160), the helper marks post-expiry batches skippable (299-305), and StrategyKeeper excludes their liability (StrategyKeeperExecutor.sol:524-527), but execution only calls `_affordableRequests` then `controller.processRequests` (209-214).
fix:          Apply `_isBatchSkippable(queue, batchId)` (or the explicit expiry predicate) in the `ProcessRequests` execution branch before affordability.
related:      none

FINDING
file:         src/contracts/StrategyManager.sol
function:     _withdrawFromStrategies
mechanism:    Batch paths wrap only the final strategy action in `try/catch`; their prerequisite `maxWithdrawal`, `maxDeposit`, `paused`, and `isHealthy` calls remain outside failure isolation.
consequence:  One degraded or selectively reverting registered strategy can revert whole-system deposits, withdrawals, rebalances, and syncs instead of being skipped, delaying redemption liquidity until a timelocked force removal.
trigger:      any registered strategy reverts from an eligibility/status view
severity:     medium
rationale:    Plugin guard confidence 100% — all four batch families advertise/carry partial-success catches, yet all four expose unguarded preflight calls; availability rather than direct theft dominates.
poc:          none — reasoning only
evidence:     Withdrawal reads `strategy.maxWithdrawal()` before its per-strategy `try strategy.withdraw` (StrategyManager.sol:1090-1100,1124-1141). Deposit similarly reads `maxDeposit/isHealthy` before `try deposit` (1000-1032); rebalance reads `paused/isHealthy` before `try rebalance` (1177-1185); sync reads `paused` before `try sync` (1211-1219).
fix:          Isolate the complete per-strategy preflight plus action, catching each external view failure and continuing with the next strategy.
related:      none

FINDING
file:         src/contracts/Oracle.sol
function:     updateUsdFeedInfo
mechanism:    Runtime USD-feed additions/updates validate only nonzero address, nonzero staleness, and decimals, omitting the USD-quote semantic guard applied to the initial deployment feed.
consequence:  A timelocked but mistaken update can install (for example) a TOKEN/ETH or ETH/BTC feed in a TOKEN/USD slot, deterministically corrupting NAV, mint, redemption, and strategy swap bounds.
trigger:      ADMIN configures a live, correctly-decimalized feed with the wrong quote denomination
severity:     medium
rationale:    Plugin guard confidence 67% (both initial deployment paths assert USD semantics; the reusable runtime path does not) — configuration is privileged, but a wrong feed can misprice all protocol value.
poc:          none — reasoning only
evidence:     `_assertUsdQuotedFeed` requires a `" / USD"` description (ProtocolDeployBase.sol:225-238), and DeployOracle calls it before the initial update (DeployOracle.s.sol:36-48). `_upsertFeed` used for all later updates calls only `_validateFeedParams` and `_validateFeedDecimals` (Oracle.sol:344-353,386-411).
fix:          Enforce quote-domain metadata in the Oracle update itself (or store/verify explicit base and quote identifiers), and validate a current round before accepting the feed.
related:      none

FINDING
file:         script/ProtocolDeployBase.sol
function:     _deployTimelock
mechanism:    The sole proposer and emergency participant are not validated as nonzero and distinct from the deployer before roles are granted, while the verifier merely checks membership for the supplied values.
consequence:  `DAO_ADDRESS=address(0)` passes verification but leaves no address able to schedule ADMIN operations after bootstrap renunciation; setting DAO or security to the deployer can also leave the deployer with permanent proposer/canceller or SECURITY authority.
trigger:      deployment operator supplies a zero or tier-colliding governance address
severity:     medium
rationale:    Plugin guard confidence 96% — critical address validation is an otherwise strong deployment pattern; only configuration error triggers it, but the zero-proposer end state is unrecoverable through the self-administered timelock.
poc:          none — reasoning only
evidence:     `_protocolDao/_protocolSecurity` return raw `vm.envAddress` values (lines 263-272); `_deployTimelock` directly assigns proposer and security roles (361-378). `_verifyTimelockRoles` checks `hasRole(..., _proposer)` but neither nonzero nor `_proposer != _deployer` (450-460). The deployment then renounces deployer Registry ADMIN (418-421).
fix:          Require proposer/security nonzero and pairwise distinct from each other and the deployer before broadcasting; repeat those identity assertions in final verification.
related:      none

FINDING
file:         script/ProtocolDeployBase.sol
function:     _deployTimelocks
mechanism:    `TIMELOCK_ADMIN_DELAY` is guarded only by a 48-hour default, not by a lower-bound assertion when the environment variable is explicitly supplied.
consequence:  An explicit zero or short value deploys and verifies a governance tier with no promised reaction window for upgrades, role changes, feed updates, or unpausing.
trigger:      deployment operator supplies `TIMELOCK_ADMIN_DELAY < 48 hours`
severity:     low
rationale:    Plugin guard confidence 100% — the source repeatedly states a hard production minimum while the only write path omits it; exploitability is limited to deployment error.
poc:          none — reasoning only
evidence:     `DEFAULT_ADMIN_TIMELOCK_DELAY = 48 hours` is documented as the production minimum and `never weaker` fallback (lines 31-39,348-350), but the raw `envOr` result is passed to `_deployTimelock` (352-358).
fix:          Require the resolved delay to be at least `DEFAULT_ADMIN_TIMELOCK_DELAY` before constructing the timelock.
related:      none

FINDING
file:         script/DeployUniCLStrat.s.sol
function:     _deploymentConfig
mechanism:    Environment integers are narrowed to `uint32`, `int24`, and `int56` before range validation; DeployUniswapV3ConverterAdapter performs the same pre-check `uint32` narrowing.
consequence:  Out-of-range operator input silently wraps/truncates to a different security parameter that can pass the subsequent minimum/positivity guards and deploy shorter TWAPs or unintended strategy widths/deviations.
trigger:      deployment operator supplies a value outside the destination integer type
severity:     low
rationale:    Plugin guard confidence 100% — validation is present but ordered after lossy conversion; post-deploy logging reduces likelihood, while an unintended short TWAP weakens manipulation resistance.
poc:          none — reasoning only
evidence:     `uint32(vm.envUint(...))` occurs before TWAP minimum checks (DeployUniCLStrat.s.sol:92-99), and strategy ints are narrowed inline at 113-115. Adapter deployment repeats `uint32(vm.envUint("ADAPTER_TWAP_INTERVAL"))` before its check (DeployUniswapV3ConverterAdapter.s.sol:49-55). For example, `2**32 + 60` becomes 60 and passes the adapter floor.
fix:          Read into `uint256/int256`, validate both semantic bounds and destination-type bounds, then cast.
related:      none

FINDING
file:         src/contracts/automation/QueueKeeperExecutor.sol
function:     advanceBatchCursor
mechanism:    Automated cursor changes advance only across `_isBatchSkippable` batches, but the ADMIN setter can irreversibly jump over nonempty, unexpired batches without applying that guard.
consequence:  A mistaken admin operation removes skipped users from Automation discovery; they wait until the three-day escape hatch and must cancel manually even when settlement was affordable.
trigger:      ADMIN advances the cursor beyond a live priced batch
severity:     low
rationale:    Plugin guard confidence 50% (one of two post-construction cursor writers enforces skippability) — timelock review and cancellation limit impact, but the cursor cannot move backward.
poc:          none — reasoning only
evidence:     `_peekAdvancedCursor` loops only while `_isBatchSkippable` (316-323), whose criteria are empty or expired (299-305). `advanceBatchCursor` checks only monotonicity and `<= currentBatchId` before assignment (276-284).
fix:          Require every batch in `[nextBatchIdToProcess, _toBatchId)` to be skippable, or make any explicit force-skip reversible and separately named.
related:      none

LEAD
file:         src/contracts/strategies/UniCLStrat.sol
function:     setMaxTickDeviation
suspicion:    Positivity is the only bound, so a huge value can disable the calm-period guard (or overflow TWAP band arithmetic); `setPositionWidth` similarly omits a safe product/tick bound despite multiplying by `tickSpacing` in `int24`.
blocked_by:   Safe economic maxima are configuration-specific and no production pool/config was supplied.
next_step:    Derive bounds from pool tick spacing and policy, then fuzz all setters through `_isCalm`, `_setTicks`, deposit, and rebalance at boundary values.

LEAD
file:         src/contracts/Converter.sol
function:     pause
suspicion:    Converter is the only value-moving core module whose pause is ADMIN-only; other protocol and keeper pauses admit immediate SECURITY, so an adapter/caller incident cannot be stopped at this boundary without the timelock.
blocked_by:   Auth comments omit Converter from the SECURITY pause list, which may reflect an intentional assumption that pausing every strategy is sufficient.
next_step:    Confirm the incident model for orphaned/malicious Converter callers and grant SECURITY pause-only authority if direct containment is required.

LEAD
file:         src/contracts/Oracle.sol
function:     removeToken
suspicion:    A feed can be removed while the token remains referenced by StrategyManager or a registered strategy, immediately turning their previously guarded NAV reads into reverts; staleness intervals also have no upper bound.
blocked_by:   Consumer enumeration and acceptable feed-specific staleness require governance/configuration intent not present in the bundle.
next_step:    Add/reference-count consumers or validate a coordinated removal batch, and define per-feed maximum staleness policy.

CLEARED
area:         Pause exceptions for user recovery
checked:      AMM `claim/cancelRedemption` and ExitQueue `closeRequest` intentionally omit pause guards but retain nonreentrancy, ownership/request membership, and expiry/finality checks so pausing cannot trap settled or cancellable users.

CLEARED
area:         Runtime authorization surface
checked:      Every non-view state-changing runtime entry was mapped; mint/burn, queue writes, controller/manager calls, Converter calls, callbacks, self-calls, forwarders, configuration, and upgrades have an explicit role/registered-contract/domain guard.

CLEARED
area:         Whitelist semantic guards
checked:      Active-gate mutators consistently use `whenNotDisabled`; permissionless voucher redemption binds user/ID/deadline/signer, and the disabled-path early return is an intentional terminal-state behavior.

CLEARED
area:         Swap guard propagation
checked:      Strategy calm/oracle/slippage checks, Converter caller/adapter/route/deadline/delta checks, adapter TWAP/oracle checks, and pool/mint callback authentication were traced end to end.

CLEARED
area:         Upgrade and initialization guards
checked:      Implementation initializers are disabled, proxy initialization is one-shot, and all five UUPS authorization hooks use Registry ADMIN.

commands: full plugin/reference and allowed-bundle `sed -n` reads; frozen guard/function inventories with `git grep ... 734df96 -- src script`; exact evidence via `git show 734df96:PATH | nl -ba | sed -n ...`; pinned dependency role behavior checked at base submodule SHA; no network, worktree source, or tests used
AGENT_STATUS: COMPLETE
