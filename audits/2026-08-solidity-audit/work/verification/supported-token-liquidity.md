# Verification: supported ERC20 NAV has no settlement path

VERDICT: CONFIRMED

SEVERITY: Medium

CONFIDENCE: High. Immutable source expressly limits supported tokens to accounting, exhaustive call-site search found no token egress, and the full AMM/Controller/StrategyManager regression proves both exit-order asymmetry and failed settlement.

BASE: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`. Only immutable production source/interfaces and base helpers/mocks were read through `git show`; imported `src`, `test/helpers`, and `test/mocks` were previously confirmed byte-identical to base. No prior audit output, existing audit test, history, network, live system, production edit, or commit was used.

## Confirmed mismatch

`StrategyManager._totalNAVInETH` adds the Oracle-valued balance of every supported ERC20 held by StrategyManager to strategy NAV and all native custody (`StrategyManager.sol:923-969`). AMM uses that total for the base redemption price (`AMM.sol:138-170,349-359`), and queued batches are priced at the same NAV/supply price (`Controller.sol:331-336`). A supported token therefore creates an ETH-denominated redemption claim.

No implementation path can satisfy that claim from the token:

- `addSupportedERC20` only validates and inserts an address; the balance is used only by the NAV view (`StrategyManager.sol:477-485,961-969`).
- StrategyManager makes no ERC20 `transfer`, approval, or swap call. Its only `IConverter` calls grant/revoke strategy caller roles.
- `emergencyWithdrawToController` transfers only `address(this).balance` (native ETH) and reverts when it is zero (`StrategyManager.sol:449-463`).
- The source and interface expressly state that this release ships “ERC-20 accounting only” and defers on-chain swap recovery (`StrategyManager.sol:465-468`; `IStrategyManager.sol:483-501`).
- `removeSupportedERC20` performs no external call, leaves custody unchanged, and immediately drops the asset from NAV (`StrategyManager.sol:488-502`; `IStrategyManager.sol:503-517`). It is a valuation/liveness circuit breaker, not asset recovery.

Actual token recovery therefore requires a StrategyManager upgrade (`_authorizeUpgrade` is ADMIN-gated at `StrategyManager.sol:1237-1241`) or a non-protocol/token-specific external mechanism. Removal alone realizes the accounting loss for remaining EVE holders.

## Intended reachable path

This is not limited to unsolicited tokens. `UniCLStrat.emergencyExit` unwraps WETH and sends native ETH to StrategyManager, then sends its paired-token balance there (`UniCLStrat.sol:472-515`). Its documentation tells operators to whitelist the paired token so NAV continues to count that “recoverable value” (`:481-483`). Thus an intended emergency flow can create a material supported-token balance precisely when native liquidity is stressed.

Whitelisting requires ADMIN_ROLE and an installed Oracle feed, reducing arbitrary-token exposure (`StrategyManager.sol:477-483`). However, after a valid token is configured, anyone can transfer more of it to StrategyManager, and the intended emergency sweep needs no further NAV action.

## Exit-order harm

AMM pays every redemption entirely in native ETH. If AMM free balance covers the request, it burns EVE and pays immediately; otherwise it queues the EVE claim (`AMM.sol:164-181`). It neither pays pro rata in the supported token nor reserves native ETH based on asset composition.

Consequently, early exits can consume native liquidity for their combined native-plus-token NAV share, leaving later holders with only the non-convertible asset. Later queued requests still receive a positive ETH settlement price, but `Controller._processRequest` reverts unless the Controller has the corresponding ETH (`Controller.sol:435-448`). The strategy keeper cannot source a token held directly by StrategyManager because its withdrawal capacity is only the sum of registered strategies' `maxWithdrawal()`.

The resulting state is economically solvent at the Oracle valuation but operationally unable to honor ETH redemptions. Remaining users may cancel after the queue escape window, but they still cannot redeem until native liquidity arrives or governance adds recovery. This is a withdrawal-liveness and fairness failure, not direct theft; if governance later converts the token at its quoted value, principal remains recoverable.

## Regression proof

Created `test/audit/candidates/verification/SupportedTokenLiquidity.t.sol`; no production changes. It uses fully wired AMM, Controller, StrategyManager, ExitQueue, Oracle, Whitelist, EVE, and a standard mock ERC20/feed.

State and observations:

1. A 5 ETH bootstrap creates 20,000 EVE at $4,000/ETH.
2. StrategyManager receives a supported $20,000 token balance, adding 5 ETH NAV; total NAV is 10 ETH.
3. Controller moves the 5 native ETH to AMM. A holder of 10,000 EVE exits for all 5 ETH immediately.
4. Remaining NAV is exactly 5 ETH, entirely the supported token; Controller, AMM free balance, and StrategyManager native balance are all zero.
5. The later holder requests 4.999 ETH and is queued. Batch pricing succeeds and records 9,998 EVE to burn.
6. `Controller.processRequest` reverts `ControllerInsufficientBalance`; `StrategyManager.emergencyWithdrawToController` reverts `StrategyManagerNoBalanceToRecover`.
7. Removing support leaves the full token balance on StrategyManager and drops total NAV from 5 ETH to zero.

Pinned offline command:

`FOUNDRY_OUT=/private/tmp/supported-token-liquidity-out FOUNDRY_CACHE_PATH=/private/tmp/supported-token-liquidity-cache /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/SupportedTokenLiquidity.t.sol -vvv`

Attempt 1/3: PASS — 1 passed, 0 failed, 0 skipped. The only warning was sandbox denial when Foundry tried to flush its global signature cache outside the isolated output/cache paths.

## Severity rationale

Medium is appropriate because the intended emergency unwind can strand a material portion of protocol backing and make withdrawals unavailable until a governance upgrade/recovery, while transaction ordering decides which users receive scarce native liquidity. Impact is conditional on supported-token custody and insufficient other withdrawable native assets; there is no permissionless creation of value, no over-redemption beyond reported NAV, and no permanent loss if governance successfully recovers the token. Those constraints keep it below High.

## Recommendation

Do not count a supported ERC20 as immediately redeemable ETH unless StrategyManager has a bounded, oracle/slippage-protected conversion or transfer/recovery path. During emergency custody, either convert before unpausing exits, distribute redemption assets pro rata, or reserve/gate ETH settlements so early callers cannot consume the native portion attributable to later holders. Removal should be paired with an explicit custody recovery and loss-allocation procedure.

AGENT_STATUS: COMPLETE
