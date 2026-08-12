# Reviewer 11 — trust/access/economic/asymmetry seams

The bundle was read completely and in order. Review used local source/tests only; no network or deployed state was used.

## Material reasoning markers

[Feynman: StrategyManager.setPerformanceFeeBps / settlePerformanceFee] Governance stores one current percentage. Strategies separately accumulate an uncharged lifetime fee base. At harvest, the strategy multiplies the entire uncharged base by whichever percentage is current then and marks the whole base charged; it does not remember which percentage applied while each portion was earned.

[Socratic: src/contracts/StrategyManager.sol:836 — why?] Why may the rate change without first settling the fee base accumulated under the old rate, when settlement receives no time- or epoch-specific rate information?

[Inversion: StrategyManager.setPerformanceFeeBps] (1) accrue 10 ETH of LP fees at 0%, then set 20% and harvest; (2) accrue at 20%, set 0%, let users transact without dilution, then restore 20%; (3) accrue at 20%, lower to 1% just before harvest. The current code prices all three histories only by the final rate.

[Feynman: StrategyManager.setDaoTreasury / _mintPerformanceFeeEVE] Strategies accrue a pending protocol fee, but no account is credited until harvest. The harvest mints all fee shares to the treasury address stored at that moment, even if a different treasury was configured throughout accrual.

[Socratic: src/contracts/StrategyManager.sol:809 — why?] Why does changing the beneficiary not checkpoint pending value to the old beneficiary before changing the address used by the mint?

[Inversion: StrategyManager.setDaoTreasury] (1) accrue fees under treasury A then change to B and harvest; (2) alternate A/B around harvests; (3) change treasury after settlement views are published but before keeper execution. In each case the caller with ADMIN_ROLE selects which beneficiary receives already-accrued value.

[Feynman: StrategyManager._mintPerformanceFeeEVE] A fee measured in ETH is paid by minting new EVE so the treasury owns the same fraction of protocol value. Existing holders fund that payment through dilution; the larger the fee input, the more ownership is transferred from them.

[Socratic: src/contracts/StrategyManager.sol:777 — why?] Why is an external strategy's claimed fee accepted without an independent upper bound tied to that strategy's fee base or NAV?

[Inversion: StrategyManager._mintPerformanceFeeEVE] (1) registered strategy returns fee equal to total NAV; (2) returns total NAV minus 1 wei; (3) returns a positive fee without corresponding fee growth. Move (1) reverts, move (2) produces extreme dilution, and move (3) transfers ownership from holders based solely on a trusted strategy report.

## Confirmed defects

FINDING | contract: StrategyManager / UniCLStrat | function: setPerformanceFeeBps / pendingPerformanceFeeInETH / settlePerformanceFee | bug_class: retroactive-fee-rate-repricing | group_key: StrategyManager | setPerformanceFeeBps | retroactive-fee-rate-repricing
seam: access×economics×asymmetry
actor: ADMIN_ROLE through the 48-hour timelock; ordinary EVE holders bear the resulting dilution while the DAO treasury receives it.
path: strategy earns LP fees -> no settlement checkpoint occurs -> admin changes `performanceFeeBps` -> keeper harvest passes the new rate to `settlePerformanceFee` -> strategy applies it to the entire old uncharged base -> EVE is minted to treasury and existing holders are diluted.
proof: let a strategy have 10 ETH uncharged LP fees. While the configured rate is 0, pending fee is 0. `setPerformanceFeeBps(2_000)` immediately makes the same unchanged base report and settle 2 ETH (`10 * 2,000 / 10,000`), then marks all 10 ETH charged. With supply 100 EVE and total NAV 100 ETH, `_mintPerformanceFeeEVE` mints `2*100/(100-2)=2.040816... EVE`. Reversing the rate change from 20% to 0 before harvest instead charges 0 for that same history. Existing local `test_PendingPerformanceFeeInETH` explicitly demonstrates that a base accumulated while rate=0 becomes chargeable after restoring 20%.
expected: economic value earned before a governance rate change is charged under the old rate (or explicitly grandfathered by a documented checkpoint policy), so the write affects future accrual only.
actual: the authorized setter retroactively selects the fee on all unharvested historical earnings; increases transfer extra ownership from current holders, while decreases forgive previously expected treasury fees.
consequence: timelocked governance can systematically reprice accrued value and change holder dilution after the economic activity already occurred; users/treasury cannot infer liability from the rate in force during accrual.
fix: before changing the rate, settle every registered strategy at the old rate and mint that checkpoint, then store the new rate; alternatively make strategies accrue fee entitlement per rate epoch rather than storing only a rate-agnostic base.

FINDING | contract: StrategyManager | function: setDaoTreasury / _mintPerformanceFeeEVE | bug_class: accrued-fees-follow-new-beneficiary | group_key: StrategyManager | setDaoTreasury | accrued-fees-follow-new-beneficiary
seam: access×asymmetry
actor: ADMIN_ROLE through the timelock chooses the beneficiary; old and new treasury addresses are treated asymmetrically at the setter boundary.
path: strategies accumulate an uncharged fee base while treasury A is configured -> admin calls `setDaoTreasury(B)` -> next keeper harvest settles the pre-change base -> `_mintPerformanceFeeEVE` mints every fee token to current `daoTreasury` B -> A receives none.
proof: with 10 ETH uncharged and a 20% rate, pending fee is 2 ETH. No state binds that 2 ETH to A. After `setDaoTreasury(B)`, the same `_mintPerformanceFeeEVE(2 ether)` executes `EVE.mint(B, evesToMint)`; A's balance delta is 0 and B receives the full mint. Neither setter nor strategy settlement checkpoints A.
expected: already-accrued fees remain payable to the beneficiary under which they accrued, or the old beneficiary is settled before the destination changes.
actual: a correctly authorized address change redirects the entire backlog of accrued value to the new address.
consequence: governance can transfer historical fee entitlement between treasury entities at the exact change boundary, defeating accounting/audit expectations for past accrual periods.
fix: harvest/checkpoint all pending fees to the old treasury before updating `daoTreasury`, or record accrued EVE/ETH entitlement by beneficiary epoch.

## Leads

LEAD | contract: StrategyManager | function: _mintPerformanceFeeEVE | bug_class: trusted-strategy-fee-report-can-overdilute | group_key: StrategyManager | _mintPerformanceFeeEVE | trusted-strategy-fee-report-can-overdilute
seam: access×economics
code_smells: ADMIN_ROLE can register arbitrary strategy code, and harvest trusts its `settlePerformanceFee()` return as fee ETH without checking the strategy's NAV, pending view, or a per-strategy upper bound; only `totalNAV > fee` is enforced globally.
description: a registered faulty strategy returning `totalNAV - 1` can request an enormous EVE mint (`fee*supply/1`) and dilute holders, but completing this as an exploitable defect would require establishing that a timelocked strategy registration is not itself the intended full economic-trust grant; retained as a LEAD rather than reporting “admin can rug.”

LEAD | contract: StrategyKeeperExecutor / QueueKeeperExecutor | function: setForwarder / performUpkeep | bug_class: replacement-forwarder-can-select-favorable-valid-action | group_key: KeeperExecutors | performUpkeep | replacement-forwarder-can-select-favorable-valid-action
seam: access×asymmetry
code_smells: ADMIN_ROLE may replace `forwarder` immediately when its timelocked call executes, and a forwarder may submit any currently valid action/batch rather than the precise priority result of `checkUpkeep`; ProcessRequests validates affordability but not cursor/window/oldest-action selection.
description: a compromised or intentionally selected forwarder could choose among simultaneously valid batches/actions and alter user ordering, but no concrete extractable value or measurable victim delta was established locally.

## Specific cleared areas

- AMM entry versus exit pricing intentionally uses premium price for issuance and base NAV price for redemption; deposits pay the spread while exits cannot choose the premium branch, and both use the same atomic NAV source.
- Immediate and queued exits both settle at base NAV price; queued requests additionally bind a user-selected tolerance and return EVE rather than applying an unacceptable priced result.
- `processRedemption` preserves paired accounting: Controller computes the same token-times-final-price liability, sends exactly that amount, AMM locks exactly that amount, and excess value would be returned to Controller.
- Fee mint batching uses one pre-batch aggregate mint and assigns its EVE pro rata; the final strategy receives rounding remainder, so per-strategy event totals equal the actual mint.
- Deposit/withdraw strategy weights are owned by StrategyManager, capped to 100 individually, and zero weight consistently excludes a strategy from the corresponding batch economics.
- Controller measures requested versus actual strategy deposits/withdrawals separately in events; StrategyManager uses Controller balance delta for actual withdrawal proceeds rather than trusting strategy return data.
- Converter exact-input/exact-output payouts use token balance deltas and route tokens from an admin-allowed adapter; adapter-reported swap amounts cannot directly withdraw pre-existing output inventory.
- Whitelist gating is asymmetric only on entry: exits never require admission, so admin/signers cannot use the gate to trap an existing holder's redemption.
- SECURITY_ROLE can pause and recover but cannot unpause, set fee destinations/rates, alter feeds, register strategies, or mint EVE; the emergency role therefore lacks the configuration primitives needed for a direct value-redirection seam.
- Registry role administration makes CONVERTER_CALLER_ROLE subordinate to the Converter-held manager role; registered strategies cannot grant themselves or peers that authority.
- Strategy removal deletes both allocation weights and drops the strategy from NAV atomically; normal removal checks residue, while force removal is explicitly a timelocked loss-recognition escape hatch.

AGENT_STATUS: COMPLETE
