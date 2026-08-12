# Pashov four-gate judging handoff

This is a wave-level handoff, not the final report. `PASS` here means the candidate survives this methodology's source/guard/path/harm gates and still requires independent cross-verification.

| ID | Source exists | Guards checked | Complete path | Material consequence | Wave verdict |
|---|---|---|---|---|---|
| P-01 | PASS | PASS | PASS | PASS | PASS — verify both pricing and cap impacts |
| P-02 | PASS | PASS | PASS | PASS | PASS — strongest multi-reviewer result |
| P-03 | PASS | PASS | PARTIAL | PARTIAL | LEAD — execute real fee/rounding harm assertion |
| P-04 | PASS | PASS | PASS | PASS if deployment uses an explicit weak value | PASS, configuration-dependent |
| P-05 | PASS | PASS | PASS | PASS | PASS |
| P-06 | PASS | PASS | PASS | Conditional on paired token not being pre-whitelisted | CONTESTED / configuration-dependent |
| P-07 | PASS | PASS | PASS | PASS (automation/redemption liveness) | PASS |
| P-08 | PASS | PASS | PASS | PASS (emergency circuit breaker unavailable) | PASS |
| P-09 | PASS | PASS | PASS | PASS (unrelated native recovery unavailable) | PASS |
| P-10 | PASS | PASS | PASS | PASS (post-timeout user outcome overridden) | PASS |
| P-11 | PASS | PASS | PASS | PASS when a registered strategy view degrades | PASS, external-strategy precondition |
| P-12 | PASS | PASS | PASS | FAIL at demonstrated dust scale | LEAD / hardening |
| P-13 | PASS | PASS | PASS | Depends on intended fee-change semantics | CONTESTED design candidate |
| P-14 | PASS | PASS | PASS | Depends on intended beneficiary semantics | APPENDIX/design observation |
| P-15 | PASS | PASS | PASS | PASS (entry unavailable after finalization) | PASS |

Partial candidate files from incomplete reviewers 04 and 05 were rerun successfully, but promotion above relies on complete reviewers and/or later independent verification, not on those incomplete leaves.
