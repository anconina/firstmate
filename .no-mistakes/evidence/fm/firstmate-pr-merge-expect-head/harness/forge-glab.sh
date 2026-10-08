#!/usr/bin/env bash
# Disposable local stand-in for a GitLab instance, answering the glab calls
# bin/fm-pr-merge.sh makes. The merge request head is read live from a bare git
# repository, the head pipeline is a per-head status file (absent = no
# pipeline), and `mr merge --sha` is enforced the way GitLab enforces it.
set -u
F=${FORGE_ROOT:?FORGE_ROOT unset}
printf 'glab GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$F/forge.log"
GIT="git --git-dir=$F/repo.git"

pr_dir() { printf '%s/prs/gitlab-%s' "$F" "$1"; }
live_head() { $GIT rev-parse "refs/heads/$(cat "$(pr_dir "$1")/head_ref")"; }

case "${1:-} ${2:-}" in
  "mr view")
    n=$3; d=$(pr_dir "$n"); head=$(live_head "$n")
    if [ -f "$F/pipelines/$head" ]; then
      pipeline=$(jq -nc --arg sha "$head" --arg st "$(cat "$F/pipelines/$head")" '{sha:$sha,status:$st}')
    else
      pipeline=null
    fi
    jq -nc --arg state "$(cat "$d/state")" --arg head "$head" --argjson p "$pipeline" --argjson iid "$n" \
      '{iid:$iid,state:$state,detailed_merge_status:(if $state=="opened" then "mergeable" else "not_open" end),has_conflicts:false,blocking_discussions_resolved:true,sha:$head,head_pipeline:$p,merge_when_pipeline_succeeds:false,merge_after:null}'
    ;;
  "mr merge")
    n=$3; shift 3
    sha=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --sha) sha=$2; shift 2 ;;
        -R|--repo) shift 2 ;;
        --yes|-y|--squash|--rebase|--auto-merge=false) shift ;;
        *) echo "Error: unknown flag: $1" >&2; exit 1 ;;
      esac
    done
    d=$(pr_dir "$n")
    if [ -f "$d/push-on-merge" ]; then
      $GIT update-ref "refs/heads/$(cat "$d/head_ref")" "$(cat "$d/push-on-merge")"
      rm -f "$d/push-on-merge"
    fi
    [ "$(cat "$d/state")" = opened ] || { echo "ERROR: 405 Method Not Allowed" >&2; exit 1; }
    head=$(live_head "$n")
    if [ -n "$sha" ] && [ "$sha" != "$head" ]; then
      echo "ERROR: 409 Conflict: SHA does not match HEAD of source branch: $head" >&2
      exit 1
    fi
    new=$($GIT commit-tree "$head^{tree}" -p "$($GIT rev-parse refs/heads/main)" -m "Merge MR !$n at $head")
    $GIT update-ref refs/heads/main "$new"
    echo merged > "$d/state"
    printf '%s\n' "$head" > "$d/merged_head"
    echo "✓ Merged! !$n"
    ;;
  *) echo "forge stand-in: unsupported glab call: $*" >&2; exit 1 ;;
esac
