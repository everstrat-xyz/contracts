# Plamen Raw Pass — governance-attack-vectors

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full immutable primary scope, 39/39 files (25 runtime/library + 14 deployment)
methodology: Plamen governance-attack-vectors; sections 1-4 and all five key questions executed
read_counts: orchestrator-rules 79/79; finding-output-format 114/114; skill 146/146; direct required refs 0; scope 139/139; profile 207/207; context 181/181; source 9417/9417; bundle finding-format 101/101
constraints: base-only (`git show`/`git grep`); no prior audit outputs/history/test-audit/post-base source; no network/live deployment
result: 1 FINDING, 1 LEAD, 3 CLEARED

FINDING
id:           GOV-1
title:        Explicit timelock configuration can silently remove the promised 48-hour reaction window
file:         script/ProtocolDeployBase.sol:352
function:     _deployTimelocks
mechanism:    `TIMELOCK_ADMIN_DELAY` is passed directly from `vm.envOr` into `TimelockController` without enforcing `DEFAULT_ADMIN_TIMELOCK_DELAY` as a lower bound, so an explicitly configured value of zero or less than 48 hours overrides the safe fallback.
consequence:  A deployment can place the entire Registry admin plane (configuration, roles, feeds, strategy admission, unpause, and UUPS upgrades) behind a zero/short-delay timelock, allowing a malicious or compromised DAO proposer to execute those changes before users or the security multisig have the documented 48-hour response window.
trigger:      deployment operator supplies `TIMELOCK_ADMIN_DELAY < 48 hours`; a DAO proposer then schedules the harmful admin operation and executes it after that weaker minimum
severity:     medium
rationale:    impact is protocol-wide privilege/configuration loss, but likelihood is reduced by the deployment-configuration precondition and need for a harmful/compromised proposer; impact dominates.
poc:          none — direct configuration/data-flow proof
evidence:     `uint256 internal constant DEFAULT_ADMIN_TIMELOCK_DELAY = 48 hours;` (L39), but L356-358 execute `timelocks.adminTimelock = _deployTimelock(vm.envOr("TIMELOCK_ADMIN_DELAY", DEFAULT_ADMIN_TIMELOCK_DELAY), ...)`, and L376 constructs `new TimelockController(_minDelay, proposers, executors, _deployer)` with no `require(_minDelay >= DEFAULT_ADMIN_TIMELOCK_DELAY)`.
fix:          Read the configured delay into a local, require it is at least `DEFAULT_ADMIN_TIMELOCK_DELAY`, and only then deploy the timelock; also verify `getMinDelay()` in the post-deploy checks.
related:      none
confidence:   high — the caller-controlled env value reaches the constructor unchanged and the claimed minimum appears nowhere as a validation predicate.
verdict:      CONFIRMED
step_execution: ✓1(no vote-power surface), ✓2(proposal/timelock lifecycle), ✓3(no quorum surface), ✗4(N/A: no delegation)
rules_applied: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗(no token-transfer mechanism), R12:✓, R13:✓, R14:✓, R15:✗(no voting-power state), R16:✗(no oracle dependency)]
preferred_tag: CODE-TRACE
depth_evidence: [BOUNDARY:TIMELOCK_ADMIN_DELAY=0 → TimelockController minDelay=0], [TRACE:envOr→_deployTimelock→constructor]
material_harm: EVE holders can lose the intended opportunity to exit or have security cancel a queued malicious admin/upgrade action before it becomes executable.
postconditions_created: Registry ADMIN_ROLE remains timelocked, but its on-chain execution delay is weaker than the declared production minimum.
postcondition_types: [ACCESS, TIMING, STATE]
who_benefits: a malicious or compromised DAO proposer

LEAD
id:           GOV-L1
file:         script/ProtocolDeployBase.sol
function:     _deployTimelock / _verifyTimelockRoles
suspicion:    Source wires a DAO address as sole proposer/canceller and a security address as canceller, but the supplied bundle has no multisig threshold, signer membership, operational separation, or deployed role enumeration with which to assess proposer capture, veto availability, or unexpected role holders.
blocked_by:   deployment-state and off-chain multisig evidence were not supplied; live/network inspection is prohibited.
next_step:    Obtain the target-bound deployment manifest and enumerate Timelock role members, `getMinDelay()`, DAO/security multisig implementations, owners, thresholds, modules/guards, and queued operations.

CLEARED
area:         flash-loan voting and snapshot manipulation
checked:      Full-scope search found no Governor, voting token/checkpoints, `getVotes`, vote casting, delegation, proposal threshold, or snapshot mechanism. EVE is a plain Registry-gated ERC-20, so sections 1, 3, and 4 have no voting-power state to manipulate.

CLEARED
area:         proposal content and authority topology
checked:      The repository intentionally delegates arbitrary admin calls to an external DAO proposer through OpenZeppelin TimelockController; the DAO receives no direct Registry role, security receives cancellation/emergency authority but not proposer authority, and the temporary timelock admin is renounced in `_deployTimelock`.

CLEARED
area:         execution caller and deployment bootstrap teardown
checked:      Executor openness is restricted to already-ready timelock operations, avoiding a liveness key; one-shot verification checks proposer/security/executor topology and removal of deployer timelock/Registry admin, while modular finalization renounces the bootstrap Registry role and verifies critical grants.

KEY_QUESTION_ANSWERS
1: No voting-power implementation exists; snapshot/live-balance classification is N/A.
2: No Governor proposal API exists in scope; the DAO-controlled timelock can target governance/token/admin functions by design after its configured delay.
3: No quorum or voting supply denominator exists.
4: A mandatory delay exists only to the configured `TIMELOCK_ADMIN_DELAY`; GOV-1 shows the scripts do not make the documented 48-hour floor non-bypassable.
5: No vote token, snapshot, or vote entry point exists, so flash-loan accumulation cannot affect governance in this codebase.

COMMANDS_AND_TESTS
- `git -C contracts grep -n -E 'Governor|TimelockController|propose|castVote|quorum|getVotes|delegate\\(|votingPower|TIMELOCK_ADMIN_DELAY|DEFAULT_ADMIN_TIMELOCK_DELAY' 734df96 -- script src/contracts src/libraries` — only deployment TimelockController wiring matched; no Governor/voting/delegation implementation.
- `git -C contracts show 734df96:script/ProtocolDeployBase.sol | nl -ba | sed -n '30,42p;342,380p;450,462p'` — confirmed direct env-to-constructor flow and role checks.
- tests: not run; the defect is a direct missing-bound check and no production/live state was available.

AGENT_STATUS: COMPLETE
