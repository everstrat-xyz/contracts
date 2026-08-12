# Security Audit Report — EverStrat Contracts

- **Date**: 2026-08-12
- **Audited snapshot**: `734df96a1391e95dd40843210997da0b9f3ab05e`
- **Requested branch**: `chore/claude-reviewer-setup`
- **Audit branch**: `audit/solidity-audit-skills-734df96`
- **Methodology snapshot**: `daoism-systems/solidity-audit-skills@7a3dca988b8f4c2070aaac01975d1ae93058b699`
- **Language / toolchain**: Solidity 0.8.30; Foundry 1.0.0 (`8692e926`); optimizer 200; `via_ir=true`
- **Build status**: PASS
- **Final audit-regression status**: 37 passed, 0 failed, 0 skipped
**Release assessment**: **BLOCK PRODUCTION DEPLOYMENT until the material accounting, custody, emergency, and governance findings are remediated and a deployment-specific review is completed.**

---

## Executive summary

EverStrat is a Registry-centred, upgradeable EVM protocol that issues EVE against
aggregate ETH-denominated NAV, supports immediate and queued redemptions, moves
capital through strategies, and automates queue/strategy maintenance. The audit
reviewed the full immutable source snapshot rather than only the branch diff:
25 implementation/local-library files and 14 deployment/finalization scripts,
totalling 4,849 normalized lines.

The review found no Critical or High findings under the stated trust model. It
found 14 Medium, 16 Low, and one Informational issue. The dominant risks are
accounting across time-separated fee and queue states, supported-token custody
without a settlement path, emergency-path dependence on failing assets, and
automation actions whose discovery predicate can remain true after a no-progress
execution. Several verified examples redistribute value between cohorts; others
can delay or block redemptions and emergency recovery.

The target commit itself adds `CLAUDE.md` and two review workflows; it does not
modify Solidity. Contract findings therefore describe pre-existing behavior in
the audited branch state, not regressions introduced by that commit. The newly
added pull-request workflow is reported separately because it executes checked-out
PR code in a job with repository/OIDC authority and an OAuth secret.

This was a source audit, not an on-chain deployment audit. No chain, proxy or
implementation addresses, initializer transactions, bytecode matches, live role
membership, timelock state, feed/pool manifests, adapter routes, strategies, or
Automation Forwarders were supplied. Production release remains blocked until
those items are verified against a fixed deployment manifest.

## Finding summary

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 14 |
| Low | 16 |
| Informational | 1 |
| **Total** | **31** |

### Finding index

| ID | Severity | Verification | Title |
|---|---|---|---|
| M-01 | Medium | VERIFIED | Priced queue liabilities distort active-share accounting |
| M-02 | Medium | VERIFIED | Pending performance-fee liabilities are absent from share pricing |
| M-03 | Medium | VERIFIED | Unpoked Uniswap V3 fee growth is omitted from NAV and deposit caps |
| M-04 | Medium | VERIFIED | Supported ERC-20 NAV has no native-asset settlement or egress path |
| M-05 | Medium | VERIFIED | Removing a held supported token opens a dilution window |
| M-06 | Medium | CONFIRMED | Emergency paired-token custody can disappear from protocol NAV |
| M-07 | Medium | VERIFIED | An unauthenticated configured pool can drain UniCL inventory |
| M-08 | Medium | VERIFIED | Failed allowance revocation rolls back the UniCL pause |
| M-09 | Medium | VERIFIED | A paired-token balance query can block native emergency recovery |
| M-10 | Medium | VERIFIED | Failed rebalance can monopolize keeper priority |
| M-11 | Medium | VERIFIED | Freely cancellable requests can force repeatable liquidity churn |
| M-12 | Medium | VERIFIED | Cached queue work remains executable after the cancellation boundary |
| M-13 | Medium | VERIFIED | A zero DAO proposer permanently disables governance |
| M-14 | Medium | CONFIRMED | PR-controlled code executes in a job with material repository authority |
| L-01 | Low | VERIFIED | Explicit timelock configuration bypasses the documented 48-hour floor |
| L-02 | Low | VERIFIED | Finalization can renounce admin before Whitelist registration is verified |
| L-03 | Low | VERIFIED | External preflight views bypass strategy batch failure isolation |
| L-04 | Low | VERIFIED | Unbounded revert data defeats strategy batch failure isolation |
| L-05 | Low | VERIFIED | Tokens above 18 decimals permit dust-triggered NAV denial of service |
| L-06 | Low | VERIFIED | An unavailable TWAP window freezes aggregate NAV |
| L-07 | Low | VERIFIED | Positive-only UniCL parameter checks admit values that later panic |
| L-08 | Low | VERIFIED | Zero-weight strategies create repeatable no-progress keeper work |
| L-09 | Low | VERIFIED | Swap-and-pop queue ordering obstructs affordable redemptions |
| L-10 | Low | VERIFIED | The first depositor can capture pre-bootstrap residual NAV |
| L-11 | Low | CONFIRMED | Fee-on-transfer output checks do not protect the caller's receipt |
| L-12 | Low | CONFIRMED | Dust can activate a stale supported-token feed and freeze NAV |
| L-13 | Low | CONFIRMED | Runtime Oracle updates do not bind the feed quote domain |
| L-14 | Low | CONFIRMED | Keeper completion events report requested rather than actual movement |
| L-15 | Low | CONFIRMED | Broadcast inputs are not fully bound before deployment |
| L-16 | Low | CONFIRMED | The repository lacks a parity-preserving Solidity CI gate |
| I-01 | Informational | CONFIRMED | Taxed input can consume a pre-existing Converter balance |

## Scope

| Component | Paths | nSLOC | Treatment |
|---|---|---:|---|
| Entry, receipt token, redemption, whitelist | `AMM.sol`, `EVE.sol`, `ExitQueue.sol`, `Whitelist.sol` | 518 | Primary |
| Coordination and NAV accounting | `Controller.sol`, `StrategyManager.sol` | 895 | Primary |
| Registry and access | `Registry.sol`, Registry clients, `Auth.sol` | 274 | Primary |
| Oracle and shared math | `Oracle.sol`, `Math.sol` | 315 | Primary |
| Converter, UniCL strategy and local Uniswap code | `Converter.sol`, adapter, `UniCLStrat.sol`, six local libraries | 1,437 | Primary |
| Automation | Keeper base and both executors | 445 | Primary |
| Deployment and finalization | `script/**` (14 files) | 965 | Primary |
| Interfaces, tests, mocks, docs, dependencies | `src/interfaces/**`, `test/**`, `docs/**`, `lib/**` | — | Context / evidence |
| Review workflows | `.github/workflows/**` | — | Repository-readiness context; M-14/L-16 apply |

The exact 39-file list and deterministic nSLOC calculation are in
`audits/2026-08-solidity-audit/bundle/scope.md`.

## Methodology and verification

The audit used the complete routed EVM review set from the pinned
`solidity-audit-skills` snapshot:

- architecture, scope, history and integration profiling;
- twelve isolated Pashov specialties (nine durable completions; three explicitly
  incomplete and not silently credited);
- three independent current-code Omega passes plus a separate historical
  regression census;
- all eleven routed QuillShield plugins; and
- all 28 routed Plamen EVM/depth/feature outputs.

Every current finding/lead occurrence was placed in a mechanism inventory,
deduplicated by root cause, and adjudicated. Historical review material was
handled separately: nine indexed artifacts and all 73 explicit historical IDs
were checked against the target; none was classified as a regression.

The pinned baseline produced:

- clean offline build;
- 1,176 local tests passed, 0 failed, with 15 mainnet-fork tests skipped for
  missing `MAINNET_RPC_URL` and fixed `MAINNET_FORK_BLOCK`;
- scoped coverage of 2,032/2,182 lines, 366/461 branches, and 433/446 functions
  using Foundry's `--ir-minimum` fallback;
- all production bytecode below EVM limits (smallest runtime margin: 947 bytes);
- zero production npm advisories; and
- final focused verification of 22 suites / 37 tests, all passing.

`VERIFIED` means a focused Forge proof passed against the immutable source.
`CONFIRMED` means the complete path was closed directly from source, interfaces,
or workflow configuration and no stateful PoC was necessary.

## Limitations

- Mainnet-fork tests were not run because no archive RPC and fixed block were
  provided.
- Slither, Aderyn, Mythril, and Semgrep were unavailable. Foundry lint and
  Solhint were the available automated analyzers.
- Coverage required `--ir-minimum`; Foundry warns that its source maps may be
  less accurate. Seven gas-budget assertions were excluded only from the
  instrumented coverage run; the normal pinned suite passes them.
- No invariant-style test declaration exists in the base suite.
- No deployed-state or bytecode/source verification was possible. Findings that
  depend on a token, feed, pool, route, role, or keeper configuration state their
  prerequisite explicitly.
- Historical artifacts found on side branches are internal/AI-assisted review
  material, not independent third-party assurance.

---

## Medium findings

### [M-01] Priced Queue Liabilities Distort Active-Share Accounting [VERIFIED]

**Severity**: Medium
**Location**: `src/contracts/AMM.sol:L138-L181, L215-L241, L397-L423`; `src/contracts/Controller.sol:L331-L336, L418-L449`; `src/contracts/ExitQueue.sol:L173-L188, L228-L268`
**Confidence**: HIGH (PoC: PASS)

**Description**:
When an immediate redemption cannot be funded, `AMM.exit()` transfers the user's EVE to the AMM instead of burning it. `ExitQueue.priceBatch()` then fixes the redemption price, but neither the escrowed shares nor their fixed ETH liability is removed from live share-price accounting:

```solidity
            if (ethToRedeem < minBatchExitETH) revert AMMTooLowBatchExitETH();

            IERC20(address(eve)).safeTransferFrom(redeemer, address(this), tokensToBurn);

            batchId =
                ExitQueue(payable(_registry.exitQueue())).pushRequest(redeemer, evePrice, tokensToBurn, _priceTolerance);

            emit RedemptionQueued(redeemer, batchId, block.timestamp);
```

The EVE is burned and the corresponding ETH leaves NAV only when `processRedemption()` runs. Keeping both sides in total NAV and total supply is ratio-neutral at the pricing instant, but it becomes incorrect after any NAV change because the queued cohort has a fixed claim. If `Q` shares are queued at NAV `N` and supply `S`, their liability is `L = Q * N / S`. After a NAV change `G`, the implementation uses `(N + G) / S`, while active holders should be priced against `(N + G - L) / (S - Q)`.

**Impact**:
NAV gains or losses occurring between batch pricing and processing are misallocated between queued users, active holders, entrants, and early exiters. After a gain, active exits burn too many shares and entrants receive too many shares; after a loss, early active exits can externalize more loss onto remaining active holders. The effect persists until the queued shares are processed or cancelled through the escape hatch and can be material when a large share of supply is queued.

The regression queued 80,000 of 100,000 EVE at an 80 ETH fixed liability, added an 80 ETH gain, and showed that a 10 ETH entrant ultimately held approximately 20 ETH after queue processing. Asset conservation held exactly; the extra value came from the active-holder cohort.

**PoC Result**:
`test/audit/candidates/verification/PricedQueueAccounting.t.sol` passed: 1 test passed, 0 failed, 0 skipped. The test exercised the full AMM, Controller, ExitQueue, StrategyManager, Oracle, Whitelist, and EVE flow and proved the cohort-value transfer with exact conservation.

**Recommendation**:
Once a batch is priced, reserve each in-tolerance fixed ETH liability and exclude its escrowed shares from active pricing. Use `activeNAV = totalNAV - reservedPricedLiabilities` and `activeSupply = totalSupply - escrowedInToleranceShares` for all subsequent AMM entries and exits. Update both values atomically on processing, slippage return, and escape cancellation. If this accounting is not implemented, block entries and active exits while a priced batch remains unresolved.

### [M-02] Pending Performance-Fee Liability Is Omitted from Share Pricing [VERIFIED]

**Severity**: Medium
**Location**: `src/contracts/AMM.sol:L138-L181, L397-L423`; `src/contracts/Controller.sol:L331-L336`; `src/contracts/StrategyManager.sol:L619-L667, L730-L794`; `src/contracts/strategies/UniCLStrat.sol:L382-L415, L859-L907`
**Confidence**: HIGH (PoC: PASS)

**Description**:
Recognized UniCL LP fees are included in strategy NAV while `pendingPerformanceFeeInETH()` simultaneously reports the treasury's accrued share. Until harvest, however, the fee liability is neither deducted from shareholder NAV nor represented by treasury-owned EVE. AMM entry, immediate exit, and queued-batch pricing therefore use gross NAV:

```solidity
        uint256 totalSupply = eve.totalSupply();
        uint256 nav = _navInETH();

        // Burning settles at the base (NAV) price, so EVE is always redeemed against
        // the assets backing it.
        uint256 basePrice = _basePriceFromNAV(nav, totalSupply);

        uint256 evePrice = basePrice;

        uint256 tokensToBurn = _ethToProtocolTokens(_requestedETH, evePrice);
```

The dilution formula is correct when the fee is harvested, but users can transact after the liability is visible and before the treasury mint. A queued request can also retain a gross pre-fee price even when sourcing its liquidity triggers fee settlement before the request is processed.

**Impact**:
An exiting holder can receive gross backing and avoid its proportional share of already-accrued performance fees, shifting that fee burden to holders who remain. Entrants during the same interval receive the inverse cohort treatment. The value transfer is permissionless once fees are recognized and is bounded by the configured fee rate, the unharvested recognized fee base, and the transacting holder's share.

In the regression, gross NAV was 11 ETH, supply was 10,000 EVE, and 0.2 ETH was already owed to the treasury. A holder exiting 1,000 EVE received 1.1 ETH instead of the 1.08 ETH net-of-liability amount, avoiding 0.02 ETH of accrued fees.

**PoC Result**:
`test/audit/candidates/verification/PendingFeeSharePricing.t.sol` passed: 2 tests passed, 0 failed, 0 skipped. The tests confirmed both the immediate-exit transfer and the queued-batch case where the fixed gross price survives a later fee harvest.

**Recommendation**:
Use a net shareholder NAV that subtracts every recognized pending performance-fee liability for AMM entry, exit, and batch-price snapshots, while retaining gross NAV for the treasury-mint equation. Alternatively, settle all visible strategy fees atomically before every EVE mint, burn, or batch price, with bounded and failure-safe behavior across strategies. Add conservation tests covering entrants, immediate exits, and queued exits around fee harvests.

### [M-03] Unpoked Uniswap V3 Fee Growth Is Omitted from NAV and Deposit Caps [VERIFIED]

**Severity**: Medium
**Location**: `src/contracts/strategies/UniCLStrat.sol:L199-L247, L362-L373, L665-L676, L758-L783, L859-L873`; `src/contracts/StrategyManager.sol:L940-L950`; `src/contracts/AMM.sol:L138-L181, L397-L423`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`UniCLStrat.navInETH()` values idle balances, position liquidity, and the pool position's stored `tokensOwed`, but it does not derive fee growth that Uniswap V3 has accrued since the position's last poke:

```solidity
        if (!_positionIsValid(_position)) return (0, 0);

        (uint128 _liquidity,,, uint128 _owed0, uint128 _owed1) = pool.positions(_positionKey(_position));
        if (_liquidity > 0) {
            (_amount0, _amount1) = _amountsForLiquidityAtSqrtPrice(_position, _liquidity, _sqrtPriceX96);
        }

        _amount0 += _owed0;
        _amount1 += _owed1;
    }
```

The omitted growth becomes visible only when a mint, burn, or zero-liquidity burn updates `tokensOwed`. Neither AMM pricing nor `maxDeposit()` enforces such a poke. A StrategyManager deposit can pass the pre-poke cap check and then call `_removeLiquidityAndCollect()`, which pokes the position and recognizes the hidden fees after the check.

**Impact**:
Entrants can be over-minted relative to fee-inclusive NAV and receive a share of yield earned before they entered, irreversibly diluting existing holders. Exits are also priced from stale NAV. Separately, a deposit sized to the advertised headroom can finish above `maxTotalNAV` by approximately the hidden fee value, weakening a configured strategy risk limit.

The regression hid 5 ETH of fee growth in a strategy reporting 40 ETH under a 60 ETH cap. A 10 ETH AMM entrant received strictly more EVE than the fee-aware formula, and a deposit of the reported headroom completed with strategy NAV approximately 5 ETH above the cap.

**PoC Result**:
`test/audit/candidates/verification/UnpokedFeeNAV.t.sol` passed: 1 test passed, 0 failed, 0 skipped. The test reproduced both stale-NAV share dilution and the cap overrun using the production AMM, Controller, StrategyManager, Converter, and UniCL accounting flow.

**Recommendation**:
Make UniCL NAV fee-aware by deriving pending V3 fee growth from pool and tick state, or enforce a freshness gate that requires a successful position poke before AMM pricing and strategy admission. Recheck `maxTotalNAV` after fee materialization in a state transition that does not roll the poke back on failure; a simple poke followed by a reverting cap check would revert the accounting update as well.

### [M-04] Supported ERC-20 NAV Has No Settlement or Egress Path [VERIFIED]

**Severity**: Medium
**Location**: `src/contracts/StrategyManager.sol:L449-L502, L923-L969`; `src/contracts/AMM.sol:L138-L181`; `src/contracts/Controller.sol:L418-L449`; `src/contracts/strategies/UniCLStrat.sol:L472-L515`
**Confidence**: HIGH (PoC: PASS)

**Description**:
StrategyManager includes every supported ERC-20 balance in total NAV, creating an ETH-denominated claim for EVE holders. This release nevertheless implements no ERC-20 transfer, swap, or recovery path from StrategyManager; its emergency withdrawal sends native ETH only:

```solidity
    {
        uint256 amount = address(this).balance;
        if (amount == 0) revert StrategyManagerNoBalanceToRecover();

        payable(registry().controller()).sendValue(amount);
        emit EmergencyWithdrawnToController(amount);
    }
```

This state is reachable through the intended emergency flow: `UniCLStrat.emergencyExit()` transfers residual paired tokens to StrategyManager and instructs operators to support the token so its value remains in NAV. AMM redemptions, however, are payable only in native ETH.

**Impact**:
The protocol can appear solvent at its Oracle-valued NAV while being unable to honor ETH redemptions. Early redeemers can consume the native-liquidity share attributable to both native and token backing, leaving later holders with positive ETH-priced claims that cannot be processed. Recovery requires new native liquidity, an upgrade, or an out-of-band token-specific mechanism. Removing support restores liveness only by writing the held value out of NAV and crystallizing the loss for remaining holders.

The regression produced 10 ETH of reported NAV backed by 5 ETH native and 5 ETH of a supported token. An early holder redeemed all 5 native ETH; a later request was priced positively but failed with `ControllerInsufficientBalance`, and the native-only emergency sweep also failed.

**PoC Result**:
`test/audit/candidates/verification/SupportedTokenLiquidity.t.sol` passed: 1 test passed, 0 failed, 0 skipped. It confirmed the exit-order asymmetry, failed settlement, failed native recovery, and NAV write-off on token removal.

**Recommendation**:
Do not count an ERC-20 as immediately redeemable ETH unless StrategyManager has a bounded, Oracle- and slippage-protected conversion or transfer path. During emergency custody, convert the token before reopening exits, distribute redemption assets pro rata, or reserve and gate native settlements so early users cannot consume liquidity attributable to later holders. Pair removal with an explicit custody-recovery and loss-allocation process.

### [M-05] Removing a Held Supported Token Creates a Dilution Window [VERIFIED]

**Severity**: Medium
**Location**: `src/contracts/StrategyManager.sol:L477-L502, L940-L969`; `src/contracts/AMM.sol:L397-L423`; `src/libraries/Auth.sol:L64-L92`
**Confidence**: HIGH (PoC: PASS; occurrence depends on an unsafe remove/re-add sequence)

**Description**:
`removeSupportedERC20()` removes a token from the NAV set without checking its balance, moving the asset, or pausing the AMM:

```solidity
    function removeSupportedERC20(address _token) external onlyEitherAuthRole(Auth.ADMIN_ROLE, Auth.SECURITY_ROLE) {
        if (!_supportedERC20s.remove(_token)) revert StrategyManagerERC20NotSupported(_token);

        emit SupportedERC20Removed(_token);
    }
```

The token remains in StrategyManager custody, but its value immediately disappears from `_supportedERC20sNAVInETH()`. New EVE is then minted against the reduced NAV. If ADMIN later re-adds the unchanged balance, the restored value is spread across both the old supply and shares minted during the omission. SECURITY can open this window immediately, while only ADMIN can close it by re-adding the token.

**Impact**:
A whitelisted entrant can capture value belonging to pre-existing holders during an otherwise honest stale-feed removal and later recovery. Profit requires the restored token value to be sufficiently large relative to the NAV that remained counted, and native liquidity must be available to realize the enlarged claim, but no malicious privileged action is required.

The regression removed 30 ETH of held token value from a 40 ETH NAV, allowed a 1 ETH entry at the depressed price, and later re-added the token. The entrant's 2,000 EVE claim rose to approximately 1.95238 ETH and a 1.9 ETH redemption realized approximately 0.9 ETH profit after the original deposit.

**PoC Result**:
`test/audit/candidates/verification/SupportedTokenRemoval.t.sol` passed: 1 test passed, 0 failed, 0 skipped. Custody remained unchanged throughout, and the test demonstrated the complete NAV drop, re-addition, dilution, and profitable redemption sequence.

**Recommendation**:
Entering a valuation-exception state should atomically disable AMM entry whenever a nonzero supported balance is removed. Require the AMM to be paused before removal and keep it paused until governance either restores the asset or permanently finalizes the loss allocation. If deposits must continue, snapshot supply and assign any restored value only to the cohort that existed when the asset was excluded.

### [M-06] Emergency Paired-Token Transfer to an Unsupported Manager Balance Drops It from NAV [CONFIRMED]

**Severity**: Medium
**Location**: `src/contracts/strategies/UniCLStrat.sol:L472-L515`; `src/contracts/StrategyManager.sol:L152-L172, L477-L485, L940-L969`; `src/contracts/AMM.sol:L397-L423`
**Confidence**: HIGH (Code trace: CONFIRMED; PoC: NOT RUN)

**Description**:
`UniCLStrat.navInETH()` counts paired-token inventory while the strategy is registered. During an emergency exit, that token is moved to StrategyManager, where ERC-20 balances are counted only if they have already been added to the supported set:

```solidity
        if (_pairedBalance > 0) {
            // trySafeTransfer (not try/catch on transfer): empty returndata from USDT-style
            // tokens cannot be ABI-decoded as `bool` and would revert outside catch scope,
            // hostaging the ETH sweep. OZ treats empty returndata + code as success.
            if (!pairedToken.trySafeTransfer(strategyManagerAddress, _pairedBalance)) {
                emit PairedTokenTransferSkipped();
            }
        }
```

Neither strategy registration nor `emergencyExit()` enforces that the paired token is supported. The source instead leaves whitelisting as an operational instruction. If the token is unsupported, a successful transfer moves value from a registered strategy, where it was included in aggregate NAV, to an ignored StrategyManager balance. Pausing the strategy does not pause the separate AMM, so users can enter against the temporarily reduced NAV. A later `addSupportedERC20()` restores the same custody value across the enlarged supply.

**Impact**:
An intended SECURITY or ADMIN emergency action can create a material accounting discontinuity and dilution window. Entrants during the omission receive excess EVE and capture part of the restored paired-token value when governance later adds support. Existing holders bear the corresponding dilution. The condition requires a nonzero emergency paired-token balance, missing prior support, and a live AMM.

**PoC Result**:
The base-source trace confirms the complete state transition: paired-token value is included while held by a registered UniCL strategy, `emergencyExit()` transfers it to StrategyManager, unsupported Manager balances are excluded from `_supportedERC20sNAVInETH()`, and `addSupportedERC20()` later restores the same held balance to NAV. No isolated executable PoC was run for this finding.

**Recommendation**:
Require every registered UniCL paired token to be Oracle-supported and present in StrategyManager's supported set before activation and before an emergency transfer. If that invariant is not satisfied, keep the token on the registered strategy or require AMM entry to be paused atomically until support is added and NAV is reconciled. Deployment finalization should verify this relationship on-chain rather than rely on an operational checklist.

### [M-07] An unauthenticated configured UniCL pool can drain strategy inventory [VERIFIED]

**Severity**: Medium

**Location**: `src/contracts/strategies/UniCLStrat.sol:136-155`, `src/contracts/strategies/UniCLStrat.sol:524-531`, `src/contracts/strategies/UniCLStrat.sol:732-755`, `script/DeployUniCLStrat.s.sol:91-120`

**Confidence**: High

**Description**: `UniCLStrat` accepts a pool address supplied in its deployment configuration and trusts the address after checking only its reported `token0`, `token1`, and `tickSpacing` values. The strategy does not authenticate the pool against an expected Uniswap V3 factory or otherwise prove that it is the canonical pool for the configured token pair.

During `_mintPosition`, the strategy sets `_minting` and calls the configured pool's `mint` function. The mint callback verifies only that `msg.sender` is the configured pool and that a mint is in progress. It then transfers the callback-supplied token amounts without checking them against the amounts that the strategy calculated for the requested liquidity. An interface-compatible malicious pool can therefore report plausible constructor and TWAP values, call back for the strategy's complete token balances, and return successfully without recording corresponding liquidity.

```solidity
function uniswapV3MintCallback(uint256 _amount0, uint256 _amount1, bytes calldata) external {
    if (msg.sender != address(pool)) revert UniCLStratCallerNotPool();
    if (!_minting) revert UniCLStratInvalidMintCallback();

    if (_amount0 > 0) token0.safeTransfer(address(pool), _amount0);
    if (_amount1 > 0) token1.safeTransfer(address(pool), _amount1);

    _minting = false;
}
```

The pool address is immutable and cannot be changed by an arbitrary caller after deployment. Exploitation therefore requires an incorrect or malicious pool address to survive deployment review, followed by privileged registration of the strategy and an allocation of protocol capital. Under the intended production role model, registration is governed by a timelock. This privileged configuration prerequisite reduces the finding to Medium even though the loss impact after such a configuration is severe.

**Impact**: A malicious configured pool can irreversibly transfer all WETH and paired-token inventory held by the strategy during a mint callback. A deposit can appear successful while the strategy receives no real LP position and its NAV falls to zero. Subsequent deposits may be drained in the same way until operators intervene.

**PoC Result**: `test/audit/candidates/verification/PoolAuthentication.t.sol` deploys an interface-compatible pool that is not factory-created, registers the resulting strategy through the normal admin path, and deposits 10 ETH. During `mint`, the pool requests the strategy's complete WETH and paired-token balances and forwards them to an attacker. The deposit succeeds, the attacker receives all 10 ETH-equivalent inventory, and strategy NAV becomes zero. Result: **1 passed, 0 failed**.

**Recommendation**: Add a trusted Uniswap V3 factory to the strategy's deployment domain and require the configured pool to equal the factory's canonical pool for the exact token pair and fee tier. Perform the same provenance check in the deployment script before registration. As defense in depth, bind each mint callback to the current mint operation and reject callback amounts that exceed the locally calculated token amounts; also validate the amounts returned by `pool.mint` before considering the operation successful.

### [M-08] Allowance revocation failure rolls back the UniCL circuit breaker [VERIFIED]

**Severity**: Medium

**Location**: `src/contracts/strategies/UniCLStrat.sol:460-462`, `src/contracts/strategies/UniCLStrat.sol:623-645`, `src/contracts/strategies/UniCLStrat.sol:1274-1277`

**Confidence**: High

**Description**: `_pauseStrategy` first writes the paused state and isolates failure of the pool unwind through a self-call and parameterless `catch`. It then calls `_removeConverterAllowances` directly. That helper invokes `forceApprove(converter, 0)` on both pool tokens without failure isolation.

```solidity
try this.selfRemoveLiquidityAndCollect() {}
catch {
    emit LiquidityUnwindSkipped();
}

_removeConverterAllowances();
}
```

If either token rejects the zero approval, the entire pause transaction reverts. This rolls back the earlier `_pause()` state transition, any successful pool unwind, and any allowance revocation that completed for the first token. The behavior conflicts with the purpose of the pause path: `emergencyExit` is reachable only while the strategy is paused, so an external token failure can disable both the circuit breaker and the primary emergency recovery path.

The trigger requires a previously configured paired token whose approval behavior later fails, such as an upgradeable, paused, or otherwise non-standard token. ERC-20 does not guarantee that `approve` remains non-reverting, and the failure is particularly harmful during the degraded conditions for which the emergency path exists.

**Impact**: ADMIN or SECURITY may be unable to pause the strategy during an incident, and `emergencyExit` remains inaccessible. If the token failure persists, unrelated WETH, native ETH, and LP capital can remain exposed or stranded. Force-removing the strategy can restore aggregate NAV liveness but does not recover assets still held by the strategy.

**PoC Result**: `test/audit/candidates/verification/EmergencyIsolation.t.sol` configures a paired token that accepts the constructor's maximum approval and later rejects zero-value approvals. A SECURITY caller's `pause` transaction reverts; `paused()` remains false and both Converter allowances remain at their maximum value. Restoring normal token behavior makes the same pause succeed. The full suite result was **2 passed, 0 failed**.

**Recommendation**: Make allowance cleanup incapable of reverting the paused state. Attempt each revocation independently through a bounded, best-effort helper, emit the token and spender when cleanup fails, and leave the strategy paused regardless of the cleanup result. Avoid binding arbitrary revert data on this emergency path. Operators can then pause the Converter or retry the individual revocation after the token recovers.

### [M-09] A paired-token balance query can block the WETH and native-ETH emergency sweep [VERIFIED]

**Severity**: Medium

**Location**: `src/contracts/strategies/UniCLStrat.sol:472-519`

**Confidence**: High

**Description**: `emergencyExit` is documented to sweep WETH and native ETH before attempting the best-effort paired-token recovery. The implementation, however, reads both the WETH balance and the paired-token balance before unwrapping WETH or sending any native ETH to StrategyManager. Only the later paired-token transfer is failure-tolerant.

```solidity
uint256 _wethBalance = weth.balanceOf(address(this));
uint256 _pairedBalance = pairedToken.balanceOf(address(this));

if (_wethBalance > 0) weth.withdraw(_wethBalance);

uint256 _ethToSend = address(this).balance;

address strategyManagerAddress = _registry.strategyManager();
// ETH first: paired-token transfer is best-effort and must not roll back the sweep.
if (_ethToSend > 0) _sendETH(strategyManagerAddress, _ethToSend);
```

A revert from `pairedToken.balanceOf(address(this))` therefore aborts the function before either independent asset is recovered. Because the function is atomic, all WETH and native ETH remain in the strategy even though neither asset depends on the degraded paired token. Retrying does not help while the paired token continues to reject its balance query.

The trigger requires a privilegedly configured paired token that later becomes broken or malicious, and the strategy must first be paused. These constraints reduce likelihood, but a failure prevents recovery precisely during an emergency and can isolate otherwise healthy capital indefinitely.

**Impact**: A degraded paired-token implementation can hold unrelated WETH and native ETH hostage in a static, non-upgradeable strategy. Force-removing the strategy excludes it from protocol NAV but does not extract the stranded assets, so permanent token failure can turn an availability incident into a capital-recovery failure.

**PoC Result**: `test/audit/candidates/verification/EmergencyIsolation.t.sol` pauses a strategy holding 2 ETH and 3 WETH, then makes the paired token revert from `balanceOf`. `emergencyExit` reverts and all 5 ETH-equivalent assets remain in the strategy. Restoring the balance query allows the same call to transfer the full amount. The full suite result was **2 passed, 0 failed**.

**Recommendation**: Complete the WETH unwrap and native-ETH transfer before interacting with the paired token. Isolate the entire paired-token leg, including its balance query and transfer, in a bounded best-effort helper and emit a failure event if that leg is skipped. Preserve retryability for the paired asset without allowing it to roll back recovery of independent assets.

### [M-10] A failed rebalance can monopolize keeper priority and starve redemption liquidity [VERIFIED]

**Severity**: Medium

**Location**: `src/contracts/automation/StrategyKeeperExecutor.sol:169-181`, `src/contracts/automation/StrategyKeeperExecutor.sol:217-238`, `src/contracts/StrategyManager.sol:1177-1187`, `src/contracts/strategies/UniCLStrat.sol:209-223`, `src/contracts/strategies/UniCLStrat.sol:299-359`

**Confidence**: High

**Description**: `StrategyKeeperExecutor.checkUpkeep` returns the first action from a strict priority order and selects `Rebalance` whenever an unpaused strategy reports unhealthy. Rebalance outranks `WithdrawShortfall` and all other liquidity work. `performUpkeep` calls the Controller, while StrategyManager catches a strategy-level rebalance revert and lets the outer keeper transaction succeed. The keeper neither verifies that a strategy became healthy nor records a failure backoff.

```solidity
// 1) Health first: rebalance any unhealthy, unpaused strategy
if (_rebalanceNeeded(strategyManager_)) {
    return (true, abi.encode(StrategyAction.Rebalance));
}

// 2) Liquidity for redemptions: withdraw the shortfall from strategies
uint256 needsETH = _pendingRedemptionNeedsETH(registry_);
```

UniCL exposes a deterministic mismatch between the selection predicate and the action precondition. During a non-calm market, `isHealthy()` returns false, so the keeper selects `Rebalance`; `rebalance()` then rejects the same non-calm condition. At the same time, the strategy remains unpaused, `maxWithdrawal()` continues to advertise NAV, and `withdraw()` can source redemption liquidity without re-adding liquidity while conditions remain non-calm.

Consequently, each successful automation transaction can leave the rebalance predicate unchanged. The next check selects the same no-progress action instead of a viable withdrawal shortfall.

**Impact**: During volatile markets, automation can repeatedly spend upkeep gas on rebalances that cannot execute while priced redemptions remain unfunded. Immediate-exit liquidity top-ups, deposits, fee harvesting, and sync are also starved by the higher-priority action. The issue causes delayed withdrawals rather than an authorization bypass or permanent lock; an authorized operator can still submit an explicitly encoded lower-priority action or intervene through the Controller.

**PoC Result**: `test/audit/candidates/verification/KeeperPriorityStarvation.t.sol` creates a priced redemption shortfall and an unhealthy strategy whose rebalance reverts while withdrawal remains functional. Two consecutive checks select `Rebalance`; the first execution succeeds at the keeper level but leaves Controller liquidity at zero. Executing `WithdrawShortfall` explicitly in the unchanged state transfers ETH to the Controller, proving the skipped action was viable. Result: **1 passed, 0 failed**.

**Recommendation**: Make discovery and execution share the same actionability predicate. Expose a strategy-level `canRebalance` view, or otherwise exclude conditions such as a non-calm pool when `rebalance` is guaranteed to reject them. Record per-strategy failure/backoff and continue evaluating higher-impact liquidity actions after a no-progress attempt. Prefer redemption-liquidity work over maintenance when both are actionable, and surface whether any strategy actually changed state.

### [M-11] Cancellable Current-Batch Liabilities Cause Repeatable Strategy Churn [VERIFIED]

**Severity**: Medium
**Location**: `src/contracts/automation/StrategyKeeperExecutor.sol:L169-L195, L229-L253, L494-L512`; `src/contracts/AMM.sol:L168-L193`; `src/contracts/ExitQueue.sol:L173-L188, L253-L297`; `src/contracts/StrategyManager.sol:L1080-L1142`
**Confidence**: HIGH (PoC: PASS; realized loss depends on pool and runtime conditions)

**Description**:
The StrategyKeeper treats the current unpriced batch as an ETH liability even though every request in that batch can be cancelled immediately and without a protocol penalty:

```solidity
        // Current (unpriced) batch, estimated at the AMM base price
        (,, uint256 totalTokensToBurn,,) = queue.batchInfo(currentBatchId);
        if (totalTokensToBurn > 0) {
            needsETH += totalTokensToBurn.convertAssets(IAMM(_registry.amm()).eveBasePriceInETH());
        }
```

At the default thresholds, a holder can queue enough EVE to select `WithdrawShortfall` before the queue's minimum pricing age elapses. After the keeper withdraws LP-backed capital, the holder cancels and receives the exact escrowed EVE back. The now-excess ETH is later redeposited, allowing the same position to repeat the cycle.

**Impact**:
An EVE holder can repeatedly force strategy liquidity to unwind and redeploy for a claim the holder never commits to. LP-backed cycles expose all holders' NAV to DEX fees and slippage, consume automation gas, and can leave capital idle during a configured deposit cooldown. The attacker does not directly capture the loss, and frequency is bounded by keeper ordering, the holder's EVE balance, strategy liquidity, and any cooldown.

**PoC Result**:
`test/audit/candidates/verification/CancellableLiabilityChurn.t.sol` passed: 2 tests passed, 0 failed, 0 skipped. One test completed two withdrawal/cancellation/redeposit cycles with exact EVE restoration; the other proved that a production-shaped LP withdrawal reaches the Converter swap path rather than being a no-op.

**Recommendation**:
Exclude the current unpriced batch from `_pendingRedemptionNeedsETH()`. Only reserve or withdraw strategy liquidity for priced, committed requests, or introduce an irrevocable commitment or proportionate cancellation cost before an unpriced request contributes to liquidity demand.

### [M-12] Stale QueueKeeper Payloads Remain Executable After the Escape Boundary [VERIFIED]

**Severity**: Medium
**Location**: `src/contracts/automation/QueueKeeperExecutor.sol:L144-L215, L299-L363`; `src/contracts/ExitQueue.sol:L253-L315`; `src/contracts/Controller.sol:L418-L449`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`checkUpkeep()` skips a priced batch after its three-day processing window, but `performUpkeep(ProcessRequests)` revalidates only affordability. It does not recheck whether the supplied batch is now expired:

```solidity
        } else if (action == QueueAction.ProcessRequests) {
            uint256 count = _affordableRequests(queue, address(controller), batchId);
            if (count == 0) revert KeeperExecutorNoUpkeepNeeded();

            controller.processRequests(batchId, 0, count);
            _advanceBatchCursor(queue);
            emit QueueUpkeepPerformed(action, batchId, count);
        } else if (action == QueueAction.AdvanceCursor) {
```

A payload generated at or before `pricedAt + MAX_BATCH_PROCESSING_TIME` can therefore be submitted by the configured Forwarder after the boundary. At that later timestamp, a fresh upkeep check would skip the batch and the request owner is allowed to cancel, yet the cached payload can still burn the escrowed EVE and settle at the old fixed price.

**Impact**:
The stale execution defeats the documented post-commitment escape hatch and creates a transaction-ordering race between user cancellation and Forwarder settlement. If settlement wins, the outcome is irreversible at the queue layer; an in-tolerance user can only claim ETH at the fixed batch price, even if retaining EVE after the expired delay would be economically preferable. Only the configured Forwarder can submit the payload, which limits exploitability but does not eliminate ordinary automation-latency risk.

**PoC Result**:
`test/audit/candidates/verification/StaleQueueExecution.t.sol` passed: 1 test passed, 0 failed, 0 skipped. It confirmed the exact equality boundary, a fresh post-boundary `AdvanceCursor` result, successful user cancellation in one branch, arbitrary-caller rejection, and successful stale Forwarder processing in the restored branch.

**Recommendation**:
Before processing a cached `ProcessRequests` action, call `_isBatchSkippable(queue, batchId)` and revert if the batch is expired. Optionally include an explicit deadline or observed `pricedAt` value in `performData` and require it to match current state, preventing delayed execution across commitment boundaries.

### [M-13] A zero DAO proposer permanently disables governance [VERIFIED]

**Severity**: Medium

**Location**: `script/ProtocolDeployBase.sol:263-267,361-378,418-421,431-460`

**Confidence**: VERIFIED

**Description**: `DAO_ADDRESS` is accepted without a non-zero check and is installed as the sole proposer of the protocol's admin `TimelockController`. OpenZeppelin records `address(0)` as a proposer, so the deployment verifier's membership check succeeds. However, scheduling uses a strict proposer-role check: no externally callable account can have `msg.sender == address(0)`. Open execution does not compensate for this because it permits anyone to execute an operation only after a valid proposer has scheduled it. The timelock renounces its temporary external administrator and the deployer later renounces Registry `ADMIN_ROLE`, leaving governance self-administered but unable to create its first repair operation.

```solidity
    function _protocolDao() internal view returns (address) {
        return vm.envAddress("DAO_ADDRESS");
    }
```

**Impact**: Upgrades, Registry rewiring, role repair, Oracle changes, configuration changes, and administrative unpausing become permanently unavailable through the intended governance system. Routine user operations may continue while the protocol is healthy, but there is no administrative recovery path once one is needed.

**PoC Result**: A pinned Forge 1.0.0 offline regression deployed the timelock with a zero proposer, confirmed that the existing verification passes, and proved that an ordinary account cannot schedule the operation needed to restore a proposer. The two-case deployment-configuration suite passed with 2 tests passing and 0 failing.

**Recommendation**: Reject zero addresses for the DAO, security council, treasury, and every other governance identity before broadcasting. Require the intended identities to be pairwise distinct where their trust tiers differ. Before renouncing bootstrap authority, enumerate the final proposer set, require at least one non-zero proposer, and prove that the final Registry administrator can schedule and execute a harmless governance operation.

### [M-14] PR workflow executes checked-out PR code with write/OIDC/OAuth job authority [CONFIRMED]

**Severity**: Medium

**Location**: `.github/workflows/claude-code-review.yml:20-24,27-51,109-166`

**Confidence**: CONFIRMED

**Description**: The pull-request job checks out the proposed repository state and runs `npm install` followed by a repository-controlled TypeScript program. The same job grants `pull-requests: write`, `issues: write`, and `id-token: write`, explicitly passes `GITHUB_TOKEN` to the architecture-check step, and later invokes an OAuth-backed third-party review action. Action references use mutable major-version tags. A same-repository pull request can therefore change package lifecycle behavior or the executed script while it runs inside a job with materially greater authority than an untrusted build requires. Fork secret restrictions reduce exposure for ordinary fork pull requests, but they do not provide a safe boundary for same-repository branches, mutable actions, or later privileged steps in the same job.

```yaml
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write

    steps:
    - name: Checkout code
      uses: actions/checkout@v4
```

**Impact**: Malicious or compromised pull-request code can abuse issue or pull-request write authority and may request an OIDC identity under any configured cloud trust. Sharing the job with the OAuth-backed review step also lets untrusted artifacts and repository instructions influence a credential-bearing action. This creates a CI supply-chain path independent of the Solidity contracts themselves.

**PoC Result**: Static workflow tracing confirmed that the checked-out repository controls both dependency installation and the executed TypeScript file, while the job-level permission and secret-bearing steps are present in the same job. No malicious pull request or credential request was executed during the audit.

**Recommendation**: Run all checked-out pull-request code in a separate unprivileged job with no secrets, no OIDC permission, and read-only repository access. Use `npm ci --ignore-scripts` unless lifecycle scripts are explicitly required, pin actions to reviewed commit SHAs, and pass only a narrowly validated artifact into a separately triggered privileged commenting/review job. Do not check out or execute pull-request-controlled code in the privileged job.


---

## Low findings

### [L-01] Explicit timelock delay bypasses the 48-hour floor [VERIFIED]

**Severity**: Low

**Location**: `script/ProtocolDeployBase.sol:31-39,348-378,431-460`

**Confidence**: VERIFIED

**Description**: The deployment code documents 48 hours as the production minimum and uses it as the default when `TIMELOCK_ADMIN_DELAY` is absent. If the variable is supplied, however, its value is forwarded directly to the `TimelockController` constructor without a lower-bound check. The final verifier checks role topology but does not compare `getMinDelay()` with the promised floor. An explicit value of zero, or any value below 48 hours, therefore deploys and verifies successfully.

```solidity
    function _deployTimelocks(address _deployer, address _proposer, address _security)
        internal
        returns (ProtocolTimelocks memory timelocks)
    {
        timelocks.adminTimelock = _deployTimelock(
            vm.envOr("TIMELOCK_ADMIN_DELAY", DEFAULT_ADMIN_TIMELOCK_DELAY), _deployer, _proposer, _security
        );
    }
```

**Impact**: The release can silently lose the review and cancellation window expected for upgrades, Registry changes, Oracle configuration, role changes, and unpausing. Exploitation requires a release-operator input error or compromised release environment, but the resulting governance policy applies protocol-wide.

**PoC Result**: A pinned Forge 1.0.0 offline regression deployed a zero-delay controller and proved that the existing verifier accepts it. The two-case deployment-configuration suite passed with 2 tests passing and 0 failing.

**Recommendation**: Resolve the delay into a full-width local value before broadcasting, require it to be at least `DEFAULT_ADMIN_TIMELOCK_DELAY`, and assert the deployed controller's `getMinDelay()` during both preflight and post-deployment verification. Record the resolved delay in a chain-qualified release manifest.

### [L-02] Finalizer omits Whitelist before renunciation [VERIFIED]

**Severity**: Low

**Location**: `script/FinalizeProtocolDeploy.s.sol:27-50`; `script/ProtocolDeployBase.sol:418-421,480-512`; `src/contracts/AMM.sol:115-132,388-390`

**Confidence**: VERIFIED

**Description**: The modular finalizer renounces the deployer's temporary Registry `ADMIN_ROLE` before running its completeness checks. `_verifyCriticalRoleGrants` resolves the core modules, Converter, and keeper executors, but omits the `WHITELIST` Registry key. Finalization can therefore succeed after a skipped Whitelist deployment or registration. Both AMM entry functions subsequently resolve the missing key and revert, while the former bootstrap deployer no longer has authority to register it.

```solidity
        vm.startBroadcast(deployerPrivateKey);

        _finalizeDeployerTieredAccess(registry, deployer);

        vm.stopBroadcast();

        _verifyDeployerTieredAccess(registry, deployer, adminTimelock);
        _verifyCriticalRoleGrants(registry, security);
```

**Impact**: All new deposits are unavailable until the timelocked administrator registers a valid Whitelist and establishes the intended admission policy. Existing exit, cancellation, and claim paths do not depend on this key and remain available, so the defect is a launch and deposit-availability failure rather than a direct loss of custody.

**PoC Result**: A pinned Forge 1.0.0 offline regression configured every key and role currently checked by the finalizer while deliberately omitting only `WHITELIST`. It proved that finalization and renunciation succeed, both entry functions fail, the former deployer cannot repair the key, and timelocked repair works only after the delay. The suite passed with 2 tests passing and 0 failing.

**Recommendation**: Add `Auth.WHITELIST` to the required Registry-key inventory. Run every module, role, and policy preflight before `vm.startBroadcast` and before renouncing bootstrap authority; keep the existing post-finalization checks as end-state assertions. Test finalization with each required key omitted in turn. For a fresh Whitelist, also verify that its signer or admission policy is initialized rather than merely checking that the key exists.

### [L-03] External preflight views bypass StrategyManager batch failure isolation [VERIFIED]

**Severity**: Low

**Location**: `src/contracts/StrategyManager.sol:989-1033`, `src/contracts/StrategyManager.sol:1080-1141`, `src/contracts/StrategyManager.sol:1177-1220`

**Confidence**: High

**Description**: StrategyManager's batch operations are intended to isolate strategy failures and continue servicing healthy peers. The mutating `deposit`, `withdraw`, `rebalance`, and `sync` calls are wrapped in `try/catch`, but the external views used before those calls are not consistently isolated.

The deposit preflight directly invokes `maxDeposit()` and `isHealthy()` for every strategy. The withdrawal preflight directly invokes every `maxWithdrawal()`. Rebalance directly calls `paused()` and `isHealthy()`, while sync directly calls `paused()`. A revert from any of these views bubbles out of StrategyManager and reverts the complete transaction. If a healthy strategy was processed before a later failing view, its work is rolled back as well.

```solidity
for (uint256 i; i < strategiesAmount; ++i) {
    IStrategy strategy = IStrategy(_strategies.at(i + _startIndex));

    uint256 maxWithdrawal = strategy.maxWithdrawal();

    if (maxWithdrawal > 0) {
```

Exploitation requires an already registered strategy to become faulty or malicious. Operators can select a range or a single strategy that excludes the failing entry, and ADMIN can force-remove it. These privileged admission and operational recovery paths limit the finding to Low severity.

**Impact**: A single registered strategy can block full-range deposit allocation, withdrawal sourcing, rebalancing, or synchronization for every healthy strategy in the batch. The principal security consequence is liveness degradation, including delayed redemption funding, rather than direct asset loss.

**PoC Result**: `test/audit/candidates/verification/StrategyBatchIsolation.t.sol` registers one failing and one healthy strategy and separately proves that reverting `maxDeposit`, `isHealthy`, `maxWithdrawal`, or `paused` aborts the corresponding batch and leaves the healthy peer unserviced. The suite result was **4 passed, 0 failed**, including the separate revert-data test described below.

**Recommendation**: Isolate every external preflight read per strategy and treat failure as ineligibility: use zero capacity for failed `maxDeposit` or `maxWithdrawal` reads, and treat failed health or pause reads as paused/unhealthy. Emit a bounded diagnostic and continue with healthy peers. Apply bounded returndata handling to these new failure paths as described in L-04.

### [L-04] Unbounded revert data defeats StrategyManager batch isolation [VERIFIED]

**Severity**: Low

**Location**: `src/contracts/StrategyManager.sol:740-753`, `src/contracts/StrategyManager.sol:1021-1033`, `src/contracts/StrategyManager.sol:1123-1141`, `src/contracts/StrategyManager.sol:1177-1186`, `src/contracts/StrategyManager.sol:1211-1220`

**Confidence**: High

**Description**: Five StrategyManager batch paths catch failures using `catch (bytes memory reason)` and emit the complete byte array. The external strategy controls the length of its revert data. Solidity must copy that returndata into the manager's memory before the catch body can execute, and logging the full dynamic value adds further memory and log cost.

```solidity
try IStrategy(strategy).deposit{value: depositAmount}() {
    totalDeposited += depositAmount;
    emit FundsDepositedToStrategy(strategy, depositAmount);
} catch (bytes memory reason) {
    emit StrategyDepositFailed(strategy, reason);
}
```

A strategy can return enough revert data to consume the transaction's remaining gas while the manager is attempting to handle the failure. The nominal `try/catch` then fails to provide isolation: the entire manager call reverts and all healthy-peer work in the transaction is rolled back.

The trigger requires a malicious or compromised registered strategy, or a strategy that propagates oversized returndata from a downstream dependency. Range and single-strategy calls can omit the failing strategy, and ADMIN can force-remove it, which limits persistence and supports Low severity.

**Impact**: A registered strategy can repeatedly prevent full-range fee settlement, deposits, withdrawals, rebalances, and syncs from completing. This can delay redemption liquidity and routine maintenance while wasting nearly the full transaction gas limit.

**PoC Result**: `test/audit/candidates/verification/StrategyBatchIsolation.t.sol` executes `syncStrategies` through a fixed 30,000,000-gas envelope. A four-byte revert is caught and the healthy peer is serviced. Changing only the revert payload to 3,000,000 bytes exhausts the envelope, makes the manager call fail, and rolls back the healthy peer's prior state change. The test consumed 29,643,761 gas; the full suite result was **4 passed, 0 failed**.

**Recommendation**: Replace dynamic Solidity catches on untrusted strategy calls with a low-level helper that copies at most a small fixed prefix of returndata, or no returndata at all. Emit a bounded prefix and hash, selector, or failure status rather than the complete payload. A per-strategy gas stipend may further contain failures, but it does not replace a strict returndata-copy bound.

### [L-05] Tokens with more than 18 decimals can freeze protocol NAV after a dust transfer [VERIFIED]

**Severity**: Low

**Location**: `src/libraries/Math.sol:40-43`, `src/contracts/Oracle.sol:263-283`, `src/contracts/StrategyManager.sol:477-485`, `src/contracts/StrategyManager.sol:940-969`, `src/contracts/strategies/UniCLStrat.sol:136-171`, `src/contracts/strategies/UniCLStrat.sol:199-203`, `src/contracts/strategies/UniCLStrat.sol:1249-1255`

**Confidence**: High

**Description**: `Math.convertDecimals` rejects token precision above 18, but neither supported-token admission in StrategyManager nor paired-token admission in UniCL validates the ERC-20 token's `decimals()` value. Oracle feed admission constrains the feed's decimals, not the token's decimals.

```solidity
function addSupportedERC20(address _token) external onlyAuthRole(Auth.ADMIN_ROLE) {
    if (_token == address(0)) revert StrategyManagerZeroAddress();
    if (_token.code.length == 0) revert StrategyManagerNoCode();
    if (!Oracle(registry().oracle()).isTokenSupported(_token)) {
        revert StrategyManagerERC20NotPriceable(_token);
    }
    if (!_supportedERC20s.add(_token)) revert StrategyManagerERC20AlreadySupported(_token);

    emit SupportedERC20Added(_token);
}
```

Both consumers skip token conversion while their balance is zero, so a misconfigured token or empty strategy can be added without exposing the incompatibility. After admission, any token holder can transfer one raw unit directly to StrategyManager or UniCL. The next NAV calculation reads the token's decimals, reaches `Math.convertDecimals`, and reverts with `MathDecimalsTooHigh`. StrategyManager propagates strategy and supported-token NAV failures into aggregate NAV, which AMM pricing, entry, and exit consume.

The initial prerequisite is a privileged configuration error: governance must first install a feed and add the token or register a UniCL strategy using it. Once that has happened, however, the trigger is permissionless and can cost only a single raw unit.

**Impact**: A dust transfer can make strategy NAV, total protocol NAV, EVE price views, new entries, new exits, and other NAV-dependent operations revert. Existing claims and cancellation paths that do not recalculate NAV remain available. SECURITY can remove a directly supported token; a UniCL instance may require pause/emergency exit or timelocked force-removal.

**PoC Result**: `test/audit/candidates/verification/TokenDecimals.t.sol` proves both paths. A 19-decimal supported token is admitted with zero balance, after which a one-unit donation freezes StrategyManager NAV and AMM pricing. A registered UniCL strategy with a 19-decimal paired token behaves identically after a one-unit donation. Result: **2 passed, 0 failed**.

**Recommendation**: Reject tokens whose `decimals()` value exceeds 18 at every consumer admission boundary, at minimum in `addSupportedERC20` and the UniCL constructor. Use an explicit custom error and cover 18-decimal acceptance and 19-decimal rejection in tests. Oracle-side validation is useful defense in depth but is not a substitute for consumer-boundary validation.

### [L-06] An unavailable UniCL TWAP window freezes aggregate NAV [VERIFIED]

**Severity**: Low

**Location**: `src/contracts/strategies/UniCLStrat.sol:199-203`, `src/contracts/strategies/UniCLStrat.sol:665-727`, `src/contracts/strategies/UniCLStrat.sol:1280-1296`, `src/contracts/StrategyManager.sol:152-172`, `src/contracts/StrategyManager.sol:924-950`

**Confidence**: High

**Description**: UniCL validates only lower bounds for its long and short TWAP intervals. Its constructor does not test whether the configured pool can serve `observe([window, 0])`, `setTwapInterval` can install a larger unavailable window, and StrategyManager registration does not probe strategy NAV or pool history.

```solidity
function _twap() internal view returns (int56 _twapTick) {
    (bool _twapAvailable, int56 _observedTwapTick) = _observeTwap(twapInterval);
    if (!_twapAvailable) revert UniCLStratPoolTWAPNotAvailable();
    return _observedTwapTick;
}
```

`navInETH` always enters the pool-balance path and requests the long TWAP, even when the strategy is empty and its positions are uninitialized. If the observation is unavailable, `_twap` reverts with `UniCLStratPoolTWAPNotAvailable`. StrategyManager intentionally does not catch strategy NAV failures, so one empty but registered UniCL instance can make aggregate NAV and all dependent pricing operations fail.

The configuration and registration steps are privileged, and the code documents pool-history provisioning as an operator prerequisite. Recovery is possible once sufficient history accrues, by lowering the interval through governance, or by force-removing the strategy. These constraints support Low severity despite the protocol-wide liveness effect.

**Impact**: Post-bootstrap AMM entry, exit, EVE price views, and new queue-batch pricing can remain unavailable until the pool accumulates sufficient observation history or governance completes a recovery. Pausing UniCL alone does not help because `navInETH` continues to request the TWAP. Force-removal restores pricing but does not itself recover strategy assets.

**PoC Result**: `test/audit/candidates/verification/TwapAvailability.t.sol` registers an empty strategy whose pool retains 1,799 seconds of history against a 1,800-second interval and observes strategy and aggregate NAV reverts. Growing history restores NAV. The test then installs a 3,600-second interval against 1,800 seconds of history and proves aggregate price, AMM entry, and AMM exit all revert; history growth, interval reduction, and force-removal each recover independently. Result: **1 passed, 0 failed**.

**Recommendation**: Before deployment, registration, and every TWAP interval update, call the pool's observation path for the proposed interval and reject the configuration unless it succeeds. Include pool observation capacity/history in the deployment verification output. Retain an explicit emergency removal procedure for later external pool failures; if StrategyManager adopts fail-soft NAV handling, it must do so only with a conservative valuation policy that cannot silently overvalue or omit active assets.

### [L-07] UniCL accepts signed configuration values that later overflow liveness paths [VERIFIED]

**Severity**: Low

**Location**: `src/contracts/strategies/UniCLStrat.sol:420-430`, `src/contracts/strategies/UniCLStrat.sol:536-558`, `src/contracts/strategies/UniCLStrat.sol:688-700`, `src/contracts/strategies/UniCLStrat.sol:801-806`, `src/contracts/strategies/UniCLStrat.sol:1280-1296`

**Confidence**: High

**Description**: Constructor and setter validation requires `positionWidth` and `maxTickDeviation` to be positive but does not enforce upper bounds derived from their later checked arithmetic.

```solidity
_validatePositiveInt24(_params.strategy.positionWidth);
_validatePositiveInt24(_params.strategy.rebalanceTickThreshold);
if (
    _params.strategy.maxTickDeviation <= 0 || _params.strategy.twapInterval < MIN_TWAP_INTERVAL
        || _params.strategy.shortTwapInterval < MIN_SHORT_TWAP_INTERVAL
) {
    revert UniCLStratInvalidConfig();
}
```

Tick construction multiplies the signed `int24 positionWidth` by pool `tickSpacing` and adds or subtracts the result from a tick floor. A positive width can therefore pass validation and later panic during the first deposit or a rebalance. Calmness checks similarly calculate `twapTick - maxTickDeviation` and `twapTick + maxTickDeviation` in checked `int56` arithmetic. A positive but excessive deviation can make `isHealthy`, `maxDeposit`, deposit, rebalance, and the non-idle withdrawal path panic for ordinary live ticks.

Only the deployer or timelocked ADMIN controls these parameters. Failed strategy actions revert atomically, and the setters remain usable while paused, so governance can recover by installing safe values. This makes the issue a configuration-induced availability failure rather than a direct asset-loss vector.

**Impact**: An accepted configuration can prevent initial capital deployment, future rebalances, health checks, keeper eligibility checks, and some withdrawals. A reverting strategy view can also propagate into batch or keeper liveness failures elsewhere in the protocol.

**PoC Result**: `test/audit/candidates/verification/UniCLConfigValidation.t.sol` proves that a constructor-accepted `type(int24).max` position width panics on the first deposit at tick spacing 60, and that an admin-accepted `type(int56).max` deviation panics `isHealthy` at TWAP tick 1. Result: **2 passed, 0 failed**.

**Recommendation**: Validate configuration against the full arithmetic domain before storing it. Compute width products and tick bounds in a wider signed type, ensure the resulting ticks remain within the Uniswap tick domain, and reject any value that cannot be narrowed safely. Bound deviation to a range for which both additions are safe for every valid TWAP tick, or perform the comparison in `int256`. Apply the same checks in the constructor and setters.

### [L-08] Zero-weight strategies cause repeated successful but no-progress upkeep [VERIFIED]

**Severity**: Low

**Location**: `src/contracts/automation/StrategyKeeperExecutor.sol:169-205`, `src/contracts/automation/StrategyKeeperExecutor.sol:229-253`, `src/contracts/automation/StrategyKeeperExecutor.sol:382-408`, `src/contracts/StrategyManager.sol:832-859`, `src/contracts/StrategyManager.sol:989-1019`, `src/contracts/StrategyManager.sol:1080-1103`

**Confidence**: High

**Description**: StrategyManager intentionally permits a registered strategy to have zero deposit or withdrawal weight. Its batch allocators return zero when every otherwise eligible strategy has zero weight. StrategyKeeper's discovery logic does not mirror this constraint: deposit capacity requires only a healthy strategy with positive `maxDeposit`, while withdrawal capacity sums positive `maxWithdrawal` values without checking withdrawal weights.

```solidity
function _depositCapacityAvailable(IStrategyManager _strategyManager) internal view returns (bool) {
    address[] memory strategies = _strategyManager.strategies();
    for (uint256 i = 0; i < strategies.length; i++) {
        IStrategy strategy = IStrategy(strategies[i]);
        if (
            !_strategyManager.isStrategyInDepositCooldown(address(strategy)) && strategy.isHealthy()
                && strategy.maxDeposit() > 0
        ) return true;
    }
    return false;
```

When every eligible strategy has zero weight for the selected direction, `checkUpkeep` chooses `DepositExcess` or `WithdrawShortfall`, but StrategyManager moves no ETH. The Controller and keeper calls still succeed, and the state that selected the action remains unchanged. The same action is therefore returned on every subsequent check and continues to outrank lower-priority work.

Zero weight is an ADMIN-supported configuration rather than an attacker-controlled input. A nonzero-weight eligible strategy or a governance weight update restores progress. The assets are not lost, but production governance recovery is timelocked and users cannot directly route around the keeper's weighted batch path.

**Impact**: Deposit-side looping wastes automation gas and can indefinitely starve fee harvest and sync while excess ETH remains idle. Withdrawal-side looping can additionally starve redemption-liquidity top-ups and keep priced exit requests unfunded despite liquid strategy assets. Users may eventually cancel after the queue escape period, but cannot receive ETH through normal automation during the no-progress state.

**PoC Result**: `test/audit/candidates/verification/ZeroWeightKeeper.t.sol` proves both directions. With a zero deposit weight, repeated successful upkeeps leave Controller ETH unchanged and never advance sync. With a zero withdrawal weight, repeated upkeeps leave a priced request unfunded although the strategy advertises sufficient liquidity. Setting the relevant weight nonzero immediately restores progress. Result: **2 passed, 0 failed**.

**Recommendation**: Make keeper eligibility mirror StrategyManager allocation exactly. Require at least one eligible strategy with a nonzero corresponding weight, and for withdrawals require positive usable capacity on a nonzero-weight strategy. After execution, treat zero actual movement as no progress, surface it explicitly, and allow lower-priority work to be considered rather than repeatedly reporting the same action as complete.

### [L-09] EnumerableSet Ordering Can Block Affordable Redemptions [VERIFIED]

**Severity**: Low
**Location**: `src/contracts/ExitQueue.sol:L195-L268`; `src/contracts/automation/QueueKeeperExecutor.sol:L336-L363`; `lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol:L86-L109, L148-L152`
**Confidence**: HIGH (PoC: PASS; material delay requires partial liquidity and favorable ordering)

**Description**:
ExitQueue stores unprocessed users in `EnumerableSet.AddressSet`. Removing an entry uses swap-and-pop, so the last requester is moved into the removed requester's index and insertion order is not preserved. QueueKeeper nevertheless treats the enumerated array as an ordered prefix and stops at the first unaffordable request:

```solidity
        batch.unprocessedUsers.remove(_user);
        batch.totalTokensToBurn -= request.tokensToBurn;
        request.processed = true;

        emit RequestPulled(_batchId, _user, !request.closedDueToSlippage);
```

An attacker can place a small request early, wait for older victims to queue, place a large request last, and cancel the early request before pricing. Swap-and-pop promotes the large tail request to index zero. Ordinary processing can create the same ordering change without an attacker.

**Impact**:
A promoted oversized request can make the affordable-prefix count zero even when Controller liquidity is sufficient to settle one or more displaced older requests. This causes unfair reordering and delays redemption under partial or temporarily illiquid conditions. It does not steal funds, and users can cancel after the three-day escape period, which bounds the impact.

**PoC Result**:
`test/audit/candidates/verification/QueueOrdering.t.sol` passed: 2 tests passed, 0 failed, 0 skipped. The tests proved both attacker-controlled tail promotion and ordinary post-processing promotion, and showed that the blocked older request remained individually processable with the same Controller balance.

**Recommendation**:
Replace set enumeration as queue order with an insertion-stable structure, such as monotonic request IDs plus a head cursor and tombstones. If throughput is preferred over strict FIFO, implement a bounded scan that can select individually affordable requests without allowing one oversized entry to force zero progress, and document the resulting fairness policy.

### [L-10] The First Bootstrap Depositor Can Capture Pre-Existing NAV [VERIFIED]

**Severity**: Low
**Location**: `src/contracts/AMM.sol:L103-L108, L349-L359, L432-L449`; `src/contracts/StrategyManager.sol:L923-L950`
**Confidence**: HIGH (PoC: PASS; practical incidence depends on pre-bootstrap funding and invitation timing)

**Description**:
When EVE supply is zero, `_bootstrap()` sizes the initial supply solely from the first deposit's USD value. It does not inspect protocol NAV that may already exist on the AMM, Controller, StrategyManager, or registered strategies:

```solidity
    function _bootstrap(uint256 _minTokensToMint, address eve, address controller) internal {
        uint256 deposit = msg.value;
        Oracle oracle = Oracle(_registry.oracle());

        uint256 depositUSD = oracle.convertTokenToUSD(address(0), deposit, Math.DECIMALS_NORMALIZED);
        if (depositUSD < MIN_INITIAL_DEPOSIT_USD) revert AMMLessThanMinInitialDeposit();

        uint256 tokensToMint = depositUSD;
        uint256 userTokens = tokensToMint - _DEAD_SUPPLY;
```

After bootstrap, the redemption price uses `StrategyManager.totalNAVInETH()`, which includes the pre-existing assets. The first depositor therefore owns nearly all genesis supply and captures nearly all residual backing despite not contributing it. AMM's unrestricted `receive()` makes pre-bootstrap native residue directly reachable.

**Impact**:
A whitelisted first depositor can extract third-party or protocol value that arrived before bootstrap. The default deployment does not itself fund these contracts, and the attacker must win the whitelist-gated first deposit, but any operationally mis-sequenced funding, donation, or residual becomes economically attributable to that depositor.

The regression donated 10 ETH to AMM before a 0.25 ETH bootstrap at a 4,000 USD/ETH price. The depositor received 999 of 1,000 EVE and immediately redeemed approximately 10 ETH, ending about 9.75 ETH above its starting balance while retaining EVE backed by the bootstrap deposit.

**PoC Result**:
`test/audit/candidates/verification/BootstrapResidual.t.sol` passed on the final run: 2 tests passed, 0 failed, 0 skipped. It confirmed both pre-bootstrap custody aggregation and profitable AMM-residual capture.

**Recommendation**:
Require total pre-bootstrap NAV to be zero, or size genesis supply from the complete post-deposit NAV rather than `msg.value` alone. Provide an explicit privileged residue-recovery procedure and enforce the intended bootstrapper and ordering as an on-chain deployment invariant before invitations are usable.

### [L-11] Fee-on-Transfer Output Breaks the Caller-Level Minimum [CONFIRMED]

**Severity**: Low
**Location**: `src/contracts/Converter.sol:L121-L215, L371-L408`; `src/contracts/adapters/UniswapV3ConverterAdapter.sol:L225-L240, L263-L278`; `src/contracts/strategies/UniCLStrat.sol:L981-L1035, L1087-L1110`
**Confidence**: HIGH (Code trace: CONFIRMED; PoC: NOT RUN)

**Description**:
Converter validates output against the balance received by Converter, then transfers that nominal amount to the authorized caller. It does not measure the caller's balance delta across the final transfer:

```solidity
        _amountOut = IERC20(_tokenOut).balanceOf(address(this)) - _balanceBefore;

        if (_amountOut < _minAmountOut) revert ConverterInsufficientOutput();

        IERC20(_tokenOut).safeTransfer(msg.sender, _amountOut);

        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _amountIn, _amountOut);
```

The exact-output path has the same boundary: it verifies that Converter received at least `_amountOut`, then transfers that nominal amount. If the output token charges a fee specifically on `Converter -> caller`, the transaction succeeds while the caller receives less than the exact-input minimum or exact-output promise. Return values and `SwapExecuted.amountOut` report the pre-tax amount.

**Impact**:
For a configured fee-on-transfer paired token, UniCL's exact-input WETH-to-token inventory trade can receive less than its slippage minimum, producing a bounded strategy and NAV loss. Intended standard-token deployments are unaffected, and swap entry points are restricted to authorized Converter callers, so this is a configuration-dependent compatibility failure rather than a permissionless drain.

**PoC Result**:
The base-source trace confirms that both swap paths enforce output before the final transfer and never compare the caller's pre- and post-transfer balances. No isolated executable PoC was run; the finding depends on a configured token whose transfer semantics deduct a fee on the final payout.

**Recommendation**:
Either reject fee-on-transfer tokens at every route and strategy admission boundary or enforce end-to-end delivery using the recipient's balance delta. Exact-input should compare and report the caller's net receipt against `_minAmountOut`; exact-output should revert unless the caller's net receipt is at least the requested amount. Events and return values should report the same net amounts guaranteed to the caller.

### [L-12] Stale supported-token dust activates a NAV freeze [CONFIRMED]

**Severity**: Low

**Location**: `src/contracts/StrategyManager.sol:473-501,940-969`; `src/contracts/Oracle.sol:355-379`

**Confidence**: CONFIRMED

**Description**: StrategyManager skips Oracle pricing for a supported ERC-20 only while its balance is zero. Any account can transfer one smallest unit of that token directly to StrategyManager. If the token's configured feed is stale or otherwise invalid at that time, the next aggregate NAV calculation calls `Oracle.convert` and propagates its revert. The source explicitly recognizes this “1-wei dust griefing” condition and provides token removal as an emergency escape hatch, but it does not prevent an unsolicited balance from activating the dependency.

```solidity
    function _supportedERC20sNAVInETH(Oracle _oracle) internal view returns (uint256 _supportedERC20sNAV) {
        uint256 supportedERC20Count = _supportedERC20s.length();
        for (uint256 i; i < supportedERC20Count; ++i) {
            address token = _supportedERC20s.at(i);
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;
            _supportedERC20sNAV +=
                _oracle.convert(token, address(0), balance, IERC20Metadata(token).decimals(), Math.DECIMALS_NORMALIZED);
        }
```

**Impact**: During a stale-feed window, a token holder can cheaply make aggregate NAV unavailable. NAV-dependent entry, redemption pricing, queue pricing, strategy automation, and fee accounting remain unavailable until the feed recovers or SECURITY removes the token. Removing a token with a real balance restores liveness by excluding that balance from NAV, which creates a separate accounting trade-off.

**PoC Result**: The deterministic state trace is: supported balance `0 -> 1`, zero-balance skip no longer applies, `Oracle.convert` reaches the stale/invalid feed check, and `totalNAVInETH()` reverts. The production comments and removal path explicitly acknowledge the same condition. No live-feed outage or standalone regression was required to confirm the control flow.

**Recommendation**: Do not let unsolicited balances add a synchronous fail-closed dependency to global pricing. Quarantine newly observed balances until their feed is healthy, or isolate an unpriceable supported token with an explicit haircut and event while automatically pausing price-sensitive entry. Add monitoring for zero-to-nonzero supported balances and feed health, and define an immediate response procedure that preserves an auditable claim on any temporarily excluded value.

### [L-13] Runtime Oracle update lacks quote-domain binding [CONFIRMED]

**Severity**: Low

**Location**: `src/contracts/Oracle.sol:263-324,344-413`; `script/ProtocolDeployBase.sol:219-238`; `script/DeployOracle.s.sol:36-48`

**Confidence**: CONFIRMED

**Description**: Initial USD-feed deployment performs an advisory `description()` suffix check for `" / USD"`. The reusable on-chain update functions do not preserve an equivalent semantic guard. Their shared `_upsertFeed` validates only a non-zero address, non-zero staleness interval, and supported decimals. A live feed with the expected ABI and decimals can therefore be stored in a USD slot despite quoting ETH, BTC, or another asset. Pair-feed updates similarly cannot establish that the feed's base and quote correspond to the ordered token pair supplied by governance.

```solidity
    function updateUsdFeedInfo(address _token, address _priceFeed, uint256 _stalenessInterval)
        external
        override
        onlyAuthRole(Auth.ADMIN_ROLE)
    {
        (bool added, address oldPriceFeed, uint256 oldStalenessInterval) =
            _upsertFeed(_tokenInfo[_token].usdFeedInfo, _priceFeed, _stalenessInterval);
```

**Impact**: A timelocked configuration mistake can deterministically corrupt protocol NAV, EVE mint and redemption prices, and strategy quote bounds while passing all on-chain admission checks. Staleness and positive-answer validation do not detect a valid but semantically wrong quote domain.

**PoC Result**: Source tracing confirmed the guard asymmetry: deployment invokes `_assertUsdQuotedFeed`, whereas runtime `updateUsdFeedInfo` and `updatePairFeedInfo` reach `_upsertFeed` without a domain check. No live feed was changed during the audit.

**Recommendation**: Bind every feed slot to explicit base and quote identifiers and validate that binding inside the Oracle update path. If feed metadata is used, treat it as one check rather than the sole source of truth; supplement it with a reviewed chain-specific feed registry, a healthy current-round check, direction tests with known values, and a timelock proposal manifest that states the intended domain and heartbeat.

### [L-14] Strategy upkeep events report requested amounts instead of actual movements [CONFIRMED]

**Severity**: Low

**Location**: `src/contracts/automation/StrategyKeeperExecutor.sol:229-253`, `src/interfaces/automation/IStrategyKeeperExecutor.sol:85-92`, `src/contracts/Controller.sol:137-162`, `src/contracts/Controller.sol:185-210`

**Confidence**: High

**Description**: `StrategyUpkeepPerformed.amount` is documented as the ETH withdrawn for a shortfall or deposited as excess. In the `WithdrawShortfall` branch, however, StrategyKeeper emits the computed shortfall after calling Controller, without observing how much ETH StrategyManager actually returned. In the `DepositExcess` branch, it similarly emits the requested excess without observing how much the strategies accepted.

```solidity
} else if (action == StrategyAction.WithdrawShortfall) {
    uint256 needsETH = _pendingRedemptionNeedsETH(registry_);
    uint256 controllerBalance = address(controller).balance;
    if (needsETH <= controllerBalance || needsETH - controllerBalance < minWithdrawETH) {
        revert KeeperExecutorNoUpkeepNeeded();
    }

    uint256 shortfall = needsETH - controllerBalance;
    controller.withdrawFromStrategies(shortfall);
    emit StrategyUpkeepPerformed(action, shortfall);
```

Both operations are explicitly partial-success paths. Strategy capacities can cap an allocation, eligibility checks can skip strategies, weighted allocation can round or return zero, and caught strategy failures can reduce the actual movement below the requested target. Controller already records the Manager's actual return and emits `(requestedAmount, actualAmount)`, demonstrating that the keeper event's single amount is a pre-call target rather than the documented completed movement.

**Impact**: Event-only dashboards, automation accounting, or alerts can overstate capital movement and mark a reserve refill or idle-fund deployment as successful when it was partial or a no-op. Operators may delay intervention while redemptions remain underfunded or funds remain undeployed. On-chain balances and authorization are not corrupted.

**PoC Result**: The mismatch is confirmed directly by the call chain. `StrategyKeeperExecutor.performUpkeep` emits `shortfall` or `excess`; `Controller` separately captures and emits the `actualWithdrawn` or `actualDeposited` value returned by StrategyManager; StrategyManager computes those actual values from Controller balance deltas and successful strategy calls. No additional runtime test was required because both requested and actual values are explicit in the same execution path.

**Recommendation**: Return the actual deposited or withdrawn amount from the Controller functions to StrategyKeeper and emit that value in `StrategyUpkeepPerformed`. If changing the Controller interface is undesirable, rename the keeper field to `requestedAmount`, update its documentation, and require monitoring to consume the Controller completion event for settlement truth. A two-field `(requestedAmount, actualAmount)` keeper event is the clearest and least ambiguous option.

### [L-15] Release inputs are not bound before broadcast [CONFIRMED]

**Severity**: Low

**Location**: `script/DeployAll.s.sol:71-84`; all broadcast entry points under `script/`; `script/DeployUniCLStrat.s.sol:91-119`; `script/DeployUniswapV3ConverterAdapter.s.sol:42-55`

**Confidence**: CONFIRMED

**Description**: Broadcast scripts select their network through the external RPC and derive the sender from `PRIVATE_KEY`, but do not assert an expected `block.chainid` or expected deployer before starting a broadcast. Separately, UniCL deployment reads environment integers and narrows them to `uint32`, `int24`, or `int56` before applying minimum and positivity checks. Solidity narrowing retains only the low bits, so the scripts validate the truncated value rather than the operator's original input. For example, `2^32 + 60` becomes an adapter interval of 60 and passes its floor, while `2^24 + 1` becomes a position width of 1.

```solidity
    function _deploymentConfig() internal view returns (IUniCLStrat.DeploymentConfig memory) {
        uint32 twapInterval = uint32(vm.envUint("TWAP_INTERVAL"));
        uint32 shortTwapInterval = uint32(vm.envUint("SHORT_TWAP_INTERVAL"));
        // The constructor enforces the same floors; checking here surfaces a clear error
        // instead of a deep constructor revert. NOTE: the target pool's observation
        // cardinality must cover TWAP_INTERVAL or navInETH() reverts until the
        // observation buffer fills (see pool.increaseObservationCardinalityNext).
        require(twapInterval >= MIN_TWAP_INTERVAL, "TWAP_INTERVAL below MIN_TWAP_INTERVAL");
        require(shortTwapInterval >= MIN_SHORT_TWAP_INTERVAL, "SHORT_TWAP_INTERVAL below MIN_SHORT_TWAP_INTERVAL");
```

**Impact**: A stale RPC, wrong signing key, or out-of-range environment value can produce a valid-looking deployment on the wrong chain, under the wrong bootstrap account, or with materially different risk parameters. These are release-operator failures rather than unprivileged on-chain attacks, but current checks do not fail closed before funds are broadcast.

**PoC Result**: Immutable-source search found no chain-ID or expected-sender assertion in the broadcast scripts. Direct cast evaluation confirms the truncation examples, and the subsequent constructor/post-deploy checks observe only the narrowed values. No release transaction was broadcast during verification.

**Recommendation**: Introduce one mandatory release-context preflight used by every broadcast entry point. It should compare `block.chainid`, `vm.addr(privateKey)`, expected Registry/timelock addresses where applicable, and a chain-qualified manifest before `vm.startBroadcast`. Read numeric inputs into `uint256` or `int256`, validate destination-type and semantic bounds, and only then cast. Post-deployment checks should compare on-chain values with the original manifest, not with already-converted locals.

### [L-16] No parity-preserving Solidity CI gate [CONFIRMED]

**Severity**: Low

**Location**: `.github/workflows/claude-code-review.yml:1-222`; `foundry.toml:1-35`

**Confidence**: CONFIRMED

**Description**: The tracked pull-request workflow runs architecture and AI-review tasks but does not run `forge fmt`, `forge build`, or `forge test`. The architecture command is explicitly `continue-on-error`. In addition, `[profile.default]`, which represents the deployment build, enables `via_ir = true`, while `[profile.ci]` omits it; neither profile pins an EVM target. A future CI job using the existing CI profile could therefore validate compiler output that is not configuration-equivalent to the deployment artifact.

```yaml
    - name: Install architecture checker dependencies
      run: |
        cd mermaid/scripts
        npm install

    - name: Run Simple Architecture Check
      id: architecture-check
      continue-on-error: true
```

**Impact**: Solidity changes can merge without a required compile, formatting, or regression-test gate, and a nominal CI build can differ from the bytecode-producing configuration. This weakens release reproducibility and can allow compile failures, test regressions, or compiler-setting-specific behavior to reach the deployment process.

**PoC Result**: Repository-wide workflow inspection found no Solidity build or test command. Configuration comparison confirmed the `via_ir` mismatch between the default and CI profiles. No failing contract change was introduced as part of the audit.

**Recommendation**: Add a required, branch-protected Solidity job using the repository-pinned Forge and Solidity versions. Run formatting checks, build, unit/fuzz/integration tests, and any explicitly configured fork suite. Make compiler, optimizer, IR, EVM-version, remapping, and dependency settings identical to deployment, and archive build-info plus bytecode hashes so source verification can reproduce the released artifacts.


---

## Informational findings

### [I-01] Taxed Input Can Consume a Pre-Existing Converter Balance [CONFIRMED]

**Severity**: Informational
**Location**: `src/contracts/Converter.sol:L141-L211, L371-L408`; `src/contracts/adapters/UniswapV3ConverterAdapter.sol:L225-L240, L263-L278`
**Confidence**: HIGH (Code trace: CONFIRMED; PoC: NOT RUN)

**Description**:
Both swap paths pull a nominal input amount without measuring how much Converter actually received. Exact-input then instructs the adapter to spend the nominal amount. Exact-output records its input baseline only after the pull and calculates a nominal refund:

```solidity
        // The full maximum must be available before the swap — the DEX router pulls
        // payment mid-swap and the exact amount is unknown until it executes. Any
        // unspent input is refunded below, in the same transaction.
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountInMaximum);

        uint256 _balanceInBefore = IERC20(_tokenIn).balanceOf(address(this));
        uint256 _balanceOutBefore = IERC20(_tokenOut).balanceOf(address(this));
```

If the incoming transfer is taxed, Converter receives less than the nominal amount. A pre-existing same-token balance can supply the difference, allowing the downstream spend and nominal refund to succeed. Such residuals can arise from unsolicited transfers or adapter behavior, and Converter has no general token sweep.

**Impact**:
An authorized caller using a configured taxed input token can consume donated or residual Converter funds to subsidize its transfer shortfall. Events continue to report nominal input semantics rather than the amount actually received from the caller. The condition requires a non-standard configured token, a same-token residual balance, and an authorized caller, so the demonstrated accounting behavior is retained as Informational.

**PoC Result**:
The base-source trace confirms that the caller-to-Converter receipt is never balance-delta checked and that both nominal spend and refund can draw on a pre-existing balance. No isolated executable PoC was run.

**Recommendation**:
Snapshot Converter's input-token balance before `safeTransferFrom`, compute the actual amount received, and use that received amount as the exact-input spend limit. For exact-output, cap spend and calculate refunds from the actual receipt attributable to the caller, not the nominal maximum. Alternatively, explicitly reject fee-on-transfer inputs and provide a controlled recovery path for residual balances.


---

## Checked and found sound

The review did not identify a current source defect in the following examined
areas, subject to the deployment-state limitations above:

- Whitelist EIP-712 domain separation, signer recovery, invite-ID replay state,
  expiry, and ban/disable enforcement;
- UUPS initializer disabling and Registry-admin upgrade authorization for the
  five proxy modules (future layout changes still require a concrete old/new
  storage diff);
- standard-token Converter balance-delta accounting, allowlisted adapter
  dispatch, and atomic rollback on failed quotes/swaps, excluding the
  fee-on-transfer cases reported here;
- ordinary same-contract reentrancy controls and UniCL callback timing guard,
  excluding the configured-pool provenance issue in M-07; and
- cross-chain message/timing and StableSwap-specific surfaces, which are not
  present in this codebase.

## Priority remediation order

1. **M-01, M-02, M-03** — correct active-share, fee-liability, and live-fee NAV
   accounting before any user-facing launch.
2. **M-04, M-05, M-06** — define supported/emergency token custody, valuation,
   conversion, and AMM-pause invariants.
3. **M-07, M-08, M-09** — authenticate the pool and make the circuit breaker and
   native-asset recovery independent of external token behavior.
4. **M-10, M-11, M-12** — align keeper predicates with executable progress and
   revalidate queue commitment state at execution.
5. **M-13, L-01, L-02, L-15** — make deployment fail closed before any broadcast
   or bootstrap-role renunciation.
6. **M-14, L-16** — isolate untrusted PR execution and add a pinned Solidity gate.
7. Address the remaining Low findings, then rerun the entire base, audit, and
   fixed-block fork suites.

## Release and trust observations

- The documented production-capable scripts consume a raw `PRIVATE_KEY`, and upgrade guidance uses plaintext `--private-key` invocation. Prefer a hardware signer or Foundry keystore account with an explicit sender, and prevent secrets from entering shell history, dotenv files, process inspection, or CI logs.
- Timelocked governance can call `forceRemoveStrategy` even when the strategy still reports value or its NAV call reverts. This is an intentional emergency loss-recognition mechanism, but it can write off funded strategy value from aggregate NAV; every use should disclose the reported amount, custody status, recovery plan, and expected effect on EVE pricing before execution.
- Performance-fee settlement uses the current fee rate for the entire uncharged historical fee base, and the current treasury receives the backlog. Existing tests encode the rate behavior, so this is a policy choice rather than a proven accounting exploit. If accrual-time economics are intended, introduce explicit fee and beneficiary epochs or checkpoint before either setting changes.
- The self-administered admin timelock is the protocol's central trust root for upgrades, Registry wiring, Oracle configuration, strategy management, and role changes. The security role can pause and cancel but cannot restore normal operation. Operational review should therefore focus on proposer/canceller membership, delay policy, multisig security, monitoring, and rehearsed recovery.
- No target-bound deployment manifest, chain ID, transaction set, runtime bytecode inventory, complete role membership, Oracle/feed manifest, pool liquidity/history, Forwarder configuration, or fixed-block fork inputs were supplied. This source audit does not attest that any live deployment matches the reviewed code or satisfies its external integration assumptions.

## Excluded or unresolved candidates

- A claim that `_requireUnregistered` swallows its own deliberate revert was
  rejected: Solidity `try/catch` catches failure of the external expression, not
  a revert executed inside the success body.
- Structural-only route validation was not promoted: the interface promises
  well-formedness, and missing pools fail atomically at quote/swap time. A
  deployment existence check remains useful hardening.
- Current performance-fee BPS reprices the uncharged base, but the base tests
  affirm this behavior. It is an economic-policy observation unless an external
  accrual-time-rate specification is adopted.
- A later-deposit charge from allegedly depleted historical fee counters was not
  reproduced; normal manager ordering leaves matching backing and settles it
  before depletion.
- Registry key replacement, different-WETH Converter migration, old/new
  allowances, exact-output rounding, checker-view failures, Oracle round
  semantics, and bounded-scan/gas concerns remain deployment-specific or
  unresolved leads. Validate them against the actual release manifest and fixed
  fork rather than treating them as confirmed findings.

## Audit artifacts

- Scope and architecture bundle: `audits/2026-08-solidity-audit/bundle/`
- Reproducible baseline: `audits/2026-08-solidity-audit/baseline.md`
- Readiness and limitations: `audits/2026-08-solidity-audit/readiness.md`
- Internal occurrence ledger: `audits/2026-08-solidity-audit/work/cross-verification-inventory.md`
- Verification reports: `audits/2026-08-solidity-audit/work/verification/`
- Focused proofs: `test/audit/candidates/verification/`
- Final proof summary: `audits/2026-08-solidity-audit/logs/26-audit-regression-summary.log`
- Coverage ledger: `audits/2026-08-solidity-audit/report_coverage.md`

## Disclaimer

This review is a time-bounded analysis of the specified source snapshot. It does
not guarantee the absence of defects and does not replace independent review,
deployment verification, a bug-bounty program, monitoring, incident response,
or secure governance and key-management procedures.
