# Plamen P1 — staking-receipt-tokens

target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
scope/read: full 39 files; skill 220/220 (no references); rules 193/193; bundle 139/207/181/9,417/101 lines
instantiation: EVE is the protocol receipt/share ERC-20; UniCL pool positions are external liquidity receipts stored by the pool under `(owner,ticks)` rather than transferable ERC-20/ERC-721 tokens; WETH, pairedToken and StrategyManager-supported ERC-20s are transferable external assets.

## FINDING SRT-1 — A dust donation activates a stale supported-token feed and freezes NAV

file: `src/contracts/StrategyManager.sol`
function: `_supportedERC20sNAVInETH`
mechanism: Supported-token pricing skips the Oracle only while the contract balance is exactly zero; any account can transfer one smallest unit after that token's feed becomes stale, forcing every NAV read through a reverting conversion.
consequence: A permissionless donor can halt AMM entry, exit pricing, queue pricing, strategy automation and performance-fee minting until SECURITY removes the token or the feed recovers.
trigger: anyone holding a supported ERC-20 during a stale/invalid Oracle period while StrategyManager's balance was zero
severity: low
rationale: The liveness blast radius is protocol-wide, but attackability requires an external feed-failure window and SECURITY has an immediate no-external-call removal escape hatch.
poc: none — code/state trace
evidence: `StrategyManager.sol:961-968`: `balanceOf(this)`, `if (balance == 0) continue`, otherwise `oracle.convert(...)`. `totalNAVInETH` feeds AMM prices and executor calculations. `removeSupportedERC20` at `491-501` intentionally provides the SECURITY escape hatch and acknowledges “1-wei dust griefing.”
fix: Store/check feed health independently of unsolicited balances and quarantine unpriceable donated dust without reverting global NAV; alternatively retain the fail-closed design but automate immediate token isolation and expose bounded user exit.
related: none
verdict: PARTIAL
step_execution: ✓1, ✓2, ✓2b, ✓3, ✓4, ✓5, ✓8 | ✗6,7(N/A-one pool/one position owner) | ✗9(N/A-no validators)
rules_applied: R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash loan needed), R16:✓
preferred_tag: CODE-TRACE
material_harm: All users temporarily lose access to mint/redemption pricing and queued processing until emergency governance responds.
missing_precondition: a supported token's configured feed is stale/invalid while StrategyManager holds zero of it
precondition_type: EXTERNAL / STATE
why_this_blocks: With a live feed the donation is valued normally; with an already nonzero balance the feed outage already caused the freeze.
postconditions: StrategyManager balance becomes nonzero and every aggregate NAV read reverts at Oracle conversion.
postcondition_types: BALANCE, EXTERNAL, STATE
who_benefits: griefing token holder (no direct extraction)
NEEDS_DEPENDENCY_RESEARCH: configured Chainlink feeds:src/contracts/StrategyManager.sol:968: determine realistic simultaneous stale-feed windows and response SLA for each supported token.

## LEAD SRT-L1 — Non-standard supported ERC-20 behavior can make NAV non-deterministic

file: `src/contracts/StrategyManager.sol`
function: `_supportedERC20sNAVInETH`
suspicion: ADMIN may support any code-bearing Oracle-priceable token; NAV trusts its live `balanceOf` and `decimals`, so rebasing, callback-bearing, proxy-upgraded, or reverting tokens can change/freeze backing independently of protocol flows.
blocked_by: No deployed supported-token list or exact token implementations were supplied, and network/live dependency review is prohibited.
next_step: Verify each deployed token's transfer/rebase/proxy semantics and restrict support to vetted immutable/non-rebasing assets; fuzz balance/decimals failure modes with local mocks.

## CLEARED

area: EVE unsolicited transfer accounting
checked: EVE is transferable and can be sent to AMM/Controller/StrategyManager, but raw EVE balances are never used to size NAV, mints, burns, requests, or claims. Queue escrow is tracked per request, cancellation returns exactly its recorded amount, and processing burns exactly its recorded amount; unsolicited EVE cannot be claimed by another user and does not inflate a withdrawal calculation.

## CLEARED

area: UniCL external receipt transferability
checked: The Uniswap pool position is keyed to `keccak256(owner=strategy,tickLower,tickUpper)` and exposed through `pool.positions`; no ERC-20/ERC-721 position receipt is held or accepted. An attacker cannot buy/transfer a foreign position into the strategy, and direct pool-token donations affect only ordinary token balances, not stored position liquidity or `tokensOwed` fee counters.

## CLEARED

area: External token donations and tracked-versus-actual balances
checked: WETH/paired-token donations to UniCL are intentionally included in `navInETH`, max deposit/withdrawal and later inventory balancing, so they increase holder backing rather than create an untracked claim. Supported-token donations to StrategyManager are likewise included at Oracle value when healthy. Converter swap payouts/refunds use measured pre/post deltas, so authorized callers cannot extract pre-existing donated token balances through adapter-reported amounts.

## CLEARED

area: Transfer side effects and multi-entity dust
checked: EVE uses standard OZ ERC20 transfers with no hooks/rebase. Exact deployed WETH/paired/supported token transfer side effects remain a deployment verification obligation (SRT-L1). There is one UniCL pool with two tick ranges under one owner; per-position owed amounts are aggregated before fee accounting, and no validator/source proliferation or per-entity withdrawal rounding exists.

## CLEARED

area: Pending-operation adverse events
checked: The only request→wait→settle flow is internal EVE redemption, not external staking. Once priced, settlement uses stored EVE price and can proceed without a fresh pool/Oracle read if Controller liquidity exists; if strategies/integrations cannot fund it, users regain all escrowed EVE through `closeRequest` after three days. Claims remain pullable independent of pause.

## Receipt/token matrix

| Token/receipt | Transferable/unsolicited | Balance dependency | Donation impact | Tracked vs actual |
|---|---|---|---|---|
| EVE | yes | no raw-balance economic dependency | stranded/self-donation only | request records isolate escrow |
| UniCL position | no tokenized receipt | `pool.positions(owner,ticks)` | foreign position cannot be sent | pool is authoritative |
| WETH/pairedToken | yes | UniCL NAV/cap/withdraw/inventory | increases backing; possible external semantics lead | actual balance intentional |
| supported ERC-20 | yes | StrategyManager NAV | valued normally; stale-feed dust DoS in SRT-1 | actual balance intentional |
| Converter tokens | yes | swap balance deltas | pre-existing balance excluded from payouts | deltas isolate caller flow |

## Commands/results

- Base-only `git show 734df96:PATH | nl -ba | sed -n ...` traced EVE, StrategyManager token enumeration, UniCL position/balance/fee accounting, Converter delta accounting, ExitQueue and AMM escrow/claim paths.
- No network, live dependency calls, or test-tree reads. Tests not run; SRT-1 is conditional on a feed-failure state and correctly marked PARTIAL.

AGENT_STATUS: COMPLETE
