#!/usr/bin/env bash
# Guards against drift between UniCLStrat and its Slipstream copy, AeroCLStrat.
#
# AeroCLStrat.sol is the UniCLStrat body with the Slipstream deltas inlined (6-field slot0,
# tick-spacing provenance, inlined cardinality gate, naming). This script diffs the two files
# with line numbers stripped and compares the result to a committed baseline:
#   - a change applied identically to both files leaves the diff unchanged -> passes;
#   - a change applied to only one file (e.g. a security fix) alters the diff -> fails.
# When the new delta is intentional, regenerate the baseline with `--update` and justify the
# delta in the PR.
#
# Usage: script/ci/check-strategy-drift.sh [--update]
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

BASE=src/contracts/strategies/UniCLStrat.sol
COPY=src/contracts/strategies/AeroCLStrat.sol
BASELINE=script/ci/strategy-drift/AeroCLStrat.diff

# -U0: changed lines only, so shared context shifting never matters. Drop the file and hunk
# headers (line numbers shift when both files change identically). `git diff` instead of
# `diff`: BSD (macOS) and GNU diff align ambiguous blocks (e.g. a `}` + blank line) differently.
current() {
    git diff --no-index --no-color --no-ext-diff -U0 --histogram "$BASE" "$COPY" \
        | grep -v -e '^diff --git' -e '^index ' -e '^---' -e '^+++' -e '^@@' || true
}

# Compare as a sorted multiset of +/- lines, so even a diff-algorithm alignment difference
# between git versions cannot cause a false failure. A one-sided change still alters the set.
normalize() {
    LC_ALL=C sort
}

if [[ "${1:-}" == "--update" ]]; then
    current > "$BASELINE"
    echo "Updated $BASELINE"
    exit 0
fi

if ! cmp -s <(normalize < "$BASELINE") <(current | normalize); then
    diff -u "$BASELINE" <(current) || true
    cat >&2 <<MSG

Strategy drift: the delta between $BASE and $COPY changed (shown above:
'-' = delta in the baseline, '+' = delta now).
A change applied to only one strategy must be mirrored in the other. If the new delta is
intentional, run 'script/ci/check-strategy-drift.sh --update' and explain it in the PR.
MSG
    exit 1
fi
echo "No strategy drift: $COPY matches $BASE up to the baseline delta."
