# Audit coverage and disposition ledger

Target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
Methodology: `daoism-systems/solidity-audit-skills@7a3dca988b8f4c2070aaac01975d1ae93058b699`

This is internal traceability for `AUDIT_REPORT.md`. It records completion,
conservation, and disposition counts without exposing raw pipeline identifiers in
the client finding bodies.

## Actual execution census

| Review family | Planned current-code leaves | Durable complete | Incomplete | Notes |
|---|---:|---:|---:|---|
| Pashov specialties | 12 | 9 | 3 | Execution-trace, invariant/conservation, and flow-gap leaves produced no complete raw report; partial candidate tests were not credited as completion. |
| Omega independent discovery | 5 | 3 | 2 | Bottom-up, top-down retry, and asset-centric reports are durable. Actor-centric and invariant passes completed full read gates but did not produce durable reports. |
| QuillShield plugins | 11 | 11 | 0 | All routed plugins complete. |
| Plamen EVM/depth/feature outputs | 28 | 28 | 0 | All routed outputs complete. |
| **Current-code total** | **56** | **51** | **5** | No incomplete leaf was silently imputed. |
| Omega historical regression census | 1 | 1 | 0 | Separate from discovery: 9/9 artifacts and 73/73 explicit historical ID occurrences. |

Three Pashov dispatches encountered content-filter interruptions; two completed
after defensive/local-only prompt narrowing, while the third remained incomplete.
The source scope and evidence standard did not change.

## Current occurrence conservation

The 51 durable discovery reports contain 103 semantic finding occurrences and 81
lead occurrences. One Plamen raw block contains two independent emergency-path
mechanisms and is counted as two semantic findings because the triggers and fixes
differ.

| Family | Findings | Leads |
|---|---:|---:|
| Pashov | 22 | 15 |
| Omega current discovery | 12 | 5 |
| QuillShield | 33 | 25 |
| Plamen | 36 | 36 |
| **Total** | **103** | **81** |

All 103 findings are placed once in 45 normalized root-cause mechanisms. All 81
leads have an explicit retained, promoted, retired, or external-state disposition
in `work/cross-verification-inventory.md`.

Mechanism presence distribution:

| Independent review families raising mechanism | Mechanisms |
|---:|---:|
| 4 | 3 |
| 3 | 6 |
| 2 | 4 |
| 1 | 32 |
| **Total** | **45** |

Every singleton was adjudicated. Final mechanism-level outcomes are:

- 36 confirmed, informational, or explicitly accepted privileged-design items;
- 3 rejected source interpretations; and
- 6 retained leads/contested deployment-dependent mechanisms.

The client report contains 31 security-relevant or concrete informational
findings after root-cause consolidation. Accepted trust assumptions and release
observations without a demonstrated source consequence are kept outside the
finding count. Rejected and unresolved candidates are listed in the report's
excluded/unresolved section rather than silently dropped.

## Historical regression census

Nine side-branch internal/AI-assisted artifacts contained 73 explicit ID
occurrences. The separate regression pass classified them as:

| Status | Count |
|---|---:|
| Fixed | 33 |
| Still open | 33 |
| Contingent on configuration/deployment | 5 |
| Unverifiable with supplied inputs | 2 |
| Regressed after a prior fix | 0 |
| **Total** | **73** |

Historical `STILL OPEN` labels were not copied into the client report by vote;
each relevant mechanism had to survive current-code verification and
deduplication.

## Verification evidence

- 23 durable verification reports plus one source-only adjudication ledger.
- 21 focused Forge proof files under `test/audit/candidates/verification/`.
- Final combined result: 22 suites, 37 passed, 0 failed, 0 skipped.
- Full pinned base suite: exit 0; baseline inventory records 1,176 local passes,
  0 failures, and 15 fork skips.
- Pinned `forge fmt --check`: exit 0.
- Production source/configuration was not modified by the audit.

## Deferred deployment validation

The following require a concrete chain-qualified manifest and fixed-block fork:

- proxy/implementation addresses, initializer calldata, bytecode/source matches,
  storage-layout ancestry, and complete Registry/role membership;
- timelock proposer/canceller/executor identities and actual minimum delays;
- Oracle feed direction, implementation, round semantics, staleness, and L2
  sequencer applicability;
- Converter/adapters/routes, WETH identity, UniCL pool provenance/history,
  strategy weights/caps, supported tokens, and Automation Forwarders/upkeep IDs;
- migration sequences and any prior/current token allowances.

AGENT_STATUS: COMPLETE
