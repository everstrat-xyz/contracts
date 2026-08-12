# Plamen P3 — fork-ancestry

snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: 39/39 primary files
method_read: `SKILL.md` 171/171; Plamen rules 79/79; Plamen finding format 114/114
bundle_read: scope 139/139; profile 207/207; context 181/181; source 9417/9417; finding-format 101/101
network: intentionally not used (assignment requires no network/live deployment); generic hardcoded-floor fallback applied where applicable

## Detected parent/provenance signals

| Parent | Confidence | Immutable evidence | Disposition |
|---|---|---|---|
| Uniswap V3 core/periphery | HIGH | Four files explicitly say `Adapted from Uniswap V3 ...`; 9 primary files match UniswapV3/TickMath signatures | true embedded fork surface; divergence reviewed |
| OpenZeppelin 5.3 | HIGH | 11 primary files import OZ access/proxy/pause/token code; `.gitmodules` pins the upgradeable package | dependency integration, not locally forked code |
| Yearn/yield-vault family | LOW false signal | generic `Strategy`/`harvest` words, but no Vault/totalDebt/debtRatio pattern | not treated as ancestry |
| Compound family | NONE | zero CToken/Comptroller/InterestRateModel matches | N/A |

LEAD
id:           FA-1
file:         src/libraries/integrations/uniswap/{FixedPoint96,FullMath,LiquidityAmounts,TickMath}.sol
function:     embedded library provenance
suspicion:    The four embedded libraries name Uniswap V3 Core/Periphery but record no upstream repository commit, tag, file hash, or patch set, so exact ancestry and inherited-fix coverage cannot be reproduced offline.
blocked_by:   No Uniswap git submodule/version lock and network research is prohibited for this pass; only the target snapshot is immutable evidence.
next_step:    Pin an upstream Uniswap commit, retain pristine copies or a patch series, and CI-diff each embedded library against that pin; then map upstream advisories to every retained/diverged function.
verdict:      CONTESTED (provenance/reproducibility gap; no concrete arithmetic defect established)
step_execution: 1✓ 2? (live sources forbidden) 3 partial 4✓ (this raw artifact)
rules_applied: R4✓ R10✓
preferred_tag: FORK
confidence:   high that the pin is absent; medium that an undiscovered divergence could matter

CLEARED
area:         retained Uniswap math subset
checked:      FixedPoint96 contains only Q96 constants; FullMath retains 512-bit `mulDiv`; LiquidityAmounts normalizes ratio ordering and uses FullMath for every product/division; TickMath retains the canonical tick bounds/constants and rounded-up Q64.96 conversion. No protocol-authored storage or external calls were introduced into these four libraries.
evidence:     `FixedPoint96.sol:7-8`; `FullMath.sol:7-55`; `LiquidityAmounts.sol:10-103`; `TickMath.sol:7-38` at 734df96.
verdict:      REFUTED (hypothesis: obvious unsafe fork edit in retained arithmetic)
step_execution: 1✓ 3a✓ 3b✓
rules_applied: R10✓
preferred_tag: FORK
confidence:   medium-high — complete local code trace, but exact upstream diff is blocked by FA-1

CLEARED
area:         protocol-authored OracleLibrary/path divergences
checked:      TickUtils preserves negative-infinity mean-tick rounding; adapter `_quoteAtTick` generalizes the canonical quote path to uint256 using FullMath; packed routes validate `(length-20)%23==0`, enforce one hop, and reverse exact-output routes internally.
evidence:     `TickUtils.sol:24-52`; `UniswapV3ConverterAdapter.sol:285-324`; `UniswapV3Path.sol:40-105`.
verdict:      REFUTED (hypothesis: sign rounding, path direction, or unchecked multiplication drift)
step_execution: 1✓ 3a✓ 3b✓
rules_applied: R10✓
preferred_tag: FORK
confidence:   high for the traced local semantics

CLEARED
area:         inherited Uniswap V3 flash/callback issue classes
checked:      Mint callback requires the configured pool and a live `_minting` handshake; price/NAV paths use trailing TWAPs (strategy floor 1800s, short floor 60s) and adapter quotes additionally cross-check Chainlink. The Uniswap V2 first-LP/minimum-liquidity floor is not applicable because the protocol owns V3 positions rather than issuing pool shares.
evidence:     `UniCLStrat.sol:424-433,52-63,691-727`; `UniswapV3ConverterAdapter.sol:121-156,285-297`.
verdict:      REFUTED for the checked inherited classes
step_execution: 2d✓ 3a✓ 3b✓
rules_applied: R4✓ R10✓ R16✓
preferred_tag: FORK
confidence:   high for single-block/callback source mechanics; deployed pool/feed validity is not asserted

CLEARED
area:         OpenZeppelin ancestry and integration boundary
checked:      OZ is consumed from pinned submodules rather than copied into primary source. Protocol overrides are limited to Registry role bookkeeping, UUPS authorization, and initialization; no locally modified OZ implementation was found in the 39-file scope.
evidence:     `.gitmodules` pins `openzeppelin-contracts-upgradeable`; UUPS imports/overrides in Controller, Converter, ExitQueue, Oracle and StrategyManager.
verdict:      REFUTED (hypothesis: hidden local OZ fork divergence)
step_execution: 1✓ 3✓
rules_applied: R4✓ R10✓
preferred_tag: FORK
confidence:   high for primary-scope provenance

## Known-issue fallback disposition

- The skill's hardcoded floor has no Uniswap-V3-specific row. Closest generic AMM rows (first-LP inflation and spot-balance oracle manipulation) were checked and are inapplicable/mitigated as stated above.
- Live Solodit/Tavily queries were not run because this assignment expressly disallows network use; no unsupported “no known issues” conclusion is made.

commands:
- `git grep -l -E 'UniswapV3|TickMath|SqrtPriceMath|NonfungiblePositionManager' 734df96 -- script src/contracts src/libraries | wc -l` → 9 files
- equivalent OZ pattern census → 11 files; Compound census → 0 files
- `git show 734df96:.gitmodules` → forge-std, OpenZeppelin-upgradeable, Chainlink; no Uniswap pin
- `git grep -n -E 'Adapted from|OracleLibrary|getQuoteAtTick|meanTick' 734df96 -- src/libraries src/contracts/adapters src/contracts/strategies`
tests: no PoC added; ancestry and divergence source trace only
finding_count: 0
lead_count: 1
cleared_count: 4
AGENT_STATUS: COMPLETE
