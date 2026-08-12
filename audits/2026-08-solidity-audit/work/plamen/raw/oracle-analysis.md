# Plamen raw pass: oracle-analysis

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope: full immutable 39-file source scope
method: oracle inventory; staleness/round/decimal/TWAP/deviation/failure-mode traces; all consumers followed to user outcomes
plugin_confidence: high for in-scope arithmetic and failure traces; medium for configuration-dependent exposure because chain, feeds, heartbeats, pool history/liquidity and deployed parameters are unknown

ORACLE_INVENTORY
- Chainlink-style Token/USD feeds: dynamic `Oracle.TokenInfo.usdFeedInfo`; `latestRoundData()` + `decimals()`; configured heartbeat is each stored `stalenessInterval` (initial ETH script value 3,600s, all deployed values unknown). Decisions: bootstrap USD minimum, USD views, supported-token and strategy NAV, token conversions, swap oracle bounds, performance-fee valuation.
- Chainlink-style ordered TokenA/TokenB overlays: same read API and per-feed interval; direct then inverse feed takes precedence over USD cross-rate. Decisions: every `Oracle.convert` consumer above. Deployed pair set/direction/heartbeat unknown.
- Uniswap route-pool TWAP: Factory `getPool` then Pool `observe([twapInterval,0])`; adapter interval immutable, floor 60s, deployed value/liquidity unknown. Decision: exact-in/out quote; gross TWAP amount must be within 2% of Chainlink.
- UniCL configured-pool TWAP/spot: `observe` at mutable long/short windows (floors 1,800s/60s) plus `slot0` spot. Decisions: NAV position composition, health/calm gating, deposit/rebalance and LP sizing. Pool history/liquidity/config unknown.
- No pull oracle, median/weighted oracle, hardcoded stablecoin price, liquidation, loan, or rebase path exists in scope.

FINDING
file:         src/contracts/strategies/UniCLStrat.sol
function:     navInETH / _setTwapInterval
mechanism:    Registration and TWAP setters enforce only duration floors, not that the configured pool can serve the chosen history; `navInETH` has no cold-start fallback and reverts when `observe` cannot cover the long window.
consequence:  Registering a young/low-cardinality pool, or raising `twapInterval` beyond available history, makes the strategy revert inside aggregate NAV and halts AMM entry, exit, and batch pricing.
trigger:      ADMIN_ROLE registers the strategy or changes its TWAP window while pool history is insufficient
severity:     medium
rationale:    The trigger is governance/configuration-dependent, but the cold-start failure deterministically blocks all holders' core liquidity paths until observations mature or a timelocked force-removal/config repair executes.
poc:          none — immutable-base code trace
evidence:     `DeployUniCLStrat.s.sol:94-99` states cardinality “must cover TWAP_INTERVAL” but only checks numeric floors; `UniCLStrat.sol:554-557` stores any larger window; `:665-672,713-720` routes NAV through TWAP and reverts `UniCLStratPoolTWAPNotAvailable`; `StrategyManager.sol:940-943` propagates every strategy NAV revert.
fix:          Before strategy registration and every interval update, require a successful pool observation for the proposed window; alternatively retain a safe last-good interval until the new history exists.
related:      none
plamen_verdict: CONFIRMED
plamen_steps: ✓1 ✓2 ✓3 ✓3d ✓4 ✓4d ✓5 ✓5c ✓6
plamen_rules: R4:✓, R5:✓, R6:✓(ADMIN config), R8:✓, R10:✓, R11:✗(oracle/pool data), R12:✓, R13:✓(documented prerequisite), R14:✓, R15:✓(considered; cold-start path needs no flash loan), R16:✓
preferred_tag: CODE-TRACE
material_harm: All EVE holders can be unable to enter, redeem, or price queued exits while otherwise recoverable protocol capital remains inaccessible.
postconditions: aggregate NAV reverts; AMM price reads revert; pricing and liquidity automation cannot progress
postcondition_types: STATE, TIMING, EXTERNAL
who_benefits: no required beneficiary; a malicious governance proposer could intentionally induce the outage

LEAD
file:         src/contracts/Oracle.sol
function:     _getPriceWithStalenessCheck
suspicion:    `roundId` and `answeredInRound` are discarded, so `answeredInRound >= roundId` is not enforced even though answer sign, timestamp and age are checked.
blocked_by:   Safety depends on the concrete AggregatorV3 implementations; no feed addresses/versions were supplied, and some current aggregators make `answeredInRound` non-informative.
next_step:    Identify every deployed feed implementation and verify its round semantics; add the coherence check for any implementation where lagging answers are possible.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✗(no semi-trusted role at read), R8:✓, R10:✓, R11:✗, R12:✓, R13:✗(not design-labelled), R14:✗(no aggregate constraint), R15:✗(not flash state), R16:✓

LEAD
file:         src/contracts/Oracle.sol
function:     updateUsdFeedInfo / updatePairFeedInfo
suspicion:    Registration accepts any nonzero interval and checks only feed decimals; it does not validate a live round, cap staleness against heartbeat, or enforce USD/pair direction. Runtime feed changes do not receive the deploy script's advisory `/ USD` description check.
blocked_by:   Calls are 48h-timelocked ADMIN operations and the actual feed/heartbeat/review process is outside the supplied source/deployment state.
next_step:    Compare each deployed feed's base/quote and heartbeat to stored intervals, and execute a live-round sanity read in the timelock proposal simulation.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✗, R12:✓, R13:✓(documented off-chain invariant), R14:✓, R15:✗, R16:✓

LEAD
file:         src/contracts/Oracle.sol
function:     _getPriceWithStalenessCheck
suspicion:    There is no L2 sequencer-uptime/grace-period gate; after a sequencer outage, an otherwise age-valid feed can be used before markets/users have recovered.
blocked_by:   No production chain ID was supplied, so L2 applicability and the correct uptime feed are unknown.
next_step:    If deployment is on an L2 with a sequencer, integrate its uptime feed and post-recovery grace period into all price reads.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✗, R12:✓, R13:✗, R14:✗, R15:✗, R16:✓

LEAD
file:         src/contracts/strategies/UniCLStrat.sol
function:     _setMaxTickDeviation / _isCalm
suspicion:    `maxTickDeviation` has only a positive lower bound; large but non-overflowing values admit every feasible spot/short-TWAP divergence, while extreme int56 values make the band arithmetic revert.
blocked_by:   ADMIN_ROLE controls the parameter and no deployed value or policy bound was supplied.
next_step:    Derive a maximum tick deviation from tolerated price movement, enforce it in constructor/setter, and test exact maximum plus int56 boundary values.
plamen_verdict: PARTIAL
plamen_rules: R4:✓, R5:✗(single strategy), R6:✓, R8:✓, R10:✓, R11:✗, R12:✓, R13:✗, R14:✓, R15:✓, R16:✓

CLEARED
area:         Chainlink basic staleness/sign/timestamp handling
checked:      All registered feed reads share one helper; it rejects updatedAt=0, answer<=0, future timestamps and age strictly above the configured interval. Equality at the age boundary is consistently accepted. Feed reverts and malformed returns fail closed.

CLEARED
area:         Decimal normalization and mandatory grep sweep
checked:      Feed decimals are read dynamically, constrained to <=18 at registration and normalized to 18; token decimals are read dynamically and Math rejects either side above 18. `18` in UniCL token/ETH conversions denotes native ETH precision. Grep of every oracle consumer for `10**|decimals()|1eN|normaliz` found no 1e8/1e6/1e10 feed assumption or hardcoded stablecoin price.

CLEARED
area:         Direct/inverted/USD cross-rate direction
checked:      Direct A/B multiplies normalized A by B-per-A, inverted B/A divides, and USD fallback computes amountA*USD/A divided by USD/B. Same-token conversion changes decimals without reading an irrelevant price.

CLEARED
area:         TWAP arithmetic
checked:      `observe([window,0])` is time-weighted; cumulative delta divides by nonzero uint32 windows and negative quotients round toward negative infinity. Tick-to-quote uses FullMath and address-order inversion consistently.

CLEARED
area:         Deviation reference and exact boundaries
checked:      Adapter compares gross TWAP and gross Chainlink amounts symmetrically around Chainlink and permits exactly ±2%; fee is applied afterward. UniCL independently bounds adapter quotes against Chainlink before applying its separate slippage floor/cap. No prior-price cache or first-update bypass exists.

CLEARED
area:         Oracle failure-mode impact
checked:      Zero/negative/future/stale/reverting feeds and unavailable TWAPs revert rather than mint/redeem at a fabricated fallback. Extreme fresh Chainlink values remain the trusted-source risk; adapter swaps add a TWAP cross-check, while direct NAV/bootstrap consumers intentionally fail only when source validation itself fails.

READ_COUNTS
- Plamen rules: orchestrator-rules.md 79/79; finding-output-format.md 114/114.
- Skill: oracle-analysis/SKILL.md 237/237; directly referenced required files: 0.
- Fresh shared bundle (completed once for P2): scope 139/139; profile 207/207; context 181/181; source 9,417/9,417 (39/39 files); finding-format 101/101.

COMMANDS_TESTS
- Mandatory decimal sweep: base-only `git grep -nE '10\\*\\*|decimals\\(\\)|1e[0-9]+|normaliz' 734df96 --` across all oracle consumers and math libraries.
- Validation: base-only `git show 734df96:PATH | nl -ba | sed -n ...`; no working-tree production source read.
- Tests: not run; cold-start result follows the explicit `tryMeanTick=false -> _twap revert -> aggregate NAV revert` trace.
- Network/live systems/production edits/commit: not used.

AGENT_STATUS: COMPLETE
