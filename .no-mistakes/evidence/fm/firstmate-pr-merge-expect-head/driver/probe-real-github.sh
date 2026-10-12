#!/usr/bin/env bash
# Read-only probe of bin/fm-pr-merge.sh --expect-head against the real GitHub.
#
# Target: an ALREADY MERGED public pull request, which GitHub cannot merge
# again, read through the real gh behind driver/readonly-gh, which forwards
# only reads and blocks everything else. Each run uses its own disposable
# marked lab home; nothing is written anywhere but that home.
#
# Usage: probe-real-github.sh <worktree-root> <work-dir> <owner/repo> <number>
set -u
ROOT=$1
WORK=$2
REPO=$3
NUMBER=$4
DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="https://github.com/$REPO/pull/$NUMBER"
REAL_GH=$(command -v gh) || { echo "gh is not on PATH" >&2; exit 1; }
REAL_CONFIG=${GH_CONFIG_DIR:-$HOME/.config/gh}
FAILS=0

check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then printf '  PASS  %s\n' "$desc"; else FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$desc"; fi
}

new_case() {
  SC="$WORK/$1"
  LAB="$SC/lab"
  mkdir -p "$SC"
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  mkdir -p "$SC/bin" "$SC/user-home"
  ln -s "$DRIVER/readonly-gh" "$SC/bin/gh"
  for t in gh-axi glab tea; do ln -s "$DRIVER/blocked-cli" "$SC/bin/$t"; done
  git init -q -b main "$SC/wt"
  (
    cd "$SC/wt" || exit 1
    printf '# wt\n' > README.md
    git add README.md
    git -c user.name='fm lab' -c user.email=lab@example.invalid commit -qm initial
    git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
  )
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 10' > "$LAB/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  printf '%s\n' 'window=fm-task-x1' "worktree=$SC/wt" "project=$SC/project" \
    'kind=ship' 'mode=no-mistakes' > "$LAB/state/task-x1.meta"
  : > "$SC/gh.log"
}

run_merge() {
  printf '\n$ bin/fm-pr-merge.sh'
  printf ' %q' "$@"
  printf '\n'
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$LAB" HOME="$SC/user-home" PATH="$SC/bin:$PATH" \
    READONLY_GH_LOG="$SC/gh.log" READONLY_GH_REAL="$REAL_GH" READONLY_GH_CONFIG="$REAL_CONFIG" \
    "$ROOT/bin/fm-pr-merge.sh" "$@" > "$SC/stdout" 2> "$SC/stderr.raw"
  RC=$?
  grep -v '^●' "$SC/stderr.raw" > "$SC/stderr" || true
  printf 'exit code: %s\n' "$RC"
  [ ! -s "$SC/stdout" ] || sed 's/^/  stdout| /' "$SC/stdout"
  [ ! -s "$SC/stderr" ] || sed 's/^/  stderr| /' "$SC/stderr"
  printf 'calls that reached the gh gate:\n'
  sed 's/^/  | /' "$SC/gh.log"
}

rc_is() { [ "$RC" -eq "$1" ]; }
stderr_has() { grep -qF -- "$1" "$SC/stderr"; }
stderr_lacks() { ! grep -qF -- "$1" "$SC/stderr"; }
no_blocked() { ! grep -q '^BLOCKED' "$SC/gh.log"; }
no_merge_call() { ! grep -qF 'pr merge' "$SC/gh.log"; }
no_locks_left() { [ ! -e "$LAB/state/.control-task-x1.lock" ] && [ ! -e "$LAB/state/.afk-contract.lock" ]; }

printf 'product: %s\ncommit:  %s\n' "$ROOT/bin/fm-pr-merge.sh" "$(git -C "$ROOT" rev-parse HEAD)"
printf 'real CLI: %s (%s)\n' "$REAL_GH" "$("$REAL_GH" --version | head -1)"
printf 'target:  %s\n' "$URL"
INDEPENDENT=$("$REAL_GH" pr view "$URL" --json state,headRefOid --jq '.state + " " + .headRefOid')
LIVE_STATE=${INDEPENDENT%% *}
LIVE_HEAD=${INDEPENDENT#* }
printf 'independent read of the target: state=%s headRefOid=%s\n' "$LIVE_STATE" "$LIVE_HEAD"
[ "$LIVE_STATE" = MERGED ] || { echo "refusing to probe: the target is not an already merged pull request" >&2; exit 1; }
STALE=0000000000000000000000000000000000000001

printf '\n=== R1  real GitHub: an expected head that is not the live head is refused ===\n'
new_case r1-mismatch
run_merge task-x1 "$URL" --expect-head "$STALE"
check "exit 1" rc_is 1
check "the refusal names the head GitHub really reports as live" stderr_has "the live head $LIVE_HEAD is not the expected head $STALE"
check "no merge call was attempted" no_merge_call
check "nothing but reads reached the gate (no BLOCKED line)" no_blocked
check "locks were released" no_locks_left

printf '\n=== R2  real GitHub: the real live head passes the expected-head check ===\n'
new_case r2-match
run_merge task-x1 "$URL" --expect-head "$LIVE_HEAD"
check "no expected-head refusal: the real head string compares equal" stderr_lacks 'is not the expected head'
check "the run then refuses for the unrelated reason that the pull request is not open" stderr_has 'state is "MERGED", not open'
check "exit 1" rc_is 1
check "no merge call was attempted" no_merge_call
check "nothing but reads reached the gate (no BLOCKED line)" no_blocked
check "locks were released" no_locks_left

printf '\n%s failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
