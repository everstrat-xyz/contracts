# Verification: supported-token removal opens a dilution window

VERDICT: CONFIRMED

SEVERITY: Medium

CONFIDENCE: High for authorization, custody/NAV transitions, dilution math, and realizable profit; medium for occurrence because exploitation depends on an unsafe operational remove/re-add sequence and specific value ratios.

BASE: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`. Only immutable production source, interfaces, and base tests were inspected through `git show`. No prior audit output, existing audit test, history, network, live system, production edit, or commit was used.

## Confirmed state transition

`StrategyManager.removeSupportedERC20` is callable by either ADMIN_ROLE or SECURITY_ROLE, has no pause precondition, balance check, asset movement, or external call (`StrategyManager.sol:488-502`). Its documented effect with a held balance is to drop that balance from NAV immediately. The base tests separately confirm SECURITY removal and removal with a nonzero balance (`test/unit/StrategyManager.t.sol:1874-1890,1914-1927`).

Removal changes only the supported-address set. The ERC20 remains held by StrategyManager, while `_supportedERC20sNAVInETH` stops reading it (`StrategyManager.sol:940-969`). It does not call `AMM.pause`; AMM entry remains enabled unless SECURITY/ADMIN performs a separate pause (`AMM.sol:115-132`). Pausing StrategyManager alone also does not gate the AMM's view-based NAV read.

Re-addition is ADMIN-only and requires the token still have an Oracle feed (`StrategyManager.sol:477-485`). In production, ADMIN is the 48-hour timelock while SECURITY is an immediate multisig (`Auth.sol:64-92`). Thus SECURITY can open the window but cannot close it; an honest later ADMIN re-add after feed/token recovery is sufficient to complete the value transfer.

## Why entry during omission captures value

Post-bootstrap entry prices EVE at the premium price using current NAV, supply, and connector weight, excluding the in-flight deposit (`AMM.sol:397-423`). If removing the token reduces counted NAV, an entrant mints more EVE. Re-adding the unchanged custody later restores NAV across the now-diluted supply.

Let:

- `A` = all NAV that remains counted during removal;
- `R` = Oracle value restored on token re-add;
- `S` = supply before the window deposit;
- `D` = attacker deposit;
- `c` = connector weight as a fraction in `(0,1]`.

During omission the premium price is `A/(S*c)`, so the attacker receives `x = D*S*c/A`. After re-add its base-value claim is:

`V = x*(A + D + R)/(S + x) = D*c*(A + D + R)/(A + D*c)`.

Therefore `V > D` exactly when `R > A*(1-c)/c`, ignoring integer rounding. At the default `c = 0.5`, restored token value must exceed the NAV left counted. At `c = 1`, any positive restored value is dilutive. If `A == 0`, entry encounters a zero price/division and cannot execute; if `R` is below the threshold, premium pricing prevents profit.

## Regression state trace

Created `test/audit/candidates/verification/SupportedTokenRemoval.t.sol`; no production changes. It uses the real Registry roles, Whitelist, AMM, Controller, StrategyManager, Oracle, ExitQueue, and EVE flow.

1. Existing holder bootstraps with 10 ETH at $4,000/ETH: total supply is 40,000 EVE (39,999 holder plus one dead EVE).
2. StrategyManager receives 120,000 supported $1 tokens, worth 30 ETH. Counted NAV becomes 40 ETH, and custody is recorded.
3. A distinct SECURITY_ROLE account removes support. Custody remains 120,000 tokens; counted NAV becomes 10 ETH; both AMM and StrategyManager remain unpaused.
4. A whitelisted attacker deposits 1 ETH while the token is omitted. At the default 50% connector weight it receives exactly 2,000 EVE, and included NAV becomes 11 ETH.
5. ADMIN re-adds the same held token. Custody never moves; NAV becomes 41 ETH and supply is 42,000 EVE.
6. The attacker's 2,000 EVE base-value claim becomes approximately 1.95238 ETH. The pre-existing holder's claim falls by approximately 0.95236 ETH.
7. The attacker queues a 1.9 ETH exit, the Controller prices and processes it from its 11 ETH native balance, and the attacker claims. After paying the 1 ETH deposit, its ETH balance increases by approximately 0.9 ETH, proving realizable value transfer.

Pinned offline command:

`FOUNDRY_OUT=/private/tmp/supported-token-removal-out FOUNDRY_CACHE_PATH=/private/tmp/supported-token-removal-cache /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/SupportedTokenRemoval.t.sol -vvv`

Attempt 1/3: PASS — 1 passed, 0 failed, 0 skipped. The sole warning was Foundry's denied attempt to flush a global signature cache outside the isolated output/cache paths.

## Preconditions and bounds

- The attacker cannot remove or re-add the token and must already be whitelisted (or hold a valid invite).
- A SECURITY compromise alone cannot force re-add; profit requires ADMIN eventually restoring the token at sufficient Oracle value. A scheduled timelock re-add is public and makes the endpoint predictable.
- Omitted value must exceed the connector-weight-dependent threshold above. Changes in the token's recovered Oracle price change `R` and can eliminate profit.
- The attacker locks `D` until re-add and risks loss if the token is never restored.
- Realized ETH profit additionally requires native liquidity. Without it, the attacker only gains a larger claim against the same non-convertible token custody.
- Explicitly pausing AMM before removal and keeping it paused until re-add/final loss allocation prevents the tested entry. The code does not enforce this operational sequence or make removal and AMM pause atomic.

## Severity rationale

Medium is appropriate because a documented emergency recovery operation can transfer existing holders' economic ownership to opportunistic depositors and the regression realizes that transfer in native ETH. It is conditional on privileged remove/re-add actions, a favorable NAV ratio, whitelist access, and available native settlement liquidity; those requirements keep it below High. It is more than Low because no role compromise is necessary: an honest stale-feed removal followed by later re-add can create the same public entry window.

## Recommendation

Enforce a valuation-exception mode across AMM and StrategyManager: removing a held supported asset should atomically block `enter` (and carefully define exit behavior) until governance either restores it or permanently crystallizes the loss. At minimum, require AMM pause before nonzero-balance removal and require re-add/finalization before unpause. Consider an epoch/snapshot mechanism if deposits must continue, so restored value accrues only to supply that existed when the asset was excluded.

AGENT_STATUS: COMPLETE
