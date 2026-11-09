#!/usr/bin/env bash
# Reproduces the AeroCLStrat library-split parity check (PR #58).
#
# Runs one fork scenario (deposit, sync, partial withdraw, settle, rebalance, top-up, non-calm
# withdraw, investIdleETH, near-full withdraw, pause, emergencyExit) against the pre-split
# single-contract AeroCLStrat and the current split version, at the same address from the same fork
# state, and requires identical observable state after every step (235 values at the time of the
# split).
#
# The pre-split contract is not kept in the tree (~1,200 lines). It is extracted from git at
# LEGACY_REF, renamed to AeroCLStratLegacy, and removed again on exit together with the test.
#
# Needs MAINNET_RPC_URL (archive) and MAINNET_FORK_BLOCK after the 2026-10-22 Aero launch.
# Usage: script/ci/run-aero-split-differential.sh [legacy-ref]
set -euo pipefail

LEGACY_REF="${1:-99f7fb1}" # last commit with the single-contract AeroCLStrat
root="$(git rev-parse --show-toplevel)"
cd "$root"

legacy_dir="test/fork/legacy"
legacy="$legacy_dir/AeroCLStratLegacy.sol"
test_file="test/fork/AeroCLStratDifferential.t.sol"
[ -e "$legacy" ] || [ -e "$test_file" ] && { echo "refusing to overwrite $legacy / $test_file" >&2; exit 1; }

cleanup() { rm -rf "$legacy_dir" "$test_file"; }
trap cleanup EXIT

mkdir -p "$legacy_dir"
git show "${LEGACY_REF}:src/contracts/strategies/AeroCLStrat.sol" \
  | sed -e 's#"\.\./\.\./#"../../../src/#' -e 's/^contract AeroCLStrat is/contract AeroCLStratLegacy is/' \
  > "$legacy"
cp parity/AeroCLStratDifferential.t.sol "$test_file"

forge test --match-contract AeroCLStratDifferentialTest -vv
