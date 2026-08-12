# Pre-Audit X-Ray — Architecture and Attack-Surface Map

> Pashov X-Ray v2–guided Tier 0 artifact. This is an architecture/profile handoff, **not** a vulnerability review. “Review focus” and “candidate invariant” statements below are questions for later independent passes, not findings.

## Target at a glance

| Field | Value |
|---|---|
| Immutable snapshot | [`734df96a1391e95dd40843210997da0b9f3ab05e`](https://github.com/everstrat-xyz/contracts/tree/734df96a1391e95dd40843210997da0b9f3ab05e) |
| Scope | Full runtime/library/deployment source snapshot |
| Primary scope | 39 files / 4,849 normalized LOC |
| Runtime/local-library slice | 25 files / 3,884 normalized LOC |
| Deployable contracts | 13: 5 UUPS/ERC1967 modules and 8 static contracts |
| Main value model | ETH-funded pooled strategy system with NAV-priced EVE receipt token |
| Strategy/integration | Uniswap V3-style WETH/paired-token concentrated liquidity |
| Automation | Two static Chainlink Automation executors, each gated to a configured Forwarder |
| Governance | Registry-centric roles; scripts intend 48-hour admin timelock plus immediate security multisig |
| Test baseline | 1,169 pass / 0 fail / 15 fork skips excluding gas benchmarks; full offline preflight 1,176 / 0 / 15 |
| Coverage | `--ir-minimum` primary-scope aggregate 93.13% lines / 79.39% branches / 97.09% functions; source-map caveat |

The portable nSLOC recomputation replaces the bundled enumerator's invalid zero counts: the host `/usr/bin/grep` does not support the script's GNU `-P` option. Physical file enumeration and git analysis remained usable; only grep-derived counts were recomputed with `rg`, Perl and `awk`.

## System map

```text
                                      DAO proposer / open executor
                                                   |
                                                   v
                                    48h Admin TimelockController
                                                   |
                                                   v
User / relayer ---> Whitelist ---> AMM <------> Registry <------ Security multisig
       |              |             |               |             (pause/emergency)
       |              |             | mint/burn     |
       |              |             v               |
       |              +-----------> EVE              |
       |                            |                |
       | enter ETH                  | queued EVE     |
       v                            v                |
      AMM ---- ETH ----> Controller <----> ExitQueue |
       ^                    |    ^            ^       |
       | claim ETH          |    |            |       |
       |                    v    |            |       |
       +-- exit float -- StrategyManager -----+       |
                              |                        |
                              v                        |
                           UniCLStrat <----------------+
                              |  ^      registered identities/roles
                              |  |
                    WETH / paired token
                              |  |
                              v  |
                           Converter --delegatecall--> allowed Adapter
                              |                             |
                              +------ Uniswap Router <------+
                                             |
                                   Uniswap Pool / Factory

Oracle <---- Chainlink Data Feeds
  ^                  |
  +---- price/NAV ---+---- Adapter and UniCL TWAP/price cross-checks

Chainlink nodes --checkUpkeep--> QueueKeeperExecutor / StrategyKeeperExecutor
Chainlink Forwarders --performUpkeep--> executors --KEEPER_ROLE--> Controller
```

Addresses for peer modules are normally resolved from Registry at call time. This makes Registry state both the address book and a contract-identity authorization boundary.

## Component inventory

| Component | Upgrade model | Assets/state controlled | Principal external authority |
|---|---|---|---|
| Registry | Static | Contract keys and all protocol role membership/admins | `ADMIN_ROLE`; pause also `SECURITY_ROLE` |
| AMM | Static | ETH entry/exit float, EVE escrow, claim liabilities, connector weight | Users; registered Controller; admin/security circuit breaker |
| EVE | Static ERC-20 | Pooled receipt-token supply/balances | `MINTER_ROLE` for mint/burn; users for ERC-20 transfers |
| Controller | UUPS | Idle ETH and orchestration of strategies/redemptions | `KEEPER_ROLE`; admin/security emergency; admin upgrades |
| ExitQueue | UUPS | Request batches, prices, tolerances and unprocessed-user sets | Registered AMM/Controller; admin/security pause; admin upgrades |
| StrategyManager | UUPS | Strategy set/weights, idle ETH/ERC-20s, total NAV and fee dilution | Registered Controller; admin config; admin/security emergency; admin upgrades |
| Oracle | UUPS | Supported token/pair feed registry and staleness policy | Admin feed/config changes; admin upgrades |
| Converter | UUPS | Temporary WETH/ERC-20 balances, adapter allowlist, delegatecall execution | Converter callers; registered StrategyManager for caller roles; admin upgrades/config |
| Whitelist | Static EIP-712 | Invite signers, used invites, admitted/banned users, irreversible disable flag | Permissionless voucher relay; admin and limited security signer removal |
| QueueKeeperExecutor | Static | Queue cursor and batch/upkeep parameters | Chainlink Forwarder performs; admin config; admin/security pause |
| StrategyKeeperExecutor | Static | Reserve/liquidity/threshold/sync policy | Chainlink Forwarder performs; admin config; admin/security pause |
| UniswapV3ConverterAdapter | Static/immutable | No intended storage; code executes in Converter context during swaps | Converter allowlist is the trust gate |
| UniCLStrat | Static | ETH/WETH/paired token, two LP positions, fee snapshots, route/risk parameters | Registered StrategyManager; admin config; admin/security emergency; pool callback |

## Primary value flows

### 1. Entry and EVE issuance

1. A user calls `AMM.enter` after Whitelist admission or `enterWithInvite` with an EIP-712 voucher.
2. On the first deposit, Oracle converts ETH to USD, the AMM locks a dead EVE supply and mints the remainder to the user.
3. Later deposits price EVE at the AMM premium derived from pre-deposit protocol NAV and connector weight.
4. ETH is forwarded to Controller; AMM mints EVE to the depositor via its Registry `MINTER_ROLE`.

### 2. Capital deployment

1. StrategyKeeperExecutor simulates policy through `checkUpkeep`; its configured Forwarder calls `performUpkeep`.
2. The executor, which holds `KEEPER_ROLE`, calls Controller.
3. Controller funds StrategyManager to the requested amount.
4. StrategyManager allocates across registered, healthy, non-cooling strategies using admin-owned weights/capacity.
5. UniCLStrat wraps ETH through Converter, balances WETH/paired-token inventory, and mints two Uniswap V3 positions.

### 3. Immediate exit

1. AMM computes the EVE base price from total NAV/supply and the burn amount for requested ETH.
2. If AMM free balance covers the payout, it burns user EVE (allowance required) and sends ETH immediately.
3. `lockedForClaims` is excluded from the free balance and NAV contribution.

### 4. Queued exit and claim

1. When AMM free balance is insufficient, it escrows user EVE and pushes a request into the current ExitQueue batch.
2. QueueKeeperExecutor eventually asks Controller to price the batch at the same base EVE price used for exits.
3. StrategyKeeperExecutor estimates redemption needs, withdraws strategy liquidity into Controller when needed and may top up AMM's immediate-exit float.
4. QueueKeeperExecutor processes an affordable prefix; Controller supplies ETH to AMM, which burns EVE or returns it when tolerance closes the request.
5. Successful payout becomes `claimableBalances[user]` and increases `lockedForClaims`; the user later pulls ETH via `claim()`.
6. Unpriced requests can be cancelled; priced requests gain an escape hatch after `MAX_BATCH_PROCESSING_TIME`.

### 5. Performance fees

1. UniCLStrat tracks LP fees with cumulative earned/charged counters plus aggregate `tokensOwed` snapshots.
2. StrategyManager asks each strategy to settle an ETH-equivalent fee base.
3. The manager mints EVE to the DAO treasury using dilution against total supply/NAV and accounts cumulative EVE fees.
4. Fees may be harvested explicitly, by automation, or inline around strategy withdrawals.

### 6. Emergency and governance operations

1. `SECURITY_ROLE` can immediately pause core modules and trigger specified capital-recovery paths, but cannot unpause/configure/upgrade.
2. UniCLStrat pause attempts a best-effort pool unwind; emergency exit sends available ETH and then best-effort paired tokens to StrategyManager.
3. Controller can move idle ETH back to AMM; StrategyManager can move idle ETH back to Controller.
4. Scripts intend all `ADMIN_ROLE` powers to end at a minimum-48-hour TimelockController, with DAO proposal/cancellation, security cancellation and open execution after delay.
5. A deployment EOA holds a temporary bootstrap admin grant until `FinalizeProtocolDeploy` renounces it.

## External entrypoint census

Across the 13 concrete ABIs there are 362 function selectors: 155 ABI non-view/payable and 207 view/pure. Five UUPS selectors and three ERC-20 transfer/approval selectors are inherited; 147 non-view/payable selectors are defined in protocol source. Adding five payable `receive()` functions gives **152 source-defined non-view/payable call entry points**. There are no `fallback()` functions. This is an ABI classification, not proof that every nominally non-view function writes storage (for example, Converter quote dispatch is intentionally non-view-compatible).

Highest mutating-selector ABIs:

| Contract | Count | Surface shape |
|---|---:|---|
| StrategyManager | 31 | Strategy lifecycle, allocation, NAV/fees, supported tokens, pause/upgrade |
| Controller | 25 | Keeper orchestration, queue settlement, emergency, pause/upgrade |
| UniCLStrat | 19 | LP actions, fee settlement, configuration, emergency, pool callback |
| Converter | 13 | Wrap/unwrap/swap/quote dispatch, roles, adapter config, pause/upgrade |
| Registry / StrategyKeeperExecutor | 11 each | Role/address administration; automation policy/action execution |
| AMM | 10 | Entry, exit, cancellation, claim, settlement and configuration |

The full per-contract count and entrypoint classification are in `profile.md`.

## Callback and receiver map

| Callback/receiver | Authorization/state expectation |
|---|---|
| `UniCLStrat.uniswapV3MintCallback` | `msg.sender == pool` and `_minting == true`; transfers token0/token1 payment and clears `_minting` |
| Both `checkUpkeep` functions | Public view simulations; encode an action from current state |
| Both `performUpkeep` functions | Only configured Forwarder; untrusted action data and live predicates are revalidated |
| `Whitelist.whitelist` | Permissionless relay; EIP-712 signer, invite ID, user and deadline provide authorization/replay state |
| `UniCLStrat.selfRemoveLiquidityAndCollect` | `msg.sender == address(this)`; allows pause to catch pool unwind failure |
| `receive()` on AMM | Adds exit float/NAV unless locked for claims |
| `receive()` on Controller | Adds idle deployable/redemption ETH |
| `receive()` on StrategyManager | Adds in-flight NAV/strategy allocation balance |
| `receive()` on Converter | Receives WETH unwrap proceeds during authorized flows |
| `receive()` on UniCLStrat | Receives WETH unwrap/donations and contributes to NAV |
| Proxy `initialize(...)` | Expected in ERC1967 constructor calldata; implementation constructors disable initializers |

## Trust boundaries

1. **User ↔ AMM/Whitelist:** public capital and voucher inputs, slippage bounds, allowances and pull claims.
2. **Registry ↔ every module:** mutable address resolution and role membership determine both routing and authorization.
3. **Timelock/security/deployer ↔ Registry:** delayed governance, immediate emergency response and temporary bootstrap privilege have distinct intended capabilities.
4. **Chainlink nodes/Forwarders ↔ executors:** simulation output is untrusted; only a configured Forwarder may execute; executor—not Chainlink—holds protocol keeper privilege.
5. **Controller ↔ StrategyManager ↔ arbitrary registered strategy:** admin-selected strategy code reports health, capacity and NAV and receives protocol ETH.
6. **Converter ↔ allowed adapter:** adapter code executes by `delegatecall` in Converter storage/balance context; allowlisting is a full-code trust decision.
7. **Protocol ↔ ERC-20/WETH:** token decimals, transfer/approval behavior, callbacks/reverts and balance accounting cross contract boundaries.
8. **Oracle ↔ Chainlink feeds:** feed decimals, positive answers, timestamps, staleness and deployment-time feed identity.
9. **UniCL/adapter ↔ Uniswap V3:** pool identity, tick/TWAP availability, observation history, LP callbacks, router/factory behavior and price movement.
10. **Source ↔ deployment state:** scripts express intended roles/configuration, but actual production addresses, calldata, roles, feeds and bytecode were not supplied.

## Candidate invariants for later independent review

These are test/review targets, not assertions that currently fail.

### EVE, NAV and claims

- After bootstrap, EVE supply is non-zero and the dead supply remains irrecoverable.
- Deposit pricing excludes the in-flight `msg.value`; exit pricing uses backing NAV/base price.
- `AMM.freeBalance() == address(AMM).balance - lockedForClaims` and `lockedForClaims <= balance`.
- Aggregate user claim liabilities equal `lockedForClaims`; a successful claim clears exactly one user's liability once.
- NAV includes each owned value location exactly once: strategies, StrategyManager, Controller, AMM free balance and supported ERC-20s.
- EVE performance-fee dilution preserves the intended fee/NAV relationship and cannot advance charged fee state on a zero-rounded fee.

### Queue state machine

- A user has at most one live request per batch; processed/cancelled requests leave the unprocessed set exactly once.
- Batch `totalTokensToBurn` equals the sum of live unprocessed request amounts.
- Pricing advances `currentBatchId` exactly once and creates the next batch timestamp.
- A priced request is final during the commitment window and user-closable after it; out-of-tolerance requests consume zero ETH and return EVE.
- Keeper cursor is monotonic, does not pass the live batch, and its bounded scan/skip semantics agree between the two executors.

### Capital routing and strategies

- Controller/StrategyManager/strategy balance deltas conserve ETH across deposit/withdrawal success, partial success and catch paths.
- Registered-strategy weights, health, max capacity and cooldown filters used by automation agree with StrategyManager execution.
- StrategyManager never counts a strategy or supported-token value twice, and failure/force-removal semantics match the chosen fail-closed/fail-open boundary.
- Emergency paths remain reachable under the pause states and external degradation they are designed to handle.

### Converter and Uniswap integration

- Only intended strategies hold `CONVERTER_CALLER_ROLE`; Converter remains the sole manager of that role through registered StrategyManager calls.
- Allowed adapter route token decoding agrees with actual router input/output; balance deltas—not adapter return data—bound payouts/refunds.
- `delegatecall` adapters are immutable/stateless under the storage layout assumed by Converter; token approvals are cleared or intentionally infinite only at documented boundaries.
- Every pool mint sets `_minting`, accepts exactly the configured pool callback, pays at most requested token amounts and clears `_minting` on success/revert paths.
- LP principal, idle balances and `tokensOwed` contribute to NAV/fee accounting once; fee `charged <= earned` and snapshots advance/reset consistently.
- TWAP windows, tick rounding and Oracle cross-checks use consistent directions/decimals in both swap directions and exact-input/exact-output modes.

### Authorization and deployment

- Each privileged function's Registry role or registered-contract identity matches the intended tier; pause/unpause asymmetry is consistent.
- Registry role-admin edges remain: ADMIN self-admin; KEEPER/MINTER/SECURITY/manager under ADMIN; converter caller under converter-caller-manager.
- At finalization, the deployment EOA no longer has Registry admin; intended role holders and Registry keys are complete before renunciation.
- Proxy implementation contracts cannot be initialized, proxy initialization is atomic, and upgrades preserve storage layouts/Registry bindings.
- Timelock proposer/executor/canceller/admin membership and minimum delay match the intended governance model.

## Structural review priority map

This ordering allocates later audit attention; it is not a severity list.

| Priority | Surface | Why it is structurally dense |
|---:|---|---|
| 1 | AMM ↔ StrategyManager NAV/EVE pricing ↔ fee dilution | One accounting system connects deposits, exits, queued liabilities, idle funds, strategy-reported NAV and minted supply |
| 2 | ExitQueue + both keeper executors + Controller | Multi-transaction state machine, time windows, bounded scans, affordability, partial processing and pull claims |
| 3 | UniCLStrat + Converter + adapter | External pool/router/feed state, callbacks, `delegatecall`, approvals, decimal/rounding, LP fee snapshots and emergency degradation |
| 4 | Registry/timelock/deployment scripts/UUPS | Mutable identities and roles govern every module; correctness depends on ordered bootstrap and finalization |
| 5 | Oracle and supported ERC-20 NAV | Feed identity/decimals/staleness and fail-closed NAV behavior propagate to entry/exit availability |
| 6 | Whitelist/EIP-712/Forwarders | Replay/domain/deadline/signer state and meta-caller boundaries |

## History and readiness weighting

- Git history is too short to provide strong independent evidence: 5 commits, 2 source-touching commits, 7 days.
- The bulk monorepo import is classified by the x-ray git script as a high-score “fix candidate” because it adds many guards/domains; that is a heuristic artifact, not evidence of a historical security fix.
- The 6-line post-import UniCL change receives extra history attention because it is the only focused source delta, but it is not a finding by itself.
- In the current target/current tree, no tracked prior audit report exists. Historical side-branch internal/AI artifacts are indexed in `history.md` and are not treated as an independent external audit.
- Mainnet fork tests, static-readiness completion and property/invariant tooling remain prerequisites before any claim of exhaustive validation. Coverage now has a usable `--ir-minimum` aggregate (93.13% lines / 79.39% branches / 97.09% functions), but ordinary coverage is blocked by stack-too-deep and IR-minimum source maps carry an accuracy caveat.
- Actual deployed configuration is outside the supplied source snapshot and must be reviewed separately if production assurance is expected.

## Downstream handoff

- `scope.md` is authoritative for primary finding locations and exclusions.
- `profile.md` is authoritative for counts, build posture, actors/assets/integrations and raw routing signals.
- `manifest.md` is authoritative for every loaded/skipped skill and weak-trigger rationale.
- `context.md` and `history.md` are separate shared-bundle inputs; historical/AI material must not anchor or pre-seed independent vulnerability passes.
- Later agents should independently validate the candidate invariants above and report both leads and cleared areas in the common finding format.
