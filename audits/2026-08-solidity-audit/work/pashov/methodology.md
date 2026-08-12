# Pashov methodology execution note

The Pashov portion used the repository's x-ray/profile preparation, common rules, Senior Auditor SOP, twelve specialty bundles, four-gate judging and root-cause deduplication against the immutable full-source snapshot.

Execution deviations are explicit:

- 12 specialties were dispatched; 9 completed and 3 were incomplete.
- Reviewer prompts were narrowed to defensive local code review after three content-filter interruptions. This changed phrasing, not source scope or the evidence standard.
- No live chain, wallet, credential, deployed contract or external transaction was used.
- Candidate tests were staged under `test/audit/candidates/pashov/` and run with
  isolated Foundry output/cache directories. They were removed after adjudication;
  only independently accepted proofs under `test/audit/candidates/verification/`
  are retained in the handoff branch.
- Raw agent narration remains internal. Client-facing reporting will contain only independently verified, deduplicated findings with clean severity-prefixed IDs.

Coverage obtained from complete specialties includes math/precision, access control, economics, periphery/libraries, first principles, asymmetry, boundary/external calls, numerical gaps and trust gaps. Execution-trace, invariant/conservation and flow-gap leaves are explicitly incomplete; their intended domains are covered again by Omega, QuillShield, Plamen and the final cross-verification pass rather than being claimed complete here.

Wave result: 15 consolidated candidates from 22 raw findings; 10 promoted for independent verification, 2 configuration/design-contested, 2 low-evidence/low-materiality leads and 1 governance-design observation. Counts are provisional until cross-methodology merge.
