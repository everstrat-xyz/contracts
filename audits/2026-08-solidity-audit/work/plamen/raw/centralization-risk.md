# Plamen P1 — centralization-risk

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: all 39 primary files (25 runtime/library + 14 deployment), 4,849 nSLOC
bundle_read: scope 139/139; profile 207/207; context 181/181; source 9,417/9,417; finding-format 101/101
method_read: orchestrator 79/79; Plamen finding rules 114/114; skill 116/116; referenced files 0
tool_note: Slither is unavailable per the frozen profile. Base-only `git grep` fallback found 129 access-modifier occurrences, including 70 ADMIN/SECURITY occurrences; each occurrence and its call effects was manually classified over the full bundle.

## FINDING CR-1 — One governance role controls every protocol trust root

file: `src/contracts/registry/Registry.sol`
function: `constructor`, `registerContract`, `grantRole`; five `_authorizeUpgrade` functions and ADMIN setters
mechanism: Self-administered `ADMIN_ROLE` can replace every Registry-resolved module, administer all other roles, upgrade all five UUPS modules, whitelist delegatecalled adapters, choose strategies/oracles/fees, and unpause the system.
consequence: Compromise or malicious control of the DAO proposer can, after the timelock, install logic or wiring that transfers or misprices all depositor assets.
trigger: DAO multisig controlling the sole timelock proposer; any address may execute after delay
severity: low
rationale: Worst-case loss is total, but the intended multisig, 48-hour on-chain minimum delay, independent security canceller, and open executor materially reduce likelihood.
poc: none — trust-topology/code-trace finding
evidence: `Registry.sol:48-54` makes ADMIN self-admin and administrator of KEEPER, MINTER, SECURITY, and caller-manager roles; `Registry.sol:218-226` permits replacement of an existing key with any code address. `ProtocolDeployBase.sol:345-378` gives one DAO proposer control of the self-administered timelock and uses a 48-hour default minimum.
fix: Separate upgrade/Registry-wiring authority from economic configuration, require independent approval for fund-critical operations, and enforce the longer upgrade delay on-chain rather than by policy.
related: none
verdict: CONFIRMED
step_execution: ✓1(fallback enumeration), ✓2, ✓3, ✓4, ✓5
rules_applied: R4:✗(evidence clear), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan prerequisite), R16:✓
preferred_tag: CODE-TRACE
centralization_type: FUND_CONTROL / PARAMETER_CONTROL / OPERATIONAL_CONTROL / UPGRADE_CONTROL
affected_role: `ADMIN_ROLE` via `TimelockController`
mitigation_present: intended DAO multisig + 48-hour minimum delay + security canceller + open execution
material_harm: If the sole proposer is compromised and its operation is not cancelled within 48 hours, EVE holders can lose all protocol-backed assets to malicious upgraded or Registry-selected code.
postconditions: A ready malicious operation can replace an implementation/address or grant a value-moving role; after open execution, the new authority/code is immediately trusted protocol-wide.
postcondition_types: ACCESS, STATE, TIMING, BALANCE
who_benefits: compromised governance controller

## FINDING CR-2 — The emergency role can deliberately omit live assets from NAV

file: `src/contracts/StrategyManager.sol`
function: `removeSupportedERC20`
mechanism: `SECURITY_ROLE` may remove a supported ERC-20 without checking its balance or pausing AMM entry, and `_totalNAVInETH` then stops counting that still-held asset immediately.
consequence: A compromised security multisig can buy EVE against understated NAV and later benefit when honest governance re-adds the recoverable asset, diluting incumbent holders.
trigger: compromised/malicious SECURITY_ROLE plus a whitelisted buyer; supported token balance must be large enough relative to connector weight
severity: medium
rationale: The action is immediate and can cause material holder dilution in a reachable emergency inventory state, while exploitation requires a semi-trusted role, a sufficiently large retained ERC-20 balance, and eventual admin re-addition.
poc: none — worked algebra/code trace
evidence: `StrategyManager.sol:491-501` expressly allows SECURITY removal and says a non-zero balance drops out of NAV; `StrategyManager.sol:940-950` adds only enumerated ERC-20 balances; `AMM.sol:408-421` mints from the reduced NAV. If pre-removal NAV is A, omitted value X, supply S, deposit D, and connector weight c, the buyer receives `D*S*c/(A-X)` EVE and profits after re-addition exactly when `X > A*(1-c)` (for default c=0.5, X>A/2; for c=1, any X>0).
fix: Couple security removal to an atomic protocol/AMM pause, or retain a quarantined conservative NAV value until ADMIN resolves or disposes of the balance.
related: none
verdict: CONFIRMED
step_execution: ✓1, ✓2, ✓3, ✓4, ✓5
rules_applied: R4:✗(closed in-scope path), R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(role action required), R16:✓
preferred_tag: CODE-TRACE
centralization_type: FUND_CONTROL / OPERATIONAL_CONTROL
affected_role: `SECURITY_ROLE`
mitigation_present: independent ADMIN is required to re-add; ADMIN can revoke SECURITY after timelock
material_harm: Incumbent EVE holders can lose a material fraction of their pro-rata claim through dilution when a compromised emergency operator removes and later-restored ERC-20 backing is omitted during an attacker deposit.
postconditions: Supported-set deletion lowers reported NAV without moving the token, lowering AMM mint price until ADMIN re-adds it.
postcondition_types: STATE, ACCESS, BALANCE, TIMING
who_benefits: compromised security operator or an associated whitelisted account

## LEAD CR-L1 — Actual production authority may differ from the scripts

file: `script/ProtocolDeployBase.sol`
function: `_deployTimelock`, `_finalizeDeployerTieredAccess`
suspicion: Source intends one 48-hour timelock ADMIN and teardown of the deployer, but no target-bound deployment receipt, live role membership, delay, multisig threshold, or bytecode mapping was supplied.
blocked_by: deployment state is explicitly unknown in the bundle; live systems/network access are out of scope
next_step: Verify every Registry role member/admin, timelock role/delay, proposer/security multisig thresholds, proxy implementation, and Registry key against a signed deployment manifest.

## CLEARED

area: Bootstrap and timelock teardown in supplied deployment scripts
checked: `DeployAll` and `FinalizeProtocolDeploy` verify that deployer ADMIN is renounced; `ProtocolDeployBase` makes execution open after delay and grants SECURITY cancellation without proposal/execution power.

## CLEARED

area: Emergency-power recovery boundaries
checked: SECURITY can pause and recover Controller/strategy capital but cannot unpause, configure, upgrade, add tokens, or grant roles; ADMIN supplies the recovery path. User exits are paused, so recovery depends on ADMIN after the enforced delay, but no permanent source-level lock was found while ADMIN remains live.

## Skill coverage

- Step 1: Classified all 129 base-SHA access-modifier occurrences into fund, parameter, operational, upgrade, protocol-caller, or token roles; Slither absence is explicit.
- Step 2: Mapped ADMIN self-administration; ADMIN-administered SECURITY/KEEPER/MINTER/caller-manager; caller-manager-administered converter callers.
- Step 3: Assessed DAO proposer, security multisig, executor contracts/Forwarders, whitelist signer, bootstrap EOA, and protocol-contract identities.
- Step 4: Assessed Chainlink feeds/Automation and Uniswap/WETH governance/code dependencies; deployed instances remain unknown.
- Step 5: Traced pause/unpause and Controller/UniCL emergency exits, user-exit availability, role revocation, and 48-hour recovery.

## Commands/results

- `wc -l bundle/{scope,profile,context,source,finding-format}.md` → `139,207,181,9417,101`.
- `git grep -n -E 'onlyAuthRole|onlyEitherAuthRole|onlyAuthContract|onlyRole' 734df96 -- src/contracts script | wc -l` → `129`.
- ADMIN/SECURITY-specific base-SHA grep → `70` occurrences.
- `git show 734df96:PATH | nl -ba | sed -n ...` → confirmed quoted Registry, deployment, StrategyManager, AMM, and Math paths at immutable base.
- Tests: not run; both findings close by authorization/state/math traces without production or test-tree access.

AGENT_STATUS: COMPLETE
