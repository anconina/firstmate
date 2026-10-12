#!/usr/bin/env bash
# Live drive of bin/fm-pr-merge.sh --expect-head.
#
# The product under test is the real bin/fm-pr-merge.sh from the worktree given
# as $1, run the way an operator runs it: as a CLI against a firstmate home.
# Each scenario gets its own disposable marked lab home (bin/fm-lab-home.sh
# create), a task record, and a throwaway forge. The forge is played by the
# stand-in gh/glab/tea CLIs beside this script, which answer from a mutable
# state directory and reject a merge whose bound head is not the live head, as
# the real forges do. No test bypass variable is set and no FM_*_OVERRIDE is
# used: the home is the stock layout.
#
# Usage: drive.sh <worktree-root> <work-dir>
set -u

ROOT=$1
WORK=$2
DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
FAILS=0
CHECKS=0

A=1111111111111111111111111111111111111111   # the head the caller verified
B=2222222222222222222222222222222222222222   # a newer head pushed afterwards
A64=3333333333333333333333333333333333333333333333333333333333333333
GH_URL=https://github.com/example/repo/pull/45
GL_HOST=gitlab.example
GL_PROJECT=https://$GL_HOST/group/subgroup/project
GL_URL=$GL_PROJECT/-/merge_requests/7
FJ_URL=https://forgejo.example/fixture/fixture-repo/pulls/9

GREEN='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'
SKIPPED='[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SKIPPED"}]'
EMPTY='[]'

section() { printf '\n================================================================\n%s\n================================================================\n' "$1"; }
note() { printf '%s\n' "$*"; }

check() {  # <description> <command...>: one observable assertion
  local desc=$1
  shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$desc"
  else
    FAILS=$((FAILS + 1))
    printf '  FAIL  %s\n' "$desc"
  fi
}

# A fresh disposable home and forge for one scenario.
new_case() {
  SC="$WORK/$1"
  LAB="$SC/lab"
  FORGE="$SC/forge"
  mkdir -p "$SC"
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "could not create lab home" >&2; exit 1; }
  mkdir -p "$FORGE" "$SC/bin" "$SC/user-home"
  for t in gh gh-axi glab tea; do ln -s "$DRIVER/standin-$t" "$SC/bin/$t"; done
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
  : > "$FORGE/gh.log"; : > "$FORGE/gh-axi.log"; : > "$FORGE/glab.log"; : > "$FORGE/tea.log"; : > "$FORGE/events.log"
}

github_pr() {  # <head> <rollup-json>: an open, mergeable pull request
  printf 'OPEN\n' > "$FORGE/state"
  printf '%s\n' "$1" > "$FORGE/head"
  printf '%s\n' "$2" > "$FORGE/rollup.json"
  note "[forge] GitHub pull request #45 is OPEN at head $1, checks: $2"
}
github_push() {  # <new-head> <rollup-json>: a contributor pushes a newer head
  printf '%s\n' "$1" > "$FORGE/head"
  printf '%s\n' "$2" > "$FORGE/rollup.json"
  note "[forge] a newer head is pushed: head is now $1, checks: $2"
}
gitlab_mr() {  # <head> <pipeline-sha> <pipeline-status>
  printf 'opened\n' > "$FORGE/state"
  printf '%s\n' "$1" > "$FORGE/head"
  printf '{"sha":"%s","status":"%s"}\n' "$2" "$3" > "$FORGE/pipeline.json"
  note "[forge] GitLab merge request !7 is opened at head $1, head pipeline: $3 at $2"
}

run_merge() {  # the real product, as an operator invokes it
  printf '\n$ bin/fm-pr-merge.sh'
  printf ' %q' "$@"
  printf '\n'
  set +e
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$LAB" HOME="$SC/user-home" STANDIN_FORGE="$FORGE" PATH="$SC/bin:$PATH" \
    "$PR_MERGE" "$@" > "$SC/stdout" 2> "$SC/stderr.raw"
  RC=$?
  set -e
  # The lab home has no watcher, so every run prints the same seven-line
  # "WATCHER DOWN" supervision banner (lines starting with the bullet); it is
  # dropped from the transcript and nothing else is.
  grep -v '^●' "$SC/stderr.raw" > "$SC/stderr" || true
  printf 'exit code: %s\n' "$RC"
  if [ -s "$SC/stdout" ]; then sed 's/^/  stdout| /' "$SC/stdout"; fi
  if [ -s "$SC/stderr" ]; then sed 's/^/  stderr| /' "$SC/stderr"; fi
}

show_forge_calls() {  # <log>
  if [ -s "$FORGE/$1" ]; then
    printf 'forge CLI calls (%s):\n' "$1"
    sed 's/^/  | /' "$FORGE/$1"
  else
    printf 'forge CLI calls (%s): none\n' "$1"
  fi
  if [ -s "$FORGE/events.log" ]; then sed 's/^/  /' "$FORGE/events.log"; fi
}

rc_is() { [ "$RC" -eq "$1" ]; }
stderr_has() { grep -qF -- "$1" "$SC/stderr"; }
stdout_has() { grep -qF -- "$1" "$SC/stdout"; }
log_has() { grep -qxF -- "$2" "$FORGE/$1"; }
log_lacks() { ! grep -qF -- "$2" "$FORGE/$1"; }
log_empty() { [ ! -s "$FORGE/$1" ]; }
forge_state_is() { [ "$(cat "$FORGE/state")" = "$1" ]; }
merged_head_is() { [ "$(cat "$FORGE/merged-head" 2>/dev/null)" = "$1" ]; }
never_merged() { [ ! -e "$FORGE/merged-head" ]; }
no_locks_left() { [ ! -e "$LAB/state/.control-task-x1.lock" ] && [ ! -e "$LAB/state/.afk-contract.lock" ]; }
meta_lacks_pr() { ! grep -q '^pr=' "$LAB/state/task-x1.meta"; }
state_untouched() { [ "$(ls -A "$LAB/state")" = task-x1.meta ]; }

set -e
note "product: $PR_MERGE"
note "commit:  $(git -C "$ROOT" rev-parse HEAD)"
note "A (head the caller verified) = $A"
note "B (newer head pushed later)  = $B"

# ---------------------------------------------------------------- GitHub ----
section "G0  GitHub baseline, no flag: a newer head with no checks yet still merges (the gap)"
new_case g0-baseline
github_pr "$A" "$GREEN"
note "[caller] verifies a full green CI run on head A"
github_push "$B" "$EMPTY"
run_merge task-x1 "$GH_URL"
show_forge_calls gh.log
check "exit 0: without --expect-head the behavior is unchanged" rc_is 0
check "the forge merged the newer, unverified head B" merged_head_is "$B"
check "the merge call was bound to the live head B" log_has gh.log "pr merge 45 --repo example/repo --match-head-commit $B --squash"

section "G1  GitHub, --expect-head A, head moved to B with an EMPTY check list: refused"
new_case g1-moved-empty
github_pr "$A" "$GREEN"
note "[caller] verifies a full green CI run on head A"
github_push "$B" "$EMPTY"
run_merge task-x1 "$GH_URL" --expect-head "$A"
show_forge_calls gh.log
check "exit 1" rc_is 1
check "the refusal names the live head B" stderr_has "the live head $B"
check "the refusal names the expected head A" stderr_has "is not the expected head $A"
check "no 'gh pr merge' call was made" log_lacks gh.log 'pr merge'
check "the pull request is still OPEN on the forge" forge_state_is OPEN
check "nothing was merged" never_merged
check "the per-task control lock and the away-record lock were released" no_locks_left

section "G2  GitHub, --expect-head A, head moved to B whose checks completed SKIPPED: refused"
new_case g2-moved-skipped
github_pr "$A" "$GREEN"
note "[caller] verifies a full green CI run on head A"
github_push "$B" "$SKIPPED"
run_merge task-x1 "$GH_URL" --expect-head "$A"
show_forge_calls gh.log
check "exit 1" rc_is 1
check "the refusal names both heads" stderr_has "the live head $B is not the expected head $A"
check "no 'gh pr merge' call was made" log_lacks gh.log 'pr merge'
check "nothing was merged" never_merged
check "locks were released" no_locks_left

section "G3  GitHub, --expect-head A and the live head is still A: merges, bound to A"
new_case g3-match
github_pr "$A" "$GREEN"
note "[caller] verifies a full green CI run on head A"
run_merge task-x1 "$GH_URL" --expect-head "$A"
show_forge_calls gh.log
check "exit 0" rc_is 0
check "the merge call was bound to the expected head A" log_has gh.log "pr merge 45 --repo example/repo --match-head-commit $A --squash"
check "the forge merged exactly head A" merged_head_is "$A"
check "the product reports the pull request as merged" stdout_has "verified: $GH_URL is merged"
check "locks were released" no_locks_left

section "G4  GitHub, --expect-head A, a push lands AFTER the verifying read: the bound merge is rejected"
new_case g4-late-push
github_pr "$A" "$GREEN"
note "[caller] verifies a full green CI run on head A"
printf '%s\n' "$B" > "$FORGE/push-after-verify"
note "[forge] armed: head B will be pushed right after the product's verifying read"
run_merge task-x1 "$GH_URL" --expect-head "$A"
show_forge_calls gh.log
check "the product does not exit 0" test "$RC" -ne 0
check "the merge call it sent was bound to the expected head A, not to B" log_has gh.log "pr merge 45 --repo example/repo --match-head-commit $A --squash"
check "the forge rejected that call, so nothing was merged" never_merged
check "the pull request is still OPEN on the forge" forge_state_is OPEN
check "locks were released" no_locks_left

section "G5  GitHub, a 64-hex (SHA-256 object format) expected head that matches: merges, bound to it"
new_case g5-sha256
github_pr "$A64" "$GREEN"
run_merge task-x1 "$GH_URL" --expect-head "$A64"
show_forge_calls gh.log
check "exit 0" rc_is 0
check "the merge call was bound to the 64-hex head" log_has gh.log "pr merge 45 --repo example/repo --match-head-commit $A64 --squash"
check "the forge merged exactly that head" merged_head_is "$A64"

section "G6  GitHub, --attended-override does not skip the expected-head refusal"
new_case g6-attended-override
github_pr "$A" "$GREEN"
github_push "$B" "$EMPTY"
run_merge task-x1 "$GH_URL" --attended-override --expect-head "$A"
show_forge_calls gh.log
check "exit 1" rc_is 1
check "the refusal names both heads" stderr_has "the live head $B is not the expected head $A"
check "no 'gh pr merge' call was made" log_lacks gh.log 'pr merge'
check "nothing was merged" never_merged

section "G7  GitHub, --expect-head misplaced after an extra forge argument: never merges"
new_case g7-misplaced
github_pr "$A" "$GREEN"
github_push "$B" "$EMPTY"
note "[note] options are parsed only before the first extra forge argument, so this"
note "[note] --expect-head is forwarded to gh, which rejects it as an unknown flag"
run_merge task-x1 "$GH_URL" --squash --expect-head "$A"
show_forge_calls gh.log
check "the product does not exit 0" test "$RC" -ne 0
check "nothing was merged" never_merged
check "the pull request is still OPEN on the forge" forge_state_is OPEN
check "locks were released" no_locks_left

section "G8  GitHub, a caller-supplied forge head flag is still refused alongside --expect-head"
new_case g8-head-override
github_pr "$A" "$GREEN"
github_push "$B" "$EMPTY"
run_merge task-x1 "$GH_URL" --expect-head "$A" -- --match-head-commit "$B"
show_forge_calls gh.log
check "exit 1" rc_is 1
check "the refusal says the head must not be overridden" stderr_has 'extra merge arguments must not override the head commit'
check "no forge call was made at all" log_empty gh.log
check "nothing was recorded for the task" meta_lacks_pr

# ------------------------------------------------------- argument forms ----
section "ARG  malformed --expect-head values are refused with exit 2 before any state or forge call"
arg_case() {  # <label> <expected-error> <args after the URL...>
  local label=$1 expected=$2
  shift 2
  new_case "arg-$label"
  github_pr "$A" "$GREEN" >/dev/null
  run_merge task-x1 "$GH_URL" "$@"
  check "[$label] exit 2" rc_is 2
  check "[$label] named error: $expected" stderr_has "$expected"
  check "[$label] no forge call was made" log_empty gh.log
  check "[$label] no pr= was recorded and no poll was armed" state_untouched
  check "[$label] the pull request is still OPEN, nothing merged" never_merged
}
NEED_SHA='--expect-head requires a full commit SHA as the live head read accepts it'
arg_case short-prefix "$NEED_SHA" --expect-head "${A:0:7}"
arg_case 39-hex "$NEED_SHA" --expect-head "${A:0:39}"
arg_case 41-hex "$NEED_SHA" --expect-head "${A}1"
arg_case uppercase "$NEED_SHA" --expect-head AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
arg_case non-hex "$NEED_SHA" --expect-head gggggggggggggggggggggggggggggggggggggggg
arg_case leading-space "$NEED_SHA" --expect-head " $A"
arg_case trailing-newline "$NEED_SHA" --expect-head "$A"$'\n'
arg_case empty "$NEED_SHA" --expect-head ''
arg_case missing-value "$NEED_SHA" --expect-head
arg_case flag-as-value "$NEED_SHA" --expect-head --attended-override
arg_case equals-form '--expect-head requires a separate SHA argument' "--expect-head=$A"
arg_case repeated-same '--expect-head may be specified only once' --expect-head "$A" --expect-head "$A"
arg_case repeated-different '--expect-head may be specified only once' --expect-head "$A" --expect-head "$B"

# ---------------------------------------------------------------- GitLab ----
section "L0  GitLab baseline, no flag: a newer head with its own successful pipeline merges"
new_case l0-baseline
gitlab_mr "$A" "$A" success
note "[caller] verifies head A"
gitlab_mr "$B" "$B" success
run_merge task-x1 "$GL_URL"
show_forge_calls glab.log
check "exit 0: without --expect-head the behavior is unchanged" rc_is 0
check "the forge merged the newer head B" merged_head_is "$B"

section "L1  GitLab, --expect-head A and the live head is A: merges, bound to A with --sha"
new_case l1-match
gitlab_mr "$A" "$A" success
run_merge task-x1 "$GL_URL" --expect-head "$A"
show_forge_calls glab.log
check "exit 0" rc_is 0
check "the merge call was bound to the expected head A, on the host from the URL" \
  log_has glab.log "GITLAB_HOST=$GL_HOST mr merge 7 -R $GL_PROJECT --sha $A --yes"
check "the forge merged exactly head A" merged_head_is "$A"
check "locks were released" no_locks_left

section "L2  GitLab, --expect-head A, head moved to B (B's own pipeline is green): refused"
new_case l2-moved
gitlab_mr "$A" "$A" success
note "[caller] verifies head A"
gitlab_mr "$B" "$B" success
run_merge task-x1 "$GL_URL" --expect-head "$A"
show_forge_calls glab.log
check "exit 1" rc_is 1
check "the refusal names both heads" stderr_has "the live head $B is not the expected head $A"
check "no 'glab mr merge' call was made" log_lacks glab.log ' mr merge '
check "the merge request is still opened on the forge" forge_state_is opened
check "nothing was merged" never_merged
check "locks were released" no_locks_left

# --------------------------------------------------------------- Forgejo ----
section "F1  Forgejo, --expect-head: the option itself is refused before any state or forge call"
new_case f1-forgejo
run_merge task-x1 "$FJ_URL" --expect-head "$A"
show_forge_calls tea.log
check "exit 2" rc_is 2
check "the refusal names Forgejo as unsupported" stderr_has '--expect-head is not supported on Forgejo'
check "the refusal says where it is supported" stderr_has 'it is supported on GitHub and GitLab'
check "tea was never called (no merge posted, no read made)" log_empty tea.log
check "no pr= was recorded and no poll was armed" state_untouched
check "no lock was taken" no_locks_left

section "F2  Forgejo, --attended-override does not re-enable --expect-head"
new_case f2-forgejo-override
run_merge task-x1 "$FJ_URL" --attended-override --expect-head "$A"
show_forge_calls tea.log
check "exit 2" rc_is 2
check "the refusal names Forgejo as unsupported" stderr_has '--expect-head is not supported on Forgejo'
check "tea was never called" log_empty tea.log
check "no state was recorded" state_untouched

section "RESULT"
printf '%s checks, %s failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" -eq 0 ]
