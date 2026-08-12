# Pashov deduplication map

Deduplication uses root cause and required fix, not merely the same contract or variable.

| Consolidated candidate | Merged raw observations | Rationale |
|---|---|---|
| P-01 | Stale entry NAV; stale `maxDeposit`; post-poke cap excess | All arise because position fee growth is absent until a state-changing poke. Share pricing and risk-cap enforcement are separate impacts of one missing live-fee accounting mechanism. |
| P-02 | Immediate exit before harvest; queued price before harvest; entry cohort mismatch | All arise because a known fee liability is outside both NAV and supply pricing until a later mint. One fee-aware/checkpoint fix covers the supply-change surfaces. |
| P-07 | Deposit-capacity zero-weight loop; withdrawal-capacity zero-weight loop | Both keeper predicates disagree with the same downstream weight eligibility rule. |
| P-08 | Reviewer 06 allowance-cleanup rollback; reviewer 09 token-approval veto | Exact duplicate root cause and fix. |
| P-09 | Reviewer 06 pre-sweep token query; reviewer 09 paired-balance hostage | Exact duplicate root cause and fix. |

Candidates deliberately kept separate:

- P-05 (removing an already-counted token) and P-06 (moving a token into an uncounted location) create similar price discontinuities but have different triggering functions and fixes.
- P-01 (missing economically accrued pool fees from NAV) and P-02 (known protocol fee liability missing from share pricing) both affect price but represent different assets/liabilities and remediation.
- P-07 (zero weights) and P-12 (integer truncation with positive weights) both cause no progress but require different fixes.
- P-13 (rate epoch) and P-14 (beneficiary epoch) are separate governance semantics.

After consolidation, 22 raw findings map to 15 candidates. Raw leads remain traceable in their originating files.
