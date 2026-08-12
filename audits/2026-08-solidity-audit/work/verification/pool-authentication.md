# Pool authentication verification

## Verdict: CONFIRMED

Commit reviewed: `734df96a1391e95dd40843210997da0b9f3ab05e`.

`UniCLStrat` will accept a caller-supplied, interface-compatible pool without authenticating it against an expected Uniswap V3 factory. Once governance registers the resulting strategy and Controller allocates funds, that configured pool can choose arbitrary callback amounts up to the strategy's token balances and receive them during `mint`. The regression demonstrates a successful 10 ETH deposit after which an attacker owns all 10 ETH-equivalent WETH/paired-token inventory and strategy NAV is zero.

## Exact evidence

- `src/interfaces/strategies/IUniCLStrat.sol:20-24,41-45` makes `pool` a raw address in constructor deployment config; there is no factory field.
- `src/contracts/strategies/UniCLStrat.sol:136-155` stores that address as immutable `pool`, trusts its reported `token0()`, `token1()`, and `tickSpacing()`, and only ensures one reported token equals configured WETH. It does not call `factory()`, `getPool(token0,token1,fee)`, or otherwise verify pool provenance.
- `src/interfaces/integrations/uniswap/IUniswapV3Pool.sol:9-58` exposes no `factory()` method. A repository search of the pinned production strategy finds no factory authentication.
- `src/contracts/strategies/UniCLStrat.sol:732-755` calculates a liquidity argument, sets `_minting = true`, and calls the configured `pool.mint(...)`. The returned `amount0/amount1` values are ignored.
- `src/contracts/strategies/UniCLStrat.sol:524-531` authorizes the callback only by `msg.sender == address(pool)` and `_minting`. It transfers the callback-supplied `_amount0` and `_amount1` to the configured pool without bounding those amounts to the strategy's locally calculated mint amounts.
- `script/DeployUniCLStrat.s.sol:91-120` takes `POOL_ADDRESS` directly from the environment. Its post-deployment checks at lines 76-84 validate registry/TWAP constants, not pool provenance. Registration is a separate timelocked step (lines 39-49, 86-88).
- `src/contracts/StrategyManager.sol:152-173` permits admin/timelock registration of any code-bearing strategy; it does not inspect the strategy's pool. `depositToStrategy` is Controller-only (lines 327-337), then `_depositToStrategy` calls the registered strategy with ETH (lines 1049-1064).

## Reachability and token flow

1. A deployer supplies a malicious pool address that implements the small `IUniswapV3Pool` surface and reports `(WETH, pairedToken)`, plausible tick spacing/price, and calm TWAP observations. The constructor succeeds.
2. Production governance/admin must register this exact deployed strategy through `StrategyManager.addStrategy`; ordinary external users cannot configure the immutable pool or self-register it.
3. A normal Controller-authorized allocation calls `strategy.deposit{value: amount}`. The strategy wraps ETH and balances roughly half the inventory into the paired token before `_addLiquidity`.
4. While `_minting` is true, the configured pool's `mint` calls back asking for the strategy's complete WETH and paired-token balances. Both transfers succeed because they are no greater than the held balances.
5. The pool forwards the received assets to the attacker and returns successfully. `deposit` and StrategyManager accounting both report success, while the malicious pool reports no position and the strategy's NAV becomes zero.

The attack does not need callback reentrancy, private-state manipulation, or an independently callable callback. `_minting` correctly restricts timing but does not make an unauthenticated configured pool trustworthy.

## Regression test

File: `contracts/test/audit/candidates/verification/PoolAuthentication.t.sol`

The test uses local tokens/converter/oracle, a real proxied `StrategyManager`, admin registration, and a code-bearing registered Controller caller. `MaliciousConfiguredPool` is deliberately not factory-created. It implements calm pool views, requests both complete token balances during `mint`, forwards them to `poolAttacker`, and reports no position.

Command (pinned Foundry 1.0.0, offline, isolated artifacts):

```sh
/private/tmp/everstrat-foundry-v1.0.0/forge test --offline \
  --match-path test/audit/candidates/verification/PoolAuthentication.t.sol \
  --out out-audit-verify-pool --cache-path cache-audit-verify-pool -vv
```

Result:

```text
[PASS] test_ConfiguredNonFactoryPoolDrainsDepositDuringMintCallback() (gas: 511978)
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

The first run compiled but its setup used an EOA Controller and failed Registry's `RegistryContractNoCode()` check. Replacing it with the existing code-bearing `MockController` made the same exploit test pass; this was a harness correction, not an exploit-condition change.

## Severity reasoning

Impact is critical in isolation: every token held by the strategy when minting can be transferred irreversibly to an attacker, including newly allocated user capital, and the transaction appears to succeed. Repeated future deposits could also be drained up to `maxTotalNAV` unless operators intervene.

Practical likelihood is governance/deployment-error dependent, not permissionless against an already-correct immutable deployment. The attacker must cause a malicious pool address to be included in the constructor config and the resulting strategy to pass the separate admin/timelock `addStrategy` process. Therefore this is best treated as **High** if the contract is expected to enforce pool authenticity on-chain (catastrophic loss after one bad address survives review), with likelihood reduced by the 48-hour governance review and off-chain deployment checklist. It is not a permissionless Critical finding against a correctly configured production strategy.

## Missing preconditions / limits

- The immutable pool on an existing strategy must already be malicious; an arbitrary attacker cannot replace it after deployment.
- The maliciously configured strategy must be registered by `ADMIN_ROLE`/timelock and receive a nonzero Controller allocation (or later admin `investIdleETH` on donated ETH).
- The pool must return coherent constructor/view values and satisfy calm/TWAP calls long enough to reach `mint`.
- Callback amounts above actual balances revert `SafeERC20`; the demonstrated malicious pool asks for exactly the balances, so this is not a barrier.
- A legitimate canonical Uniswap V3 pool cannot arbitrarily choose callback amounts; factory authentication would bind the callback sender to that known implementation/deployment lineage.

AGENT_STATUS: COMPLETE
