# Plamen Raw Pass: migration-analysis

**Target**: immutable `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
**Scope**: 39/39 source files; same-address UUPS upgrades, Registry address replacements, static-component redeployments, role/config handoff, in-flight redemptions, token-type evolution
**Migration model**: “V1” and “V2” below mean old and newly registered component addresses; no explicit old-token/new-token migrator or `reinitializer` exists in scope.

## FINDING [MG-1]: Re-registering core addresses abandons old custody and in-flight state

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,3b,3c,4a,4b,4c,4d,4e,4f,6 | ?5(production dependency code/addresses not supplied; network prohibited)
**Rules Applied**: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan requirement), R16:✓]
**Depth Evidence**: [TRACE:Registry AMM old->new -> old AMM owns queued EVE -> old AMM rejected by ExitQueue -> new AMM lacks queued EVE], [TRACE:EVE old->new -> AMM reads new balances/supply -> old holders cannot burn for exit]
**Preferred Tag**: CODE-TRACE
**Severity**: Medium
**Location**: `src/contracts/registry/Registry.sol:109-139,218-226`; `src/contracts/AMM.sol:138-193,215-248,400-451`; `src/contracts/ExitQueue.sol:195-268`
**Token Transition**:
- **Old**: EVE balances and queued custody/requests/claims at the previously registered EVE, AMM and ExitQueue.
- **New**: Fresh contracts installed under the same Registry keys.
- **Mismatch Point**: Every peer resolves the new address immediately, but Registry performs no state/custody handoff and validates only non-zero code.
**Description**: `registerContract(s)` overwrites any existing address without a per-key migration check. This is safe for a same-address UUPS implementation upgrade, but not for replacing a contract address. Replacing AMM leaves queued EVE in the old AMM: the old AMM's cancel path is no longer an authorized ExitQueue caller, while the new AMM has no EVE to refund/burn. Replacing ExitQueue leaves requests in a contract that AMM no longer calls. Replacing EVE makes AMM and StrategyManager use the new token's balances/supply, with no conversion of existing holders. No scoped migrator imports requests, balances, claims, or supply.
**Impact**: A routine static-component redeployment or fresh-proxy replacement can strand queued redemptions; an EVE replacement can make the entire legacy holder base non-redeemable and make zero/new supply incompatible with an already-bootstrapped AMM.
**Material Harm**: Users can permanently lose the on-chain path to cancel or settle queued EVE, and legacy EVE holders can lose redemption access, until governance deploys bespoke recovery code outside the supplied system.
**Evidence**: Registry lines 218-226 overwrite the map after only zero/code checks. AMM lines 149-192 dynamically resolves EVE/ExitQueue and holds queued EVE itself; its cancel requires the held balance. ExitQueue push/pull/close accept only the currently registered AMM. `RegistryClientBase.onlyAuthContract` compares against the current key on every call. No `migrate`, queue import/export, EVE swap, or general token recovery function exists.
**Postconditions Created**: New peers become authoritative immediately; old local state and assets remain at addresses no normal peer calls or authorizes.
**Postcondition Types**: [STATE, ACCESS, BALANCE]
**Who Benefits**: No necessary attacker; a migration sequencing error harms holders. A malicious ADMIN could deliberately create the same state, but ADMIN is timelocked and not required for the finding's operational failure mode.
**Semantic Invariant**: Updating a canonical address must preserve every liability and asset referenced by the old address before peers switch.
**Branch Preconditions**: ADMIN replaces AMM, ExitQueue, or EVE while balances/requests exist instead of using a state-preserving same-address upgrade.
**Terminal Mechanism**: Registry pointer switch has no atomic state/custody transfer or empty-state assertion.
**Recommendation**: Make stateful core keys immutable after bootstrap or route replacement through key-specific migration contracts that prove liabilities are empty/imported, assets transferred, roles synchronized, and the new component initialized before an atomic handoff. Document that UUPS components must be upgraded in-place rather than re-registered.

## FINDING [MG-2]: Converter WETH replacement can turn future strategy deposits into an untracked, unrecoverable token

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,3b,3c,4a,4b,4c,4d,4e,4f,6 | ?5(actual production WETH migration not supplied)
**Rules Applied**: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan requirement), R16:✓]
**Depth Evidence**: [TRACE:Converter key old->new(WETH-B) -> old UniCL.deposit wraps ETH to WETH-B -> strategy NAV/emergency exit read only immutable WETH-A/token0/token1 -> WETH-B has no exit]
**Preferred Tag**: CODE-TRACE
**Severity**: Medium
**Location**: `src/contracts/Converter.sol:40-76,281-283`; `src/contracts/strategies/UniCLStrat.sol:75-85,136-171,199-247,494-519,1280-1296`
**Token Transition**:
- **Old**: Strategy-immutable WETH-A and a pool whose token0/token1 includes WETH-A.
- **New**: Newly registered Converter initialized with WETH-B.
- **Mismatch Point**: Strategy calls the Registry's current Converter but accounts and exits only its constructor-immutable WETH/pool tokens.
**Description**: Converter stores its WETH at initialization; UniCL stores a separate WETH and pool token set immutably. Neither strategy construction nor Registry replacement enforces `strategy.weth() == registry.converter().weth()`. After a Converter migration to a different wrapper, `deposit()` sends ETH to the new Converter, which transfers WETH-B back to the old strategy. The strategy's NAV, balancing, LP, withdrawal, and emergency exit paths ignore WETH-B.
**Impact**: Every post-migration deposit can complete while its newly wrapped asset is omitted from NAV and has no strategy rescue/transfer path. Re-registering the old Converter later does not teach the static strategy how to handle WETH-B already held.
**Material Harm**: EVE holders can lose the full value of ETH deposited through affected strategies because the received wrapper is neither priced nor withdrawable by the strategy.
**Evidence**: Converter lines 66-76 accepts/stores independent `_wethAddress`; strategy lines 77-85/139-153 fix WETH and pool tokens. Deposit lines 227-247 dynamically calls `registry.converter()`. `navInETH()` lines 199-202 counts only native/token0/token1, and emergency exit lines 497-515 handles only immutable WETH and paired token. Constructor validation lines 1280-1296 checks only non-zero addresses/config, not Converter-WETH equality.
**Postconditions Created**: Strategy holds WETH-B as an unrecognized ERC-20 while its accounting records the ETH deposit.
**Postcondition Types**: [STATE, EXTERNAL, BALANCE]
**Who Benefits**: No direct beneficiary; the asset is stranded. Remaining accounting can understate NAV and distort mint/redemption prices.
**Semantic Invariant**: The wrapper produced by the active Converter must equal every registered strategy's accounted WETH token.
**Branch Preconditions**: Converter key points to a converter with different WETH; the existing strategy remains registered/caller-authorized; its deposit reaches completion.
**Terminal Mechanism**: Dynamic converter lookup composes with immutable strategy token identity without a compatibility assertion.
**Recommendation**: On strategy add and before every Converter handoff, enforce `IConverter(new).weth() == strategy.weth()` (and route/pool token agreement). Require all old strategies to be fully exited/replaced before permitting a wrapper transition; add a scoped recovery path for mistakenly received tokens.

## LEAD [MG-L1]: Registry address replacement does not synchronize role authority

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4f,6 | ?5(production Timelock batching/runbook unavailable)
**Rules Applied**: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(no token-type premise), R12:✓, R13:✓, R14:✗(no aggregate), R15:✗(no flash loan), R16:✗(no oracle)]
**Preferred Tag**: CONTESTED
**Severity**: Medium
**Location**: `src/contracts/registry/Registry.sol:109-169`; `src/contracts/EVE.sol:40-56`; `src/libraries/Auth.sol:94-105`
**Description**: Registry keys and Registry roles are independent. Replacing AMM does not revoke `MINTER_ROLE` from the old AMM or grant it to the new one; replacing keeper executors does not move `KEEPER_ROLE`; replacing Converter does not move `CONVERTER_CALLER_MANAGER_ROLE`. An old static component can remain privileged after being “replaced,” while the new one is inert.
**Material Harm**: If governance omits a separate role handoff, a deprecated or vulnerable old component can retain mint/burn or capital-management authority after monitoring considers it retired.
**Missing Precondition**: Evidence that production migration operations are not atomically batched with explicit grants/revocations.
**Precondition Type**: ACCESS
**Why This Blocks**: A correctly constructed Timelock batch can update keys and roles together even though Registry itself does not enforce the invariant.

## Upgrade / Pre-Upgrade Inventory

| Component class | State/assets before change | Supported migration | Result |
|---|---|---|---|
| Controller, Converter, ExitQueue, Oracle, StrategyManager | Proxy storage; ETH/tokens/config/requests as applicable | Same-address UUPS, ADMIN-authorized | Storage/custody preserved if layout-compatible |
| AMM | ETH float, locked claims, claim mapping, queued EVE, bootstrap/config | Fresh Registry address only | Unsafe with queue/custody unless explicit handoff (MG-1) |
| EVE | All holder balances/allowances/supply | Fresh Registry address only | No token migrator; unsafe (MG-1) |
| Registry | All roles and canonical addresses | None; every client stores its Registry address | Full-system redeploy required for Registry-address change |
| Whitelist | user/ban/invite/signer mappings | Redeploy + `addToWhitelist` or irreversible `disable` | Documented manual/off-chain migration |
| UniCLStrat | ETH, WETH, paired tokens, LP positions, fee counters | Pause/emergency exit/remove + fresh strategy | Safe only after complete unwind; wrapper mismatch is MG-2 |
| Keepers/adapters | configuration/forwarder or immutable router | Deploy, configure, role/allowlist handoff | No user balances; role synchronization required |

## Cross-Era / Stranding Matrix (Steps 4a-4e)

| Old-era state under new logic | Available exit | Works? | Reason |
|---|---|---:|---|
| Legacy EVE holder after EVE key replacement | AMM `exit` | NO | AMM burns current EVE; legacy balance/supply never imported |
| Queued EVE in old AMM after AMM replacement | old/new `cancelRedemption` or process | NO | old AMM fails current-AMM auth at queue; new AMM lacks custody |
| Requests in old ExitQueue after queue replacement | current AMM/Controller | NO | callers always resolve new queue; no old-queue selector/import |
| Existing claim in old AMM after AMM replacement | call old `claim` directly | YES | claim uses local mapping/balance and only user identity |
| ETH in old Controller / StrategyManager | old emergency ETH sweep | YES | ADMIN/SECURITY role checks remain on shared Registry |
| ERC-20 in old StrategyManager / Converter | general recovery | NO | manager sweeps only ETH; Converter has no rescue |
| Existing UniCL assets before strategy replacement | pause + emergency exit | CONDITIONAL | handles native/immutable WETH/paired; pool/token failures can block portions |
| WETH-B received by WETH-A strategy | withdraw/emergency/recovery | NO | not part of token0/token1/paired/weth and no rescue (MG-2) |
| Whitelist users after redeploy | batch add or disable | YES | requires off-chain reconstruction; documented |

## Recovery / Worst-Case / Compatibility Checks

| Check | Trace / result |
|---|---|
| Recovery functions (4c) | Controller and StrategyManager sweep native ETH; UniCL exits immutable WETH/paired; `removeStrategy`/`forceRemoveStrategy`; whitelist batch-add/disable. No EVE, queue-state, arbitrary-token, or claim-import migrator. |
| Scenario 1: V1 deposit + V2 logic (4d) | Legacy EVE + new EVE key -> balance is zero in token queried by AMM -> exit cannot burn: **STRANDED**. |
| Scenario 2: in-flight upgrade (4d) | Queued EVE + AMM/queue address switch -> authorization/custody split: **STRANDED**. Same-address UUPS upgrade preserves it. |
| Scenario 3: external token change (4d) | Existing WETH-A strategy + WETH-B Converter -> deposit returns untracked WETH-B: **STRANDED**. |
| User blocks admin (4f) | Donation can push strategy NAV above 10 wei and block normal removal, but `forceRemoveStrategy` bypasses NAV; not permanent. Users cannot block UUPS/key updates because those have no empty-state precondition. |
| External side effects (3b/5) | WETH wrap/unwrap, pool token0/token1, router outputs, and ERC-20 behavior are interface-only; production implementations were not supplied, so cross-version behavior is UNVERIFIED, not refuted. |
| Downstream compatibility (6) | Core peers auto-follow Registry keys; roles do not. EVE integrations and indexers remain bound to the old token/contract address unless explicitly migrated. No production downstream inventory supplied. |

## CLEARED

- All five UUPS implementations disable initializers on implementation construction, expose one proxy initializer, and gate `_authorizeUpgrade` with Registry `ADMIN_ROLE`.
- `RegistryClientUpgradeable` uses a fixed ERC-7201 namespaced slot, reducing collision risk; each UUPS implementation reserves a storage gap. Future layout compatibility still requires build-time validation unavailable in the supplied snapshot.
- Same-address UUPS upgrades do not move token custody, queue mappings, roles, allowances, or peer addresses and therefore avoid MG-1's fresh-address split.
- No explicit legacy token, deprecated callable path, receipt-token transition, or bidirectional token migrator exists in scope; no unsupported claim of a current production token-version mismatch is made.
- Pool mint/burn/collect stays in constructor-fixed token0/token1; adapter route validation checks declared endpoints. Production external implementations remain UNVERIFIED.

## Read / Validation Record

- Plamen rules: `orchestrator-rules.md` 79/79 lines; `finding-output-format.md` 114/114 lines.
- Skill: `migration-analysis/SKILL.md` 277/277 lines; no directly referenced files.
- Fresh bundle reused for this sequential batch: `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `source.md` 9,417/9,417 (39/39 files), `finding-format.md` 101/101.
- Immutable interface context: 21/21 files, 3,564 Solidity lines, read via `git show 734df96:PATH`.
- Base-only commands: migration/initializer/UUPS/storage-gap inventories via `git grep ... 734df96`; targeted `git show 734df96:PATH | nl -ba | sed -n ...`; dynamic Registry-consumer and recovery-path traces. No post-base source, prior work output, history, or `test/audit` read.
- Tests: not run; MG-1 and MG-2 close by authorization/custody/token-identity traces. Production proxy state, external contracts, Timelock batches, and downstream consumers were not supplied and were not inferred.
- Confidence: high for the two conditional code mechanisms; medium for real-world likelihood because both require an ADMIN migration choice. MG-L1 remains a lead because an external atomic role-handoff runbook could close it operationally.

AGENT_STATUS: COMPLETE
