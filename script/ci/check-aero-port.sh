#!/usr/bin/env bash
# Flags a UniCLStrat range / LP-fee change that does not touch the Aero implementation.
#
# AeroCLStrat is no longer a textual copy of UniCLStrat: its range management and LP-fee logic live
# in AeroCLRangeLib / AeroCLPositionLib. A security fix to UniCLStrat (or to the range / LP-fee
# functions in UniCLStratLib that the Aero libraries mirror) must be ported by hand
# (CLAUDE.md §8a, docs/STRATEGY_GUARDRAILS.md §1.1.2).
#
# The parity suites (test/unit/AeroCLStratParity.t.sol, test/fuzz/AeroCLStratParityFuzz.t.sol) run
# every UniCLStrat unit/fuzz test against AeroCLStrat, so a fix that ships with a test is already
# enforced. This check covers the rest: a diff that changes the UniCLStrat side and none of the
# Aero side fails, unless the PR carries the `aero-port-not-needed` label (set by the reviewer
# after confirming the change does not apply to Aero, e.g. swap math the Aero libraries call
# straight from UniCLStratLib).
#
# Usage: check-aero-port.sh <base-ref>   (CI sets AERO_PORT_ACK=true when the label is present)
set -euo pipefail

base="${1:?usage: check-aero-port.sh <base-ref>}"

uni_paths=(
  src/contracts/strategies/UniCLStrat.sol
  src/libraries/strategies/UniCLStratLib.sol
)
aero_paths=(
  src/contracts/strategies/AeroCLStrat.sol
  src/libraries/strategies/AeroCLRangeLib.sol
  src/libraries/strategies/AeroCLPositionLib.sol
)

changed="$(git diff --name-only "${base}...HEAD")"

uni_changed=()
for p in "${uni_paths[@]}"; do
  if grep -qxF "$p" <<<"$changed"; then uni_changed+=("$p"); fi
done
[ ${#uni_changed[@]} -eq 0 ] && { echo "aero-port: no UniCLStrat changes"; exit 0; }

for p in "${aero_paths[@]}"; do
  if grep -qxF "$p" <<<"$changed"; then
    echo "aero-port: UniCLStrat and Aero sides both changed; reviewer confirms the port"
    exit 0
  fi
done

if [ "${AERO_PORT_ACK:-false}" = "true" ]; then
  echo "aero-port: UniCLStrat changed without an Aero change; acknowledged via label"
  exit 0
fi

echo "::error::UniCLStrat changed (${uni_changed[*]}) but AeroCLStrat / AeroCLRangeLib / AeroCLPositionLib did not."
echo "Port the fix to the Aero libraries, or add the 'aero-port-not-needed' label once a reviewer"
echo "has confirmed it does not apply (CLAUDE.md §8a, docs/STRATEGY_GUARDRAILS.md §1.1.2)."
exit 1
