#!/usr/bin/env bash
# Live scenarios for the stacked-PR publication check in bin/fm-pr-merge.sh
# (GitHub path). Each scenario builds a fresh lab, drives the real scripts, and
# removes the lab again.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap lab_destroy EXIT

printf 'Live lab transcript: bin/fm-pr-merge.sh / bin/fm-pr-check.sh driven against a disposable lab.\n'
printf 'FM_HOME is a marked lab home from bin/fm-lab-home.sh; the worker copy is a real git worktree\n'
printf 'pushing to a real bare git remote; gh is a local stand-in that answers from that remote.\n'
printf 'Lines starting with "$" are commands; "(forge)" and "(worker copy)" lines show real git state.\n'
printf 'The lab home runs no watcher, so the guard'"'"'s "WATCHER DOWN" banner is elided from script output.\n'

# The common starting point: the worker finished part 1 on its own branch,
# pushed it, the forge opened PR #4 for it, and CI went green at that head.
part1_pushed_and_green() {
  wgit checkout -q -b fm/stack-part-1
  wcommit part1.txt 'part 1'
  PART1=$(git -C "$WT" rev-parse HEAD)
  wgit push -q -u origin fm/stack-part-1
  forge_open_pr 4 fm/stack-part-1
  forge_ci_green fm/stack-part-1
}
# The worker moves on to the next part on a new local branch and does not push.
move_on_to_part2() {
  wgit checkout -q -b fm/stack-part-2
  wcommit part2.txt 'part 2'
  PART2=$(git -C "$WT" rev-parse HEAD)
}

# ---------------------------------------------------------------------------
scenario 'G0 (reproduction, base commit): green part-1 PR is refused because the copy HEAD is unpushed part-2'
lab_new; write_meta direct-PR
part1_pushed_and_green
step 'firstmate registers the ready PR while the worker is still on part 1'
fm base fm-pr-check.sh "$TASK" "$PR_URL"
expect_rc 0 'registration of the pushed, green part-1 PR'
move_on_to_part2
show_copy; show_forge
step 'merge the green part-1 PR with the scripts from the base commit'
fm base fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'base commit refuses the merge'
expect_out "named head $PART2 is unreachable outside the worker copy" \
  'base commit refuses with the reported message, naming the unpushed part-2 commit'
expect_eq "$(forge_pr_state 4)" OPEN 'the PR is still open on the forge'
expect_eq "$(forge_merge_calls)" 0 'no merge was sent to the forge'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G1: green part-1 PR merges while the copy HEAD is on unpushed part-2 (registered earlier)'
lab_new; write_meta direct-PR
part1_pushed_and_green
step 'firstmate registers the ready PR while the worker is still on part 1'
fm fixed fm-pr-check.sh "$TASK" "$PR_URL"
expect_rc 0 'registration of the pushed, green part-1 PR'
move_on_to_part2
show_copy; show_forge
step 'merge the green part-1 PR'
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'the merge goes through'
expect_out "verified: $PR_URL is merged" 'the script reports the PR merged'
expect_eq "$(forge_pr_state 4)" MERGED 'the PR is merged on the forge'
expect_eq "$(grep -c "^pr merge 4 --repo $OWNER/$REPO --match-head-commit $PART1 --squash\$" "$FORGE/gh.log")" 1 \
  'the forge merge was bound to part-1'"'"'s pushed head'
expect_eq "$(forge_main_files)" 'README.md part1.txt ' 'forge main now carries part 1 and nothing of part 2'
expect_eq "$(git -C "$FORGE_GIT" rev-parse --verify --quiet refs/heads/fm/stack-part-2 || echo absent)" absent \
  'part-2 was not pushed by the merge'
expect_eq "$(git -C "$WT" symbolic-ref --short HEAD) $(git -C "$WT" rev-parse HEAD)" "fm/stack-part-2 $PART2" \
  'the worker copy is still on its unpushed part-2 commit'
expect_eq "$(grep -c "^pr=$PR_URL\$" "$META") $(grep -c "^pr_head=$PART1\$" "$META")" '1 1' \
  'the task record holds pr= and pr_head= of the merged PR'
expect_no_nm_call
show_copy; show_forge
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G2: never-registered stacked PR - registration still refuses the unpushed HEAD, the merge still goes through'
lab_new; write_meta direct-PR
part1_pushed_and_green
move_on_to_part2
show_copy
step 'ordinary PR-ready registration names the copy HEAD, which is unpushed part 2'
fm fixed fm-pr-check.sh "$TASK" "$PR_URL"
expect_rc 1 'PR-ready registration still refuses while HEAD is only in the copy'
expect_out "named head $PART2 is unreachable outside the worker copy" 'registration names the unpushed HEAD'
expect_eq "$(grep -c '^pr=' "$META")" 0 'the refused registration recorded no pr='
step 'merge the green part-1 PR'
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'the merge goes through'
expect_eq "$(forge_pr_state 4)" MERGED 'the PR is merged on the forge'
expect_eq "$(forge_main_files)" 'README.md part1.txt ' 'forge main carries part 1 only'
expect_eq "$(grep -c "^pr=$PR_URL\$" "$META")" 1 'the merge recorded pr='
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G3 (guard): an unpushed commit on the PR'"'"'s own branch still refuses; pushing it and a green check lets it merge'
lab_new; write_meta direct-PR
part1_pushed_and_green
fm fixed fm-pr-check.sh "$TASK" "$PR_URL" >/dev/null
step 'the worker adds a review fix to part 1 and does not push it, then moves on to part 2'
wcommit part1.txt 'part 1 review fix'
FIX=$(git -C "$WT" rev-parse HEAD)
move_on_to_part2
show_copy; show_forge
step 'merge the part-1 PR'
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'the merge is refused'
expect_out "named head $FIX could not be verified in pull request head $PART1" \
  'the refusal names the unpushed part-1 fix and the PR head that lacks it'
expect_eq "$(forge_pr_state 4)" OPEN 'the PR is still open on the forge'
expect_eq "$(forge_merge_calls)" 0 'no merge was sent to the forge'
expect_eq "$(forge_main_files)" 'README.md ' 'forge main is unchanged'
expect_eq "$(grep -c "^pr=$PR_URL\$" "$META")" 1 'pr= stays recorded after the refusal'
if [ -f "$LAB/state/$TASK.check.sh" ]; then ok 'the merge poll stays armed after the refusal'; else bad 'the merge poll is not armed'; fi
step 'the worker pushes the part-1 fix (still sitting on part 2); CI has not reported at the new head yet'
wgit push -q origin fm/stack-part-1
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'a pushed head whose check is not green yet is refused'
expect_out "check 'ci' is not green" 'the refusal is the green-check one, not the publication one'
step 'CI goes green at the new head'
forge_ci_green fm/stack-part-1
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'the merge goes through once the fix is pushed and green'
expect_eq "$(grep -c "^pr merge 4 --repo $OWNER/$REPO --match-head-commit $FIX --squash\$" "$FORGE/gh.log")" 1 \
  'the forge merge was bound to the pushed fix'
expect_eq "$(git -C "$FORGE_GIT" show refs/heads/main:part1.txt | tr '\n' '|')" 'part 1|part 1 review fix|' \
  'forge main carries part 1 with its fix'
expect_eq "$(git -C "$WT" rev-parse HEAD)" "$PART2" 'the worker copy is still on unpushed part 2'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G4 (adversarial): the PR branch fix is unpushed while HEAD is on a PUSHED part-2, and the fix exists only on another remote branch'
lab_new; write_meta direct-PR
part1_pushed_and_green
fm fixed fm-pr-check.sh "$TASK" "$PR_URL" >/dev/null
wcommit part1.txt 'part 1 review fix'
FIX=$(git -C "$WT" rev-parse HEAD)
wgit checkout -q -b fm/stack-part-2
wcommit part2.txt 'part 2'
wgit push -q -u origin fm/stack-part-2
show_copy; show_forge
step 'merge the part-1 PR: HEAD is fully pushed, the PR branch is not'
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'a pushed HEAD on another branch does not hide the unpushed PR-branch commit'
expect_out "named head $FIX could not be verified in pull request head $PART1" 'the refusal names the unpushed part-1 fix'
expect_eq "$(forge_merge_calls)" 0 'no merge was sent to the forge'
step 'the fix is pushed, but to a different remote branch than the PR'"'"'s'
wgit push -q origin fm/stack-part-1:refs/heads/fm/part-1-backup
show_forge
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'a fix published only on another remote branch still refuses'
expect_out "named head $FIX could not be verified in pull request head $PART1" 'the refusal still names the fix missing from the PR head'
expect_eq "$(forge_pr_state 4) $(forge_merge_calls)" 'OPEN 0' 'the PR is still open and no merge was sent'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G5 (boundary): the PR branch has another name in the copy - the copy HEAD is gated instead, so an unpushed HEAD still refuses'
lab_new; write_meta direct-PR
wgit checkout -q -b wip-part-1
wcommit part1.txt 'part 1'
PART1=$(git -C "$WT" rev-parse HEAD)
wgit push -q origin wip-part-1:refs/heads/fm/stack-part-1
forge_open_pr 4 fm/stack-part-1
forge_ci_green fm/stack-part-1
wcommit part1.txt 'follow-up'
FOLLOW=$(git -C "$WT" rev-parse HEAD)
show_copy; show_forge
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'with no local branch of the PR'"'"'s name, an unpushed HEAD refuses'
expect_out "named head $FOLLOW is unreachable outside the worker copy" 'the refusal comes from the copy HEAD gate'
expect_eq "$(forge_pr_state 4) $(forge_merge_calls)" 'OPEN 0' 'the PR is still open and no merge was sent'
step 'the worker pushes the follow-up to the PR branch and CI goes green'
wgit push -q origin wip-part-1:refs/heads/fm/stack-part-1
forge_ci_green fm/stack-part-1
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'once HEAD is pushed, the merge goes through'
expect_eq "$(forge_pr_state 4)" MERGED 'the PR is merged on the forge'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G6 (adversarial): the forge cannot tell which branch the PR is from - the merge refuses rather than guessing'
lab_new; write_meta direct-PR
part1_pushed_and_green
fm fixed fm-pr-check.sh "$TASK" "$PR_URL" >/dev/null
move_on_to_part2
step 'the forge head-branch read fails (injected 502 on headRefName)'
: > "$FORGE/$OWNER/$REPO.prs/4/fault-headRefName"
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'an unreadable PR head branch refuses'
expect_out 'pull request head branch could not be verified' 'the refusal says the head branch could not be verified'
expect_eq "$(forge_pr_state 4) $(forge_merge_calls)" 'OPEN 0' 'the PR is still open and no merge was sent'
step 'the read works again'
rm -f "$FORGE/$OWNER/$REPO.prs/4/fault-headRefName"
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'the merge goes through once the head branch is readable'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G7: no-mistakes task whose pipeline rebased and pushed the PR branch - the stale local branch and unpushed part-2 do not block'
lab_new; write_meta no-mistakes
wgit checkout -q -b fm/stack-part-1
wcommit part1.txt 'part 1'
PART1=$(git -C "$WT" rev-parse HEAD)
step 'main moves on; the pipeline rebases part 1 onto it in its own checkout, adds a fix, and pushes'
git -C "$BOX/seed" pull -q origin main
printf 'unrelated\n' > "$BOX/seed/other.txt"
git -C "$BOX/seed" add other.txt
git -C "$BOX/seed" commit -q -m 'main moved on'
git -C "$BOX/seed" push -q origin main
git clone -q "$FORGE_GIT" "$BOX/pipeline"
git -C "$BOX/pipeline" fetch -q "$WT" fm/stack-part-1
git -C "$BOX/pipeline" checkout -q -b fm/stack-part-1 origin/main
git -C "$BOX/pipeline" cherry-pick FETCH_HEAD >/dev/null
printf 'pipeline fix\n' >> "$BOX/pipeline/part1.txt"
git -C "$BOX/pipeline" commit -q -am 'pipeline fix for part 1'
git -C "$BOX/pipeline" push -q origin fm/stack-part-1
PIPE=$(git -C "$BOX/pipeline" rev-parse HEAD)
printf '(pipeline) pushed rebased head %s; the copy still has part-1 at %s\n' "$PIPE" "$PART1"
if git -C "$BOX/pipeline" merge-base --is-ancestor "$PART1" "$PIPE"; then bad 'setup: the rebased head still contains the copy tip'; else ok 'setup: the pushed head does not contain the copy'"'"'s part-1 tip'; fi
forge_open_pr 4 fm/stack-part-1
forge_ci_green fm/stack-part-1
move_on_to_part2
show_forge
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'the no-mistakes PR merges at the pipeline head'
expect_eq "$(grep -c "^pr merge 4 --repo $OWNER/$REPO --match-head-commit $PIPE --squash\$" "$FORGE/gh.log")" 1 \
  'the forge merge was bound to the pipeline head'
expect_eq "$(forge_pr_state 4)" MERGED 'the PR is merged on the forge'
expect_eq "$(git -C "$WT" rev-parse fm/stack-part-1) $(git -C "$WT" rev-parse HEAD)" "$PART1 $PART2" \
  'the copy branches were left as they were'
expect_no_nm_call
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G8: in a secondmate home, a refused merge never tells the parent the PR is ready; a landed one reports merged once'
lab_new; write_meta direct-PR; seed_secondmate_home
REPLIES="$LAB/state/parent-replies.status"
part1_pushed_and_green
wcommit part1.txt 'part 1 review fix'
FIX=$(git -C "$WT" rev-parse HEAD)
move_on_to_part2
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'the merge is refused for the unpushed part-1 fix'
printf '(parent channel after the refusal)\n'; sed 's/^/    /' "$REPLIES" 2>/dev/null || printf '    (no lines)\n'
expect_eq "$(count_in 'PR ready' "$REPLIES")" 0 'no PR-ready line reached the parent channel'
expect_eq "$(grep -c "^pr=$PR_URL\$" "$META")" 1 'pr= is recorded'
if [ -f "$LAB/state/$TASK.check.sh" ]; then ok 'the merge poll is armed'; else bad 'the merge poll is not armed'; fi
step 'the fix is pushed, CI goes green, the merge lands'
wgit push -q origin fm/stack-part-1
forge_ci_green fm/stack-part-1
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'the merge goes through'
printf '(parent channel after the merge)\n'; sed 's/^/    /' "$REPLIES" 2>/dev/null | scrub || printf '    (no lines)\n'
expect_eq "$(count_in "merged $TASK $PR_URL" "$REPLIES")" 1 'the landed merge was reported upward once'
expect_eq "$(count_in 'PR ready' "$REPLIES")" 0 'the merge-time re-record still sent no PR-ready line'
lab_destroy

scenario 'G9: in a secondmate home, ordinary PR-ready registration still tells the parent'
lab_new; write_meta direct-PR; seed_secondmate_home
REPLIES="$LAB/state/parent-replies.status"
part1_pushed_and_green
fm fixed fm-pr-check.sh "$TASK" "$PR_URL"
expect_rc 0 'registration of the pushed, green PR'
printf '(parent channel after registration)\n'; sed 's/^/    /' "$REPLIES" 2>/dev/null | scrub || printf '    (no lines)\n'
expect_eq "$(count_in "child $TASK PR ready: $PR_URL" "$REPLIES")" 1 'the PR-ready line reached the parent channel'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G10: someone else pushed a commit on top of the worker'"'"'s part-1 - the forge head is newer than the copy, and the merge still goes through'
lab_new; write_meta direct-PR
part1_pushed_and_green
step 'a reviewer pushes a commit on top of part 1 from their own clone; the copy never fetches it'
git clone -q "$FORGE_GIT" "$BOX/reviewer"
git -C "$BOX/reviewer" checkout -q fm/stack-part-1
printf 'reviewer tweak\n' >> "$BOX/reviewer/part1.txt"
git -C "$BOX/reviewer" commit -q -am 'reviewer tweak on part 1'
git -C "$BOX/reviewer" push -q origin fm/stack-part-1
FORGE_HEAD=$(git -C "$BOX/reviewer" rev-parse HEAD)
forge_ci_green fm/stack-part-1
move_on_to_part2
if git -C "$WT" cat-file -e "$FORGE_HEAD^{commit}" 2>/dev/null; then bad 'setup: the copy already had the forge head'; else ok 'setup: the forge head is not an object in the worker copy'; fi
REFS_BEFORE=$(git -C "$WT" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes)
show_copy; show_forge
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'the merge goes through: the copy'"'"'s part-1 tip is contained in the newer forge head'
expect_eq "$(grep -c "^pr merge 4 --repo $OWNER/$REPO --match-head-commit $FORGE_HEAD --squash\$" "$FORGE/gh.log")" 1 \
  'the forge merge was bound to the forge'"'"'s current head'
expect_eq "$(git -C "$WT" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/remotes)" "$REFS_BEFORE" \
  'no local or remote-tracking branch in the copy moved'
expect_eq "$(git -C "$WT" symbolic-ref --short HEAD) $(git -C "$WT" rev-parse HEAD)" "fm/stack-part-2 $PART2" \
  'the worker copy is still on its unpushed part-2 commit'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G11 (adversarial): the PR branch was force-pushed to a history that drops the worker'"'"'s commit - the merge refuses'
lab_new; write_meta direct-PR
part1_pushed_and_green
step 'the worker commits a second part-1 change locally; meanwhile the remote branch is force-pushed to a rewrite without it'
wcommit part1.txt 'part 1 second change'
LOCAL_TIP=$(git -C "$WT" rev-parse HEAD)
git clone -q "$FORGE_GIT" "$BOX/rewriter"
git -C "$BOX/rewriter" checkout -q -b rewrite origin/main
printf 'rewritten part 1\n' > "$BOX/rewriter/part1.txt"
git -C "$BOX/rewriter" add part1.txt
git -C "$BOX/rewriter" commit -q -m 'part 1, rewritten'
git -C "$BOX/rewriter" push -q --force origin rewrite:fm/stack-part-1
REWRITE=$(git -C "$BOX/rewriter" rev-parse HEAD)
forge_ci_green fm/stack-part-1
move_on_to_part2
show_forge
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 1 'a green forge head that does not contain the copy'"'"'s PR-branch tip refuses'
expect_out "named head $LOCAL_TIP could not be verified in pull request head $REWRITE" \
  'the refusal names the local part-1 tip and the rewritten forge head'
expect_eq "$(forge_pr_state 4) $(forge_merge_calls)" 'OPEN 0' 'the PR is still open and no merge was sent'
lab_destroy

# ---------------------------------------------------------------------------
scenario 'G12: a whole stack from one task copy - PR #4 then PR #5 each merge while the next part is still unpushed'
PR_URL5="https://github.com/$OWNER/$REPO/pull/5"
lab_new; write_meta direct-PR
part1_pushed_and_green
move_on_to_part2
step 'merge part 1 (PR #4) while part 2 is only in the copy'
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL"
expect_rc 0 'PR #4 merges'
step 'the worker pushes part 2, PR #5 opens and goes green, and the worker moves on to part 3 without pushing'
wgit push -q -u origin fm/stack-part-2
forge_open_pr 5 fm/stack-part-2
forge_ci_green fm/stack-part-2
wgit checkout -q -b fm/stack-part-3
wcommit part3.txt 'part 3'
PART3=$(git -C "$WT" rev-parse HEAD)
show_copy; show_forge
step 'merge part 2 (PR #5) from the same task'
fm fixed fm-pr-merge.sh "$TASK" "$PR_URL5"
expect_rc 0 'PR #5 merges'
expect_eq "$(forge_pr_state 4) $(forge_pr_state 5)" 'MERGED MERGED' 'both PRs are merged on the forge'
expect_eq "$(grep -c "^pr merge 5 --repo $OWNER/$REPO --match-head-commit $PART2 --squash\$" "$FORGE/gh.log")" 1 \
  'the second forge merge was bound to part-2'"'"'s pushed head'
expect_eq "$(forge_main_files)" 'README.md part1.txt part2.txt ' 'forge main carries parts 1 and 2 and nothing of part 3'
expect_eq "$(git -C "$WT" symbolic-ref --short HEAD) $(git -C "$WT" rev-parse HEAD)" "fm/stack-part-3 $PART3" \
  'the worker copy is still on its unpushed part-3 commit'
expect_eq "$(grep -c "^pr=$PR_URL5\$" "$META")" 1 'the task record now holds the second PR'
show_forge
lab_destroy

printf '\n================================================================\n'
if [ "$FAILS" -eq 0 ]; then
  printf 'ALL GITHUB SCENARIO ASSERTIONS PASSED\n'
else
  printf '%s ASSERTION(S) FAILED\n' "$FAILS"
fi
[ -z "$BASE_SRC" ] || rm -rf "$BASE_SRC"
exit "$FAILS"
