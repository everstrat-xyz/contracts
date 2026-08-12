# Verification: pending performance fees are absent from share pricing

VERDICT: CONFIRMED

SUGGESTED SEVERITY: Medium

BASE: `734df96a1391e95dd40843210997da0b9f3ab05e`. The proof uses immutable production source and one isolated regression with the repository's protocol harness. No network, live deployment, or production edit was used.

## Mechanism

Recognized UniCL LP fees are part of `UniCLStrat.navInETH()` after a position poke, while `pendingPerformanceFeeInETH()` simultaneously reports the treasury's accrued percentage. Until harvest, however, that liability is represented neither as a NAV deduction nor as treasury EVE supply.

AMM entry and immediate exit calculate price from gross StrategyManager NAV and current `EVE.totalSupply()` (`AMM.sol:149-181, 408-421`). Controller batch pricing fixes the same gross base price in ExitQueue (`Controller.sol:331-336`; `ExitQueue.sol:173-187`). No path settles pending fees before those mint, burn, or price transitions.

Harvest later mints EVE to the DAO so that the minted shares represent the fee value. The dilution formula is economically sound at that instant, but an exiting holder can leave before it occurs and avoid its proportional share. For a priced batch, StrategyManager may crystallize the fee while sourcing withdrawal liquidity, yet the batch keeps the earlier gross price.

## Consequence

Permissionless holders can time an immediate exit after fees become visible but before harvest, receive gross backing, and shift their accrued fee share to holders who remain. Entrants in the same interval face the inverse cohort mismatch. A queued request can also retain a gross pre-fee valuation even when the normal withdrawal path harvests and dilutes supply before settlement.

This is distinct from changing the fee rate. The confirmed transition uses an already-configured rate and an already-recognized liability. No governance mistake is required; the gap is created by ordinary separate Sync/Harvest actions and any user can transact between them.

## Regression proof

`test/audit/candidates/verification/PendingFeeSharePricing.t.sol` wires the real AMM, Controller, ExitQueue, StrategyManager, EVE, Oracle, and a repository strategy mock with the production fee interface.

Worked state: gross NAV is 11 ETH, supply is 10,000 EVE, and the visible uncharged fee base is 1 ETH at 20%, so 0.2 ETH is already owed to the treasury.

- Immediate path: a holder of 1,000 EVE receives 1.1 ETH at gross NAV instead of 1.08 ETH net of the known liability. The 0.02 ETH avoided fee remains to be borne when the treasury mint dilutes the remaining cohort.
- Queue path: a request is priced at the gross price. `withdrawFromStrategy` then harvests the fee before sourcing ETH, lowering the live price, but processing still credits the larger fixed pre-fee payout.

Pinned offline attempt 1/3:

`FOUNDRY_OUT=/private/tmp/pending-fee-pricing-out FOUNDRY_CACHE_PATH=/private/tmp/pending-fee-pricing-cache /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/PendingFeeSharePricing.t.sol -vvv`

Result: 2 passed, 0 failed, 0 skipped. The sandbox-only global signature-cache warning did not affect compilation or execution.

## Severity, bounds, and recovery

Medium is appropriate because the timing path is open to ordinary holders and deterministically reallocates a percentage of accrued yield. Impact is bounded by the configured fee rate (maximum 20%), the unharvested visible fee base, the caller's share, and available immediate/queued liquidity. Periodic harvesting narrows but cannot atomically close the transaction-ordering window.

## Recommendation

Use a net shareholder NAV that subtracts every recognized pending performance-fee liability for AMM entry, exit, and batch pricing, while retaining gross NAV for the fee-share mint equation. Alternatively, atomically settle all visible strategy fees immediately before every EVE mint/burn and batch-price snapshot; that approach must be bounded and failure-safe across strategies. Add cohort-conservation regressions for immediate and queued exits.

AGENT_STATUS: COMPLETE
