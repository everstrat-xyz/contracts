# Tier 0 Baseline

This document records build and test facts only. It is not a vulnerability assessment.

## Target

- Branch: `audit/solidity-audit-skills-734df96`
- Commit: `734df96a1391e95dd40843210997da0b9f3ab05e`
- Platform: EVM / Solidity / Foundry
- Scope inventory: 25 implementation and library files, 3,884 normalized LOC
- Context-only inventory: 21 interfaces, 40 test files, 14 deployment scripts

## Pinned toolchain result

The repository-required Foundry `1.0.0` was run from a portable binary with commit `8692e926198056d0228c1e166b1b6c34a5bed66c`. The configured compiler was Solidity `0.8.30` with optimizer and `via_ir=true`.

- Offline clean build: PASS; 173 files compiled.
- Compiler diagnostics: 30 warnings, all in test or mock files (5 unchecked low-level-call results, 23 `view` suggestions, 2 `pure` suggestions). No compiler warning was emitted for `src/`.
- Offline full test suite: PASS; 1,176 passed, 0 failed, 15 skipped, 1,191 total across 43 suites.
- Skips: all 15 are `test/fork/UniCLStratFork.t.sol` and require `MAINNET_RPC_URL` plus `MAINNET_FORK_BLOCK`.
- Pinned formatter check (`FOUNDRY_PROFILE=ci forge fmt --check src/ test/`): PASS.
- Bytecode limits: PASS for every deployable production contract. The smallest runtime margins are `UniCLStrat` at 947 bytes and `StrategyManager` at 2,140 bytes.

## Test harness

- Executed suites: 32 unit, 7 integration, 3 fuzz and 1 fork suite.
- Executed tests by path: 1,075 unit, 91 integration, 10 dedicated fuzz-file tests and 15 skipped fork tests.
- Static inventory: 1,191 test functions, 2,448 assertion/expect calls, 546 `expectRevert` calls, 158 `expectEmit` calls and 227 zero/max-value edge-case pattern hits.
- 32 executed fuzz tests reported 256 runs each. No `invariant_*` test declaration was found.

## Coverage

Plain `forge coverage` cannot compile `script/DeployAll.s.sol` after coverage disables `viaIR` (`Stack too deep`). Foundry's documented `--ir-minimum` fallback produced a report, with the expected warning that source mappings may be inaccurate.

The first fallback run generated LCOV but failed only `test_GasBenchmark_AddStrategy` because coverage instrumentation raised gas above its fixed threshold. A second fallback excluded the seven `test_GasBenchmark_*` functions and completed with 1,169 passed, 0 failed and 15 fork skips.

For in-scope `src/` files, the generated LCOV reports 2,032/2,182 lines, 366/461 branches and 433/446 functions hit. Named lower-coverage areas include `UniCLStrat`, `UniswapV3ConverterAdapter`, `KeeperExecutorBase`, and the Uniswap helper libraries `FullMath`, `LiquidityAmounts`, `TickMath` and `UniswapV3Path`. Exact zero-hit functions and lines are listed in `logs/12d-forge-coverage-scope-summary.log`.

## Lint, dependencies and analyzers

- Foundry 1.7.1 `forge lint src`: completed with 19 warnings (15 timestamp-pattern and 4 type-cast diagnostics). These are raw analyzer leads, not triaged findings.
- Solhint 4.5.4 on `src/`: 59 warnings and 0 errors, primarily ordering, mapping-value naming and naming/import rules.
- Solhint on `src/` plus `test/`: 1,117 warnings and 5 errors. The errors are console imports/statements in `ETHFlowTest.t.sol`, `AMM.t.sol` and `Controller.t.sol`.
- `npm audit --omit=dev`: 0 production advisories.
- Full npm dev tree: 1 moderate and 5 high transitive advisory packages, all below the direct `solhint` development dependency.
- All recursive git submodules are initialized and clean.
- Slither, Aderyn, Mythril and Semgrep CLIs were not installed, so no run was performed. Foundry lint and Solhint were the available static tooling.

## Logs

Raw evidence is under `audits/2026-08-solidity-audit/logs/`. The most compact entry points are:

- `25-pinned-baseline-summary.log`
- `12d-forge-coverage-scope-summary.log`
- `14a-lint-format-summary.log`
- `15d-dependency-audit-summary.log`
- `16c-solhint-summary.log`
- `18-static-analyzer-availability.log`
