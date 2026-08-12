# Prior audit and review history

> Tier 0 evidence inventory only. This file does **not** validate, reproduce, dismiss, or
> re-severity any historical finding.

## Target and evidence boundary

- Audit target: `everstrat-xyz/contracts`, branch `chore/claude-reviewer-setup`, commit
  [`734df96a1391e95dd40843210997da0b9f3ab05e`](https://github.com/everstrat-xyz/contracts/commit/734df96a1391e95dd40843210997da0b9f3ab05e).
- Inventory date: 2026-08-12.
- Repositories inspected locally: the standalone `contracts` repository and the predecessor
  `Guide-DAO-Organization/hackerhouse` monorepo, including refs visible through `git --all`.
- Historical reports are treated as regression leads only. Their scopes, code snapshots, trust
  assumptions, tooling, and severities differ from the current target.

## Executive statement

No formal third-party audit deliverable was found in either repository's current checked-out tree.
The current product documentation says the same explicitly: no report, named auditor, or engagement
is documented, and the contracts should be treated as unaudited
([pinned public copy](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/everstrat-docs/content/docs/risk-and-trust/security-and-audits.mdx)).

Historical **internal and AI-assisted** review artifacts do exist in git history and on side
branches. They are indexed below because they can inform regression testing, not because they
establish current assurance or external audit coverage.

| Repository state | Prior-report result |
| --- | --- |
| Immutable target tree `contracts@734df96` | No prior audit report |
| Current predecessor tree `hackerhouse@733eb578` | No prior audit report; its product docs explicitly say no third-party report is documented |
| Historical predecessor refs visible through `git --all` | Internal/AI-assisted artifacts listed below; none is a third-party report for `734df96` |

## Repository lineage

The standalone repository was created with commit
[`b67fcad6ed44be4dd5535d30bf6df9b18351b944`](https://github.com/everstrat-xyz/contracts/commit/b67fcad6ed44be4dd5535d30bf6df9b18351b944)
(`move from monorepo`). Local tree-object comparison gives the following provenance:

- `contracts@b67fcad:src` and
  `hackerhouse@aebdca234d70f1f143704c04ed88588f997c350e:smart-contracts/src` have the same
  git tree (`e19bfa01dd77c87a59560b2c8e3077bf3187f473`). The predecessor commit is
  [public here](https://github.com/Guide-DAO-Organization/hackerhouse/commit/aebdca234d70f1f143704c04ed88588f997c350e).
- Between the standalone import and target `734df96`, the only change under `src/` is six lines of
  `UniCLStrat` NatSpec added by
  [`533f842d56e2f85cec8011e20974184ea5d62067`](https://github.com/everstrat-xyz/contracts/commit/533f842d56e2f85cec8011e20974184ea5d62067);
  scripts and design documents also changed.

This lineage explains why predecessor reports may be useful. It does **not** make a status recorded
against an older monorepo commit true at `734df96`; every historical item still needs current-code
revalidation.

## PL-003 clarification

`PL-003` is an internal project/design identifier for the timelock-governance work, not a finding ID
issued by an identified external auditor.

Evidence:

- The first identifiable implementation commit is
  [`6464b0f0e09374125ee8c5eb3bfc6f93f00f5e4e`](https://github.com/Guide-DAO-Organization/hackerhouse/commit/6464b0f0e09374125ee8c5eb3bfc6f93f00f5e4e)
  (`add guardian role, admin timelock, upd deployment scripts`).
- The branch name was `142-pl-003-timelock`; it was merged through
  [PR #160](https://github.com/Guide-DAO-Organization/hackerhouse/pull/160) and
  [PR #168](https://github.com/Guide-DAO-Organization/hackerhouse/pull/168).
- The later Plamen re-review labels PL-003 as a **new governance surface** and records its own new
  IDs `G-1` through `G-3`. That is a review *of* the PL-003 implementation, not the origin of
  `PL-003` as an audit finding.
- The product security page calls it an “internal design designation” and says no formal audit
  artifact exists
  ([pinned source](https://github.com/Guide-DAO-Organization/hackerhouse/blob/733eb578f6170ae4e824da4bdca7e456c95c0afd/frontend-app/everstrat-docs/content/docs/risk-and-trust/security-and-audits.mdx)).

The phrase “audit finding PL-003” in the target
[`README.md`](../../../README.md)
([pinned source](https://github.com/everstrat-xyz/contracts/blob/734df96a1391e95dd40843210997da0b9f3ab05e/README.md))
is therefore unsupported by the artifacts found here and should not be used as evidence of external
audit coverage.

## Historical artifact index

| Date | Artifact and method (as self-described) | Reviewed snapshot | Recorded headline | Current handling |
| --- | --- | --- | --- | --- |
| 2026-04-16 | Two Pashov `solidity-auditor` AI runs: [run 1](https://github.com/Guide-DAO-Organization/hackerhouse/blob/59553fe45e05d1e64d3be47ac033de9272ca7a4b/smart-contracts/x-ray/hackerhouse-pashov-ai-audit-report-20260416-110438.md), [run 2](https://github.com/Guide-DAO-Organization/hackerhouse/blob/59553fe45e05d1e64d3be47ac033de9272ca7a4b/smart-contracts/x-ray/hackerhouse-pashov-ai-audit-report-20260416-111131.md) | Older, smaller `smart-contracts` source set; exact reviewed files are listed in each report | One gate-confirmed queue-tolerance item in both runs; the second also retains a lower-confidence oracle-hardening item | AI review with an explicit no-guarantee disclaimer; use IDs and hypotheses only as historical leads |
| 2026-04-16 | [QuillShield multi-skill review](https://github.com/Guide-DAO-Organization/hackerhouse/blob/67f4a3887e264538b34bff7525c6c3f5130c93eb/smart-contracts/x-ray/quillshield-multi-skill-audit-20260416.md), methods manually applied | Older `smart-contracts/src` set | Skill-by-skill observations and review leads | Internal/manual methodology; not a professional third-party report |
| 2026-06-12 | [`AUDIT.md`](https://github.com/Guide-DAO-Organization/hackerhouse/blob/8af8d7fc32e2ee374968f8de9dae1bbc24156a4d/AUDIT.md), Behavioral State Analysis | `second-audit-july` at [`8af8d7fc32e2ee374968f8de9dae1bbc24156a4d`](https://github.com/Guide-DAO-Organization/hackerhouse/tree/8af8d7fc32e2ee374968f8de9dae1bbc24156a4d), `smart-contracts/src` | Internal correctness review; nine `F-*` items, with no direct-theft conclusion in that snapshot | The report itself says “Internal correctness review”; snapshot is not an ancestor of the imported target source |
| 2026-06-22 | [`PASHOV-AUDIT.md`](https://github.com/Guide-DAO-Organization/hackerhouse/blob/522a3457ea160fc8d2cebad48891c94f7bb819c1/smart-contracts/audits/PASHOV-AUDIT.md), Pashov skill-suite orchestration | `second-audit-july` at [`8af8d7fc32e2ee374968f8de9dae1bbc24156a4d`](https://github.com/Guide-DAO-Organization/hackerhouse/tree/8af8d7fc32e2ee374968f8de9dae1bbc24156a4d), about 5,000 LOC | 0 Critical, 0 High, 3 Medium, 8 Low | Internal/skill-assisted review of a stale side-branch snapshot; no status carries forward |
| 2026-06-22 | [`PLAMEN-AUDIT.md`](https://github.com/Guide-DAO-Organization/hackerhouse/blob/129932038e120d0d793cc084af3e240c916046f9/smart-contracts/audits/PLAMEN-AUDIT.md), Plamen skill methodology | Same `second-audit-july@8af8d7fc32e2ee374968f8de9dae1bbc24156a4d` snapshot | 1 High, 5 Medium, 6 Low; report itself explains the High as a stale-branch artifact relative to a later pricing rollback | Treat all `PLM-*` items as regression candidates, not present/current findings |
| 2026-06-22 | [`PLAMEN-REAUDIT-staging.md`](https://github.com/Guide-DAO-Organization/hackerhouse/blob/397479a95f680d5db896ecfe56da12a42b688c24/smart-contracts/audits/PLAMEN-REAUDIT-staging.md) | `staging` at [`b198fdd10cb63f1194d33df770d7f7d68edc6409`](https://github.com/Guide-DAO-Organization/hackerhouse/tree/b198fdd10cb63f1194d33df770d7f7d68edc6409); report records 870 passing tests | Records `PLM-1` resolved on that snapshot, status notes for other `PLM-*` items, and the first review of the PL-003 governance surface (`G-1..G-3`) | Statuses apply only to `b198fdd`; re-check both remediations and new governance behavior on `734df96` |
| 2026-07-02 | [Mainnet-readiness review A](https://github.com/Guide-DAO-Organization/hackerhouse/blob/a5a415043f70d3b955d32b6e46e976b2d63296ba/smart-contracts/audit/mainnet-readiness-review-2026-07-02.md), build/tests plus focused internal review | `main` at [`8cd0d10b24a5eac416b0874abc3beac1b38ab111`](https://github.com/Guide-DAO-Organization/hackerhouse/tree/8cd0d10b24a5eac416b0874abc3beac1b38ab111); report records 842 passing tests | Verdict: not mainnet-ready | `8cd0d10` is in the predecessor lineage, but later changes are substantial; use its blockers/checklist as historical input only |
| 2026-07-02 | [Mainnet-readiness review B](https://github.com/Guide-DAO-Organization/hackerhouse/blob/fbda455d6b202842e1a3ec97b298060ff1d3f6d4/audit/mainnet-readiness-review-2026-07-02.md), Behavioral State Analysis | `main` at [`528cbd383a8fd350deabcc7d06b3d996e5fe67dc`](https://github.com/Guide-DAO-Organization/hackerhouse/tree/528cbd383a8fd350deabcc7d06b3d996e5fe67dc); report records 898 passing tests | Verdict: not mainnet-ready; explicitly called out absent external audit and fork coverage at that time | Later predecessor/standalone code added fork coverage; remaining statements require current verification |

The report files above are absent from the current `hackerhouse@733eb578` and standalone target
trees; immutable commit links are used so the evidence remains inspectable.

Exact fetched refs containing the artifact commits at inventory time:

| Remote ref | Artifact commit(s) |
| --- | --- |
| `origin/pashov-skill-audit` | `59553fe45e05d1e64d3be47ac033de9272ca7a4b`, `67f4a3887e264538b34bff7525c6c3f5130c93eb` |
| `origin/second-audit-july` | `8af8d7fc32e2ee374968f8de9dae1bbc24156a4d` |
| `origin/pashov-audit` | `522a3457ea160fc8d2cebad48891c94f7bb819c1` |
| `origin/plamen-audit` | `129932038e120d0d793cc084af3e240c916046f9`, `397479a95f680d5db896ecfe56da12a42b688c24` |
| `origin/review/mainnet-readiness-2026-07-02` | `a5a415043f70d3b955d32b6e46e976b2d63296ba` |
| `origin/audit/mainnet-readiness-review` | `fbda455d6b202842e1a3ec97b298060ff1d3f6d4` |

## What is not available

The repositories inspected do not provide:

- a signed/final report from an independent audit firm or named external auditor;
- a statement of work or engagement letter tying an auditor to a scope hash;
- a third-party report scoped to standalone commit `734df96`;
- an issue-by-issue remediation matrix mapping all historical IDs to `734df96` with code links,
  tests, and reviewer sign-off;
- a deployment attestation mapping the Sepolia addresses published in monorepo application config,
  and their proxy implementations, to this exact source commit; or
- evidence about private reports that may exist outside the repositories.

If the project has a private or externally hosted report, the audit owner should supply the original
artifact, auditor identity, audited commit/tree hash, scope/exclusions, and final remediation status.

## Rules for using this history in the current audit

1. Search every historical ID and root-cause hypothesis against `734df96`, including items marked
   fixed, resolved, accepted, or stale.
2. Reproduce against current code/tests before assigning any current status or severity.
3. Record “not applicable” only with a code-level reason and current commit link.
4. Do not quote old pass counts as evidence for the target run.
5. Do not describe the protocol as externally audited on the basis of any artifact listed here.
