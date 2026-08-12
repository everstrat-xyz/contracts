# Plamen P3 — flash-loan-interaction

snapshot: `734df96a1391e95dd40843210997da0b9f3ab05e`
scope: 39/39 primary files
method_read: `SKILL.md` 215/215; Plamen rules 79/79; Plamen finding format 114/114
bundle_read: scope 139/139; profile 207/207; context 181/181; source 9417/9417; finding-format 101/101
trigger: BALANCE_DEPENDENT + DEX/oracle interactions; no native flash-loan API/callback in protocol

LEAD
id:           FL-1
file:         src/contracts/{Oracle.sol,adapters/UniswapV3ConverterAdapter.sol,strategies/UniCLStrat.sol}
function:     deployed DEX/oracle configuration
suspicion:    Source enforces TWAP floors and Chainlink deviation bounds, but flash/sustained-manipulation economics still depend on the deployed pool liquidity/observation history, configured intervals/deviation, feed independence/heartbeat, router/factory identity, and available lending markets.
blocked_by:   No target-bound deployment manifest, pool/feed state, TVL, liquidity-range data, or fixed fork block; network/live access is prohibited.
next_step:    On a fixed production fork, verify bytecode/config, observation coverage, feed independence and liquidity-in-range; sweep flash sizes and multi-block holds against AMM enter/exit, both Converter swap directions, UniCL NAV, rebalance and fee harvest.
verdict:      CONTESTED (deployment-state economics unknown; no source-level atomic exploit established)
step_execution: 0a✓ 0b✓ 0c? 1✓ 2✓ 3✓ 3b✓ 3c✓ 3d✓ 4✓ 5✓ 5b✓
rules_applied: R4✓ R10✓ R15✓ R16✓
preferred_tag: EXTERNAL
confidence:   high that source blocks single-transaction spot extraction; medium on live economic bounds

## 0. External flash-susceptibility inventory

| External boundary | State read | Flash movable? | Source disposition |
|---|---|---|---|
| Uniswap-compatible pool | `slot0` spot tick/price | yes, within one transaction | used for health/liquidity placement, but strategy actions are role-routed and calm checks compare spot+60s TWAP to 1800s TWAP |
| Uniswap-compatible pool | `observe` cumulative tick | not materially in one timestamp | adapter TWAP floor 60s; strategy long floor 1800s and short floor 60s |
| Chainlink feed | `latestRoundData` | not by a DEX flash trade under source assumptions | positive/fresh timestamp and configured staleness; independent quote bound |
| Router | execution spot price | yes | caller supplies minOut/maxIn; strategy derives them from TWAP+Chainlink and caps slippage at 200 bps |
| Pool positions/fees | liquidity, `tokensOwed` | swaps can add fees | flash trader pays the fees; only fractional value returns through EVE ownership |

## 1. Flash-accessible state inventory

| State/query | Flash write path | Security-sensitive readers | Result |
|---|---|---|---|
| AMM free ETH | direct transfer | total NAV, immediate-exit liquidity | donation counted; cannot be reclaimed in full by a holder with A<S |
| Controller/StrategyManager ETH | direct transfer | total NAV, keeper excess/needs | same donation bound; privileged movement only |
| UniCLStrat ETH/WETH/paired balance | transfer | strategy NAV/inventory | donation valued; strategy actions restricted to SM/admin |
| supported ERC20 balance on SM | token transfer | NAV via Oracle | donation valued; unsupported token ignored |
| EVE total supply | enter/exit | base/premium price and fee mint | permissionless changes cost assets; entry premium makes closed cycle lossy |
| Uniswap spot tick | flash swap | `isHealthy`, placement math | permissionless reads only; state-changing strategy calls are restricted and guarded/bounded |
| queue totals/timestamps | EVE escrow / keeper pricing | redemption automation | flash EVE cannot remain escrowed while repaid; queue+cancel leaves no consumed resource |

CLEARED
area:         atomic NAV donation and EVE share cycles
checked:      Sequence borrow→donate D→redeem holdings A→repay is non-profitable: incremental recovery is `D*A/S`, so net is `-D*(1-A/S)<0`; bootstrap dead supply ensures A<S. Borrow→enter→exit is also lossy because entry uses premium price `base/cw` while exit uses base price. A victim deposit cannot be inserted between attacker steps inside one flash-loan transaction because `enter` always mints to `msg.sender`; a cross-transaction sandwich requires non-flash capital.
evidence:     AMM `enter`/`exit` at :115-184; pending `msg.value` subtraction at :363-375; base/premium formulas at :329-347; dead mint at :429; StrategyManager NAV holder balances at :940-950.
verdict:      REFUTED (atomic profitable donation/share manipulation)
step_execution: 1✓ 2✓ 3✓ 4✓; profitability gate FAIL (net ≤ 0)
rules_applied: R10✓ R11✓ R15✓
preferred_tag: ECONOMIC
confidence:   high — symbolic bounds cover every D>0 and attacker fraction A/S<1

CLEARED
area:         same-transaction DEX/oracle manipulation
checked:      Permissionless AMM pricing consumes StrategyManager NAV; UniCL LP composition is valued at the 1800s TWAP and idle tokens through Chainlink, not the flash-moved spot. Strategy swaps are reachable only through registered StrategyManager/Controller/keeper paths; their quote is TWAP-derived, Chainlink-bounded ±200 bps, and execution is minOut/maxIn bounded. A flash trader can move spot enough to make calm checks fail (temporary DoS/read change), but cannot atomically call a value-extracting strategy action as an unprivileged user.
evidence:     UniCL `navInETH` :199-203, `_balancesOfPool` :672-677, `_isCalm` :688-702; adapter quote/check :162-211, :285-355; strategy swap bounds :1087-1219.
verdict:      REFUTED for an unprivileged atomic extraction; live parameters remain FL-1
step_execution: 0a✓ 0b✓ 0c? (live liquidity absent) 2✓ 3✓ 5✓
rules_applied: R4✓ R10✓ R15✓ R16✓
preferred_tag: ECONOMIC
confidence:   high on reachability/source defenses; medium on deployment economics

CLEARED
area:         cooldown, debounce and no-op resource consumption
checked:      The only deposit cooldown is written after Controller-authorized strategy withdrawals; `lastSyncAt` is written only by Forwarder-gated upkeep; batch pricing/timestamps are Controller/keeper-gated. Permissionless queue users must escrow nonzero EVE and can cancel an unpriced request without advancing the batch or consuming a global nonce/cooldown. No flash-triggerable shared debounce was found.
evidence:     StrategyManager cooldown writes :1135-1136, :1166-1167 and caller gates :343-375; StrategyKeeper `lastSyncAt` :217-270; ExitQueue pricing :174-188 and push/close :195-268.
verdict:      REFUTED (flash-loan-enabled shared cooldown/resource DoS)
step_execution: 3b✓ 3c✓ 3d N/A (no flash-susceptible debounce)
rules_applied: R2✓ R10✓ R15✓
preferred_tag: CODE-TRACE
confidence:   high — all time-indexed writes and permissionless routes classified

CLEARED
area:         cross-function chains and defense parity
checked:      Enter→exit uses premium/base asymmetry against the caller; queue→cancel restores escrow without advancing state; Converter exact-input and exact-output both use nonReentrant, role gates, measured balance deltas and min/max bounds; strategy deposit/rebalance require calm state while withdrawal preserves liveness but retains TWAP/Oracle-bounded swaps. Immediate and queued exits both settle at base NAV.
evidence:     AMM :115-244; Converter :121-210, :375-408; Controller `priceBatch` :331-338; UniCL deposit/withdraw/rebalance :227-360.
verdict:      REFUTED (multi-call flash chain or cross-contract defense-parity bypass)
step_execution: 3✓ 5✓ 5b✓
rules_applied: R10✓ R15✓
preferred_tag: CODE-TRACE
confidence:   high for audited-code routes

## Atomic sequence disposition

1. `BORROW → flash-swap spot → AMM enter/exit → restore → REPAY`: AMM price does not use spot; no extraction.
2. `BORROW ETH/token → donate to NAV holder → redeem EVE → REPAY`: recovery fraction `<1`; negative before fee/gas.
3. `BORROW → enter EVE → exit EVE → REPAY`: premium entry/base exit; negative.
4. `BORROW EVE → queue → cancel → REPAY`: no durable resource consumed; leaving queued prevents repayment.
5. `BORROW → manipulate spot → strategy action → restore`: attacker cannot reach state-changing strategy path; large spot deviation also fails calm checks.

## Defense audit / parity summary

| Action | Reentrancy | Price defense | Atomic access defense | Parity result |
|---|---|---|---|---|
| AMM enter/exit | yes | NAV; pending deposit excluded; premium/base | user-callable, economically bounded | no gap |
| queued/immediate redemption | yes at AMM/Controller | same base NAV | keeper price commit; EVE escrow | no gap |
| Converter exact-in/out | yes | caller minOut/maxIn; measured deltas | caller role | no gap |
| UniCL deposit/rebalance | yes | spot+short/long TWAP calm; Oracle bounds | SM only | no gap |
| UniCL withdrawal swaps | yes | TWAP+Chainlink quote; ≤200 bps input/output tolerance | SM only | liveness exception bounded |

commands:
- full bundle read plus `git grep -n -E 'balanceOf\\(|address\\(this\\)\\.balance|totalSupply\\(|slot0\\(|observe\\(|latestRoundData\\(|nonReentrant|lastStrategyWithdrawal|lastSyncAt|pricedAt|createdAt|cooldown|TWAP|ORACLE_DEVIATION|swapSlippage' 734df96 -- src/contracts src/libraries`
- native flash callback census from profile/source → 0 protocol flash-loan APIs
tests: no PoC added; source reachability and algebra close atomic hypotheses; fixed-fork economic validation remains FL-1
finding_count: 0
lead_count: 1
cleared_count: 4
AGENT_STATUS: COMPLETE
