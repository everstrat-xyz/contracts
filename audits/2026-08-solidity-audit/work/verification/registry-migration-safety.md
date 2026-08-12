# Registry migration safety verification

Target: immutable commit `734df96a1391e95dd40843210997da0b9f3ab05e`.
Evidence was limited to production contracts/interfaces and base-commit tests read with
`git show`; no audit output or pre-existing `test/audit` source was inspected.

## Bottom line

- One architectural root is confirmed: Registry peers are resolved live, while module
  storage, immutable token domains, ERC-20 approvals, and Registry roles remain attached
  to old addresses. `registerContract(s)` performs no migration or compatibility checks.
- The three mechanisms should still be treated as distinct report candidates because
  they have independent preconditions and recoveries.
- **A — CONTESTED (governance migration hazard):** blind replacement of stateful keys can
  omit live state from NAV/routing and strand queue state. Most cases are recoverable by
  restoring the old key; Controller has a direct immediate recovery path.
- **B — LEAD (contingent but permanent if triggered):** a Converter using a different
  WETH can successfully return that token to an existing static UniCL strategy, where it
  is absent from NAV and every recovery path. It also breaks withdrawal of old WETH.
- **C — CONTESTED (deterministic operational break, no direct theft shown):** every
  Converter-address rotation leaves max allowances on the old address and zero on the
  new one. Pause/unpause repairs the new allowance but does not clean the old one.

## Authority and timing

- `Registry.registerContract` and `registerContracts` are `whenNotPaused` and
  `onlyRole(ADMIN_ROLE)` (`Registry.sol:109-125`). `_registerContract` accepts any nonzero
  address with code, overwrites an existing key, and emits the old/new addresses; it does
  not inspect interfaces, state, roles, WETH, or clients (`Registry.sol:218-227`).
- Address registration and AccessControl membership are independent maps
  (`Registry.sol:28-32`). Replacing a key neither grants the replacement's operational
  roles nor revokes the old address's roles.
- In the tested production topology, only the admin Timelock has `ADMIN_ROLE`; the DAO is
  proposer, execution is open after **48 hours**, and SECURITY is a canceller
  (`TimelockGovernance.t.sol:25-35,54-78,116-149,158-174`; deployment test confirms
  `getMinDelay() == 48 hours` at `DeploymentTest.t.sol:147-171`). The 48-hour bound is a
  deployment property, not enforced inside Registry.
- SECURITY can immediately pause Registry/modules and UniCL strategies, and can cancel a
  queued timelock operation, but cannot register a replacement or unpause
  (`Registry.sol:277-295`; `TimelockGovernance.t.sol:197-208,256-313`).
- Therefore an unscheduled rollback after an executed rotation takes at least another
  48 hours. A rollback or full migration already included in the original timelock batch
  is atomic and has no additional delay.

## A. Stateful key replacement

The behavior is real, but no unprivileged caller can initiate it.

- **EVE:** balances, allowances, and total supply remain on the old static token. AMM
  dynamically resolves EVE for total supply, transfers, mint, and burn
  (`AMM.sol:149-180,189-193,222-240,400-445,488-510`). An empty replacement makes the
  bootstrapped AMM price against supply zero and makes old holders unusable in AMM exits.
  There is no token migration method. Restoring the old EVE key restores routing.
- **AMM:** the old static AMM retains ETH, `lockedForClaims`, per-user claimable balances,
  `bootstrapped`, and queued EVE escrow (`AMM.sol:57-100,168-180,199-207`). Already
  processed claims remain directly claimable from the old AMM. Unprocessed claims do not:
  ExitQueue authorizes only the currently registered AMM, while a replacement AMM does
  not hold the EVE escrow needed to cancel or burn (`ExitQueue.sol:195-269`;
  `AMM.sol:188-245`). Old AMM free ETH is also omitted from StrategyManager NAV because
  NAV reads only the current AMM (`StrategyManager.sol:940-950`). No AMM admin sweep exists;
  restore the key or execute an explicit state/asset migration.
- **EXIT_QUEUE:** all batches and requests remain in the old proxy
  (`ExitQueue.sol:29-44,84-165`). AMM and Controller always resolve the current queue, and
  old queue mutation is restricted to the current AMM/Controller (`ExitQueue.sol:173-269`).
  The three-day close escape hatch does not help: closing is still AMM-only. Restoring the
  old key restores access.
- **CONTROLLER:** the only material protocol value is its ETH balance. Immediately after
  rotation that old balance is omitted from NAV and its downstream identity-gated calls
  fail, but ADMIN or SECURITY can call `emergencyExitToAMM()` on the old Controller and
  sweep all ETH to the current AMM without requiring pause (`Controller.sol:79-108`). This
  key alone is not an irreversible orphaning case.
- **STRATEGY_MANAGER:** the old proxy retains its strategy set, weights, cooldowns, fee
  state, supported-token set, ETH, and ERC-20 balances (`StrategyManager.sol:67-104`). A
  fresh manager initially omits every strategy from NAV, while each strategy immediately
  rejects the old manager and accepts only the new registered address
  (`StrategyManager.sol:298-447,522-578,940-950`; `UniCLStrat.sol:227-399`). ADMIN can add
  existing strategies to the new manager in the same migration batch, and ADMIN/SECURITY
  can sweep old-manager ETH to the current Controller (`StrategyManager.sol:152-173,
  449-463`). Existing supported ERC-20s have no transfer/recovery path in this release
  (`StrategyManager.sol:465-468`), so merely rotating the key drops them from NAV.
- **Detached roles:** production grants `MINTER_ROLE` to AMM and StrategyManager and
  `CONVERTER_CALLER_MANAGER_ROLE` to Converter independently of their keys
  (`ProtocolTestBase.sol:196-221`; `DeploymentTest.t.sol:162-171`). A migration must grant
  replacements and revoke old addresses explicitly; key replacement alone does neither.

Assessment: the impact can be severe, but it requires a reviewed ADMIN operation and is
normally reversible by key rollback. Treat as a migration-invariant/control-plane issue,
not an unprivileged exploit. UUPS modules should be upgraded in place where possible.

## B. Converter replacement with a different WETH

This is independent of allowance migration:

1. UniCL stores its pool's WETH immutably and validates both routes against it at
   construction (`UniCLStrat.sol:75-85,136-171,594-615`).
2. Deposit resolves the current Converter and calls `wrapETH` (`UniCLStrat.sol:227-245`).
   Converter wraps its own stored `_weth` and returns that token (`Converter.sol:42-46,
   66-76,84-91`). With an empty/calm strategy, no old-token rebalance is needed, so a
   deposit can complete after rotation and leave replacement WETH on the strategy.
3. `navInETH()` counts native ETH and only immutable pool token0/token1; replacement WETH
   is absent (`UniCLStrat.sol:199-203,665-676`). `maxWithdrawal()` therefore cannot expose
   it (`UniCLStrat.sol:209-212`).
4. `emergencyExit()` directly unwraps only immutable old WETH and transfers only the
   paired token (`UniCLStrat.sol:472-520`). The strategy is static/non-upgradeable and has
   no arbitrary-token rescue. A successfully received replacement-WETH balance is not
   recoverable through any production entry point, even if Registry later rolls back.
5. For pre-existing old WETH, normal withdrawal calculates against old WETH but calls the
   new Converter's `unwrapWETH`; that Converter pulls and unwraps replacement WETH
   (`UniCLStrat.sol:299-339`; `Converter.sol:97-113`). It reverts even after old pool-token
   allowances are granted to the new Converter. Emergency exit can still recover the old
   WETH because it bypasses Converter.

Reachability is contingent on ADMIN installing/configuring an incompatible Converter.
Without allowance migration, a deposit that needs a rebalance reverts under C; a deposit
with no old-token imbalance succeeds and strands value. Do not promote beyond **LEAD**
without the audit's trusted-governance policy. Enforce `newConverter.weth() == strategy.weth()`
for every live strategy, or drain/replace all old-WETH strategies before changing domains.

## C. Converter allowance rotation

- Construction grants max token0/token1 allowance to the then-current Converter
  (`UniCLStrat.sol:171,1266-1272`). Every swap/unwrap later resolves the current Registry
  Converter (`UniCLStrat.sol:338,1087-1110,1187-1219`).
- Registry rotation has no callback: old allowances stay max and new allowances are zero.
  New-Converter swaps/unwraps that use `transferFrom` revert (`Converter.sol:97-108,
  162-169,385-388`).
- `pause()` revokes allowances only from the currently registered Converter; `unpause()`
  grants only that current address (`UniCLStrat.sol:623-660,1266-1277`). Thus pausing and
  unpausing after rotation restores new allowances but leaves old max approvals.
- No unprivileged drain through the old production Converter was found: its transferFrom
  source is always `msg.sender`, and the strategy stops calling it after rotation. The old
  approval is latent exposure if that address is later compromised/upgraded, not a present
  theft path (`Converter.sol:121-212,371-409`).

Safe same-WETH sequence: in one timelocked batch, pause every strategy while the old
Converter is registered (revokes old approvals), rotate/configure roles and adapter state,
then unpause against the new Converter (grants new approvals). Different-WETH rotation is
still unsafe under B.

## Regression proof

`test/audit/candidates/verification/RegistryMigrationSafety.t.sol` contains three scoped
tests: deterministic old/new allowance state, a successful different-WETH deposit omitted
from NAV and emergency recovery, and an old-WETH withdrawal failure after allowance refresh.

Pinned Forge `1.0.0`, offline, isolated output/cache: **3 passed, 0 failed**. The successful
run used `--skip UniCLConfigValidation` only because an unrelated concurrently created
candidate file failed global compilation; the matched suite itself compiled and ran.

AGENT_STATUS: COMPLETE
