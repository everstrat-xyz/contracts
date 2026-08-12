# Plamen P3 — storage-layout-safety

snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: 39/39 primary files (25 runtime/library + 14 deployment)
method_read: `SKILL.md` 190/190; Plamen rules 79/79; Plamen finding format 114/114
bundle_read: scope 139/139; profile 207/207; context 181/181; source 9417/9417; finding-format 101/101
trigger: five UUPS/ERC1967 modules, one ERC-7201 namespace, one allowlisted delegatecall surface

LEAD
id:           SLS-1
file:         src/contracts/{Controller,Converter,ExitQueue,Oracle,StrategyManager}.sol
function:     future UUPS upgrades
suspicion:    The current layouts are internally consistent, but no predecessor/successor storage-layout manifest or upgrade-layout diff is supplied, so continuity for an actual future implementation cannot be proven from this snapshot.
blocked_by:   No proposed V2 bytecode/source or target-bound deployment implementation map; deployment state is explicitly outside the supplied evidence.
next_step:    For every proposed upgrade, compile old/new implementations with the release compiler and run an automated storage-layout compatibility check before scheduling `upgradeToAndCall`.
verdict:      CONTESTED (future/deployment-state dependent; not a current collision)
step_execution: 1✓ 2✓ 3? (no V1→V2 pair) 4✓ 4d✓ 5✓
rules_applied: R4✓ R8✓ R10✓ R14✓
preferred_tag: CODE-TRACE
confidence:   high that the evidence gap exists; low that any current slot collision exists

CLEARED
area:         atomic initialization and implementation locking
checked:      All five implementations call `_disableInitializers()` in their constructors, and all five ERC1967Proxy constructors carry matching initializer calldata; no uninitialized proxy window was found.
evidence:     `Controller.sol:49`, `Converter.sol:52`, `ExitQueue.sol:53`, `Oracle.sol:59`, `StrategyManager.sol:113`; `ProtocolDeployBase.sol:70-120`.
verdict:      REFUTED (hypothesis: direct initialization or deployment-time proxy takeover)
step_execution: 1✓ 3a✓ 3b✓
rules_applied: R4✓ R10✓
preferred_tag: CODE-TRACE
confidence:   high — immutable source gives the complete constructor/deploy path

CLEARED
area:         current linear and namespaced storage surfaces
checked:      Controller reserves slots 0-49; Converter uses 3 linear slots plus gap[47]; ExitQueue uses mapping/currentBatchId then gap[50]; Oracle uses AddressSet+mapping then gap[47]; StrategyManager uses its declared sets/scalars/mappings then gap[40]. RegistryClientUpgradeable is isolated in one ERC-7201 namespace.
evidence:     `Controller.sol:466`, `Converter.sol:515`, `ExitQueue.sol:348`, `Oracle.sol:455`, `StrategyManager.sol:1249`, `RegistryClientUpgradeable.sol:23-29`.
verdict:      REFUTED (hypothesis: present implementation variables collide with one another)
step_execution: 1✓ 3a✓ 3c✓
rules_applied: R8✓ R10✓
preferred_tag: CODE-TRACE
confidence:   high for the current snapshot; future continuity remains SLS-1

CLEARED
area:         ERC-7201 RegistryClientUpgradeable namespace
checked:      Independently recomputed the namespace defined by `everstrat.storage.RegistryClientUpgradeable`; it exactly equals the source constant `0xbd1f...fe00`. The only assembly storage operation assigns a compile-time constant to the storage pointer; no caller controls the slot.
evidence:     `cast index-erc7201 everstrat.storage.RegistryClientUpgradeable` → `0xbd1fcda84d3854fffab59d162ed55717edaf79b73401f77c755ab4e42954fe00`; source constant is identical.
verdict:      REFUTED (hypothesis: malformed namespace or attacker-directed `sstore`)
step_execution: 1✓ 3c✓ 4a✓ 4b✓
rules_applied: R8✓ R10✓
preferred_tag: CODE-TRACE
confidence:   high — deterministic slot derivation matched exactly

CLEARED
area:         memory/storage references and hardcoded ABI offsets
checked:      Storage mutations of queue requests, feed metadata and strategy sets use explicit `storage` references; memory structs/arrays are read-only snapshots or deliberate constructor/config inputs. No `calldataload`, `sstore`, `sload`, `tstore`, or `tload` exists in primary scope. UniswapV3Path validates path length before dynamic-offset memory reads; its literal `32` skips the bytes length word, not an untrusted ABI-head pointer.
evidence:     `ExitQueue.sol:340-348,404-405`; `Oracle.sol:371-395`; `UniswapV3Path.sol:110-123`.
verdict:      REFUTED (hypothesis: lost persistent write or hardcoded dynamic-ABI dual read)
step_execution: 2a✓ 2b✓ 2c✓ 4d✓
rules_applied: R8✓ R10✓
preferred_tag: CODE-TRACE
confidence:   high — every triggered assembly/complex-reference site was classified

CLEARED
area:         deletion and auxiliary-structure coherence
checked:      ExitQueue removes the user and decrements batch totals before deleting the request; Oracle removes both feed mapping entries and pair sets, including inbound/outbound references; StrategyManager removes the strategy, clears both weights, and deliberately retains the withdrawal timestamp to preserve cooldown semantics.
evidence:     `ExitQueue.sol:264-266`; `Oracle.sol:286-295,415-418,421-441`; `StrategyManager.sol:281-297`.
verdict:      REFUTED (hypothesis: stale enumerable/index/aggregate state after deletion)
step_execution: 5a✓ 5b N/A 5c✓
rules_applied: R8✓ R14✓
preferred_tag: CODE-TRACE
confidence:   high — primary and auxiliary writes are co-located and complete

CLEARED
area:         proxy slot separation and upgrade authorization
checked:      Standard ERC1967Proxy instances hold randomized implementation state outside compiler-linear slots; each UUPS `_authorizeUpgrade` is gated by Registry ADMIN_ROLE. No custom proxy/admin slot arithmetic appears in protocol code.
evidence:     `ProtocolDeployBase.sol:70-120`; `_authorizeUpgrade` at Controller:455, Converter:345, ExitQueue:340, Oracle:84, StrategyManager:1239.
verdict:      REFUTED (hypothesis: proxy/implementation slot overlap or permissionless upgrade)
step_execution: 3a✓ 3b? (future pair absent) 3c✓
rules_applied: R4✓ R10✓
preferred_tag: CODE-TRACE
confidence:   high for source authorization; deployed role/implementation state is not asserted

commands:
- `wc -l .../storage-layout-safety/SKILL.md` → 190
- `git grep -n -E 'UUPSUpgradeable|ERC1967Proxy|delegatecall|assembly|sstore|sload|tstore|tload|calldataload|mload\\(add|delete ' 734df96 -- script src/contracts src/libraries`
- `git grep -n -E '_disableInitializers\\(|uint256\\[[0-9]+\\] private __gap|STORAGE_LOCATION|new ERC1967Proxy|abi.encodeWithSelector|delete ' 734df96 -- script src/contracts src/libraries`
- `cast index-erc7201 everstrat.storage.RegistryClientUpgradeable` → exact source constant
tests: no PoC added; deterministic source/slot checks only
finding_count: 0
lead_count: 1
cleared_count: 6
AGENT_STATUS: COMPLETE
