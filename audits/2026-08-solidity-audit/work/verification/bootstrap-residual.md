# Verification: first bootstrap depositor captures pre-existing NAV

VERDICT: CONFIRMED

SEVERITY: Low

CONFIDENCE: High for reachability, accounting, and the AMM-residual profit proof; medium for practical incidence because the standard deployment creates no residual and the first depositor is whitelist-gated.

BASE: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`. Source, interfaces, deployment scripts, and base test helpers/mocks were read through `git show`. `git diff --quiet 734df96 -- src test/helpers test/mocks` returned 0 before the regression run, confirming imported code matched the immutable base. No prior audit output, existing audit test, history, network, live system, production edit, or commit was used.

## Confirmed mechanism

On the first `enter`, `_bootstrap` converts only `msg.value` to USD and mints that amount of EVE: one EVE to the dead address and the remainder to `msg.sender` (`AMM.sol:432-449`). It never reads pre-existing NAV. At a $4,000/ETH feed, the minimum 0.25 ETH deposit therefore mints 1,000 EVE, of which the first depositor owns 999 EVE (99.9%).

Immediately afterward, all pre-existing counted assets enter the base redemption price because `_navInETH()` delegates to `StrategyManager.totalNAVInETH()` (`AMM.sol:349-359`), while exits settle at `NAV / totalSupply` (`AMM.sol:151-170,329-332`). The first depositor consequently owns approximately 99.9% of both its deposit and any residual backing, even though the residual did not contribute to initial supply sizing.

The strongest user-only realization path is residual ETH already on the AMM. Its unrestricted `receive()` accepts ETH (`AMM.sol:103-108`), and free AMM ETH is counted in NAV and is immediately available to exits. The regression donates 10 ETH before bootstrap, lets one admin-whitelisted user bootstrap with 0.25 ETH, and obtains:

- supply: 1,000 EVE, attacker balance: 999 EVE;
- post-bootstrap NAV: 10.25 ETH;
- immediate (batch ID zero) redemption of approximately 10 ETH from the residual;
- attacker ETH after the 0.25 ETH deposit and exit exceeds its starting balance by approximately 9.75 ETH, while it retains some EVE backed by the Controller deposit.

This proves profitable capture rather than only an accounting discrepancy.

## Assets reachable before bootstrap

The complete production core is deployed, registered, granted roles, given an ETH feed, and optionally given an invite signer without any bootstrap call (`DeployAll.s.sol:84-119`). Thus the zero-supply, fully wired state is reachable on-chain.

Counted pre-bootstrap locations are:

- AMM native free balance: unrestricted receive; counted by StrategyManager through `IAMM.freeBalance()`.
- Controller native balance: unrestricted receive (`Controller.sol:52-57`); counted directly.
- StrategyManager native balance: explicitly accepts top-ups and unsolicited ETH (`StrategyManager.sol:96-104`); counted directly.
- Every registered strategy's reported NAV. The shipped `UniCLStrat` accepts native ETH and includes idle ETH, token balances, and LP value (`UniCLStrat.sol:175,199-203`). Registration is ADMIN/timelock-gated and occurs through the modular go-live flow, not core `DeployAll` (`DeployUniCLStrat.s.sol:39-50`).
- Supported ERC20 balances held by StrategyManager, once an ADMIN has installed an Oracle-backed token entry (`StrategyManager.sol:465-486,961-969`).

`StrategyManager._totalNAVInETH` is the exact aggregation point for all five categories (`StrategyManager.sol:923-950`). The regression separately sends 1/2/3 ETH to AMM/Controller/StrategyManager before bootstrap and observes exactly 6 ETH total NAV at zero supply.

Not counted are native/token balances on unrelated core contracts, assets of unregistered strategies, and unsupported ERC20s. Core `DeployAll` deliberately deploys no strategy and sends no initial ETH (`DeployAll.s.sol:39-42,92-114`), so the default deployment does not itself create a capturable balance.

## Access, realization, and bounds

The first depositor must pass the Whitelist (`AMM.sol:115-132`). Production seeds an invite signer but does not designate or enforce a unique bootstrapper (`DeployAll.s.sol:103-114`), so any approved invite holder can win the first deposit if invitations exist before official bootstrap. Operations can prevent the issue by bootstrapping atomically before releasing invites, but that invariant is off-chain.

AMM residual is immediately realizable, as proven. Controller ETH can fund queued settlement or be moved to AMM by keepers/security. StrategyManager/registered-strategy native value is recoverable through privileged/keeper withdrawal flows. In contrast, the current release only accounts for supported ERC20 residual and explicitly defers on-chain swap recovery (`StrategyManager.sol:465-468`); that component may inflate the attacker's NAV claim without being immediately redeemable in ETH.

The attacker needs at least the $1,000 bootstrap deposit and cannot profit by donating only its own residual: value capture requires pre-existing third-party/protocol value. The one-EVE dead supply leaves at least 0.1% of NAV uncapturable at the minimum deposit, but larger bootstrap deposits make the first user's fraction approach 100%. Whitelist control, absence of protocol-created residual in the standard flow, and reliance on donation/mis-sequenced funding reduce likelihood; arbitrary residual loss is nevertheless real, supporting Low severity.

## Regression

Created `test/audit/candidates/verification/BootstrapResidual.t.sol`; no production changes.

Pinned offline command:

`FOUNDRY_OUT=/private/tmp/bootstrap-residual-out FOUNDRY_CACHE_PATH=/private/tmp/bootstrap-residual-cache /private/tmp/everstrat-foundry-v1.0.0/forge test --offline --match-path test/audit/candidates/verification/BootstrapResidual.t.sol -vvv`

- Attempt 1/3: compiled; native custody test passed; profit test reached the expected state but lacked the user's normal EVE allowance before `burnFrom` (1 passed, 1 failed).
- Attempt 2/3: PASS — 2 passed, 0 failed, 0 skipped. A non-fatal signature-cache warning reflected sandbox denial outside the isolated build/cache paths.

## Recommendation

Make bootstrap supply/accounting include pre-existing NAV, or require total NAV to equal the pending first deposit (equivalently, require zero pre-existing NAV before bootstrapping) and expose a privileged recovery path for any residue. Also make the intended bootstrapper/order an on-chain deployment invariant rather than relying on invitation timing.

AGENT_STATUS: COMPLETE
