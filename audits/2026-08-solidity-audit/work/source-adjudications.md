# Source-only adjudications

Target: `contracts@734df96a1391e95dd40843210997da0b9f3ab05e`.

This file closes single-methodology items that did not warrant a stateful Forge
proof. Each disposition is based on the immutable target source, its public
interfaces, and its tracked operating documentation. It is internal audit
bookkeeping; client-facing IDs are assigned only in `AUDIT_REPORT.md`.

## Promoted

### SA-01 — stale supported-token dust can activate a protocol-wide NAV freeze

- Disposition: `LOW`.
- Evidence: `StrategyManager._supportedERC20sNAVInETH()` skips a zero balance,
  but any nonzero balance calls token metadata and the Oracle. The source and
  interface explicitly state that a stale or invalid feed then reverts aggregate
  NAV. `removeSupportedERC20()` comments expressly identify one-wei dust griefing
  and provide SECURITY as the circuit breaker.
- Boundary: the token must first be admitted by ADMIN and its feed must later be
  stale or invalid; SECURITY can immediately exclude it, at the cost of dropping
  its held value from NAV. The trigger itself is permissionless once those
  conditions exist.
- Recommendation: make stale-feed handling balance-independent at admission and
  monitoring time; pause price-sensitive AMM flows before excluding a nonzero
  balance, and provide a conservative/degraded accounting state.

### SA-02 — runtime Oracle updates do not bind the feed quote domain

- Disposition: `LOW`, configuration-dependent.
- Evidence: deployment helpers call `_assertUsdQuotedFeed()`, but
  `Oracle._upsertFeed()` validates address, staleness, and decimals only. A
  correctly shaped TOKEN/ETH feed can therefore occupy a TOKEN/USD slot.
- Boundary: only timelocked ADMIN can configure the feed. Feed descriptions are
  not a cryptographic identity, so the robust fix is a chain-qualified manifest
  and explicit base/quote verification rather than trusting description text
  alone.
- Recommendation: validate a current round and a reviewed base/quote manifest in
  the Oracle update path and post-deployment checks.

### SA-03 — StrategyKeeper completion events emit requested rather than actual amounts

- Disposition: `LOW`.
- Evidence: `WithdrawShortfall` and `DepositExcess` ignore the Controller return
  value and emit the pre-call `shortfall`/`excess`. StrategyManager can cap, skip,
  or catch strategy work, while Controller separately emits requested and actual
  amounts. The interface describes the keeper field as ETH withdrawn/deposited.
- Impact: log-only automation can report a successful reserve refill or deposit
  when movement was partial or zero; on-chain balances remain correct.
- Recommendation: return and emit the actual Controller delta, or rename the
  field to `requestedAmount` and require consumers to use Controller completion
  events for settlement.

### SA-04 — broadcast inputs are not completely bound before deployment

- Disposition: `LOW`, release-safety.
- Evidence: executable scripts read a raw key and start broadcast without an
  expected chain-ID/deployer assertion. UniCL/adapter scripts also narrow several
  environment integers before checking them, allowing valid-but-different values
  to pass downstream validation.
- Boundary: this requires operator error or a compromised release environment;
  it is not a runtime permissionless path.
- Recommendation: load a chain-qualified deployment manifest, assert chain and
  sender before broadcast, validate integers in their wide types, then cast and
  post-verify the original intended values.

### SA-05 — review workflow executes checked-out PR code with job-wide authority

- Disposition: `MEDIUM`, CI/repository boundary outside the Solidity primary
  scope but introduced by the target commit.
- Evidence: `claude-code-review.yml` checks out the pull-request merge commit,
  runs `npm install` and `npx tsx` from that checkout, and grants the job
  `pull-requests: write`, `issues: write`, and `id-token: write`; the same job also
  consumes `CLAUDE_CODE_OAUTH_TOKEN`. Actions are referenced by mutable major
  tags. Fork PRs normally receive reduced token/secrets, but same-repository PRs
  execute with the configured authority.
- Recommendation: split untrusted analysis from the privileged commenting job;
  run locked dependencies with lifecycle scripts disabled, pin actions by commit
  SHA, remove unused permissions, and never expose the OAuth secret to a job that
  executes PR-controlled code.

### SA-06 — repository has no parity-preserving Solidity CI gate

- Disposition: `LOW`, release-readiness.
- Evidence: the tracked workflows do not run Foundry build/test/fmt. The CI
  profile also omits default `via_ir = true`, and no EVM target or bytecode/source
  verification recipe is pinned.
- Recommendation: add required checks using the same pinned Foundry, solc,
  optimizer, IR, and EVM settings as deployment; archive compiler metadata and
  verified implementation/proxy bytecode.

## Informational / accepted-design observations

### SA-07 — treasury changes redirect the unharvested fee backlog

`setDaoTreasury()` changes the recipient used by the next fee mint. No
accrual-time beneficiary policy or treasury epoch exists, but the supplied
interfaces describe only the current receiving address. Retain as an explicit
governance-policy choice, not a vulnerability absent an external entitlement
specification.

### SA-08 — force removal deliberately permits a NAV write-off

`forceRemoveStrategy()` can omit funded or recoverable assets from NAV, but the
source, interface, README, guardrail document, and freeze runbook all describe it
as an ADMIN-timelocked escape hatch for reverting or over-reporting strategies.
The event exposes reported/dropped NAV. Treat the resulting accounting change as
a documented privileged trust boundary. Operators should pause AMM entry/exit
and reconcile custody before removal; this is operational policy rather than a
permissionless finding.

### SA-09 — cursor force-advance is an intentional governance escape hatch

The interface expressly allows ADMIN to skip a live, unexpired but permanently
illiquid batch inside the commitment window; owners retain their requests and
can close them after expiry. The missing `_isBatchSkippable()` check is therefore
intentional semantics, not a guard omission. Monitoring should alert on every
manual cursor advance.

### SA-10 — current fee rate and treasury are non-epoch governance parameters

Verification confirmed that the current BPS reprices the uncharged fee base and
the current treasury receives the next mint. Base tests affirm the BPS behavior.
Both are informational policy items unless governance specifies accrual-time
rate/beneficiary entitlements.

### SA-11 — central ADMIN authority is a stated trust assumption

The self-administered timelock controls Registry roots, UUPS upgrades, feed and
strategy configuration. Without deployed role/multisig evidence this is a trust
model, not a source vulnerability. Live deployment review must verify proposer,
canceller, executor, delay, and multisig ownership.

### SA-12 — raw-key documentation should not be the production signing path

The scripts and README support plaintext `PRIVATE_KEY` usage. This is an
operational exposure rather than a contract defect. Production releases should
use a keystore or hardware-backed account and should never log or export the key.

AGENT_STATUS: COMPLETE
