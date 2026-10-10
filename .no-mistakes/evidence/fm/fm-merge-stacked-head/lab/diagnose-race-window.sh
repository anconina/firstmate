#!/usr/bin/env bash
# Diagnosis only. Runs tests/fm-pr-check-security.test.sh's
# test_teardown_cannot_race_authority_consumption from a temp copy in which the
# watcher poll's hold is widened from 0.5s to <seconds>, to tell a timing
# failure on a loaded host from a behaviour failure. The repository's test file
# is not modified.
# Usage: diagnose-race-window.sh <root> <seconds>
set -u
root=$1 seconds=$2
src="$root/tests/fm-pr-check-security.test.sh"
first=$(grep -n '^test_[a-z_0-9]*$' "$src" | head -1 | cut -d: -f1)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-diag.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2016 # literal source lines of the test file are matched.
head -n "$((first - 1))" "$src" \
  | sed 's|^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib.sh"$|. "'"$root"'/tests/lib.sh"|' \
  | sed 's|FM_TEST_GH_SLEEP=0.5 FM_TEST_CHECK_TIMEOUT=3 \\|FM_TEST_GH_SLEEP='"$seconds"' FM_TEST_CHECK_TIMEOUT=120 \\|' \
  > "$tmp/diag.test.sh"
[ "$(grep -c "FM_TEST_GH_SLEEP=$seconds FM_TEST_CHECK_TIMEOUT=120" "$tmp/diag.test.sh")" -eq 1 ] \
  || { echo "could not widen the window" >&2; exit 2; }
echo test_teardown_cannot_race_authority_consumption >> "$tmp/diag.test.sh"
cd "$root" && bash "$tmp/diag.test.sh"
