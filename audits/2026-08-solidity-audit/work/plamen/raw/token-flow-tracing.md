# Plamen Raw Pass: token-flow-tracing

**Target**: immutable `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`
**Scope**: 39/39 source files; ETH, EVE, WETH, paired ERC-20, supported ERC-20, LP principal/fees
**Method**: entry -> accounting -> custody -> exit, unsolicited-balance and self-transfer analysis, external-return and transfer-side-effect review

## FINDING [TFT-1]: Emergency paired tokens enter a custody sink with no conversion or withdrawal path

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,3b,4,4a,5,5b,6,7,8,9,9d
**Rules Applied**: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan leverage), R16:✓]
**Depth Evidence**: [TRACE:UniCLStrat.emergencyExit -> pairedToken.trySafeTransfer(StrategyManager) -> no ERC20 egress -> only ETH emergency sweep]
**Preferred Tag**: CODE-TRACE
**Severity**: Medium
**Location**: `src/contracts/strategies/UniCLStrat.sol:494-519`; `src/contracts/StrategyManager.sol:453-468,961-969`
**Description**: A paused UniCL strategy unwraps WETH, sends ETH to StrategyManager, and sends all paired-token inventory there. StrategyManager can price supported ERC-20 balances, but its only emergency egress sends `address(this).balance`; it has no ERC-20 transfer or conversion function. The source explicitly defers conversion recovery to a future release.
**Impact**: During an emergency unwind, paired-token value can remain counted in total NAV while being unavailable to fund ETH redemptions. If it was not whitelisted, it is also omitted from NAV until an admin adds it.
**Material Harm**: EVE redeemers can be delayed or unable to receive the ETH represented by their shares while paired-token assets remain trapped in StrategyManager until a contract upgrade or new recovery mechanism.
**Evidence**: `UniCLStrat.emergencyExit()` transfers `_pairedBalance` to `strategyManagerAddress` at 508-514. `emergencyWithdrawToController()` transfers only native balance at 453-462. Lines 465-468 state ERC-20 accounting is present but on-chain swap recovery is deferred. `_supportedERC20sNAVInETH()` prices, but does not move, balances at 961-969. Base grep found no `safeTransfer`, `safeTransferFrom`, or `IERC20` use in StrategyManager except EVE `totalSupply` and supported-token `balanceOf`.
**Postconditions Created**: StrategyManager owns a paired-token balance that may contribute to NAV but cannot be converted or withdrawn through the immutable implementation.
**Postcondition Types**: [STATE, BALANCE, ACCESS]
**Who Benefits**: No direct attacker captures value; remaining holders may temporarily benefit if earlier redeemers cannot realize counted assets.
**Semantic Invariant**: Every asset included in redeemable NAV must have a realizable path to the ETH redemption pool.
**Branch Preconditions**: UniCLStrat is paused, holds paired tokens, and `trySafeTransfer` succeeds.
**Terminal Mechanism**: Missing StrategyManager ERC-20 egress.
**Recommendation**: Add a role-gated, slippage-bounded conversion/recovery path and enforce supported-token registration before strategy activation; alternatively exclude balances from redeemable NAV until an executable conversion path exists.

## FINDING [TFT-2]: One unit of unsolicited supported-token dust can activate a stale feed and freeze global NAV

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,3b,4,4a,5,5b,6,7,8,9,9d
**Rules Applied**: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no profitable flash-loan requirement), R16:✓]
**Depth Evidence**: [BOUNDARY:supported balance 0->1 bypasses zero skip], [TRACE:ERC20 transfer -> balanceOf=1 -> Oracle.convert -> stale feed revert -> AMM NAV-dependent entry/exit revert]
**Preferred Tag**: CODE-TRACE
**Severity**: Medium
**Location**: `src/contracts/StrategyManager.sol:473-501,940-969`; `src/contracts/Oracle.sol:355-379`; `src/contracts/AMM.sol:138-181,356-373`
**Description**: Once ADMIN whitelists an ERC-20, zero balance skips pricing, but any non-zero balance invokes its metadata and oracle feed. Anyone able to transfer one smallest unit to StrategyManager can therefore activate the path. A stale/invalid feed then reverts the entire aggregate NAV calculation. The source comment expressly identifies “1-wei dust griefing”; SECURITY can remove the token only after the freeze occurs.
**Impact**: `totalNAVInETH()` becomes unavailable and all AMM paths that price EVE from it, including entry and exit initiation, revert until a privileged circuit-breaker transaction removes the token or the feed recovers.
**Material Harm**: Depositors and redeemers lose protocol liveness during the stale-feed interval and depend on SECURITY/ADMIN response even though the triggering balance can be supplied permissionlessly at negligible cost.
**Evidence**: Lines 961-969 call `balanceOf`, skip only zero, then call `Oracle.convert`; Oracle reverts for no data, non-positive answer, future timestamp, or staleness at 364-374. Aggregate NAV calls this loop at 940-950; AMM exit reads NAV at 152 and AMM pricing delegates to it at 356-373. Lines 491-496 document the dust failure and removal escape hatch.
**Postconditions Created**: A non-zero supported-token balance makes global NAV synchronously dependent on that token, its metadata, and its feed.
**Postcondition Types**: [STATE, EXTERNAL, BALANCE]
**Who Benefits**: A griefer gains a cheap global pause primitive when a whitelisted feed is stale or invalid.
**Semantic Invariant**: An unsolicited token transfer must not let an untrusted sender add a new fail-closed dependency to core pricing.
**Branch Preconditions**: Token remains supported; transfers to StrategyManager are possible; its feed is stale/invalid at the attempted NAV read.
**Terminal Mechanism**: Aggregate NAV propagates the token/feed revert without per-token isolation.
**Recommendation**: Cache bounded prices or quarantine newly observed balances, permit NAV to omit a failing token with an explicit haircut/event, and alert/circuit-break automatically rather than letting dust activate a synchronous global dependency.

## LEAD [TFT-L1]: Paired-token emergency value may be omitted from NAV before operational whitelisting

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5,5b,6,7 | ?8(deployment configuration unavailable)
**Rules Applied**: [R4:✓, R5:✓, R6:✓, R8:✓, R10:✓, R11:✓, R12:✓, R13:✓, R14:✓, R15:✗(no flash-loan lever), R16:✓]
**Preferred Tag**: CONTESTED
**Severity**: Medium
**Location**: `src/contracts/strategies/UniCLStrat.sol:480-519`; `src/contracts/StrategyManager.sol:477-496,961-969`
**Description**: The strategy documentation asks operators to whitelist the paired token, but activation/emergency exit does not enforce this prerequisite. A missed step makes transferred assets vanish from reported NAV and can underprice EVE until ADMIN adds the token. Deployment state and runbook enforcement were not supplied.
**Material Harm**: Users who redeem while emergency assets are omitted can receive an inequitable share of liquid assets, leaving the accounting correction to later holders.
**Missing Precondition**: Evidence that a live/launchable UniCL strategy can have an unwhitelisted paired token.
**Precondition Type**: STATE
**Why This Blocks**: Correct deployment operations can register every paired token before value is placed at risk.

## LEAD [TFT-L2]: Converter has no rescue path for unsolicited or residual assets

**Verdict**: CONTESTED
**Step Execution**: ✓1,2,3,4,5,5b,6,7 | ?8,9(production token/router behavior)
**Rules Applied**: [R4:✓, R5:✗(single converter), R6:✗(no semi-trusted role), R8:✗(single-step), R10:✓, R11:✓, R12:✓, R13:✗(not design-labelled), R14:✗(no aggregate limit), R15:✗(no flash-loan gain shown), R16:✗(no oracle)]
**Preferred Tag**: CONTESTED
**Severity**: Low
**Location**: `src/contracts/Converter.sol`
**Description**: Converter can receive native/ERC-20 assets and has no general recovery function. Normal swaps use balance deltas and refund excess, but forced ETH, unsolicited tokens, or unusual router/token residuals can remain stranded. No protocol-funded residual path was proven.
**Material Harm**: A caller or operator can lose accidentally sent assets; protocol loss requires an unverified external side effect that leaves protocol-funded residue.

## External Return-Type Verification (mandatory)

| Boundary | Expected result/state | Base verification | Result |
|---|---|---|---|
| WETH `deposit` / `withdraw` | exact 1:1 WETH/native movement | Interface only; deployed implementation absent | ? UNVERIFIED |
| UniCL pool `mint/burn/collect` | callback payment and exact pool-accounted deltas | Pool interface only; implementation absent | ? UNVERIFIED |
| Router exact-input/output | amount return consistent with asset deltas | Converter uses measured deltas for settlement/refund | ✓ in-scope settlement; external semantics ? |
| Strategy `withdraw` | ETH reaches Controller | UniCL implementation traced; StrategyManager measures Controller balance delta and ignores declared amount | ✓ |
| Adapter `swap` | ABI `uint256` or failure | Converter requires 32-byte returndata but settles from balance deltas | ✓ for supplied adapter ABI |
| ERC-20 transfer family | bool or empty-success returndata | SafeERC20/trySafeTransfer used; deployed external token absent | ? side effects UNVERIFIED |

## Transfer Side-Effect / Token-Type Verification (mandatory)

| Type | Hooks/rebase/fee/blacklist assessment | Disposition |
|---|---|---|
| EVE | In-scope OZ ERC20; no transfer hook, fee, or rebase | ✓ CLEARED |
| WETH | Interface only; strategy assumes wrap/unwrap 1:1 | ? LEAD surface |
| Paired ERC-20 | Arbitrary configured external token; fees/rebase/hooks/blacklist can alter or block custody flows | ? LEAD surface |
| Supported ERC-20 | Arbitrary external token; `balanceOf`, `decimals`, rebase, and feed are live NAV dependencies | CONFIRMED in TFT-2 |
| Pool/router token callbacks | Expected token0/token1 boundaries checked in strategy; production implementations unavailable | ? UNVERIFIED |

## Unsolicited-Transfer Matrix (mandatory)

| Asset | Entry / custody | Intended exit | Accounting source | Unsolicited consequence |
|---|---|---|---|---|
| Native ETH | AMM, Controller, StrategyManager, strategies, Converter | investments, AMM redemption/claim, emergency sweep | contract balances; AMM subtracts `lockedForClaims` | Counts in NAV at core custody; Converter donations strand |
| EVE | mint to user/treasury/dead; queued transfer to AMM | burn, slippage refund, cancellation | totalSupply + ExitQueue request records | Excess sent to protocol contracts is stranded; does not inflate supply/NAV |
| WETH | Converter/UniCL/pool flows | unwrap, swap, pool payment | direct balance + LP position | Donation raises inventory/NAV and benefits holders; no share capture found |
| Paired ERC-20 | swaps/collect/donation in UniCL | pool mint/swap; emergency transfer to manager | direct balance + LP position | Donation changes inventory/NAV; emergency custody sink is TFT-1 |
| Supported ERC-20 | emergency transfer or donation to StrategyManager | No ERC-20 exit in base | live `balanceOf` priced through Oracle | Dust can activate global failure path (TFT-2) |
| UniCL LP position | pool mint | burn/collect | pool position keyed by strategy/ticks | No transferable receipt token in scope |

## CLEARED

- **Native sentinel**: `address(0)` is used as Oracle's native-asset identifier only. Strategy execution branches WETH/native explicitly and does not issue ERC-20 calls to the sentinel.
- **Deposit donation capture**: `_navInETHPendingTransfer()` subtracts current `msg.value`; post-bootstrap donations are included in price before new shares mint. No profitable donation/share capture was closed.
- **Exit/claim ordering**: queued EVE accounting is updated before refund/burn, and claim balance/lock are cleared before ETH send; transaction atomicity restores state on failure.
- **Self-transfer**: EVE self-transfers do not create supply, queue, claim, or NAV credit; no balance-delta bookkeeping assumes sender and receiver differ.
- **LP principal versus fees**: pool principal/inventory flows are balance/position based; performance fees mint EVE dilution to treasury and do not silently transfer underlying assets.
- **Cross-token settlement**: Converter measures before/after balances, enforces exact-input output minimums/exact-output targets, and refunds excess input; no in-scope return-value-only payout was found.

## Read / Validation Record

- Plamen rules: `orchestrator-rules.md` 79/79 lines; `finding-output-format.md` 114/114 lines.
- Skill: `token-flow-tracing/SKILL.md` 291/291 lines; no directly referenced files.
- Fresh bundle reused for this sequential batch: `scope.md` 139/139, `profile.md` 207/207, `context.md` 181/181, `source.md` 9,417/9,417 (39/39 files), `finding-format.md` 101/101.
- Immutable interface context: 21/21 files, 3,564 Solidity lines, read via `git show 734df96:PATH`.
- Base-only commands: targeted `git show 734df96:PATH | nl -ba | sed -n ...`; `git grep -nE ... 734df96 -- PATH` for custody exits and NAV callers. No post-base source, prior work output, history, or `test/audit` read.
- Tests: not run; both findings close by immutable code trace and no safe local test was necessary.
- Confidence: high for TFT-1/TFT-2 because ingress, balance/accounting, revert propagation, and absence of an ERC-20 exit were traced in the base snapshot; external deployed token/pool/router behavior remains explicitly UNVERIFIED and is not used to claim a refutation.

AGENT_STATUS: COMPLETE
