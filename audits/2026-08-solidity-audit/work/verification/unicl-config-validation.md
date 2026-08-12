# UniCL configuration validation — independent verification

Base: `734df96` (production, scripts, interfaces, and base tests read from git objects only).

## Verdicts

| ID | Verdict | Reason |
| --- | --- | --- |
| A | **FINDING — Low** | Positive-only validation admits values that later panic in core liveness paths. The values are constructor/deployer- or 48h-timelock-controlled, transactions fail atomically, and the configuration/funds are recoverable. |
| B | **FINDING — Informational** | Deployment scripts narrow `int256`/`uint256` environment values before checking them, so out-of-range operator input can silently become an accepted in-range value. These scripts only deploy bytecode; later privileged go-live actions remain necessary. |
| C | **REJECT** | The behavior is real, but `validateRoute` is expressly a well-formedness API. Pool existence is fail-closed at quote/swap time, route choice is privileged, and failures are atomic. Treat a stronger deployment preflight as defense in depth, not a security defect. |

## A — UniCL signed configuration ranges

### Evidence and exact bounds

- `UniCLStrat._validateConstructorParams` (lines 1280-1296) checks only `positionWidth > 0` and `maxTickDeviation > 0`.
- The admin setters apply the same positive-only checks (lines 420-430 and 536-551). In production, `ADMIN_ROLE` is held by the 48h timelock (`Auth.sol` lines 64-82).
- Tick computation performs checked `int24` arithmetic (lines 801-806):
  `w = positionWidth * tickSpacing`, followed by `tickFloor - w` and `tickFloor + w`.
- For positive canonical pool spacing `s`, multiplication is safe only when
  `positionWidth <= floor((2^23 - 1) / s)`. At the base mock's `s = 60`, the largest multiplication-safe width is `139810`; `139811` and above panic.
- Even when multiplication fits, the two bounds are safe at a concrete `tickFloor = t` only when
  `w <= min((2^23 - 1) - t, t - (-2^23))`.
- Calmness performs checked `int56` arithmetic (lines 688-700):
  `minCalm = q - d` and `maxCalm = q + d`, where the long TWAP `q` originated as an `int24` and `d = maxTickDeviation`.
- A positive `d` is arithmetic-safe at a concrete `q` only when
  `d <= min(q - (-2^55), (2^55 - 1) - q)`. Thus `d = type(int56).max` panics for `q = 1` (upper addition) and for `q <= -2` (lower subtraction), though it happens to fit at `q = 0` and `q = -1`.

### Reachability and impact

- Constructor reachability: after the route prerequisites succeed, deployment stores either unsafe value without exercising this arithmetic.
- `positionWidth`: when ticks are uninitialized, the first `deposit` or `investIdleETH` reaches `_setTicks` and panics. After initialization, changing width does **not** make `isHealthy` panic and normal deposits reuse existing ticks; the new width is exercised by a later unhealthy `rebalance`, which panics. All preceding wrap/swap/remove operations roll back with that transaction.
- `maxTickDeviation`: any `isHealthy`, `maxDeposit`, `deposit`, `investIdleETH`, or `rebalance` call that reaches `_isCalm` can panic when the live TWAP has an unsafe sign/magnitude. A non-idle withdrawal also calls `_isCalm` before re-adding liquidity, so that branch can revert too. `navInETH` itself does not use this value.
- There is no unprivileged input path: constructor values come from the deployer, and post-deployment setters require `ADMIN_ROLE`.

### Recovery and severity

- Both setters remain callable while paused, so the timelocked admin can restore safe values. The immediate security role can pause; pause does not call `_isCalm`, attempts an unwind best-effort, and `emergencyExit` can return held WETH/paired assets to StrategyManager.
- Before registration, a bad deployment can simply be discarded. Registration itself is a separate timelocked `StrategyManager.addStrategy` call.
- The consequence is configuration-induced availability loss, not attacker-triggered loss or persisted partial execution. Low is appropriate; validate bounds derived from `tickSpacing`/tick domain and cap deviation so both `int56` operations are safe.

## B — narrowing environment values before validation

### Evidence

- `DeployUniCLStrat._deploymentConfig` narrows first: `uint32(envUint)` at lines 92-93, then `int24(envInt)`/`int56(envInt)` at lines 113-115. Floors/constructor positivity checks see only the narrowed values.
- `DeployUniswapV3ConverterAdapter.run` does `uint32(vm.envUint("ADAPTER_TWAP_INTERVAL"))` at line 49, then checks the already-narrowed value at line 54.
- Solidity explicit narrowing keeps the low bits. Consequently:
  - `POSITION_WIDTH = 2^24 + 2` becomes `int24(2)` and passes;
  - `MAX_TICK_DEVIATION = 2^56 + 10` becomes `int56(10)` and passes;
  - `TWAP_INTERVAL = 2^32 + 1800` becomes `uint32(1800)` and passes;
  - `ADAPTER_TWAP_INTERVAL = 2^32 + 60` becomes `uint32(60)` and passes.
- More generally, signed inputs are accepted whenever their residue modulo `2^N`, interpreted as signed, is positive; unsigned TWAP inputs are accepted whenever their residue modulo `2^32` meets the applicable floor.
- UniCL's post-deploy checks do not compare the strategy fields. The adapter check compares its immutable to the same narrowed local, so neither detects the original-input mismatch.

### Reachability, recovery, and severity

- Only the funded deployment operator controls these environment values. Neither script allowlists/registers its result: adapter allowlisting and strategy registration are later 48h-timelocked operations.
- A wrongly narrowed UniCL value can be corrected through its admin setters; before go-live it can also be redeployed. The adapter's TWAP interval is immutable, so correcting it requires deploying/re-allowlisting a replacement adapter (and updating strategy routes if used).
- This is a silent deployment footgun with potentially weaker-than-intended timing/configuration, but no attacker-controlled on-chain path. Informational severity is appropriate. Check the original `int256`/`uint256` against target-type bounds before casting, then perform semantic checks.

## C — structural route validation

### Verified behavior

- `UniswapV3ConverterAdapter.validateRoute` (lines 142-144) is pure and checks only packed-path shape and exactly one hop. `UniswapV3Path.isValidPath`/`isSingleHop` likewise do not query the factory or constrain the decoded `uint24` fee.
- UniCL construction/configuration checks converter allowlisting, structural validity, and WETH/paired-token direction (lines 593-615), so a correctly shaped path for an absent pool passes.
- Quotes decode the fee and call `factory.getPool`; zero reverts with `UniswapV3ConverterAdapterPoolNotFound` (adapter lines 288-297). The base test at `Converter.t.sol` lines 1656-1663 asserts this delayed failure.
- Swaps pass the structurally valid path to the configured router. A canonical router/factory rejects an absent or unsupported-fee pool. Converter token pulls and all earlier strategy actions roll back if the downstream call reverts.

### Boundary and disposition

- `IConverterAdapter.validateRoute` documents “well-formed” route validation (lines 55-62), so existence was not promised by this API. Quotes are permissionless; Converter execution is role-gated, and UniCL route changes require the timelocked admin.
- A bad route can temporarily deny strategy operations that require a quote/swap, but it cannot make a failed transaction retain user funds. Admin can install a valid route; pause/emergency exit remain available, including paired-token recovery.
- Therefore this is not a security finding. Optional hardening is a deployment/config preflight for `fee < 1_000_000` and `factory.getPool(tokenIn, tokenOut, fee) != address(0)`.

## Proof test

`test/audit/candidates/verification/UniCLConfigValidation.t.sol` proves (1) a constructor-accepted `type(int24).max` width panics on first deposit with spacing 60, and (2) an admin-accepted `type(int56).max` deviation panics `isHealthy` at TWAP tick 1.

Pinned offline command: Forge `1.0.0`, isolated out/cache; 2 tests passed, 0 failed. (First compile attempt lacked the explicit `stdError` import; the second passed.)

AGENT_STATUS: COMPLETE
