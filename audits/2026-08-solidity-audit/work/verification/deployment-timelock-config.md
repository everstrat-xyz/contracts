# Verification: deployment accepts unsafe timelock configuration

BASE: `734df96a1391e95dd40843210997da0b9f3ab05e`. Source and a local OpenZeppelin TimelockController regression were evaluated offline. No network, live deployment, or production edit was used.

## A — explicit sub-policy delay overrides the documented 48-hour floor

VERDICT: CONFIRMED

SUGGESTED SEVERITY: Low

`DEFAULT_ADMIN_TIMELOCK_DELAY` is documented as the production policy minimum and as a fallback that is “never weaker” (`ProtocolDeployBase.sol:31-39`). `_deployTimelocks`, however, passes `vm.envOr("TIMELOCK_ADMIN_DELAY", 48 hours)` directly to `_deployTimelock` without a lower-bound check (`:352-358`). The latter constructs OpenZeppelin `TimelockController` with the supplied value (`:361-378`).

An explicit `TIMELOCK_ADMIN_DELAY=0` therefore creates a zero-delay admin timelock. Current verification checks proposer, canceller, open executor, and former-deployer roles but never checks `getMinDelay()` (`:431-460`). The regression deploys a zero-delay controller and proves the existing verifier accepts it.

This can remove the promised review/cancellation window from Registry rewiring, UUPS upgrades, Oracle/configuration changes, and unpausing. It requires an operator-provided environment value and is observable at deployment, so Low fits the configuration-dependent trigger despite protocol-wide privileged impact.

Recommendation: resolve the environment value before broadcast, require it to be at least `DEFAULT_ADMIN_TIMELOCK_DELAY`, and assert `getMinDelay()` in both preflight expectations and post-deploy verification.

## B — a zero DAO proposer passes verification and permanently disables governance

VERDICT: CONFIRMED

SUGGESTED SEVERITY: Medium

`_protocolDao()` returns the required `DAO_ADDRESS` without rejecting zero (`ProtocolDeployBase.sol:263-267`). `_deployTimelock` places that value in the sole proposer array, grants the separate SECURITY address only `CANCELLER_ROLE`, configures open execution, and renounces the temporary external admin (`:361-378`). Open execution permits anyone to execute an already-scheduled operation; it does not permit scheduling.

OpenZeppelin accepts `address(0)` in the proposer array and records that address as both proposer and canceller. `_verifyTimelockRoles` then checks `hasRole(PROPOSER_ROLE, _proposer)`, which returns true for the supplied zero address, and passes (`:450-460`). Yet no real EOA transaction or contract call can have `msg.sender == address(0)`. All ordinary actors fail `schedule`'s proposer-role check.

The TimelockController is self-administered after bootstrap. Granting a usable proposer therefore itself requires a scheduled timelock operation, which cannot be created. DeployAll also makes this controller the Registry's persistent ADMIN and renounces the deployer's temporary Registry admin. The result is not merely a delay: Registry rewiring, role repair, unpause, Oracle changes, and UUPS upgrades become permanently unavailable through the specified governance system.

No external attacker can choose `DAO_ADDRESS`; the trigger is an explicit release misconfiguration. Nevertheless, the irreversible loss of every admin recovery path makes this an essential Medium deployment finding. Routine entry/exit can continue while the protocol remains healthy and unpaused, which keeps it below High under the report's severity ladder.

Recommendation: reject zero for DAO, security, treasury, and every governance identity before broadcasting; require the DAO/security/deployer identities to be pairwise distinct where intended. Verification must enumerate at least one nonzero proposer and confirm the final Registry admin can be governed before renunciation.

## Regression evidence

Test: `test/audit/candidates/verification/DeploymentTimelockConfig.t.sol`

Pinned offline attempt 1 exposed only a test-harness argument-evaluation ordering issue in the zero-proposer assertion; no production hypothesis changed. Attempt 2/3 passed both cases:

`FOUNDRY_OUT=/private/tmp/deploy-timelock-config-out-2 FOUNDRY_CACHE_PATH=/private/tmp/deploy-timelock-config-cache-2 /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/DeploymentTimelockConfig.t.sol -vvv`

Result: 2 passed, 0 failed, 0 skipped. The global signature-cache warning was sandbox-only.

AGENT_STATUS: COMPLETE
