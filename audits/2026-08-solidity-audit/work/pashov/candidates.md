# Pashov candidate register

This register is internal audit infrastructure. IDs below must not appear in the client-facing final report.

| ID | Consolidated root cause | Raw support | Evidence at wave exit | Initial disposition |
|---|---|---|---|---|
| P-01 | `UniCLStrat.navInETH()` omits unpoked Uniswap fee growth | 01, 05 partial, 07 | Passing cap regression; existing sync discontinuity test | Promote to cross-verification |
| P-02 | AMM supply changes and queue pricing ignore accrued, unminted performance-fee liability | 01, 03, 04 partial, 05 partial, 07 | Four independently rerun local examples | Promote to cross-verification |
| P-03 | Exact-output required-input calculations round down | 01; 10 lead | Concrete arithmetic only | Retain as lead pending router-level harm test |
| P-04 | Deployment helper does not enforce its documented 48-hour timelock floor | 02 | Complete source trace | Promote to cross-verification |
| P-05 | Removing a balance-bearing supported token while AMM is live causes an immediate NAV discontinuity | 02 | Complete source trace; separate root regression exists | Promote to cross-verification |
| P-06 | Emergency paired-token transfer can cross into an uncounted accounting location | 02 | Complete source trace | Retain; verify configuration/runbook precondition |
| P-07 | Automation capacity predicates count zero-weight strategies that downstream allocation cannot use | 03, 07 | Deposit and withdrawal regressions pass | Promote to cross-verification |
| P-08 | Mandatory allowance cleanup can roll back `UniCLStrat.pause()` | 06, 09 | Two independently authored equivalent regressions pass | Promote to cross-verification |
| P-09 | A paired-token balance query can block unrelated native-asset emergency recovery | 06, 09 | Two independently authored equivalent regressions pass | Promote to cross-verification |
| P-10 | Stale queue perform data can process a request after the documented cancellation handoff | 08 | Passing regression | Promote to cross-verification |
| P-11 | Unguarded strategy preflight views can defeat best-effort batch isolation | 09 | Complete cross-function trace | Promote to cross-verification |
| P-12 | Weighted withdrawal truncation can make a positive dust request allocate zero everywhere | 10 | Concrete `1 wei`, 50/50 trace | Retain as low-materiality lead |
| P-13 | Changing the performance-fee rate reprices all unharvested historical fee base | 11 | Complete state/economic trace | Retain as governance-design candidate |
| P-14 | Changing treasury redirects the entire unharvested fee backlog | 11 | Complete state trace | Retain as governance-design observation |
| P-15 | Modular finalization omits the mandatory Whitelist registration from completeness checks | 07 | Complete deployment trace | Promote to cross-verification |

Additional raw leads (unreachable overflow scales, unchecked deployment narrowing, role exclusivity assurance, zero proposer, no-op perform parity, large revert data, route hardening and trusted-strategy fee reporting) remain in the raw files and are not silently promoted.
