#!/usr/bin/env bash
# Disposable local stand-in for the GitHub forge, answering the gh calls
# bin/fm-pr-merge.sh makes. The pull request head is read live from a bare git
# repository, check rollups are per-head files (absent = no checks reported yet),
# and `pr merge --match-head-commit` is enforced the way GitHub enforces it:
# a bound head that is not the live head fails the merge.
set -u
F=${FORGE_ROOT:?FORGE_ROOT unset}
printf 'gh %s\n' "$*" >> "$F/forge.log"
GIT="git --git-dir=$F/repo.git"

pr_dir() { printf '%s/prs/github-%s' "$F" "$1"; }
live_head() { $GIT rev-parse "refs/heads/$(cat "$(pr_dir "$1")/head_ref")"; }

view_json() {
  local n=$1 d head rollup state
  d=$(pr_dir "$n")
  head=$(live_head "$n")
  state=$(cat "$d/state")
  if [ -f "$F/checks/$head.json" ]; then rollup=$(cat "$F/checks/$head.json"); else rollup='[]'; fi
  jq -nc --arg state "$state" --arg head "$head" --argjson rollup "$rollup" \
    '{state:$state,isDraft:false,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",headRefOid:$head,baseRefName:"main",statusCheckRollup:$rollup}'
}

case "${1:-} ${2:-}" in
  "pr view")
    url=$3; n=${url##*/}; shift 3
    q=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -q|--jq) q=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$q" ]; then view_json "$n" | jq -r "$q"; else view_json "$n"; fi
    ;;
  "pr merge")
    n=$3; shift 3
    match=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --match-head-commit) match=$2; shift 2 ;;
        --repo|-R|--subject|--body) shift 2 ;;
        --squash|--merge|--rebase|--auto|--admin|--delete-branch|-d) shift ;;
        *) echo "unknown flag: $1" >&2; echo "Usage:  gh pr merge [<number> | <url> | <branch>] [flags]" >&2; exit 1 ;;
      esac
    done
    d=$(pr_dir "$n")
    # A push that lands between fm-pr-merge.sh's live read and this call.
    if [ -f "$d/push-on-merge" ]; then
      $GIT update-ref "refs/heads/$(cat "$d/head_ref")" "$(cat "$d/push-on-merge")"
      rm -f "$d/push-on-merge"
    fi
    [ "$(cat "$d/state")" = OPEN ] || { echo "GraphQL: Pull request is not open (mergePullRequest)" >&2; exit 1; }
    head=$(live_head "$n")
    if [ -n "$match" ] && [ "$match" != "$head" ]; then
      echo "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)" >&2
      exit 1
    fi
    new=$($GIT commit-tree "$head^{tree}" -p "$($GIT rev-parse refs/heads/main)" -m "Squash PR #$n at $head")
    $GIT update-ref refs/heads/main "$new"
    echo MERGED > "$d/state"
    printf '%s\n' "$head" > "$d/merged_head"
    echo "✓ Squashed and merged pull request #$n"
    ;;
  "api graphql")
    n=
    for a in "$@"; do case "$a" in number=*) n=${a#number=} ;; esac; done
    st=$(cat "$(pr_dir "$n")/state")
    merged=false; [ "$st" = MERGED ] && merged=true
    printf 'state=%s\nmerged=%s\nqueued=false\nbase=main\n' "$st" "$merged"
    ;;
  api\ *)
    case " $* " in
      *" --jq "*) exit 0 ;;   # merge-queue rule read: no merge_queue rule
      *"/rules/branches/"*) echo '[{"type":"deletion"}]' ;;
      *"/branches/"*)
        echo '{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}'
        ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    ;;
  *) echo "forge stand-in: unsupported gh call: $*" >&2; exit 1 ;;
esac
