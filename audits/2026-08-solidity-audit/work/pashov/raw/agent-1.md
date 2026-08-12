# Pashov Agent 1 — math / precision working log

Bundle read: `agent-1-bundle.md`, lines 1–9606, in order and in full. Review is limited to the immutable local snapshot. No network, wallet, deployed-contract, or third-party access was used.

## Continuous mental-tool log

[Feynman: DeployAMM.run] This builds the strategy manager and entry/exit market, records both addresses, and gives both components permission to create or destroy protocol tokens.

[Inversion: DeployAMM.run] Try a zero treasury, a fee above the manager's limit, and a registry whose expected keys are already occupied; construction or the explicit post-checks reject each path.

[Feynman: DeployAll.run] This creates the full protocol, joins every component through one address book, sets governance and emergency permissions, configures the first price source, and removes the deployer's temporary power.

[Feynman: DeployAll._toDeploymentResult] This packages the deployed addresses and reads each replaceable component's implementation address for reporting.

[Feynman: DeployAll._verifyDeployment] This checks that every deployed component points at the same registry, has its required permissions, and can resolve the first ETH price feed.

[Feynman: DeployController.run] This creates the controller, records it under the controller key, and checks that both sides of the relationship agree.

[Feynman: DeployConverter.run] This creates the swap coordinator, records it, and gives it authority to manage which strategies may use conversion services.

[Feynman: DeployEVE.run] This creates the protocol share token and records its address.

[Feynman: DeployExitQueue.run] This creates the queued-redemption book and records its address.

[Feynman: DeployKeeperExecutors.run] This creates the two automation workers, optionally grants their operating permission, and applies liquidity policy values.

[Feynman: DeployOracle.run] This creates the price service, records it, and installs the initial ETH-to-USD source.

[Feynman: DeployRegistry.run] This creates delayed governance and the central address-and-permission book while leaving the deployer only temporary setup power.

[Feynman: DeployUniCLStrat.run] This reads pool, route, range, time-window, and cap settings, creates one concentrated-liquidity strategy, and deliberately leaves registration for delayed governance.

[Feynman: DeployUniCLStrat._deploymentConfig] This narrows environment numbers into the strategy's smaller integer fields and assembles them into one creation record.

[Socratic: DeployUniCLStrat._deploymentConfig — why?] Why are large environment integers narrowed before checking their original range? The code assumes operators never supply values outside the destination type, so high bits can be discarded before validation.

[Feynman: DeployUniswapV3ConverterAdapter.run] This creates the price-and-swap adapter using a router, factory, oracle, WETH address, and averaging window, then checks the stored immutable choices.

[Socratic: DeployUniswapV3ConverterAdapter.run — why?] Why is the averaging window converted to 32 bits before its lower-bound check? The implicit belief is that an environment value already fits 32 bits.

[Feynman: DeployWhitelist.run] This creates the invitation gate, records it, and optionally installs its first signing address.

[Feynman: FinalizeProtocolDeploy.run] This removes the deployer's setup authority only after checking that every critical production permission exists.

[Feynman: ProtocolDeployBase._deployProtocolInstances] This creates the registry and every core component against it, including the fixed share token, the replaceable modules, and the entry/exit market.

[Feynman: ProtocolDeployBase._registerProtocolContracts] This assigns each component address to its canonical registry key in one batch.

[Feynman: ProtocolDeployBase._protocolFeeConfig] This turns the configured treasury and basis-point rate into the manager's fee settings.

[Feynman: ProtocolDeployBase._assertUsdQuotedFeed] This rejects a deployment price source unless its human-readable label ends in “ / USD”.

[Feynman: ProtocolDeployBase._deployKeeperExecutors] This creates both automation workers, records and optionally authorizes them, then sets the controller reserve and immediate-exit target.

[Feynman: ProtocolDeployBase._deployTimelock] This creates delayed governance with one proposer, open execution after the delay, emergency cancellation, and no lasting deployer control.

[Feynman: ProtocolDeployBase._grantTieredProtocolRoles] This assigns administrative, emergency, minting, and converter-management permissions to the intended components.

[Feynman: ProtocolDeployBase._verifyCriticalRoleGrants] This proves that all required components are registered and hold the permissions needed for minting, swaps, and automation.

[Inversion: ProtocolDeployBase deployment verification] Try omitting a component, granting a permission to the wrong address, and retaining deployer authority; registry lookups or explicit checks fail each case.

[Feynman: AMM] This is the user-facing share market: users pay ETH to receive EVE, burn EVE for backed ETH, queue redemptions when immediate cash is short, and later claim processed ETH.

[Feynman: AMM.enter] This lets an admitted user exchange incoming ETH for newly created EVE while the market is active.

[Feynman: AMM.enterWithInvite] This first consumes a valid invitation for the caller and then performs the same ETH-for-EVE exchange.

[Feynman: AMM.exit] This computes how many EVE correspond to requested ETH at current backing value, burns immediately when free ETH is available, or holds the shares in a priced queue otherwise.

[Socratic: AMM.exit — why?] Why convert requested ETH to shares and then shares back to ETH? The second conversion deliberately removes any fraction not backed by the integer number of shares actually burned, so rounding favors remaining holders.

[Inversion: AMM.exit] Request 1 wei, request just below one share unit, and request with 100% tolerance; zero-share requests revert, double conversion never overpays, and full tolerance only disables slippage closure as intended.

[Feynman: AMM.processRedemption] This closes one queued request, returns shares if its price protection failed, or burns them and records claimable ETH if it passed.

[Feynman: AMM._basePriceFromNAV] This divides total backed ETH by all outstanding EVE to get the redemption value of one normalized share.

[Feynman: AMM._premiumPriceFromNAV] This prices new shares above backing value according to the connector weight, so entry transfers a premium to existing holders.

[Feynman: AMM._navInETHPendingTransfer] This removes the caller's just-arrived ETH from the system-value reading so a depositor cannot make their own purchase price rise before minting.

[Inversion: AMM._navInETHPendingTransfer] Force ETH into the market first, enter with zero ETH, and make the strategy value smaller than the current payment; forced ETH is legitimate backing, zero entry fails its minimum output, and the last state fails closed.

[Feynman: AMM._bootstrap] This values the first ETH deposit in USD, locks one EVE forever, gives the rest to the first depositor, and forwards the ETH to the controller.

[Feynman: AMM._freeBalance] This subtracts ETH already promised to claimants from the market's cash available for new immediate exits.

[Feynman: Controller] This component moves idle ETH between the market and strategies, asks strategies to maintain themselves, and processes queued redemptions.

[Feynman: Controller.provideExitLiquidity] This sends a requested amount of idle controller ETH to the market's immediate-redemption pool.

[Feynman: Controller.depositToStrategies] This ensures the strategy manager has the requested amount and asks it to distribute that amount across a chosen range or all strategies.

[Feynman: Controller.withdrawFromStrategies] This asks a chosen range or all strategies to return ETH and records how much actually arrived.

[Feynman: Controller.harvestPerformanceFeeFromStrategies] This asks the manager to settle earned fees and reports the EVE created for the treasury.

[Feynman: Controller.priceBatch] This fixes the current queued batch's redemption price at the same backed-share value used for immediate exits.

[Feynman: Controller._processRequest] This treats an out-of-tolerance request as costing zero; otherwise it computes the exact ETH owed, checks available cash, and pays the market for later user claim.

[Inversion: Controller._processRequest] Compare the tolerance calculation used here with the queue, compare the ETH conversion with the market, and process a zero-cost slippage closure; both contracts use the same formulas and the zero-cost path returns the user's shares.

[Feynman: Converter] This component receives tokens from an authorized strategy, runs approved swap code in its own balance context, measures what really moved, and returns outputs and refunds.

[Feynman: Converter.executeSwapExactAmountIn] This pulls a fixed input, runs the chosen approved route, measures output gained, enforces the user's minimum, and pays that measured output back.

[Feynman: Converter.executeSwapExactAmountOut] This pulls the maximum input, runs the route for a fixed output, measures input spent and output gained, refunds unused input, and returns exactly the requested output.

[Inversion: Converter.executeSwapExactAmountOut] Have an adapter lie about input, lie about output, and spend a pre-existing converter balance; measured balance changes, the maximum-input check, and the output-delta check prevent those reports from funding an overpayment.

[Feynman: Converter._dispatchSwap] This runs one approved adapter's swap instructions and rejects failure or a malformed single-number response.

[Feynman: Converter._executeSwapExactAmountIn] This is the shared fixed-input implementation used by the public entry point.

[Feynman: Converter._quoteSwapExactAmountIn] This asks the adapter for a fixed-input estimate and replaces any adapter failure with a converter-specific failure.

[Feynman: Converter._quoteSwapExactAmountOut] This asks the adapter for the estimated input needed to receive a fixed output.

[Feynman: Converter._validateRoute] This asks the adapter whether route bytes are meaningful and rejects both a negative answer and an adapter failure.

[Feynman: EVE] This is the transferable protocol share whose supply can change only at authorized protocol components.

[Feynman: EVE.mint] This creates shares for a chosen recipient when called by an approved minter.

[Feynman: EVE.burnFrom] This consumes the owner's allowance and destroys that owner's shares for an approved minter.

[Feynman: ExitQueue] This groups illiquid redemption requests, fixes one price per batch, tracks unprocessed users, and provides a timeout escape.

[Feynman: ExitQueue.priceBatch] This records the batch's final EVE price, marks it processable, and opens a fresh batch.

[Feynman: ExitQueue.pushRequest] This records one user's shares, request-time price, and tolerance in the current unpriced batch.

[Feynman: ExitQueue.pullRequest] This removes one processable request, marking it as a slippage closure when the final price is too low.

[Feynman: ExitQueue.closeRequest] This lets a request leave before pricing or after the processing commitment has expired and removes its shares from batch totals.

[Inversion: ExitQueue price/close boundary] Close exactly at three days, just after three days, and while a batch remains unpriced; the strict boundary matches the keeper's skip rule and unpriced requests remain cancellable.

[Feynman: Oracle] This stores USD and optional pair price sources, checks freshness and positivity, normalizes them to 18 decimals, and converts amounts between token units.

[Feynman: Oracle.convertTokenToUSD] This first expresses a token amount with 18 decimals and then multiplies it by that token's normalized USD price.

[Feynman: Oracle.convertUsdToToken] This divides normalized USD by the token's normalized USD price and then changes the result to the requested token precision.

[Feynman: Oracle.convert] This uses a direct pair price if present, otherwise an inverse pair price, otherwise the ratio of the two USD prices, and finally emits the requested output precision.

[Socratic: Oracle.convert — why?] Why multiply normalized input by the input price before dividing by the output price? It preserves a single rounding step, but assumes the intermediate product fits in 256 bits.

[Inversion: Oracle.convert] Convert one smallest unit, convert between 6 and 18 decimals, and submit an amount large enough to overflow the intermediate product; the first two round down consistently, while the last remains an unbounded arithmetic smell recorded as a lead.

[Feynman: Oracle._getPriceWithStalenessCheck] This reads the latest answer, rejects missing, non-positive, future, or old data, and expands the answer to 18 decimals.

[Feynman: Oracle._upsertFeed] This validates a price source and freshness window, adds a new record or changes only the fields that differ.

[Feynman: Oracle._clearInboundPairs] This visits every supported token and removes any pair whose output is the token being removed.

[Feynman: StrategyManager] This owns the strategy list and weights, totals all protocol value, allocates deposits and withdrawals, and converts settled strategy earnings into treasury EVE.

[Feynman: StrategyManager.addStrategy] This records a checked strategy, assigns its two weights, and gives it permission to use the converter.

[Feynman: StrategyManager.removeStrategy] This removes a strategy only when its reported remaining value is at most ten wei.

[Feynman: StrategyManager.forceRemoveStrategy] This records whatever value can be read and removes even a broken or over-reporting strategy through delayed governance.

[Feynman: StrategyManager._totalNAVInETH] This totals every strategy's reported ETH value plus loose ETH in the manager and controller, free market ETH, and priced supported-token balances.

[Socratic: StrategyManager._totalNAVInETH — why?] Why is every strategy report treated as immediately complete economic value? The calculation assumes each strategy view includes value that has accrued but has not yet been written into the pool position.

[Inversion: StrategyManager._totalNAVInETH] Add loose ETH during an entry, donate a supported token, and accrue pool fees without touching the position; loose ETH and supported tokens are counted, but untouched pool fee growth is omitted until a later poke.

[Feynman: StrategyManager._depositToStrategies] This finds healthy capacity, divides the requested ETH by configured weights, deposits each nonzero part, and returns anything unplaced to the controller.

[Feynman: StrategyManager._withdrawFromStrategies] This divides a requested withdrawal by eligible weights, first settles fees for involved strategies, then measures the ETH actually returned by each successful withdrawal.

[Feynman: StrategyManager._harvestPerformanceFeesFor] This asks each chosen strategy to settle its fee, sums the successful ETH amounts, creates treasury EVE once, and attributes the EVE across strategies for events.

[Feynman: StrategyManager._mintPerformanceFeeEVE] This creates enough treasury shares that their post-creation fraction of total backing equals the settled ETH fee.

[Socratic: StrategyManager._mintPerformanceFeeEVE — why?] Why divide by total value minus the fee? Solving `newShares / (oldShares + newShares) * totalValue = fee` gives exactly that denominator, so the algebra is sound when the fee is crystallized at the same ownership snapshot.

[Inversion: StrategyManager._mintPerformanceFeeEVE] Use a fee equal to NAV, use a one-wei fee at a very high share price, and use operands whose product exceeds 256 bits; equality reverts, the one-wei fee can mint zero, and the large product remains an unproven reachability lead.

[Feynman: StrategyManager.pendingPerformanceFeeInETH] This asks one registered strategy how much of its recognized earnings would currently belong to the treasury.

[Feynman: StrategyManager._supportedERC20sNAVInETH] This skips empty supported-token balances and converts every nonempty balance to ETH before adding it to total value.

[Feynman: StrategyManager._setDepositWeight] This accepts a weight from zero through one hundred and records it for later proportional allocation.

[Feynman: StrategyManager._isStrategyInDepositCooldown] This blocks deposits until the configured number of seconds has passed since the strategy's last successful withdrawal.

[Feynman: Whitelist] This admits users by administrator action or one-time signed invitations and can irreversibly open entry to everyone.

[Feynman: Whitelist.whitelist] This verifies that an unused, unexpired invitation names the user and comes from an approved signer, then consumes it and admits that user.

[Inversion: Whitelist.whitelist] Replay an invitation, relay it before its owner, and replay it after a ban; reuse is blocked, relaying only admits the named user, and a ban takes precedence.

[Feynman: UniswapV3ConverterAdapter] This estimates a one-pool swap from an averaged pool price, compares that estimate to independent prices, applies the pool fee, and performs approved router swaps when called through the converter.

[Feynman: UniswapV3ConverterAdapter.quoteExactAmountIn] This finds the gross averaged-price output for a fixed input, compares it with the oracle, and then removes the input-side pool fee from the estimate.

[Feynman: UniswapV3ConverterAdapter.quoteExactAmountOut] This finds the averaged-price input corresponding to the desired output, compares it with the oracle, and increases it for the pool fee.

[Socratic: UniswapV3ConverterAdapter.quoteExactAmountOut — why?] Why does a maximum/required input use ordinary floor division? Exact-output execution must have at least enough input, so both the inverse-price step and fee gross-up need upward rounding.

[Inversion: UniswapV3ConverterAdapter.quoteExactAmountOut] Ask for 1 output unit at a 1:1 price, ask for 99 units with a 0.3% fee, and use the returned quote as the strategy's maximum; each small request exposes that flooring can leave less net input than the output requires.

[Feynman: UniswapV3ConverterAdapter._quoteAtTick] This converts a token amount at a pool tick with a full-width multiply-and-divide routine, choosing the price or reciprocal according to token order.

[Feynman: UniswapV3ConverterAdapter._checkDeviation] This builds a two-percent band around the independent estimate and rejects an averaged-pool estimate outside it.

[Inversion: UniswapV3ConverterAdapter._checkDeviation] Compare one-unit outputs, a zero oracle result, and a huge result whose band multiplication overflows; dust bands lose resolution, equal zero passes only zero, and huge arithmetic remains a reachability lead.

[Feynman: QueueKeeperExecutor] This chooses whether to process an affordable queued prefix, price an old live batch, or advance past dead batches.

[Feynman: QueueKeeperExecutor._affordableRequests] This walks the first bounded set of queued users and counts the longest prefix whose settlement cost fits controller cash.

[Inversion: QueueKeeperExecutor._affordableRequests] Put a zero-cost slippage closure first, put an unaffordable request first, and compare its cost with the controller's cost; zero-cost users advance, the prefix stops at the first unaffordable request, and the same conversion is used downstream.

[Feynman: StrategyKeeperExecutor] This prioritizes unhealthy positions, redemption funding, immediate-exit cash, investing excess cash, fee collection, and periodic synchronization.

[Feynman: StrategyKeeperExecutor._pendingRedemptionNeedsETH] This estimates priced redemption costs from the live queue cursor and current unpriced shares, within bounded batch and user windows.

[Feynman: StrategyKeeperExecutor._pendingPerformanceFeeETH] This sums each strategy's currently visible fee liability and returns zero when fees are disabled.

[Feynman: StrategyKeeperExecutor.performUpkeep] This recomputes the selected action from current state and then calls the controller with amounts derived on chain rather than trusting supplied numbers.

[Socratic: StrategyKeeperExecutor.performUpkeep Sync — why?] Why does synchronization and fee harvest require separate automation actions? The priority machine performs only one action per call, creating a public state interval after fees become visible but before treasury shares are created.

[Inversion: StrategyKeeperExecutor Sync/Harvest order] Enter just before sync, exit just after sync, and keep another higher-priority action continuously available; the first two move across a discontinuous NAV/fee snapshot and the third can delay crystallization further.

[Feynman: Registry] This is the central list of component addresses and permission holders, with emergency freezing of mutations.

[Feynman: Registry.grantRoles] This checks equal list lengths and the caller's authority for every requested permission before recording each holder.

[Feynman: Registry._registerContract] This rejects empty or code-less destinations and records a new or replacement address under a key.

[Feynman: UniCLStrat] This holds WETH and a paired token in two concentrated-liquidity ranges, values them in ETH, balances inventory through the converter, and tracks fee earnings for performance charges.

[Feynman: UniCLStrat.navInETH] This adds loose ETH to the ETH value of idle tokens, withdrawable position principal, and the pool's already-recorded owed tokens, all valued using the long averaged price and oracle.

[Socratic: UniCLStrat.navInETH — why?] Why are `tokensOwed` treated as all earned fees? A Uniswap position writes new fee growth into `tokensOwed` only when the position is touched, so untouched earnings are economically owned but absent from this view.

[Inversion: UniCLStrat.navInETH] Accrue fees without touching the position, read NAV, then call `sync` and read again; the local regression suite itself expects the second reading to increase, proving the first reading was stale rather than merely rounded.

[Feynman: UniCLStrat.maxDeposit] This reports the gap between the strategy's visible value and its configured cap, unless the strategy is paused or the market is not calm.

[Feynman: UniCLStrat.deposit] This accepts manager ETH, checks calmness and the post-payment cap, wraps the ETH, realizes old position balances and fees, balances inventory, chooses ranges, and adds liquidity.

[Feynman: UniCLStrat.withdraw] This pays idle ETH first, otherwise removes liquidity, buys the missing WETH, unwraps only what is needed, pays the receiver, and redeploys leftovers when calm.

[Feynman: UniCLStrat.sync] This touches both pool positions with zero liquidity so the pool records newly earned fees without collecting them.

[Feynman: UniCLStrat.pendingPerformanceFeeInETH] This applies the configured rate to recognized but uncharged LP fees and returns zero while paused.

[Feynman: UniCLStrat.settlePerformanceFee] This makes recognized owed-token growth durable, values all uncharged fee tokens, returns the treasury's ETH share, and marks those token amounts charged unless the ETH result rounds to zero.

[Inversion: UniCLStrat.settlePerformanceFee] Settle before a poke, settle after a poke, and settle a fee base below the one-wei threshold; the first sees zero, the second creates a liability, and the third deliberately preserves dust.

[Feynman: UniCLStrat._balancesOfPool] This values the two stored ranges at the long averaged price and adds their token amounts together.

[Feynman: UniCLStrat._amountsForPosition] This reads current liquidity and already-recorded owed tokens, calculates principal amounts at the chosen price, and adds recorded fees.

[Feynman: UniCLStrat._removeLiquidityAndCollect] This first makes new fees visible, records them as earned, removes principal, collects everything, and resets the owed-token snapshots.

[Feynman: UniCLStrat._unchargedLpFeeAmounts] This combines durable earned counters with owed-token growth since the last snapshot and subtracts token amounts already charged.

[Feynman: UniCLStrat._balanceInventory] This compares WETH and paired-token values and swaps half of the value imbalance toward the scarcer side.

[Feynman: UniCLStrat._swapViaRouteExactAmountIn] This obtains a route estimate, bounds it against independent value, reduces it by allowed slippage, and swaps a fixed input.

[Feynman: UniCLStrat._swapViaRouteExactAmountOut] This obtains the estimated input for a fixed output, bounds and pads it, falls back to spending all available input if unaffordable, or otherwise executes with the padded maximum.

[Socratic: UniCLStrat._swapViaRouteExactAmountOut — why?] Why is the padded maximum rounded down? A maximum meant to tolerate price movement should be rounded up; for small values the one-percent padding itself disappears.

[Feynman: UniCLStrat._tokenValueInETH] This treats WETH units as ETH units and otherwise asks the oracle for one direct token-to-ETH conversion.

[Feynman: UniCLStrat._ethValueToTokenAmount] This treats WETH one-for-one and otherwise asks the oracle to express ETH value in the paired token's smallest units.

[Feynman: Math.convertDecimals] This multiplies or divides by a power of ten to move an amount between precisions no greater than 18 decimals.

[Feynman: Math.convertAssets] This multiplies an 18-decimal amount by an 18-decimal price and removes one 18-decimal scale factor.

[Feynman: Math.convertAssetsInverse] This multiplies an 18-decimal value by the scale factor and divides by an 18-decimal asset price.

[Feynman: Math.basePrice] This divides total normalized backing by normalized share supply and returns an 18-decimal price.

[Feynman: Math.premiumPrice] This first reduces effective supply by connector weight and then divides backing by that adjusted supply.

[Feynman: Math.isRelativelyLessThan] This compares two values after applying the accepted relative loss to the reference value without performing a division.

[Socratic: Math fixed-point helpers — why?] Why do all multiply-then-divide helpers use a 256-bit intermediate when the repository already contains a full-width multiply-and-divide routine? The implementation assumes economically reachable operands make every intermediate fit.

[Feynman: FullMath.mulDiv] This computes a floor of a multiplication divided by a denominator even when the multiplication needs twice the normal width.

[Feynman: LiquidityAmounts] These routines translate token amounts and price-range boundaries into liquidity and translate liquidity back into token amounts using full-width products.

[Feynman: TickUtils.meanTickFromCumulatives] This divides cumulative tick movement by elapsed seconds and rounds negative non-integers downward to match the pool's price convention.

[Inversion: TickUtils.meanTickFromCumulatives] Use positive remainder, negative remainder, and an exact negative quotient; only the negative remainder subtracts one, matching mathematical floor.

## Confirmed review items

FINDING | contract: UniCLStrat | function: navInETH | bug_class: stale-nav-underpricing | group_key: UniCLStrat | navInETH | stale-nav-underpricing
path: whitelisted user times `AMM.enter` before a routine strategy `sync` → `AMM._premiumPriceFromNAV` reads `StrategyManager.totalNAVInETH` → `UniCLStrat.navInETH` includes position principal and stored `tokensOwed` but omits fee growth not yet materialized by `burn(..., 0)` → user receives too many EVE → keeper calls `Controller.syncStrategy`/`syncStrategies`, which makes the omitted fees appear in NAV → user immediately calls `AMM.exit` against sufficient free AMM liquidity → value belonging to prior holders is redeemed by the new shares
proof: Let visible NAV be 100 ETH (80 ETH position principal plus 20 ETH AMM free balance), unpoked but economically earned LP fees be 10 ETH, EVE supply be 100 EVE, connector weight be the allowed value 1e18, and the user's deposit be 10 ETH. Before the poke, `navInETH()` reports 100 ETH and entry price is `100 / (100 * 1) = 1 ETH/EVE`, so the user receives 10 EVE; correct pricing against 110 ETH of owned value would mint only `10 * 100 / 110 = 9.0909 EVE`. After `sync()` writes the 10 ETH fees into `tokensOwed`, NAV is 120 ETH (100 visible + 10 deposit + 10 fees), supply is 110 EVE, and base price floors to 1.090909090909090909 ETH/EVE. Burning the user's 10 EVE returns 10.909090909090909090 ETH, a 0.909090909090909090 ETH gain funded by old holders. The mechanism also overmints under the default 0.5 connector weight; it becomes directly round-trip profitable once hidden fees exceed visible NAV—for example N=100 ETH, H=110 ETH, deposit=10 ETH mints 5 EVE and later redeems 10.476190476190476190 ETH. The included local test `test_Sync_PokesAccruedFeesIntoPosition` independently establishes the key state discontinuity by asserting `navInETH()` increases after a zero-liquidity poke with no token transfer.
description: `navInETH()` treats stored `tokensOwed` as complete LP earnings even though untouched Uniswap V3 fee growth is owned by the strategy but absent until a later position poke.
consequence: Users can enter against understated backing and redeem after synchronization, diluting incumbent EVE holders; stale NAV can also understate `maxTotalNAV` usage.
fix: Include live fee growth in `navInETH()` by deriving each position's pending fees from global/outside fee-growth accumulators, rather than relying on a later state-changing poke (a mere periodic sync does not make share pricing atomic).

FINDING | contract: AMM | function: exit | bug_class: uncrystallized-performance-fee | group_key: AMM | exit | uncrystallized-performance-fee
path: existing EVE holder observes a successful `UniCLStrat.sync` that makes LP fees and `pendingPerformanceFeeInETH` visible → before the next separate `HarvestPerformanceFees` upkeep, holder calls `AMM.exit` → `exit` prices and burns at gross NAV without settling or reserving the pending fee → later keeper harvest calls `StrategyManager._mintPerformanceFeeEVE` → the full treasury fee is diluted only from holders who remained after the exit
proof: Start with 100 EVE supply and 100 ETH pre-fee NAV (60 ETH free in AMM and 40 ETH strategy principal); the attacker owns 50 EVE. A sync materializes 10 ETH of LP fees, so gross NAV becomes 110 ETH and a 20% performance fee liability is 2 ETH. Before harvest, `exit` uses base price `110 / 100 = 1.1 ETH/EVE`, allowing the attacker to burn 50 EVE for 55 ETH from the 60 ETH AMM float. NAV and supply become 55 ETH and 50 EVE. The later harvest mints `2 * 50 / (55 - 2) = 1.886792452830188679 EVE` to the treasury, worth 2 ETH post-mint. The remaining original 50 EVE are then worth exactly 53 ETH; economically fair net ownership before the exit was `(110 - 2) / 2 = 54 ETH` per half. The early exiter received 55 ETH, avoiding and shifting their 1 ETH half of the fee to remaining holders. `StrategyKeeperExecutor` cannot close the window atomically because Sync and HarvestPerformanceFees are separate one-action upkeeps, and immediate AMM exits do not touch StrategyManager withdrawal/harvest code.
description: `exit()` burns shares against gross strategy NAV even when a determinable performance-fee liability will be crystallized into treasury shares only later.
consequence: Holders can front-run fee crystallization, redeem gross earnings, and shift their proportional performance fee onto remaining EVE holders; entrants between sync and harvest face the inverse unfair dilution.
fix: Atomically crystallize all recognized performance fees before every EVE mint/burn or batch price snapshot, or expose a separate net-of-pending-fee NAV for shareholder pricing while retaining gross NAV for the fee-share mint equation.

FINDING | contract: UniswapV3ConverterAdapter | function: quoteExactAmountOut | bug_class: exact-output-rounding-down | group_key: UniswapV3ConverterAdapter | quoteExactAmountOut | exact-output-rounding-down
path: Controller/StrategyManager requests a small UniCL withdrawal → `UniCLStrat.withdraw` needs a fixed WETH remainder → `_swapViaRouteExactAmountOut` consumes `Converter.quoteSwapExactAmountOut` → adapter floors both the reciprocal TWAP input and fee gross-up → UniCL also floors its percentage-padded maximum → converter forwards an input maximum below the amount a real fee-charging pool requires → router reverts and the withdrawal cannot complete
proof: At tick 0 (1:1 raw-unit price), fee 3000 (0.3%), and desired output 99 units, `_twapQuote(tokenOut, tokenIn, ..., 99)` returns 99. The adapter returns `floor(99 * 1,000,000 / 997,000) = 99`, but exact output needs `ceil(99 * 1,000,000 / 997,000) = 100`: 99 gross input leaves only `floor(99 * 997,000 / 1,000,000) = 98` net units. With UniCL's default 1% padding, `_maxAmountIn = floor(99 * 10,100 / 10,000) = 99`, so the padding adds nothing and a real router must reject the maximum. The repository's adapter unit expectation also uses the floor formula, while its local mock router consumes output one-for-one and does not charge the configured pool fee, so that test cannot exercise this boundary.
description: The exact-output quote uses floor division where a required/maximum input must round upward, and the downstream slippage padding can also disappear at small units.
consequence: Small exact-output conversions (and therefore dust-sized strategy withdrawals that need WETH conversion) deterministically revert despite sufficient token balance.
fix: Use full-width rounding-up division for the reciprocal quote and the fee gross-up, and round UniCL's exact-output maximum upward as well.

## Leads retained for follow-up

LEAD | contract: Math | function: convertAssets/convertAssetsInverse/basePrice/premiumPrice/isRelativelyLessThan | bug_class: intermediate-overflow | group_key: Math | fixed-point-helpers | intermediate-overflow
code_smells: Every helper evaluates `a * b / c` with a checked 256-bit product even though the final quotient can fit; `Oracle.convert` likewise evaluates `normalizedAmountIn * priceIn / priceOut`. For example, at price 1e18, any normalized amount above `floor((2^256-1)/1e18)` reverts in `convertAssets` even when division by 1e18 would return the original amount, and a donated supported-token balance flows through this code during global NAV reads.
description: A protocol-wide NAV freeze is arithmetically possible, but I did not establish a realistic in-scope supported token/feed whose attainable supply crosses the approximately 1.16e59-raw-unit threshold, so this remains a lead rather than a finding.

LEAD | contract: DeployUniCLStrat/DeployUniswapV3ConverterAdapter | function: _deploymentConfig/run | bug_class: unchecked-narrowing-cast | group_key: Deploy scripts | config casts | unchecked-narrowing-cast
code_smells: Environment values are narrowed before validation: `TWAP_INTERVAL = 2^32 + 1800` becomes 1800 and passes, `ADAPTER_TWAP_INTERVAL = 2^32 + 60` becomes 60, and `POSITION_WIDTH = 2^24 + 1` becomes 1. Original-value range checks are absent.
description: The scripts can silently deploy materially different precision/range settings than supplied, but the input is deployment-operator controlled and no unprivileged local call path was established.

LEAD | contract: StrategyManager | function: _mintPerformanceFeeEVE | bug_class: zero-rounded-fee-mint | group_key: StrategyManager | _mintPerformanceFeeEVE | zero-rounded-fee-mint
code_smells: `UniCLStrat.settlePerformanceFee` marks all recognized fee-token amounts charged once `feeETH > 0`, then `_mintPerformanceFeeEVE` floors `feeETH * supply / (NAV - feeETH)` without requiring a nonzero EVE result. With supply 1000e18, NAV 2000e18, and feeETH 1 wei, the mint is zero even though settlement is permanent.
description: The treasury can lose sub-share-unit fees at a sufficiently high EVE price, but the demonstrated loss is dust and no material compounding extraction path was established.

## Cleared areas

CLEARED_AREAS
- AMM bootstrap, entry, immediate exit, queued exit, claim locking, and pending-payment NAV subtraction: checked zero/one-unit boundaries and confirmed ordinary conversion rounding favors the protocol/remaining holders rather than the caller; the fixed dead supply is protected by the USD minimum.
- Controller ↔ ExitQueue ↔ AMM settlement arithmetic: checked that slippage closure and `tokens * finalPrice / 1e18` are reproduced consistently in affordability estimates, controller payment, and market accounting.
- Oracle price orientation and scale: checked direct pair, inverse pair, USD cross-rate, feed-decimal normalization, token-decimal normalization, timestamp/freshness guards, and same-token conversions; no scale inversion found for tokens/feed precisions at or below 18.
- StrategyManager fee-share algebra: independently derived `fee * supply / (NAV - fee)` and confirmed it gives treasury shares worth the stated fee at one ownership snapshot; batch event allocation assigns the rounding remainder to the final strategy.
- Strategy deposit/withdraw weight arithmetic: checked zero weights, cumulative weights, per-strategy caps, and residual return; floor dust and cap-driven multi-upkeep behavior do not overdraw or overcredit a user.
- Converter swap accounting: checked exact-input output deltas, exact-output input/output deltas, refund subtraction, and malformed adapter returns; measured balances prevent adapter-reported numbers from funding payouts.
- Uniswap full-width tick quotation and liquidity libraries: checked the two sqrt-price branches, shift widths, uint128 checked conversion, token-order reciprocal, and negative mean-tick floor behavior; no unsafe downcast was found for valid Uniswap tick/liquidity domains.
- UniCL range principal/owed-token accounting after a poke: checked main/alternate position separation, fee snapshot advancement before collect, principal exclusion from LP-fee counters, collect reset, charged-counter monotonicity, and emergency reset; no double count or double fee was found once fee growth is materialized.
- Queue and strategy keeper percentage/threshold arithmetic: checked strict timeout boundary agreement, zero-cost slippage requests, reserve subtraction, immediate-exit target cap, and recomputation of execution amounts.

AGENT_STATUS | COMPLETE | bundle_read: 9606/9606 | findings: 3 | leads: 3 | poc: not-created (worked local state traces plus existing local regression behavior were sufficient)
