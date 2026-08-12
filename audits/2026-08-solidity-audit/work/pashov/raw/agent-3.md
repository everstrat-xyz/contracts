# Agent 3 — Economic/value-flow correctness under unusual inputs

Review target: immutable local snapshot at `734df96a1391e95dd40843210997da0b9f3ab05e`.
Scope discipline: local source, interfaces, mocks, and one isolated harmless regression test only; no network/fork/deployed-system activity.

## Marked review stream

[Feynman: DeployAMM.run] It deploys the strategy accounting module and the mint/redemption contract, records both in the address book, and gives both permission to change EVE supply. Value-flow question: a performance fee is paid by minting supply, whereas entry and exit use the current supply and asset total.
[Inversion: DeployAMM.run] (1) Configure a zero fee and verify harvest is inert; (2) configure the maximum fee and test entry/exit before harvest; (3) give mint permission to AMM but omit it for the fee minter and make sure deployment catches the mismatch.

[Feynman: DeployAll.run] It assembles the full protocol, installs price data, sets operational roles, configures keepers, and removes the deployer's temporary power. Economic knobs include the fee rate, treasury, redemption float, and controller reserve.
[Socratic: script/DeployAll.s.sol — why?] Why can the exit-liquidity and reserve knobs be zero? Because zero intentionally disables the float or reserve, so later automation logic must remain correct at those boundaries.
[Inversion: DeployAll.run] (1) Use zero reserve and zero float; (2) use maximum allowed performance fee; (3) omit a keeper grant and verify final checks prevent an inert value-flow deployment.

[Feynman: ProtocolDeployBase._protocolFeeConfig] It packages the explicit treasury and fee percentage that will govern later dilution.
[Feynman: ProtocolDeployBase._deployKeeperExecutors] It creates two automation relays, registers them, optionally authorizes them, and sets how much ETH is held idle or sent to the AMM.
[Inversion: ProtocolDeployBase._deployKeeperExecutors] (1) Set both policy amounts to zero; (2) set them larger than total assets; (3) set keeper grants false and verify finalization rejects a nonfunctional configuration.

[Feynman: AMM] This contract accepts ETH for newly minted EVE and burns EVE for ETH. Entries pay a premium, exits receive the asset-backed base price, and insufficient immediate ETH creates a queued request. Claim ETH is removed from free assets while it awaits pickup.
[Feynman: AMM.enter] It checks admission and sends the incoming ETH through the shared entry routine.
[Feynman: AMM.enterWithInvite] It first consumes a signed admission voucher and then performs the same deposit.
[Feynman: AMM.exit] It reads current assets and supply, turns the requested ETH into the matching EVE burn amount, and either pays now or escrows the EVE in a redemption batch.
[Socratic: src/contracts/AMM.sol:151-156 — why?] Why is gross NAV divided by current supply without first recognizing an already-accrued dilution fee? The implicit belief is that fee harvesting happens before every economically relevant supply change, but no local call path enforces that belief.
[Inversion: AMM.exit] (1) Exit immediately while the AMM has enough float and a large fee is pending; (2) queue an exit before harvest so its price snapshot is gross of the fee; (3) exit the entire transferable balance immediately and leave the fee to be minted against the remaining supply.
[Feynman: AMM.processRedemption] It closes a queued item; if price protection failed it returns EVE, otherwise it burns EVE and reserves ETH for the user to claim.
[Inversion: AMM.processRedemption] (1) Send exactly the required ETH; (2) send extra ETH and verify the excess returns to Controller; (3) settle a slippage-closed request with value and verify all value is returned.
[Feynman: AMM.cancelRedemption] It removes a still-cancellable queue request and returns its escrowed EVE.
[Feynman: AMM.claim] It zeroes the user's credit, releases the matching locked amount, and sends ETH.
[Feynman: AMM._navInETHPendingTransfer] It removes the current caller's not-yet-owned deposit from the asset reading because that ETH already sits in the AMM during the call.
[Inversion: AMM._navInETHPendingTransfer] (1) Deposit with no pre-existing AMM float; (2) deposit with locked claims; (3) deposit when the AMM also holds donated ETH.
[Feynman: AMM._enter] It prices a post-bootstrap deposit from pre-deposit assets and supply, moves ETH to the Controller, and mints EVE.
[Socratic: src/contracts/AMM.sol:408-412 — why?] Why does entry also use supply/NAV without recognizing pending fee dilution? The same unenforced timing assumption exists, though the connector-weight premium changes who benefits and requires separate economic treatment.
[Inversion: AMM._enter] (1) Enter immediately before a fee harvest; (2) use connector weight 1 and connector weight 0.5; (3) enter after unsolicited NAV arrives but before fee accounting is refreshed.
[Feynman: AMM._bootstrap] It values the first ETH deposit in dollars, locks one EVE forever, gives the rest to the depositor, and forwards ETH to Controller.

[Feynman: Controller] It is the privileged traffic director: it moves idle ETH to and from strategies, sends ETH to the AMM, prices and processes redemption batches, and invokes fee harvests.
[Feynman: Controller.depositToStrategies] It ensures enough ETH is available, tops up StrategyManager, and asks it to split an amount among strategies.
[Feynman: Controller.withdrawFromStrategies] It asks StrategyManager to source ETH from a set of strategies.
[Feynman: Controller.priceBatch] It freezes the current queue batch at the same base price used by immediate exits.
[Feynman: Controller.processRequests] It processes a selected slice of a priced batch.
[Feynman: Controller._processRequest] It computes a request's ETH cost from the frozen price, or zero on excessive downside, then sends that amount through AMM settlement.
[Inversion: Controller._processRequest] (1) Use zero tolerance at the boundary; (2) process a request whose cost exactly equals Controller balance; (3) process a slippage-closed request with an empty Controller.

[Feynman: Converter] It holds caller-supplied tokens while approved adapter code performs a swap in Converter's context, then measures real balance changes and pays/refunds the caller.
[Feynman: Converter.executeSwapExactAmountOut] It pulls the maximum input, executes a swap for an exact output, measures actual input and output, refunds unused input, and transfers the requested output.
[Inversion: Converter.executeSwapExactAmountOut] (1) Make token-in equal token-out; (2) use a fee-on-transfer input; (3) have an adapter consume or create pre-existing balances and verify deltas fail closed.
[Feynman: Converter._executeSwapExactAmountIn] It pulls a fixed input, runs the adapter, measures newly received output, enforces the floor, and returns only that new output.
[Inversion: Converter._executeSwapExactAmountIn] (1) Use zero input; (2) use a token that rebases during the call; (3) use token-in equal token-out and check the before/after measurement.
[Feynman: Converter.wrapETH] It turns the exact incoming ETH into WETH and sends WETH back to the approved strategy.
[Feynman: Converter.unwrapWETH] It pulls WETH from an approved strategy, turns it into ETH, and sends it to a chosen nonzero recipient.

[Feynman: EVE] It is the protocol ownership token. Authorized modules can create supply, destroy their own balance, or destroy an approved holder's balance.
[Inversion: EVE.burnFrom] (1) Burn exactly the allowance; (2) burn more than allowance; (3) burn from a holder after a prior queued escrow transfer.

[Feynman: ExitQueue] It groups one redemption per user into an open batch, freezes a price when the batch closes, and tracks which requests remain to process or can be cancelled.
[Feynman: ExitQueue.pushRequest] It records a user's price, EVE amount, and tolerance in the current unpriced batch.
[Feynman: ExitQueue.priceBatch] It freezes a nonempty batch price, opens it for processing, and creates the next batch.
[Feynman: ExitQueue.pullRequest] It marks one priced request processed, flags excessive price loss, and removes its EVE amount from outstanding totals.
[Feynman: ExitQueue.closeRequest] It cancels an open request, or a priced request after the processing commitment expires, and deletes its record.
[Inversion: ExitQueue.closeRequest] (1) Close immediately before the timeout boundary; (2) close exactly at the boundary; (3) close after the boundary when the batch still has other users.

[Feynman: Oracle] It registers dollar and pair price feeds, rejects stale/nonpositive data, and converts amounts between tokens after normalizing decimal precision.
[Feynman: Oracle.convert] It converts identical assets directly, otherwise prefers a direct pair, then an inverse pair, then a dollar cross-rate.
[Socratic: src/contracts/Oracle.sol — why?] Why does the fallback multiply before division? It preserves one rounding step, but the implied assumption is that protocol-sized normalized amounts do not overflow 256 bits.
[Inversion: Oracle.convert] (1) Use 0-decimal and 18-decimal assets; (2) use values at the normalization boundary; (3) compare direct, inverted, and USD-cross routes for rounding-direction inconsistencies.
[Feynman: Oracle._getPriceWithStalenessCheck] It reads the latest feed answer, ensures a real past timestamp and positive value, rejects excessive age, and scales the price to 18 decimals.
[Inversion: Oracle._getPriceWithStalenessCheck] (1) Set updatedAt to zero; (2) set it one second in the future; (3) use age exactly equal to and one second beyond the allowed interval.

[Feynman: StrategyManager] It owns the strategy list and allocation weights, sums all protocol assets for pricing, moves ETH among strategies, and pays performance fees by diluting EVE supply.
[Feynman: StrategyManager.addStrategy] It registers a code-bearing strategy, stores deposit/withdrawal weights (including zero), and authorizes it to use Converter.
[Inversion: StrategyManager.addStrategy] (1) Register deposit weight zero; (2) register withdrawal weight zero; (3) register both zero while the strategy still advertises capacity and liquidity.
[Feynman: StrategyManager._depositToStrategies] It finds healthy non-cooling strategies, splits the requested ETH in proportion to their nonzero weights and per-strategy caps, and returns anything unused to Controller.
[Inversion: StrategyManager._depositToStrategies] (1) Make all deposit weights zero; (2) let a positive-weight deposit revert after a zero-weight strategy advertises capacity; (3) cap every strategy below its proportional share and observe returned remainder.
[Feynman: StrategyManager._withdrawFromStrategies] It calculates weighted withdrawal requests, recognizes fees for the selected nonzero amounts, attempts each withdrawal, and measures ETH actually arriving at Controller.
[Inversion: StrategyManager._withdrawFromStrategies] (1) Make all withdrawal weights zero despite positive `maxWithdrawal`; (2) make one strategy retain a withdrawal fee; (3) make one withdrawal revert and verify other allocations do not exceed their original shares.
[Feynman: StrategyManager._harvestPerformanceFeesFor] It asks each strategy to crystallize its pending fee, sums successful values, mints EVE once, and attributes the mint among those strategies.
[Feynman: StrategyManager._mintPerformanceFeeEVE] It mints enough EVE that the treasury's new ownership share equals the fee's share of pre-fee assets: fee times supply divided by assets minus fee.
[Socratic: src/contracts/StrategyManager.sol:786-792 — why?] Why is the fee recognized only when an authorized keeper/admin calls harvest? The formula is sound at that instant, but value can enter or leave through public AMM calls beforehand, changing who bears the already-accrued liability.
[Inversion: StrategyManager._mintPerformanceFeeEVE] (1) Harvest before any holder exits; (2) let half the supply exit before harvest; (3) add new supply before harvest and compare fee incidence by cohort.
[Feynman: StrategyManager._totalNAVInETH] It sums reported strategy assets, loose ETH in StrategyManager and Controller, spendable AMM ETH, and whitelisted token balances.
[Inversion: StrategyManager._totalNAVInETH] (1) Add locked claims and confirm they are excluded; (2) add a stale-feed token balance and confirm fail-closed behavior; (3) leave accrued fees unharvested and observe they remain inside gross NAV.

[Feynman: UniswapV3ConverterAdapter] It validates one-pool routes, quotes from a time-averaged pool price checked against Oracle, and executes swaps through the configured router when used by Converter.
[Feynman: UniswapV3ConverterAdapter.quoteExactAmountIn] It computes gross TWAP and oracle outputs, rejects disagreement above two percent, then subtracts the pool fee.
[Feynman: UniswapV3ConverterAdapter.quoteExactAmountOut] It computes gross input from the inverse direction, checks it against Oracle, then increases it enough to cover the pool fee.
[Inversion: UniswapV3ConverterAdapter.quoteExactAmountOut] (1) Use a fee equal to one million; (2) use tiny output where gross-up truncates; (3) use a pool at extreme ticks and compare inverse quotes.
[Socratic: src/contracts/adapters/UniswapV3ConverterAdapter.sol — why?] Why is a fee below the denominator not checked explicitly? The implicit trust is that a factory-supported pool fee is valid; route validation itself checks shape, not fee range.
[Feynman: UniswapV3ConverterAdapter._checkDeviation] It builds a two-percent band around the oracle amount and rejects a TWAP amount outside it.
[Inversion: UniswapV3ConverterAdapter._checkDeviation] (1) Use oracle amount zero; (2) use values that make the upper multiplication overflow; (3) test exact floor and ceiling boundaries.

[Feynman: QueueKeeperExecutor] It scans redemption batches, chooses affordable processing before pricing new work, and advances a cursor past finished or expired batches.
[Feynman: QueueKeeperExecutor._affordableRequests] It walks the first capped set of users and counts the longest prefix whose total ETH cost fits Controller balance.
[Inversion: QueueKeeperExecutor._affordableRequests] (1) Put a zero-cost slippage request before a costly one; (2) make cumulative cost exactly equal budget; (3) make addition approach the numeric limit.

[Feynman: StrategyKeeperExecutor] It chooses one strategy-related upkeep by priority: repair health, source queued redemption ETH, fund immediate exits, invest excess ETH, harvest fees, or refresh strategies.
[Feynman: StrategyKeeperExecutor.checkUpkeep] It observes current state and announces the highest-priority action it believes will materially change state.
[Socratic: src/contracts/automation/StrategyKeeperExecutor.sol:177-180 — why?] Why does any positive `maxWithdrawal` make a withdrawal actionable? The implicit belief is that every withdrawable strategy also has positive withdrawal weight, but StrategyManager explicitly permits zero weights.
[Socratic: src/contracts/automation/StrategyKeeperExecutor.sol:191-194 — why?] Why does advertised capacity alone make a deposit actionable? The implicit belief is that every eligible strategy also has positive deposit weight, again contradicted by the manager's valid zero-weight state.
[Inversion: StrategyKeeperExecutor.checkUpkeep] (1) Give the only deposit-capable strategy weight zero; (2) give the only withdrawable strategy weight zero; (3) combine either state with a lower-priority harvest or sync and see whether it is starved.
[Feynman: StrategyKeeperExecutor.performUpkeep] It recomputes the selected action's conditions, calls Controller, and records the requested amount; for deposits/withdrawals it does not require a positive actual result.
[Inversion: StrategyKeeperExecutor.performUpkeep] (1) Make the controller call return zero; (2) make only an ineligible zero-weight strategy advertise capacity; (3) make the requested withdrawal exceed all weighted capacity.
[Feynman: StrategyKeeperExecutor._totalMaxWithdrawal] It sums every strategy's advertised withdrawable ETH without considering whether batch allocation is allowed to select it.
[Feynman: StrategyKeeperExecutor._depositCapacityAvailable] It reports capacity when any strategy is healthy, out of cooldown, and accepts ETH, without considering whether its allocation weight is zero.

[Feynman: UniCLStrat] It manages a WETH/token concentrated-liquidity position, values it in ETH, swaps inventory toward useful proportions, and tracks LP fees for later EVE dilution.
[Feynman: UniCLStrat.navInETH] It values idle ETH, idle pool tokens, position principal, and already-materialized owed tokens at time-averaged/oracle-backed prices.
[Feynman: UniCLStrat.deposit] It accepts StrategyManager ETH, checks the post-receipt cap, wraps it, removes old liquidity, balances inventory, and remints positions.
[Inversion: UniCLStrat.deposit] (1) Call with exactly advertised max deposit; (2) receive unsolicited ETH immediately before deposit; (3) let price move from calm to non-calm around the operation.
[Feynman: UniCLStrat.withdraw] It pays idle ETH first, otherwise removes liquidity, swaps paired inventory for missing WETH, unwraps what is available, sends the actual amount, and optionally reinvests leftovers.
[Inversion: UniCLStrat.withdraw] (1) Request exactly `maxWithdrawal`; (2) make swap output insufficient so the function returns less than requested; (3) use an ETH receiver that rejects payment.
[Socratic: src/contracts/strategies/UniCLStrat.sol — why?] Why may `withdraw(maxWithdrawal())` return less than the advertised maximum? The interface describes maxWithdrawal as available ETH but the implementation intentionally caps payout by realizable WETH after swap; this is a compatibility smell, but no direct user call relies on an exact-return guarantee because StrategyManager measures actual receipts.
[Feynman: UniCLStrat.pendingPerformanceFeeInETH] It values already-materialized but uncharged LP fees and applies the global fee percentage; unpoked growth remains invisible.
[Feynman: UniCLStrat.settlePerformanceFee] It moves materialized fee growth into durable counters, computes the ETH fee, preserves rounding dust, and marks the entire fee base charged once the fee is nonzero.
[Inversion: UniCLStrat.settlePerformanceFee] (1) Set fee base just below one-wei fee; (2) accrue one token leg while the other feed is stale; (3) settle before and after a public AMM exit.
[Feynman: UniCLStrat._balanceInventory] It compares each token's ETH value and swaps half the imbalance from the richer side to the poorer side.
[Inversion: UniCLStrat._balanceInventory] (1) Make oracle conversion round a small imbalance to zero; (2) use a low-decimal paired token; (3) leave one side at one unit and the other at zero.
[Feynman: UniCLStrat._swapViaRouteExactAmountOut] It quotes the exact output, checks the quoted input against Oracle, adds slippage headroom, and either executes exact output or spends the entire available input as a fallback.
[Inversion: UniCLStrat._swapViaRouteExactAmountOut] (1) Make padded input equal the balance; (2) make it one unit above balance; (3) make the balance zero and confirm the fallback has no effect rather than fabricating output.

## Confirmed items

FINDING | contract: AMM / StrategyManager | function: exit / _mintPerformanceFeeEVE | bug_class: uncrystallized-fee-liability-escape | group_key: AMM | exit | uncrystallized-fee-liability-escape
path: any EVE holder with allowance → `AMM.exit` reads gross `StrategyManager.totalNAVInETH()` and current EVE supply → immediate path burns the holder's EVE and pays gross NAV value → later keeper/admin calls `Controller.harvestPerformanceFeeFromStrategies` → StrategyManager mints the previously accrued fee only against the reduced remaining supply → the exiting holder avoids its pro-rata share and remaining holders bear it
proof: isolated test `test_ExitBeforeHarvestAvoidsAccruedPerformanceFee` bootstraps 100 ETH at connector weight 1, places 50 ETH in a strategy and 50 ETH in AMM free liquidity, and creates 50 ETH of already-accrued fee base at 20%, i.e. 10 ETH pending. A holder of approximately half the supply exits before harvest. `exit` pays approximately 50 ETH from gross NAV; valuing the same burned share after the 10 ETH liability gives approximately 45 ETH, so about 5 ETH of fee burden is avoided/shifted. Harvest immediately afterward still mints EVE to the DAO, proving the obligation existed rather than being globally waived. Local test passed.
description: Public exits can settle against NAV that still includes already-accrued protocol fees, allowing exiting holders to externalize their share of the fee onto holders who remain until harvest.
fix: Crystallize all pending strategy fees before any AMM supply-changing price snapshot (both exit/batch pricing and entry), or make NAV/supply pricing continuously fee-aware by subtracting pending fee liabilities and using the corresponding effective diluted supply.

FINDING | contract: StrategyKeeperExecutor | function: _depositCapacityAvailable | bug_class: zero-weight-noop-upkeep | group_key: StrategyKeeperExecutor | _depositCapacityAvailable | zero-weight-noop-upkeep
path: valid admin configuration sets the only healthy strategy's `depositWeight` to 0 → Controller holds at least `minDepositETH` excess → `checkUpkeep` sees `maxDeposit() > 0` and announces `DepositExcess` → `performUpkeep` calls Controller/StrategyManager → StrategyManager finds cumulative deposit weight 0 and returns all ETH to Controller → unchanged state makes the same high-priority upkeep recur and lower-priority fee harvest/sync can be starved
proof: isolated test `test_DepositUpkeepRepeatsWhenOnlyCapacityHasZeroDepositWeight` bootstraps 10 ETH into Controller, registers one healthy unlimited-capacity strategy with deposit weight 0, and calls the forwarder path. The upkeep succeeds, deposits 0 ETH, Controller remains at 10 ETH, and the immediately repeated `checkUpkeep` returns `DepositExcess` again. Each cycle spends automation gas without changing value allocation. Local test passed.
description: The keeper counts zero-deposit-weight strategies as actionable capacity although StrategyManager deliberately allocates them nothing, producing a perpetual successful no-op.
fix: Require `strategyManager.depositWeight(strategy) > 0` inside `_depositCapacityAvailable`, and optionally reject/skip execution when Controller reports zero actually deposited.

FINDING | contract: StrategyKeeperExecutor | function: _totalMaxWithdrawal | bug_class: zero-weight-noop-upkeep | group_key: StrategyKeeperExecutor | _totalMaxWithdrawal | zero-weight-noop-upkeep
path: valid admin configuration sets the only funded strategy's `withdrawalWeight` to 0 → a priced redemption needs ETH while Controller is empty → `checkUpkeep` sums the strategy's positive `maxWithdrawal()` and announces `WithdrawShortfall` → `performUpkeep` calls batch withdrawal → StrategyManager sees cumulative withdrawal weight 0 and returns 0 → shortfall and queue state are unchanged, so the same action recurs and redemption processing remains unfunded
proof: isolated test `test_WithdrawalUpkeepRepeatsWhenOnlyLiquidityHasZeroWithdrawalWeight` invests 10 ETH into one strategy configured with withdrawal weight 0, queues/prices a 1 ETH redemption, and leaves Controller at 0. The keeper reports and successfully performs `WithdrawShortfall`, but Controller remains at 0; the next `checkUpkeep` reports the identical action again. Local test passed.
description: The keeper treats liquidity in zero-withdrawal-weight strategies as available to its batch withdrawal even though StrategyManager is configured never to source from them.
fix: Sum only strategies with `withdrawalWeight(strategy) > 0`, and optionally require a positive actual withdrawal before treating the upkeep as successful.

## Leads

LEAD | contract: AMM / StrategyManager | function: _enter / _mintPerformanceFeeEVE | bug_class: uncrystallized-fee-cohort-misattribution | group_key: AMM | _enter | uncrystallized-fee-cohort-misattribution
code_smells: Entry uses gross NAV/current supply while pending performance fees are crystallized later from then-current supply; new entrants can therefore participate in dilution for gains accrued before they joined. The exact transfer between old and new cohorts depends on connector weight/premium and was not separately proven in the single allowed candidate file beyond the confirmed exit mechanism.
description: Pending fee timing appears to misattribute pre-entry fee liabilities to later entrants, but the net economic beneficiary across connector-weight configurations remains unverified.

LEAD | contract: UniCLStrat | function: maxWithdrawal / withdraw | bug_class: advertised-liquidity-mismatch | group_key: UniCLStrat | maxWithdrawal | advertised-liquidity-mismatch
code_smells: `maxWithdrawal()` reports oracle-valued NAV, while `withdraw(maxWithdrawal())` expressly permits returning less when real swap proceeds/WETH are insufficient; the manager tolerates partial receipts, so no direct local loss path was established.
description: The query/execution values can diverge under slippage or rounding, but the current trusted-strategy manager path measures actual ETH and prevents promotion without an affected guarantee or downstream invariant.

## Regression evidence

Candidate: `test/audit/candidates/pashov/Agent03.t.sol`
Command: `FOUNDRY_OUT=out-pashov-agent-03 FOUNDRY_CACHE_PATH=cache-pashov-agent-03 forge test --match-path test/audit/candidates/pashov/Agent03.t.sol`
Result: 3 passed, 0 failed, 0 skipped. Solc 0.8.30 compilation succeeded. Foundry emitted a non-test warning that its global signature cache was not writable; the isolated suite itself completed successfully.

## CLEARED_AREAS

- AMM incoming-ETH exclusion: `_navInETHPendingTransfer` correctly removes `msg.value` that is already visible through AMM free balance.
- Immediate and queued redemption arithmetic: both use the base NAV price; rounding re-computes ETH from the actual burn amount and favors retained protocol dust.
- Claim locking: `lockedForClaims` is excluded from free balance/NAV and reduced before external payment under reentrancy protection.
- ExitQueue batch totals and cancellation: push/pull/close consistently add/subtract the stored token amount; the three-day boundary is consistent between close eligibility and keeper skippability (`>` after the inclusive commitment window).
- Controller withdrawal accounting: it uses Controller balance deltas rather than trusting strategy return values.
- Converter output/refund accounting: exact-input and exact-output use observed token balance deltas and enforce minimum/maximum bounds; no confirmed unusual-token extraction path within the configured standard WETH/pair-token assumptions.
- Oracle feed validation: rejects zero feeds, zero staleness, future timestamps, stale/nonpositive answers, and feed decimals over 18; no concrete in-scope ordinary-value conversion loss was confirmed.
- StrategyManager allocation arithmetic: zero weights intentionally allocate zero, positive weights are normalized over eligible strategies, and unused ETH returns to Controller. The defect is the keeper's inconsistent readiness predicate, not these allocation routines.
- StrategyManager withdrawal fee harvest ordering: selected positive withdrawal amounts are harvested before withdrawals and actual receipts are balance-measured.
- Fee mint formula itself: `fee * supply / (NAV - fee)` produces the intended treasury fraction when invoked before supply/value cohorts change; the confirmed issue is crystallization timing.
- UniCLStrat deposit cap: execution checks post-receipt NAV and accepts the advertised remaining capacity without double-counting the incoming transfer.
- UniCLStrat fee dust: zero-rounded fee does not advance charged counters, so dust remains feeable.
- UniCLStrat emergency token transfer: native ETH is sent first and paired-token transfer is best effort; failed token behavior does not roll back the ETH sweep.
- Uniswap adapter quote structure: TWAP/oracle comparison is gross of pool fee and execution quotes apply fee afterward; no concrete configured-route value loss was confirmed.
- Queue keeper affordability: cost logic mirrors Controller slippage behavior and accepts the exact-balance boundary.

AGENT_STATUS: COMPLETE — full 9,593-line bundle read; 3 confirmed local correctness defects, 2 leads, and cleared areas recorded; one isolated candidate suite added and all 3 tests pass; production source unchanged; no commit.
