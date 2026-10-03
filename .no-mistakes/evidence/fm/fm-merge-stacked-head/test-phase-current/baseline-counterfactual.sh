#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/mosheanconina/.no-mistakes/worktrees/954444e3c755/01M412K529Y0VANR7WJEGK4EGQ
EVIDENCE=/Users/mosheanconina/.no-mistakes/evidence/01M412K529Y0VANR7WJEGK4EGQ/test-phase-current
AREA="$ROOT/.test-merge-stacked/counterfactual"
mkdir "$AREA"
trap 'rm -rf "$AREA"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME='Live validation' GIT_AUTHOR_EMAIL=validation@example.invalid
export GIT_COMMITTER_NAME='Live validation' GIT_COMMITTER_EMAIL=validation@example.invalid
export TMPDIR="$ROOT/.test-merge-stacked/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TASK_ID FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
mkdir "$AREA/base"
git -C "$ROOT" archive 1f3e769616fdf9f31f85f4c3e6a9f71606634238 bin | tar -x -C "$AREA/base"
LAB="$AREA/home"
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
printf 'manual\n' > "$LAB/config/backlog-backend"
WT="$AREA/worker"
BRANCH=$(jq -r .headRefName "$EVIDENCE/green-pr-initial.json")
PR_HEAD=$(jq -r .headRefOid "$EVIDENCE/green-pr-initial.json")
git init -q "$WT"
git -C "$WT" remote add origin https://github.com/cloud-practitioner/firstmate.git
git -C "$WT" fetch -q --depth=3 origin "$PR_HEAD"
git -C "$WT" checkout -q -b "$BRANCH" FETCH_HEAD
git -C "$WT" update-ref "refs/remotes/origin/$BRANCH" "$PR_HEAD"
git -C "$WT" checkout -q -b part-2
git -C "$WT" commit -q --allow-empty -m 'unpublished later part for original-failure reproduction'
LATER=$(git -C "$WT" rev-parse HEAD)
printf 'window=firstmate:fm-counterfactual\nendpoint_task_id=counterfactual\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\npr=https://github.com/kunchenguid/firstmate/pull/6489\n' "$WT" "$WT" > "$LAB/state/counterfactual.meta"
chmod 600 "$LAB/state/counterfactual.meta"
printf 'Real GitHub PR: https://github.com/kunchenguid/firstmate/pull/6489\nPR head: %s\nCurrent branch: part-2\nUnpublished current HEAD: %s\n' "$PR_HEAD" "$LATER"
printf '\nBASE COMMIT: 1f3e769616fdf9f31f85f4c3e6a9f71606634238\nCommand: FM_HOME=<disposable-home> <base>/bin/fm-pr-merge.sh counterfactual https://github.com/kunchenguid/firstmate/pull/6489 -- --fm-validation-read-only-stop\n'
base_rc=0
FM_HOME="$LAB" "$AREA/base/bin/fm-pr-merge.sh" counterfactual https://github.com/kunchenguid/firstmate/pull/6489 -- --fm-validation-read-only-stop > "$AREA/base-output" 2>&1 || base_rc=$?
cat "$AREA/base-output"
printf 'exit=%s\n' "$base_rc"
[ "$base_rc" -ne 0 ]
grep -Fq "named head $LATER is unreachable outside the worker copy" "$AREA/base-output"
printf '\nTARGET COMMIT: 7595b5a37968395d6c3e05d772ddd79db2fc25dd\nCommand: FM_HOME=<same-disposable-home> bin/fm-pr-merge.sh counterfactual https://github.com/kunchenguid/firstmate/pull/6489 -- --fm-validation-read-only-stop\n'
target_rc=0
FM_HOME="$LAB" "$ROOT/bin/fm-pr-merge.sh" counterfactual https://github.com/kunchenguid/firstmate/pull/6489 -- --fm-validation-read-only-stop > "$AREA/target-output" 2>&1 || target_rc=$?
cat "$AREA/target-output"
printf 'exit=%s\n' "$target_rc"
[ "$target_rc" -ne 0 ]
grep -Fq 'unknown flag: --fm-validation-read-only-stop' "$AREA/target-output"
! grep -Fq "named head $LATER is unreachable outside the worker copy" "$AREA/target-output"
[ "$(git -C "$WT" symbolic-ref --short HEAD)" = part-2 ]
[ "$(git -C "$WT" rev-parse HEAD)" = "$LATER" ]
printf '\nObserved counterfactual: identical worker and forge state; the base rejects the unpublished later branch, the target passes preflight and reaches the intentional GitHub CLI parser stop. No merge was performed.\n'
gh pr view 6489 --repo kunchenguid/firstmate --json state,headRefOid,mergedAt
