#!/usr/bin/env bash
# Live scenarios for the stacked-MR publication check in bin/fm-pr-merge.sh
# (GitLab path). Each scenario builds a fresh lab, drives the real scripts, and
# removes the lab again. glab is a local stand-in answering from real bare git
# repositories; the target project is id 1 and the fork, when used, is id 2.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap lab_destroy EXIT

GL_HOST=gitlab.lab.example
GL_PATH=group/project
MR_URL="https://$GL_HOST/$GL_PATH/-/merge_requests/7"
FORGE_REL="gitlab/$GL_PATH.git"
PROJECT_NAME=project

printf 'Live lab transcript: bin/fm-pr-merge.sh driven against a disposable GitLab-shaped lab.\n'
printf 'FM_HOME is a marked lab home from bin/fm-lab-home.sh; the worker copy is a real git worktree\n'
printf 'pushing to real bare git remotes; glab is a local stand-in that answers from those remotes.\n'
printf 'The lab home runs no watcher, so the guard'"'"'s "WATCHER DOWN" banner is elided from script output.\n'

gl_lab_new() {
  lab_new
  mkdir -p "$FORGE/gitlab/projects/1" "$FORGE/gitlab/pipelines"
  printf '%s\n' "$GL_PATH" > "$FORGE/gitlab/projects/1/path"
  write_meta direct-PR
}
# A fork of the target project (project id 2) and a `fork` remote in the copy
# whose URL is the fork's GitLab URL; pushes go to the fork's bare repository.
gl_add_fork() {
  FORK_GIT="$FORGE/gitlab/fork-owner/project.git"
  mkdir -p "$FORGE/gitlab/fork-owner" "$FORGE/gitlab/projects/2"
  git clone -q --bare "$FORGE_GIT" "$FORK_GIT"
  printf 'fork-owner/project\n' > "$FORGE/gitlab/projects/2/path"
  wgit remote add fork "https://$GL_HOST/fork-owner/project.git"
  git -C "$WT" config remote.fork.pushurl "$FORK_GIT"
  printf '(forge) project 2 is a fork: https://%s/fork-owner/project\n' "$GL_HOST"
}
forge_open_mr() {  # <iid> <source-branch> <source-project-id>
  local d="$FORGE/gitlab/mrs/$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/source_branch"
  printf '%s\n' "$3" > "$d/source_project"
  printf '1\n' > "$d/target_project"
  printf 'opened\n' > "$d/state"
  printf '(forge) merge request !%s opened: %s (project %s) -> main (project 1)\n' "$1" "$2" "$3"
}
forge_pipeline_success() {  # <source-branch> <git-dir>
  local sha
  sha=$(git -C "$2" rev-parse "refs/heads/$1")
  printf 'success\n' > "$FORGE/gitlab/pipelines/$sha"
  printf '(forge) head pipeline succeeded at %s (head of %s)\n' "$sha" "$1"
}
mr_state() { cat "$FORGE/gitlab/mrs/7/state"; }
mr_merge_calls() { grep -c ' mr merge ' "$FORGE/glab.log" || true; }
show_gl() {
  printf '(forge) MR !7 state: %s\n' "$(mr_state)"
  printf '(forge) target project branches:\n'
  git -C "$FORGE_GIT" for-each-ref --format='          %(refname:short) %(objectname:short=12) %(subject)' refs/heads
  printf '(forge) files on target main: %s\n' "$(forge_main_files)"
}
part1_pushed_same_project() {
  wgit checkout -q -b fm/stack-part-1
  wcommit part1.txt 'part 1'
  PART1=$(git -C "$WT" rev-parse HEAD)
  wgit push -q -u origin fm/stack-part-1
  forge_open_mr 7 fm/stack-part-1 1
  forge_pipeline_success fm/stack-part-1 "$FORGE_GIT"
}
move_on_to_part2() {
  wgit checkout -q -b fm/stack-part-2
  wcommit part2.txt 'part 2'
  PART2=$(git -C "$WT" rev-parse HEAD)
}

# ---------------------------------------------------------------------------
scenario 'L0 (reproduction, base commit): a green part-1 MR is refused because the copy HEAD is unpushed part-2'
gl_lab_new
part1_pushed_same_project
move_on_to_part2
show_copy; show_gl
fm base fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 1 'base commit refuses the merge'
expect_out "named head $PART2 is unreachable outside the worker copy" \
  'base commit refuses naming the unpushed part-2 commit'
expect_eq "$(mr_state) $(mr_merge_calls)" 'opened 0' 'the MR is still open and no merge was sent'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'L1: a green part-1 MR merges while the copy HEAD is on unpushed part-2'
gl_lab_new
part1_pushed_same_project
move_on_to_part2
show_copy; show_gl
fm fixed fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 0 'the merge goes through'
expect_eq "$(grep -c "GITLAB_HOST=$GL_HOST mr merge 7 -R https://$GL_HOST/$GL_PATH --sha $PART1 --yes\$" "$FORGE/glab.log")" 1 \
  'the forge merge was bound to part-1'"'"'s pushed head'
expect_eq "$(mr_state)" merged 'the MR is merged on the forge'
expect_eq "$(forge_main_files)" 'README.md part1.txt ' 'target main carries part 1 and nothing of part 2'
expect_eq "$(git -C "$WT" symbolic-ref --short HEAD) $(git -C "$WT" rev-parse HEAD)" "fm/stack-part-2 $PART2" \
  'the worker copy is still on its unpushed part-2 commit'
show_gl
lab_destroy

# ---------------------------------------------------------------------------
scenario 'L2 (guard): an unpushed commit on the MR'"'"'s own source branch still refuses; pushing it and a passed pipeline lets it merge'
gl_lab_new
part1_pushed_same_project
wcommit part1.txt 'part 1 review fix'
FIX=$(git -C "$WT" rev-parse HEAD)
move_on_to_part2
show_copy
fm fixed fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 1 'the merge is refused'
expect_out "named head $FIX could not be verified in pull request head $PART1" \
  'the refusal names the unpushed part-1 fix and the MR head that lacks it'
expect_eq "$(mr_state) $(mr_merge_calls)" 'opened 0' 'the MR is still open and no merge was sent'
expect_eq "$(grep -c "^pr=$MR_URL\$" "$META")" 1 'pr= stays recorded after the refusal'
if [ -f "$LAB/state/$TASK.check.sh" ]; then ok 'the merge poll stays armed after the refusal'; else bad 'the merge poll is not armed'; fi
step 'the worker pushes the fix and the pipeline passes at the new head'
wgit push -q origin fm/stack-part-1
forge_pipeline_success fm/stack-part-1 "$FORGE_GIT"
fm fixed fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 0 'the merge goes through once the fix is pushed and its pipeline passed'
expect_eq "$(mr_state)" merged 'the MR is merged on the forge'
expect_eq "$(git -C "$FORGE_GIT" show refs/heads/main:part1.txt | tr '\n' '|')" 'part 1|part 1 review fix|' \
  'target main carries part 1 with its fix'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'L3: an MR from a fork - the copy'"'"'s part-1 tracks the fork and is pushed there, HEAD is on unpushed part-2'
gl_lab_new
gl_add_fork
wgit checkout -q -b fm/stack-part-1
wcommit part1.txt 'part 1'
PART1=$(git -C "$WT" rev-parse HEAD)
wgit push -q -u fork fm/stack-part-1
forge_open_mr 7 fm/stack-part-1 2
forge_pipeline_success fm/stack-part-1 "$FORK_GIT"
move_on_to_part2
fm fixed fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 0 'the fork MR merges'
expect_eq "$(grep -c "GITLAB_HOST=$GL_HOST api projects/2 --hostname $GL_HOST\$" "$FORGE/glab.log")" 1 \
  'the fork'"'"'s URLs were read from the MR'"'"'s own instance'
expect_eq "$(mr_state)" merged 'the MR is merged on the forge'
expect_eq "$(forge_main_files)" 'README.md part1.txt ' 'target main carries part 1 only'
lab_destroy

scenario 'L4 (guard): the same fork MR with an unpushed fix on the tracked source branch refuses'
gl_lab_new
gl_add_fork
wgit checkout -q -b fm/stack-part-1
wcommit part1.txt 'part 1'
PART1=$(git -C "$WT" rev-parse HEAD)
wgit push -q -u fork fm/stack-part-1
forge_open_mr 7 fm/stack-part-1 2
forge_pipeline_success fm/stack-part-1 "$FORK_GIT"
wcommit part1.txt 'part 1 review fix'
FIX=$(git -C "$WT" rev-parse HEAD)
move_on_to_part2
fm fixed fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 1 'the fork MR is refused'
expect_out "named head $FIX could not be verified in pull request head $PART1" \
  'the refusal names the unpushed fix on the fork-tracking branch'
expect_eq "$(mr_state) $(mr_merge_calls)" 'opened 0' 'the MR is still open and no merge was sent'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'L5 (adversarial): a fork MR whose branch name matches an unrelated local branch - readable fork gates HEAD, unreadable fork refuses'
gl_lab_new
gl_add_fork
step 'someone else pushes fm/stack-part-1 to the fork and opens the MR; the copy has its own unrelated branch of that name tracking origin'
git clone -q "$FORK_GIT" "$BOX/contributor"
git -C "$BOX/contributor" checkout -q -b fm/stack-part-1
printf 'contributed\n' > "$BOX/contributor/part1.txt"
git -C "$BOX/contributor" add part1.txt
git -C "$BOX/contributor" commit -q -m 'contributed part 1'
git -C "$BOX/contributor" push -q origin fm/stack-part-1
MR_HEAD=$(git -C "$BOX/contributor" rev-parse HEAD)
forge_open_mr 7 fm/stack-part-1 2
forge_pipeline_success fm/stack-part-1 "$FORK_GIT"
wgit checkout -q -b fm/stack-part-1
wcommit notes.txt 'unrelated local notes'
wgit config branch.fm/stack-part-1.remote origin
wgit config branch.fm/stack-part-1.merge refs/heads/fm/stack-part-1
wgit checkout -q fm/stack-task
show_copy
step 'the fork project cannot be read (injected 404)'
: > "$FORGE/gitlab/projects/2/fault-unreadable"
fm fixed fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 1 'an unreadable fork refuses even though the copy HEAD is pushed'
expect_out "source project 2 could not be read to tell whether local branch fm/stack-part-1 is the merge request's source branch" \
  'the refusal names the unreadable fork'
expect_eq "$(mr_state) $(mr_merge_calls)" 'opened 0' 'the MR is still open and no merge was sent'
step 'the fork project is readable again: the namesake branch is not the source branch, so the pushed HEAD is what is gated'
rm -f "$FORGE/gitlab/projects/2/fault-unreadable"
fm fixed fm-pr-merge.sh "$TASK" "$MR_URL"
expect_rc 0 'the fork MR merges; the unrelated same-named branch is ignored'
expect_eq "$(grep -c "GITLAB_HOST=$GL_HOST mr merge 7 -R https://$GL_HOST/$GL_PATH --sha $MR_HEAD --yes\$" "$FORGE/glab.log")" 1 \
  'the forge merge was bound to the fork'"'"'s head'
expect_eq "$(mr_state)" merged 'the MR is merged on the forge'
lab_destroy

printf '\n================================================================\n'
if [ "$FAILS" -eq 0 ]; then
  printf 'ALL GITLAB SCENARIO ASSERTIONS PASSED\n'
else
  printf '%s ASSERTION(S) FAILED\n' "$FAILS"
fi
[ -z "$BASE_SRC" ] || rm -rf "$BASE_SRC"
exit "$FAILS"
