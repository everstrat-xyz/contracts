# Token-decimals NAV DoS verification

Scope: immutable commit `734df96a1391e95dd40843210997da0b9f3ab05e`. I read base source/interfaces/docs/tests only, excluding prior audit work and audit tests. Regression: `test/audit/candidates/verification/TokenDecimals.t.sol`.

## Verdict

**CONFIRMED for both StrategyManager supported ERC-20 admission and UniCL paired-token construction/registration. Suggested severity: Low.**

Once governance configures a token whose ERC-20 `decimals()` is greater than 18, any holder can donate one raw unit to the relevant contract and make protocol NAV and AMM pricing revert. The full availability impact is real, but it requires prior privileged token/feed/strategy configuration and has explicit security-role recovery paths; those constraints reduce it from Medium.

## Root cause

`Math.convertDecimals` rejects either precision above 18 with `MathDecimalsTooHigh` (`src/libraries/Math.sol:40-43`). Oracle feed admission validates only the Chainlink **feed's** decimals (`Oracle.sol:349-352, 386-408`); `updateUsdFeedInfo` neither queries nor bounds the ERC-20 token's decimals (`:263-283`). Thus a token can be Oracle-supported while its own decimals are unusable by conversion.

## Path 1 — StrategyManager supported ERC-20

`addSupportedERC20` checks nonzero address, deployed code, Oracle support, and uniqueness, but never calls or validates token `decimals()` (`StrategyManager.sol:477-485`). A zero-balance entry appears healthy because NAV deliberately skips conversion when `balance == 0` (`:961-969`).

After one raw unit is transferred to StrategyManager, `_supportedERC20sNAVInETH` calls:

```text
Oracle.convert(token, ETH, 1, token.decimals(), 18)
```

For a 19-decimal token this reaches `normalizeDecimals(1, 19)` and reverts `MathDecimalsTooHigh`. `_totalNAVInETH` does not catch it (`StrategyManager.sol:940-950`). `AMM.eveBasePriceInETH()` obtains NAV from StrategyManager, so the same revert freezes pricing (`AMM.sol:356-359, 488-490`); enter and exit also depend on that NAV (`:138-156, 397-412`).

The regression proves admission succeeds with zero balance, then a one-unit attacker donation makes both `totalNAVInETH()` and `eveBasePriceInETH()` revert.

## Path 2 — UniCL paired token

The UniCL constructor selects the non-WETH pool leg as `pairedToken` but does not validate its decimals (`UniCLStrat.sol:136-171`). Constructor validation covers addresses and numeric strategy parameters only (`:1280-1296`), while StrategyManager registration performs no NAV/decimals validation (`StrategyManager.sol:152-172`). A 19-decimal paired-token strategy can therefore be constructed and registered while empty.

After one raw paired-token unit is donated, `UniCLStrat.navInETH()` values the nonzero token balance (`UniCLStrat.sol:199-203`) through `_tokenValueInETH`, which passes `pairedToken.decimals()` to Oracle (`:1249-1255`). The resulting `MathDecimalsTooHigh` propagates from the registered strategy through StrategyManager total NAV and AMM pricing.

The regression deploys and registers such a UniCL strategy, transfers exactly one raw unit to it, and observes the expected revert from all three views: strategy NAV, total NAV, and AMM base price.

## Reachability and impact

- Privileged prerequisite: an admin must first register a USD feed and either add the token to StrategyManager's supported set or deploy/register a UniCL strategy using it. These are configuration/deployment mistakes, not permissionless token admission.
- Permissionless trigger after configuration: any holder of a normally transferable token can transfer one raw unit directly; neither receiving contract can reject it.
- Blast radius: fail-closed total NAV blocks AMM prices and the enter/exit paths that read them. Other NAV-dependent controller/fee operations can also revert.
- Dust cost: one unit of a 19-decimal token is `1e-19` token, so the economic cost can be negligible.

## Recovery

- Supported ERC-20: `removeSupportedERC20` makes no external calls and is callable by `SECURITY_ROLE` or `ADMIN_ROLE`, even with a nonzero balance (`StrategyManager.sol:488-501`). The regression confirms security removal immediately restores total NAV and AMM price while the donated unit remains held but excluded from NAV.
- UniCL: security/admin can `pause()` and then `emergencyExit()` (`UniCLStrat.sol:460-517`). For a standard transferable paired token, this moves the dust to StrategyManager without pricing it; if it was not separately whitelisted there, strategy/total NAV and pricing recover immediately. The regression confirms this path. Admin can also `forceRemoveStrategy`; production documentation places that admin operation behind the timelock.
- If the paired token itself blocks transfers, the instant UniCL evacuation may fail to clear its balance (the transfer is best-effort); force removal then remains the NAV escape hatch.

## Test evidence

Attempt 1 of maximum 3:

```text
FOUNDRY_OUT=out-audit-token-decimals-verification \
FOUNDRY_CACHE_PATH=cache-audit-token-decimals-verification \
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/TokenDecimals.t.sol -vvv
```

Result: `2 passed; 0 failed; 0 skipped`.

- `test_SupportedERC20_DustFreezesNAVAndPricingUntilSecurityRemovesIt` — PASS
- `test_UniCLConstructorAcceptsHighDecimalsThenDustFreezesProtocolNAV` — PASS

The post-suite signature-cache warning was sandbox-only and did not affect compilation or execution.

## Remediation

Reject tokens with `IERC20Metadata(token).decimals() > 18` at every admission boundary: at least `addSupportedERC20` and the UniCL constructor. Prefer a dedicated custom error and test 18 (accepted) versus 19 (rejected). Validating when the feed is registered is useful defense-in-depth, but it cannot replace consumer-boundary validation because native ETH and arbitrary token addresses share the Oracle registry.

AGENT_STATUS: COMPLETE
