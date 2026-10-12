#!/usr/bin/env bash
# Live driver for bin/fm-pr-merge.sh's stacked-PR publication check.
#
# What is real: the fm-pr-merge.sh / fm-pr-check.sh / fm-dod-lib.sh under test,
# a marked disposable lab home (bin/fm-lab-home.sh create), a bare git origin,
# a worker copy cloned from it, real commits, pushes and fetches.
# What is a stand-in: the forge. github.com / a GitLab / a Forgejo instance is
# replaced by a local "forge" directory whose gh / glab / tea commands answer
# from the bare origin's real refs and really land the merge in that origin, so
# the observable result is what origin's main contains afterwards.
#
# Usage: drive-stacked-merge.sh <firstmate-root> <label> <scenario>
#   scenario = <github|gitlab|forgejo>-[fork-[unreadable-]]<variant>
# Options (environment):
#   FM_LIVE_REGISTER_FIRST=1  run the ordinary PR-ready registration
#                             (bin/fm-pr-check.sh) while HEAD is still the pushed
#                             part 1, before the copy moves on, as a worker does
#   FM_LIVE_MATE=1            make the lab home a secondmate home with a remote
#                             parent channel and show what reached that channel
#   FM_LIVE_CHECK=FAILURE     the pull request's one GitHub check is red
#   FM_LIVE_ENTRY=fm-pr-check.sh  call the ordinary PR-ready registration at the
#                             final step instead of the merge
set -u
ROOT=$1 LABEL=$2 SCENARIO=$3
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid
export GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-stacked-live.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$WORK" "$LAB"' EXIT
FORGE="$WORK/forge" COPY="$WORK/copy" BIN="$WORK/forgebin"
mkdir -p "$FORGE" "$BIN" "$WORK/user-home"
ID=stack-a1

PROVIDER=${SCENARIO%%-*} VARIANT=${SCENARIO#*-}
FORK=0 UNREADABLE=0
case "$VARIANT" in fork-*) FORK=1; VARIANT=${VARIANT#fork-} ;; esac
case "$VARIANT" in unreadable-*) UNREADABLE=1; VARIANT=${VARIANT#unreadable-} ;; esac
MODE=direct-PR
case "$VARIANT" in no-mistakes-*) MODE=no-mistakes ;; esac
case "$PROVIDER" in
  github) URL=https://github.com/example/repo/pull/41 ;;
  gitlab) URL=https://gitlab.example/group/project/-/merge_requests/41 ;;
  forgejo) URL=https://forgejo.example/fixture/fixture-repo/pulls/41 ;;
  *) echo "unknown provider in $SCENARIO"; exit 9 ;;
esac

# --- the disposable lab home -------------------------------------------------
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home refused"; exit 9; }
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
if [ "${FM_LIVE_MATE:-}" = 1 ]; then
  printf '%s\n' mate-x > "$LAB/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$LAB/.fm-secondmate-parent"
fi

# --- the forge: a bare origin plus one open pull request ----------------------
git init -q --bare -b main "$FORGE/origin.git"
git clone -q "file://$FORGE/origin.git" "$COPY" 2>/dev/null
git -C "$COPY" checkout -q -b main
echo base > "$COPY/base.txt"; git -C "$COPY" add base.txt; git -C "$COPY" commit -qm 'base'
git -C "$COPY" push -q origin main
git clone -q "file://$FORGE/origin.git" "$LAB/projects/repo"

commit() {  # <file> <message>
  echo "$2" > "$COPY/$1"; git -C "$COPY" add "$1"; git -C "$COPY" commit -qm "$2"
}

# part 1: built, pushed, pull request #41 opened, checks green.
git -C "$COPY" checkout -q -b fm/stack-part-1
commit part-1.txt 'part 1'
if [ "$FORK" = 1 ]; then
  # a merge request from a fork: the copy's part 1 tracks the fork, written in
  # another URL form than the forge reports for it.
  git init -q --bare -b main "$FORGE/fork.git"
  git -C "$COPY" remote add fork 'ssh://git@GitLab.Example/fork-owner/project.git'
  git -C "$COPY" push -q "file://$FORGE/fork.git" fm/stack-part-1
  git -C "$COPY" update-ref refs/remotes/fork/fm/stack-part-1 HEAD
  git -C "$COPY" config branch.fm/stack-part-1.remote fork
  git -C "$COPY" config branch.fm/stack-part-1.merge refs/heads/fm/stack-part-1
  printf 'branch=fm/stack-part-1\nstate=OPEN\nrepo=fork.git\nsource_project=2\n' > "$FORGE/pr-41"
else
  git -C "$COPY" push -q -u origin fm/stack-part-1
  printf 'branch=fm/stack-part-1\nstate=OPEN\nrepo=origin.git\nsource_project=1\n' > "$FORGE/pr-41"
fi
[ "$UNREADABLE" = 0 ] || : > "$FORGE/source-project-unreadable"

# what the worker does in its copy after part 1's pull request went green.
move_on() {
  case "$VARIANT" in
    stacked)
      # part 2 on a new local branch, not pushed yet.
      git -C "$COPY" checkout -q -b fm/stack-part-2
      commit part-2.txt 'part 2, not pushed'
      ;;
    own-branch-unpushed|no-mistakes-unpushed)
      # a later commit on the pull request's own branch that never left the copy.
      commit part-1-fix.txt 'fix on part 1, only in the copy'
      ;;
    own-branch-amended)
      # part 1 rewritten in the copy after it was pushed.
      echo 'reworked' >> "$COPY/part-1.txt"; git -C "$COPY" add part-1.txt
      git -C "$COPY" commit -q --amend -m 'part 1, reworked and never pushed'
      ;;
    stacked-own-branch-unpushed)
      # both at once: an unpushed fix on part 1, and unpushed part 2 on top.
      commit part-1-fix.txt 'fix on part 1, only in the copy'
      git -C "$COPY" checkout -q -b fm/stack-part-2
      commit part-2.txt 'part 2, not pushed'
      ;;
    fix-only-on-another-remote-branch)
      # the fix sits on part 1 unpushed; part 2 carries it and IS pushed, so the
      # copy's HEAD is reachable outside the copy but pull request #41 lacks it.
      commit part-1-fix.txt 'fix on part 1, not pushed to part 1'
      git -C "$COPY" checkout -q -b fm/stack-part-2
      commit part-2.txt 'part 2'
      git -C "$COPY" push -q -u origin fm/stack-part-2
      ;;
    branch-absent-unpushed-head)
      # the copy no longer has the pull request's branch and HEAD is unpushed.
      git -C "$COPY" checkout -q -b fm/stack-part-2
      commit part-2.txt 'part 2, not pushed'
      git -C "$COPY" branch -q -D fm/stack-part-1
      ;;
    forge-head-ahead)
      # someone else pushed onto part 1 on the forge; the copy never fetched it
      # and has moved on to an unpushed part 2.
      git clone -q "file://$FORGE/origin.git" "$WORK/other" 2>/dev/null
      git -C "$WORK/other" checkout -q fm/stack-part-1
      echo review > "$WORK/other/review.txt"; git -C "$WORK/other" add review.txt
      git -C "$WORK/other" commit -qm 'review fix pushed from elsewhere'
      git -C "$WORK/other" push -q origin fm/stack-part-1
      git -C "$COPY" checkout -q -b fm/stack-part-2
      commit part-2.txt 'part 2, not pushed'
      ;;
    *) echo "unknown scenario $SCENARIO"; exit 9 ;;
  esac
}

cat > "$LAB/state/$ID.meta" <<META
window=fm-$ID
worktree=$COPY
project=$LAB/projects/repo
kind=ship
mode=$MODE
META

# --- forge CLIs that answer from, and merge into, the bare origin -------------
cat > "$BIN/forge-lib" <<'SH'
log() { printf '%s\n' "$*" >> "$FM_LIVE_FORGE/calls.log"; }
pr_field() { sed -n "s/^$2=//p" "$FM_LIVE_FORGE/pr-$1"; }
pr_head() { git -C "$FM_LIVE_FORGE/$(pr_field "$1" repo)" rev-parse "refs/heads/$(pr_field "$1" branch)"; }
land() {  # <number> <sha the caller bound the merge to>
  local n=$1 want=$2 head squash origin=$FM_LIVE_FORGE/origin.git
  head=$(pr_head "$n")
  [ "$want" = "$head" ] || { echo "forge: head $head is not the bound $want" >&2; return 1; }
  [ "$(pr_field "$n" repo)" = origin.git ] \
    || git -C "$origin" fetch -q "$FM_LIVE_FORGE/$(pr_field "$n" repo)" "refs/heads/$(pr_field "$n" branch)" || return 1
  squash=$(git -C "$origin" commit-tree "$head^{tree}" -p refs/heads/main -m "merge #$n at $head") || return 1
  git -C "$origin" update-ref refs/heads/main "$squash" || return 1
  sed -i 's/^state=.*/state=MERGED/' "$FM_LIVE_FORGE/pr-$n"
}
SH
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/forge-lib"
log "gh $*"
filter=; prev=
for a in "$@"; do case "$prev" in --jq|-q) filter=$a ;; esac; prev=$a; done
out() { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }
case "${1:-} ${2:-}" in
  "pr view")
    n=${3##*/}
    jq -n --arg s "$(pr_field "$n" state)" --arg h "$(pr_head "$n")" --arg b "$(pr_field "$n" branch)" \
      --arg c "${FM_LIVE_CHECK:-SUCCESS}" \
      '{state:$s,isDraft:false,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",headRefOid:$h,headRefName:$b,baseRefName:"main",
        statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:$c}]}' | out
    ;;
  "pr merge")
    n=$3; want=; prev=
    for a in "$@"; do [ "$prev" != --match-head-commit ] || want=$a; prev=$a; done
    land "$n" "$want" || exit 1
    echo "merged pull request #$n"
    ;;
  "api graphql")
    n=; for a in "$@"; do case "$a" in number=*) n=${a#number=} ;; esac; done
    s=$(pr_field "$n" state)
    jq -n --arg s "$s" '{data:{repository:{pullRequest:{state:$s,merged:($s=="MERGED"),isInMergeQueue:false,baseRefName:"main"}}}}' | out
    ;;
  api\ *)
    case " $* " in
      *"/rules/branches/"*) echo '[]' | out ;;
      *"/branches/"*) echo '{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}' | out ;;
      *) exit 1 ;;
    esac
    ;;
esac
SH
cat > "$BIN/gh-axi" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/forge-lib"
log "gh-axi $*"
[ "${1:-} ${2:-}" = "pr view" ] || exit 0
printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "$(pr_field "$3" state | tr '[:upper:]' '[:lower:]')"
SH
cat > "$BIN/glab" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/forge-lib"
log "glab $*"
case "${1:-} ${2:-}" in
  "mr view")
    n=$3; s=opened; [ "$(pr_field "$n" state)" != MERGED ] || s=merged
    jq -n --arg s "$s" --arg h "$(pr_head "$n")" --arg b "$(pr_field "$n" branch)" --argjson n "$n" \
      --argjson src "$(pr_field "$n" source_project)" \
      '{iid:$n,state:$s,detailed_merge_status:"mergeable",has_conflicts:false,blocking_discussions_resolved:true,sha:$h,
        source_branch:$b,head_pipeline:{sha:$h,status:"success"},source_project_id:$src,target_project_id:1,
        merge_when_pipeline_succeeds:false,merge_after:null}'
    ;;
  "mr merge")
    n=$3; want=; prev=
    for a in "$@"; do [ "$prev" != --sha ] || want=$a; prev=$a; done
    land "$n" "$want" || exit 1
    ;;
  "api projects/2")
    [ ! -e "$FM_LIVE_FORGE/source-project-unreadable" ] || { echo '{"message":"404 Project Not Found"}'; exit 1; }
    echo '{"id":2,"web_url":"https://gitlab.example/fork-owner/project","http_url_to_repo":"https://gitlab.example/fork-owner/project.git","ssh_url_to_repo":"git@gitlab.example:fork-owner/project.git"}'
    ;;
esac
SH
cat > "$BIN/tea" <<'SH'
#!/usr/bin/env bash
. "$(dirname "$0")/forge-lib"
log "tea $*"
if [ "${1:-} ${2:-}" = "login list" ]; then
  printf '[{"name":"lab","url":"https://forgejo.example","ssh_host":"","user":"","default":"false"}]\n'
fi
SH
chmod +x "$BIN/gh" "$BIN/gh-axi" "$BIN/glab" "$BIN/tea"
: > "$FORGE/calls.log"

# --- drive it ----------------------------------------------------------------
short() { sed -e "s#$WORK#<work>#g" -e "s#$LAB#<lab>#g"; }
fm() {  # <script> <args...>; the runbook's lab-home environment
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEST_SEAM \
    FM_HOME="$LAB" HOME="$WORK/user-home" FM_LIVE_FORGE="$FORGE" PATH="$BIN:$PATH" \
    "$ROOT/bin/$1" "${@:2}"
}
echo "================================================================"
echo "SCENARIO  $SCENARIO   [scripts from: $LABEL]   mode=$MODE${FM_LIVE_MATE:+   secondmate home}${FM_LIVE_CHECK:+   check=$FM_LIVE_CHECK}"
echo "================================================================"
if [ "${FM_LIVE_REGISTER_FIRST:-}" = 1 ]; then
  echo "\$ FM_HOME=<lab> bin/fm-pr-check.sh $ID $URL      # worker reports part 1 ready; HEAD is the pushed part 1"
  fm fm-pr-check.sh "$ID" "$URL" > "$WORK/reg" 2>&1; reg_rc=$?
  grep -v '●' "$WORK/reg" | short | sed 's/^/    /'
  echo "    exit code: $reg_rc"
fi
move_on
main_before=$(git -C "$FORGE/origin.git" rev-parse refs/heads/main)
refs_before=$(git -C "$COPY" for-each-ref; git -C "$COPY" symbolic-ref HEAD)
echo "--- worker copy now (HEAD on $(git -C "$COPY" rev-parse --abbrev-ref HEAD)):"
git -C "$COPY" log --graph --oneline --decorate --all | short | sed 's/^/    /'
echo "--- forge: PR #41 head branch fm/stack-part-1 is at $(git -C "$FORGE/$(sed -n 's/^repo=//p' "$FORGE/pr-41")" rev-parse --short refs/heads/fm/stack-part-1), checks ${FM_LIVE_CHECK:-green}"
ENTRY=${FM_LIVE_ENTRY:-fm-pr-merge.sh}
echo "\$ FM_HOME=<lab> bin/$ENTRY $ID $URL"
fm "$ENTRY" "$ID" "$URL" > "$WORK/out" 2>&1
rc=$?
grep -v '●' "$WORK/out" | short | sed 's/^/    /'
echo "    exit code: $rc"
merges=$(grep -E '^(gh pr merge|glab mr merge|tea .*merge)' "$FORGE/calls.log" | short)
echo "--- merge commands the forge received:"
if [ -n "$merges" ]; then printf '%s\n' "$merges" | sed 's/^/    /'; else echo "    (none - no merge was attempted)"; fi
main_after=$(git -C "$FORGE/origin.git" rev-parse refs/heads/main)
if [ "$main_before" = "$main_after" ]; then
  echo "--- forge origin main: UNCHANGED"
else
  echo "--- forge origin main: ADVANCED, files now on main: $(git -C "$FORGE/origin.git" ls-tree --name-only refs/heads/main | tr '\n' ' ')"
fi
refs_after=$(git -C "$COPY" for-each-ref; git -C "$COPY" symbolic-ref HEAD)
if [ "$refs_before" = "$refs_after" ]; then
  echo "--- worker copy branches, remote-tracking refs and HEAD: unchanged by the call"
else
  echo "--- worker copy refs CHANGED by the call:"; diff <(printf '%s\n' "$refs_before") <(printf '%s\n' "$refs_after") | sed 's/^/    /'
fi
echo "--- lab task record after the call:"
grep -E '^(pr|pr_head)=' "$LAB/state/$ID.meta" | sed 's/^/    /' || echo "    (no pr= recorded)"
if [ -e "$LAB/state/$ID.check.sh" ]; then echo "    merge poll armed: state/$ID.check.sh"; else echo "    merge poll not armed"; fi
if [ "${FM_LIVE_MATE:-}" = 1 ]; then
  echo "--- lines that reached the parent channel (state/parent-replies.status):"
  if [ -s "$LAB/state/parent-replies.status" ]; then sed -E 's/ \[at=[0-9]+\]//; s/^/    /' "$LAB/state/parent-replies.status"; else echo "    (none)"; fi
fi
echo "RESULT $SCENARIO [$LABEL] rc=$rc merged=$([ "$main_before" = "$main_after" ] && echo no || echo yes)"
echo
