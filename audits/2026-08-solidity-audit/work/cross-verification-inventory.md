# Cross-verification inventory (Tier 3)

Target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`. This is internal bookkeeping, not a client report. It inventories the raw outputs that existed when this file was written; Pashov bundles are expressly excluded. `F`/`L` occurrence numbers below are local to the named raw file and count structured items from top to bottom. Line numbers are the durable primary locator.

## Method, census, and completion

I read the common cross-verification procedure and finding format in full, then read the requested raw files and every current `work/verification/*.md`. Mechanisms are keyed by `(file, function, code-level mechanism)` and merged only where the same code change fixes the occurrences. Methodology count is distinct from raw-agent count. Existing verification decides dispositions; where it does not, this inventory says `NEEDS ROOT` instead of adding a new judgment.

| Methodology | Inputs inventoried | Findings | Leads | Completion / failures |
|---|---:|---:|---:|---|
| Pashov | 9 raw reports + candidates/judging/dedup/census | 22 | 15 | 9/12 complete; reviewers 04,05,12 incomplete. Filter interruptions on 01,03,04; 01/03 completed after retry, 04 produced no durable raw. Reviewer 10 uses a different heading format, so semantic counting is required; the corrected Pashov census is 22/15. |
| Omega current discovery | pass A, pass B retry, pass C | 12 | 5 | 3/5 planned discovery passes produced durable output; actor-centric D and invariant E completed their read gates but produced no durable reports and are counted incomplete. Pass R is not discovery and is isolated below. |
| QuillShield | all 11 raw files | 33 | 25 | 11/11 complete; 0 failed. |
| Plamen | all 28 raw files | 36 | 36 | 28/28 complete; 0 failed. The combined `external-precondition-audit:8` block is split into two semantic occurrences (`8a` and `8b`) because it contains independent triggers, consequences, and fixes. |
| **Current total** | **51 durable raw reports plus Pashov handoff files** | **103** | **81** | **184 current semantic occurrences accounted below; 5 planned leaves were incomplete (3 Pashov, 2 Omega).** |
| Omega Pass R | historical regression census only | — | — | 9/9 artifacts; 73/73 explicit historical ID occurrences; 0 regressed. Kept separate and not expanded. |

Pashov's handoff consolidates 22 raw findings to 15 candidates. No Pashov candidate/bundle row is counted as a second occurrence. Cleared-item counts are not needed for occurrence conservation; explicit standard-format clearances are Omega 17, Quill 67, and Plamen 96, while Pashov uses heterogeneous cleared-area lists.

## Normalized mechanisms and every raw FINDING occurrence

Legend: presence is `P/O/Q/L` (Pashov/Omega/QuillShield/Plamen); `—` means absent. `CONFIRMED`, `REJECTED`, and `LEAD` are current verification dispositions; `NEEDS ROOT` means the supplied reports do not settle final promotion. Occurrence references are `raw-file:line`; the 103 semantic finding occurrences are placed exactly once, with Plamen's combined emergency block explicitly split as `8a`/`8b`.

| Key: file :: function :: mechanism | Presence | Raw FINDING occurrences (exactly once) | Disposition | Verification |
|---|---|---|---|---|
| `UniCLStrat.sol::navInETH/sync/deposit` :: unpoked V3 fee growth omitted from NAV and pre-deposit cap | P/O/—/L | P `agent-1:305`, `agent-7:31`; O `pass-c:30`; L `depth-state-trace:5`, `share-allocation-fairness:7`, `vault-accounting:27` | CONFIRMED | `verification/unpoked-fee-nav.md` |
| `AMM/StrategyManager::entry/exit/priceBatch/_mintPerformanceFeeEVE` :: recognized pending fee liability absent from NAV/supply pricing | P/—/—/— | P `agent-1:312`, `agent-3:122`, `agent-7:42` | CONFIRMED | `verification/pending-fee-share-pricing.md` |
| `UniswapV3ConverterAdapter::quoteExactAmountOut` :: required input and fee gross-up round down | P/—/—/— | P `agent-1:319` | LEAD | no dedicated verification; P-03 retained lead |
| `ProtocolDeployBase::_deployTimelocks` :: explicit sub-48h delay bypasses documented floor | P/O/Q/L | P `agent-2:378`; O `pass-c:72`; Q `behavioral-state-analysis:48`, `defender:9`, `semantic-guard-analysis:62`; L `depth-edge-case:5`, `governance-attack-vectors:10` | CONFIRMED | `verification/deployment-timelock-config.md` |
| `StrategyManager::removeSupportedERC20` :: nonzero held token omitted from live NAV while AMM stays open | P/—/Q/L | P `agent-2:388`; Q `behavioral-state-analysis:22`, `state-invariant-detection:49`; L `centralization-risk:34`, `depth-state-trace:31`, `semi-trusted-roles:77`, `share-allocation-fairness:80` | CONFIRMED | `verification/supported-token-removal.md` |
| `UniCLStrat::emergencyExit` :: paired token crosses into an unsupported/unpriced manager location | P/—/Q/L | P `agent-2:398`; Q `state-invariant-detection:23`; L `economic-design-audit:50`, `semi-trusted-roles:52` | CONFIRMED | `verification/supported-token-removal.md` (same omission/re-add dilution); deployment state still matters |
| `StrategyKeeperExecutor::capacity checks` :: zero-weight strategies selected although allocator cannot use them | P/—/—/— | P `agent-3:128`, `agent-3:134`, `agent-7:20` | CONFIRMED | `verification/zero-weight-keeper.md` |
| `UniCLStrat::_pauseStrategy` :: fallible allowance cleanup rolls back pause | P/—/Q/L | P `agent-6:67`, `agent-9:27`; Q `dos-griefing-analysis:18`; L semantic `external-precondition-audit:8a` | CONFIRMED | `verification/emergency-isolation.md` A |
| `UniCLStrat::emergencyExit` :: paired-token balance read precedes and blocks native/WETH recovery | P/—/Q/L | P `agent-6:76`, `agent-9:38`; Q `dos-griefing-analysis:31`; L semantic `external-precondition-audit:8b` | CONFIRMED | `verification/emergency-isolation.md` B |
| `QueueKeeperExecutor::performUpkeep(ProcessRequests)` :: stale perform data remains executable after escape deadline | P/O/Q/L | P `agent-8:55`; O `pass-b-retry:53`; Q `behavioral-state-analysis:9`, `semantic-guard-analysis:10`; L `semi-trusted-roles:30` | CONFIRMED | `verification/stale-queue-execution.md` |
| `StrategyManager::batch actions` :: external preflight views sit outside per-strategy catch | P/—/Q/L | P `agent-9:49`; Q `dos-griefing-analysis:44`, `external-call-safety:27`, `semantic-guard-analysis:23`; L `external-precondition-audit:29` | CONFIRMED | `verification/strategy-batch-isolation.md` A |
| `StrategyManager::batch catches` :: unbounded caught revert data defeats isolation | —/—/Q/— | Q `dos-griefing-analysis:57`, `external-call-safety:14` | CONFIRMED | `verification/strategy-batch-isolation.md` B |
| `StrategyManager::_withdrawFromStrategies` :: positive dust request truncates to zero on every weighted leg | P/—/—/— | P `agent-10:37` | LEAD | no dedicated verification; P-12/R10-01 retained low-materiality lead |
| `StrategyManager::setPerformanceFeeBps` :: current rate applies to all historical uncharged fee base | P/O/Q/L | P `agent-11:27`; O `pass-b-retry:40`, `pass-c:52`; Q `behavioral-state-analysis:35`, `state-invariant-detection:62`; L `economic-design-audit:28`, `share-allocation-fairness:56`, `temporal-parameter-staleness:31` | CONFIRMED behavior / INFO policy item | `verification/fee-epoch-accounting.md` A; not a demonstrated vulnerability absent accrual-time policy |
| `StrategyManager::setDaoTreasury` :: pending backlog follows new beneficiary | P/—/—/— | P `agent-11:37` | INFO policy item | `source-adjudications.md` SA-07/SA-10; no accrual-time beneficiary specification |
| `ProtocolDeployBase::_verifyCriticalRoleGrants` :: modular finalization omits required Whitelist key | P/—/—/— | P `agent-7:53` | CONFIRMED | `verification/finalize-whitelist.md` |
| `StrategyManager::supported ERC20 accounting/egress` :: ERC20 value counted in redemption NAV has no liquidation/recovery path | —/O/—/L | O `pass-a:7`, `pass-b-retry:66`, `pass-c:9`; L `token-flow-tracing:7`, `vault-accounting:5` | CONFIRMED | `verification/supported-token-liquidity.md` |
| `StrategyKeeperExecutor::rebalance priority` :: deterministic failed rebalance starves actionable liquidity work | —/O/Q/— | O `pass-a:20`; Q `dos-griefing-analysis:5` | CONFIRMED | `verification/keeper-priority-starvation.md` |
| `UniCLStrat::constructor/mint callback` :: configured pool not factory-authenticated and can choose callback debits | —/O/—/L | O `pass-b-retry:27`; L `depth-external:5`, `dex-integration-security:5` | CONFIRMED | `verification/pool-authentication.md` |
| `ProtocolDeployBase::_requireUnregistered` :: alleged swallowed local revert permits overwrite | —/O/—/— | O `pass-b-retry:79` | REJECTED | false claim; deliberate revert in `try` success body propagates (see contradiction 1) |
| `Registry::registerContract(s)` :: live stateful-key replacement lacks state/custody migration | —/O/—/L | O `pass-c:93`; L `migration-analysis:7` | LEAD / CONTESTED | `verification/registry-migration-safety.md` A |
| `Converter/UniCL::WETH identity across Registry rotation` :: new wrapper is untracked/unrecoverable in static strategy | —/—/—/L | L `migration-analysis:32` | LEAD | `verification/registry-migration-safety.md` B |
| `UniCL::Converter allowance lifecycle` :: rotation leaves old approval and new spender unapproved | —/—/—/L | L `multi-step-operation-safety:10` | LEAD / CONTESTED | `verification/registry-migration-safety.md` C |
| `StrategyManager::forceRemoveStrategy` :: funded/recoverable strategy can be dropped from NAV while AMM stays open | —/—/Q/— | Q `state-invariant-detection:36` | ACCEPTED privileged escape hatch / INFO | `source-adjudications.md` SA-08; behavior is explicit in source, interface, README, and runbook |
| `ExitQueue::priceBatch / AMM pricing` :: fixed queued liability remains in both NAV and active supply | —/—/Q/— | Q `state-invariant-detection:10` | CONFIRMED | `verification/priced-queue-accounting.md` |
| `ExitQueue::EnumerableSet order / keeper prefix` :: swap-and-pop promotes later/large request and blocks affordable users | —/—/—/L | L `share-allocation-fairness:31` | CONFIRMED | `verification/queue-ordering.md` |
| `StrategyKeeperExecutor::_pendingRedemptionNeedsETH` :: freely cancellable current batch forces withdrawal/redeposit churn | —/—/—/L | L `economic-design-audit:6`, `semi-trusted-roles:8` | CONFIRMED | `verification/cancellable-liability-churn.md` |
| `AMM::_bootstrap` :: first depositor captures pre-existing protocol NAV | —/—/—/L | L `zero-state-return:6` | CONFIRMED | `verification/bootstrap-residual.md` |
| `UniCL fee counters::withdraw/settle` :: alleged depletion leaves old fees chargeable to new backing | —/—/—/L | L `zero-state-return:31` | LEAD / CONTESTED | `verification/fee-epoch-accounting.md` B; normal lossless endpoint not established |
| `UniCL::TWAP admission/setter` :: configured history need is not probed and NAV can fail closed | —/—/—/L | L `oracle-analysis:15` | CONFIRMED | `verification/twap-availability.md` |
| `StrategyManager::_supportedERC20sNAVInETH` :: dust activates stale/invalid feed and freezes aggregate NAV | —/—/—/L | L `staking-receipt-tokens:7`, `token-flow-tracing:28` | CONFIRMED (LOW) | `source-adjudications.md` SA-01; source explicitly identifies one-wei dust griefing and recovery |
| `StrategyManager/UniCL::token admission` :: token decimals >18 accepted although Math rejects them | —/—/Q/— | Q `input-arithmetic-safety:10` | CONFIRMED | `verification/token-decimals.md` |
| `UniCL::positionWidth/maxTickDeviation` :: positive-only signed config later overflows liveness arithmetic | —/—/Q/— | Q `input-arithmetic-safety:23` | CONFIRMED | `verification/unicl-config-validation.md` A |
| `DeployUniCLStrat/Adapter::config casts` :: environment integers narrow before validation | —/—/Q/— | Q `input-arithmetic-safety:36`, `semantic-guard-analysis:75` | CONFIRMED informational | `verification/unicl-config-validation.md` B |
| `Adapter::validateRoute` :: only structural validation, no configured-pool existence check | —/—/—/L | L `dex-integration-security:27` | REJECTED as security finding | `verification/unicl-config-validation.md` C |
| `Converter::output transfer` :: fee-on-transfer second hop can violate caller-received minimum | —/—/Q/— | Q `external-call-safety:40` | CONFIRMED (LOW) | `verification/fee-on-transfer.md` A |
| `Oracle::updateUsdFeedInfo` :: runtime feed update lacks denomination/direction binding | —/—/Q/— | Q `semantic-guard-analysis:36` | CONFIRMED (LOW, configuration-dependent) | `source-adjudications.md` SA-02 |
| `ProtocolDeployBase::_deployTimelock` :: zero proposer / tier-colliding identities pass verification | —/—/Q/— | Q `defender:22`, `semantic-guard-analysis:49` | CONFIRMED (zero proposer) | `verification/deployment-timelock-config.md` B; nonzero role collisions need deployment evidence |
| `QueueKeeperExecutor::advanceBatchCursor` :: admin may skip live unexpired batch irreversibly | —/—/Q/— | Q `semantic-guard-analysis:88` | REJECTED as guard omission / accepted escape hatch | `source-adjudications.md` SA-09; interface explicitly specifies this behavior |
| `Registry/roles/upgrades` :: one self-administered ADMIN controls all trust roots | —/—/—/L | L `centralization-risk:9` | INFO trust assumption | `source-adjudications.md` SA-11; live role state not supplied |
| `StrategyKeeperExecutor events` :: requested amount emitted as completed movement | —/—/—/L | L `event-correctness:7` | CONFIRMED (LOW) | `source-adjudications.md` SA-03 |
| `script::release binding` :: no chain ID / expected deployer assertion | —/—/Q/— | Q `defender:35` | CONFIRMED (LOW) | `source-adjudications.md` SA-04 |
| `script/docs::PRIVATE_KEY handling` :: production path encourages plaintext private key | —/—/Q/— | Q `defender:48` | INFO operational | `source-adjudications.md` SA-12 |
| `.github workflow::claude-review` :: mutable/untrusted execution with material permissions and no Solidity gate | —/—/Q/— | Q `defender:61` | CONFIRMED CI boundary (MEDIUM) | `source-adjudications.md` SA-05 |
| `foundry.toml::profile.ci` :: compiler/IR/deployed-bytecode parity not proved | —/—/Q/— | Q `defender:74` | CONFIRMED release-readiness (LOW) | `source-adjudications.md` SA-06 |

Normalized finding mechanisms: **45**. Methodology presence distribution: raised by 4 = **3**, by 3 = **6**, by 2 = **4**, by 1 = **32**. These counts are mechanisms, not occurrences.

## Every raw LEAD occurrence

Each of the 81 raw lead occurrences appears once below. `retained` means no current report closed it; `promoted` means existing verification confirmed the mechanism; `retired` means existing verification rejects the security claim; `deployment/fork` means the blocker is external state. Pashov R10 leads use their heading IDs because they are not pipe records.

| Raw LEAD occurrence | Suspicion / normalized destination | Disposition | Verification / note |
|---|---|---|---|
| P `agent-1:328` | 256-bit intermediate overflow in fixed-point helpers | retained | unattainable-scale concern not closed |
| P `agent-1:332` | deployment narrowing before validation | promoted (info) | `verification/unicl-config-validation.md` B |
| P `agent-1:336` | positive fee may settle for zero EVE mint | retained | dust/reachability unresolved |
| P `agent-2:408` | zero proposer governance lock | promoted | `verification/deployment-timelock-config.md` B |
| P `agent-2:412` | finalizer does not prove role exclusivity | deployment | needs actual role set / release policy |
| P `agent-3:142` | pre-entry fee liability assigned to new cohort | promoted | root confirmed in `verification/pending-fee-share-pricing.md` |
| P `agent-3:146` | maxWithdrawal can exceed realizable withdrawal | retained | manager measures actual receipt; no harm proof |
| P `agent-6:87` | structural-only route validation | retired | `verification/unicl-config-validation.md` C |
| P `agent-6:91` | unchecked observation-array shape | retained | no current verification |
| P `agent-8:68` | perform/check parity permits no-op action | retained | material consequence not independently settled |
| P `agent-9:62` | revert-returndata memory grief | promoted | `verification/strategy-batch-isolation.md` B |
| P `agent-10:61` (R10-L1) | exact-output fee gross-up floors | retained | same P-03 mechanism; router harm unverified |
| P `agent-10:62` (R10-L2) | zero-share performance-fee settlement | retained | same as `agent-1:336` |
| P `agent-11:49` | trusted strategy fee report can overdilute | retained | governance trust assumption unresolved |
| P `agent-11:54` | replacement Forwarder can choose favorable valid action | retained / deployment | actual Forwarder and harm not supplied |
| O `pass-a:33` | retroactive performance-fee rate | promoted as behavior/info | `verification/fee-epoch-accounting.md` A |
| O `pass-a:40` | zero-rounded fee mint | retained | reachability/materiality unresolved |
| O `pass-b-retry:92` | Chainlink `answeredInRound` omitted | fork/deployment | feed implementation required |
| O `pass-c:114` | pause rollback on approval failure | promoted | `verification/emergency-isolation.md` A |
| O `pass-c:121` | 50-user liability scan omits tail | retained | no current verification |
| Q `behavioral-state-analysis:61` | 50-user liability cap redeposits owed liquidity | retained | no current verification |
| Q `behavioral-state-analysis:68` | SECURITY canceller can veto its own removal | deployment | live threshold/roles needed |
| Q `defender:87` | deployment not target-bound / no complete post-deploy verification | deployment | receipt, chain, roles, Forwarders absent |
| Q `defender:94` | upgrade docs bypass timelock / omit rehearsal and layout review | retained / deployment | process evidence needed |
| Q `defender:101` | production integration/risk parameters unverified | deployment/fork | manifest and live identities needed |
| Q `dos-griefing-analysis:70` | unbounded sets can gas-DoS NAV/batches | retained | cardinality/gas bounds not tested |
| Q `dos-griefing-analysis:77` | Oracle token removal is unbounded O(n) cleanup | retained | configured size/gas needed |
| Q `dos-griefing-analysis:84` | unaffordable head blocks affordable requests | promoted | `verification/queue-ordering.md` |
| Q `external-call-safety:53` | fee-on-transfer input can use Converter residue/subsidy | retained | no current verification |
| Q `input-arithmetic-safety:49` | 256-bit multiply-before-divide intermediate overflow | retained | realistic asset-supply and price reachability unresolved |
| Q `input-arithmetic-safety:56` | unbounded reserve can overflow keeper needs arithmetic | retained | privileged configuration and realistic-balance reachability unresolved |
| Q `oracle-flashloan-analysis:18` | Chainlink round coherence omitted | fork/deployment | feed versions needed |
| Q `oracle-flashloan-analysis:27` | feed denomination/direction/heartbeat not bound | deployment | actual feeds needed |
| Q `oracle-flashloan-analysis:36` | shallow-pool TWAP manipulation within bands | fork/deployment | pool liquidity/history needed |
| Q `oracle-flashloan-analysis:45` | missing L2 sequencer gate | deployment | chain ID needed |
| Q `proxy-upgrade-safety:18` | no live proxy/init/bytecode proof | deployment | target-bound receipt needed |
| Q `proxy-upgrade-safety:25` | no old/new storage lineage diff | deployment | implementation lineage needed |
| Q `reentrancy-pattern-analysis:18` | callback entry during Converter in-transit NAV gap | retained | no current verification |
| Q `semantic-guard-analysis:101` | unbounded width/deviation | promoted | `verification/unicl-config-validation.md` A |
| Q `semantic-guard-analysis:108` | Converter cannot be immediately security-paused | retained | policy/material harm unsettled |
| Q `semantic-guard-analysis:115` | Oracle token removal can break referenced consumers | retained | no current verification |
| Q `signature-replay-analysis:18` | contract signer admitted but ERC-1271 unsupported | deployment | signer type/set needed |
| Q `signature-replay-analysis:27` | off-chain invite ID/deadline lifecycle | deployment | signing service needed |
| Q `state-invariant-detection:75` | 50-user liability omission | retained | duplicate mechanism, occurrence preserved |
| Q `state-invariant-detection:82` | `totalDeposited` excludes invested donations | retained | semantics/consumer harm unresolved |
| L `callback-receiver-safety:10` | unauthenticated configured pool | promoted | `verification/pool-authentication.md` |
| L `centralization-risk:59` | actual authority may differ from scripts | deployment | live roles/delay/multisig needed |
| L `depth-edge-case:27` | zero price after near-total loss bricks entry/conversions | retained | material reachable loss state unproven |
| L `depth-edge-case:36` | unsafe position width | promoted | `verification/unicl-config-validation.md` A |
| L `depth-external:27` | pool observation history not preflighted | promoted | `verification/twap-availability.md` |
| L `depth-external:37` | Chainlink round IDs discarded | fork/deployment | feed implementation needed |
| L `depth-external:47` | token metadata/external calls can freeze NAV | retained | high-decimal subset promoted via `token-decimals.md`; general token behavior unresolved |
| L `depth-state-trace:53` | failed sync still advances retry clock | retained | no current verification |
| L `dex-integration-security:49` | fee-on-transfer Converter input mismatch | retained | no current verification |
| L `dex-integration-security:58` | Converter rotation leaves stale allowance | retained / contested | `verification/registry-migration-safety.md` C |
| L `economic-design-audit:75` | zero minimum enables Sybil queue growth | retained | gas/backlog materiality untested |
| L `event-correctness:28` | constructor defaults lack change events | deployment | monitor consumption model needed |
| L `external-precondition-audit:50` | supported token not probed for metadata behavior | retained | high-decimal subset promoted; general behavior unresolved |
| L `external-precondition-audit:59` | TWAP history absent at registration | promoted | `verification/twap-availability.md` |
| L `external-precondition-audit:68` | checker strategy views can revert and hide lower actions | retained | no current verification of checker path |
| L `flash-loan-interaction:9` | deployed oracle/DEX manipulation economics | fork/deployment | manifest + fixed fork required |
| L `fork-ancestry:18` | embedded Uniswap library provenance not pinned | dependency research | upstream commit/diff needed |
| L `governance-attack-vectors:35` | actual proposer/security capture/veto posture | deployment | live roles/multisig needed |
| L `migration-analysis:57` | key replacement and role handoff are independent | retained / contested | `verification/registry-migration-safety.md` A |
| L `oracle-analysis:36` | Chainlink round coherence | fork/deployment | feed implementation needed |
| L `oracle-analysis:45` | feed direction/heartbeat/live-round checks | deployment | feed manifest needed |
| L `oracle-analysis:54` | L2 sequencer gate absent | deployment | chain ID needed |
| L `oracle-analysis:63` | max tick deviation unsafe/unbounded | promoted | `verification/unicl-config-validation.md` A |
| L `share-allocation-fairness:104` | unsupported emergency token NAV discontinuity | promoted | `verification/supported-token-removal.md` mechanism; actual deployed support still external |
| L `signature-verification-audit:16` | signing backend key/ID/deadline assumptions | deployment | backend evidence needed |
| L `staking-receipt-tokens:33` | non-standard token makes NAV nondeterministic | retained / deployment | deployed token semantics needed |
| L `storage-layout-safety:9` | no actual upgrade layout diff | deployment | predecessor/successor artifacts needed |
| L `temporal-parameter-staleness:52` | adapter pins old Oracle across Registry rotation | retained | no current verification |
| L `temporal-parameter-staleness:61` | route becomes stale after adapter de-allow | retained | no current verification |
| L `temporal-parameter-staleness:70` | re-adding signer revives old vouchers | retained | policy/backend evidence needed |
| L `token-flow-tracing:49` | emergency paired value omitted before support | promoted mechanism / deployment | `verification/supported-token-removal.md`; live support set needed |
| L `token-flow-tracing:63` | Converter has no residual rescue | retained | protocol-funded residue not proven |
| L `vault-accounting:49` | priced claims not reserved from active accounting | promoted | `verification/priced-queue-accounting.md` |
| L `vault-accounting:58` | head-of-line + swap-and-pop ordering | promoted | `verification/queue-ordering.md` |
| L `verification-protocol:19` | deployed integration behavior not verified | fork/deployment | manifest and fixed fork required |
| L `zero-state-return:53` | zero-NAV bootstrapped pool cannot recapitalize | retained | reachable wipeout precondition unproven |

Lead occurrence arithmetic: Pashov **15** + Omega **5** + Quill **25** + Plamen **36** = **81**. Every row above names exactly one source occurrence; duplicates are intentionally not erased.

## Contradictions and contested interpretations

1. **False Omega `_requireUnregistered` claim.** Omega pass B finding 5 says a revert inside a `try` success body is caught by that statement's `catch`. It is not: Solidity catches only failure of the external expression, so the deliberate success-body revert propagates. Pashov agent 9 explicitly cleared this. The Omega occurrence is `REJECTED`; Registry's separate overwrite/migration hazard remains a distinct real mechanism.
2. **Fee-rate epoch semantics.** Pashov/Omega/Quill/Plamen correctly observe that the current BPS reprices the whole uncharged base. `fee-epoch-accounting.md` confirms the behavior, but base tests affirmatively expect fees accrued while BPS=0 to become chargeable after BPS is restored. Therefore the stale-counter/rate-epoch claim is informational absent an external accrual-time policy; it must not be reported as an accounting vulnerability by raw-majority vote.
3. **Stale fee counters after depletion.** Plamen ZSR-2 alleges later backing can be charged. Verification confirmed the ordering and a post-withdraw pending counter, but normal lossless withdrawal leaves matching fee backing and the next manager withdrawal settles before depletion. The endpoint remains `LEAD/CONTESTED`, requiring a concrete permitted loss/depletion mechanism.
4. **Structural route validation.** Plamen reported lack of pool-existence checks as a finding and Pashov retained it as a lead. Verification found `validateRoute` expressly promises well-formedness, while quotes/swaps fail atomically on missing pools. Security finding is `REJECTED`; stronger deployment preflight is hardening.
5. **Registry migration severity.** Omega/Plamen call stateful replacement a finding; verification confirms the architectural mismatch but notes ADMIN-only, usually reversible rollback and key-specific recovery. It remains `LEAD/CONTESTED` pending the report's trusted-governance policy. This is distinct from the rejected `_requireUnregistered` explanation.

## Pass R historical regression census (not discovery)

Do not expand these into current raw findings or leads. Pass R retrieved **9/9** exact artifacts and classified **73/73** explicit ID occurrences (**51** unique raw labels): **33 FIXED, 33 STILL OPEN, 5 CONTINGENT, 2 UNVERIFIABLE, 0 REGRESSED**. Artifact counts are P1 1, P2 2, Q 3, A 9, PA 11, PL 12, PR 13, MR1 16, MR2 6 = **73**. See `work/omega/raw/pass-r.md` for the exhaustive per-ID table.

## Conservation, final tally, and sanity band

- Current semantic findings: `22 + 12 + 33 + 36 = 103`; normalized into 45 mechanisms; occurrence check: **103/103**. Plamen's two emergency-isolation mechanisms share one combined raw block but are counted separately because they require different fixes.
- Current leads: `15 + 5 + 25 + 36 = 81`; exhaustive lead rows: **81/81**.
- Current items: `103 + 81 = 184`; historical Pass R: `73` separate; grand audited occurrence count: **257**.
- Normalized finding mechanisms by methodology count: 4-way **3**, 3-way **6**, 2-way **4**, single-methodology **32**; total `3+6+4+32=45`.
- Single-methodology share is `32/45 = 71.1%`, slightly above the procedure's approximate 70% sanity band. This is plausible because Quill/Plamen supplied many specialized deployment, external-dependency, event, migration, and configuration mechanisms; it also warrants care not to split related external-state leads into findings.
- Of the 32 single-methodology mechanisms, verification and source adjudication settle 24 as confirmed/info and 3 as rejected; 5 remain `LEAD` or contested. Cross-methodology agreement is not used to invent outcomes.
- Cross-methodology chains were not independently adjudicated by the current verification set; **0 claimed here**. Candidate compositions (for example omitted asset value feeding share-price distortion) are already represented by verified root mechanisms and must not be double-counted without root adjudication.

AGENT_STATUS: COMPLETE
