# Tier 0 Readiness Handoff

Status: ready for the manual/multi-methodology review, with the limitations below. This status describes audit infrastructure readiness, not protocol security.

## Verified

- The exact target commit builds and tests successfully using the repository-pinned Foundry `1.0.0` and Solidity `0.8.30` in offline mode.
- All 1,176 non-skipped tests pass.
- Pinned formatting passes and deployable bytecode remains below EVM runtime/initcode limits.
- Production npm dependencies report no advisories; Solidity git submodules are initialized and clean.
- No production source, test, script, configuration or lockfile was changed during Tier 0.

## Limitations to carry into the audit report

1. Fifteen mainnet-fork tests were not exercised because `MAINNET_RPC_URL` and a fixed `MAINNET_FORK_BLOCK` were unavailable.
2. Coverage required `--ir-minimum`; its source maps are explicitly less accurate than normal coverage. Seven gas-budget tests were excluded only from the successful coverage pass because instrumentation changes gas costs. The pinned non-instrumented full suite, including those tests, passes.
3. No Slither, Aderyn, Mythril or Semgrep executable was available. Their absence limits automated static-analysis coverage.
4. Solhint reports 59 source warnings plus 5 test-only console errors; the full npm development tree has six transitive advisory packages through Solhint. Treat these as tooling/readiness items, not protocol findings.
5. The global Foundry `1.7.1` formatter disagrees with the pinned `1.0.0` formatter on 20 files. The authoritative pinned formatter passes.
6. Foundry could not write its global signature cache due to the filesystem sandbox. Builds and tests still completed successfully.

## Suggested reproducibility inputs

- Target SHA: `734df96a1391e95dd40843210997da0b9f3ab05e`
- Foundry: `1.0.0`, commit `8692e926198056d0228c1e166b1b6c34a5bed66c`
- Solc: `0.8.30`
- Full offline validation: `forge build --offline --force`, `forge test --offline -vv`, and `forge build --offline --sizes`
- Fork validation when credentials are provided: set `MAINNET_RPC_URL` and an explicit `MAINNET_FORK_BLOCK`, then run `forge test --match-path 'test/fork/*'`
