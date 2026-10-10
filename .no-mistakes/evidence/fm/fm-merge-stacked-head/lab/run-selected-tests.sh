#!/usr/bin/env bash
# Run a chosen subset of one repository test file's test functions, unmodified,
# against a source root. The test file ends with a plain list of test function
# names; this builds a temp copy that keeps every definition and helper and
# replaces only that trailing list with the names given. Nothing is written
# into the repository.
# Usage: run-selected-tests.sh <root> <tests/name.test.sh> <test_fn> [<test_fn> ...]
set -u
root=$1 file=$2
shift 2
src="$root/$file"
first=$(grep -n '^test_[a-z_0-9]*$' "$src" | head -1 | cut -d: -f1)
[ -n "$first" ] || { echo "no test list found in $src" >&2; exit 2; }
for name in "$@"; do
  grep -qx "$name" "$src" || { echo "$name is not a listed test in $file" >&2; exit 2; }
done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-selected.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2016 # the literal source line of the test file is matched.
head -n "$((first - 1))" "$src" \
  | sed 's|^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib.sh"$|. "'"$root"'/tests/lib.sh"|' > "$tmp/selected.test.sh"
grep -qF ". \"$root/tests/lib.sh\"" "$tmp/selected.test.sh" || { echo "could not repoint lib.sh" >&2; exit 2; }
printf '%s\n' "$@" >> "$tmp/selected.test.sh"
cd "$root" && bash "$tmp/selected.test.sh"
