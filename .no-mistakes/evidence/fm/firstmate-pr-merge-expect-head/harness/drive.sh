#!/usr/bin/env bash
# Scenario driver: builds a fresh disposable forge + marked lab FM_HOME per run
# and invokes the real bin/fm-pr-merge.sh (from the gate worktree, or from the
# extracted base commit for the before/after comparison) against it.
set -u
W=$(cd "$(dirname "$0")" && pwd)
HEAD_ROOT=/home/ubuntu/.no-mistakes/worktrees/954444e3c755/01M4DXWJS1BTYDAXCC2Y2PA6ED
BASE_ROOT=$W/base-src
export GIT_AUTHOR_NAME=fm-lab GIT_AUTHOR_EMAIL=fm-lab@example.invalid
export GIT_COMMITTER_NAME=fm-lab GIT_COMMITTER_EMAIL=fm-lab@example.invalid
GH_URL=https://github.com/example/repo/pull/45
GL_URL=https://gitlab.example/group/subgroup/project/-/merge_requests/7

# world <name> <github|gitlab>: fresh forge with main + feature@A whose CI
# fully passed, a lab home holding task-x1, and the task's worktree clone.
world() {
  RUN=$W/runs/$1; PROV=$2; local fmt=${3:-sha1}
  rm -rf "$RUN"; mkdir -p "$RUN"
  F=$RUN/forge; mkdir -p "$F/prs" "$F/checks" "$F/pipelines"; : > "$F/forge.log"
  git init -q --bare -b main --object-format="$fmt" "$F/repo.git"
  git clone -q "$F/repo.git" "$RUN/dev" 2>/dev/null
  git -C "$RUN/dev" checkout -q -b main
  echo base > "$RUN/dev/README"; git -C "$RUN/dev" add README; git -C "$RUN/dev" commit -qm base
  git -C "$RUN/dev" push -q origin main
  git -C "$RUN/dev" checkout -q -b feature
  echo 'verified change' > "$RUN/dev/change.txt"; git -C "$RUN/dev" add change.txt
  git -C "$RUN/dev" commit -qm 'A: the change CI verified'
  git -C "$RUN/dev" push -q -u origin feature
  A=$(git -C "$RUN/dev" rev-parse HEAD)
  if [ "$PROV" = github ]; then
    mkdir -p "$F/prs/github-45"; echo feature > "$F/prs/github-45/head_ref"; echo OPEN > "$F/prs/github-45/state"
    printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$F/checks/$A.json"
    URL=$GH_URL
  else
    mkdir -p "$F/prs/gitlab-7"; echo feature > "$F/prs/gitlab-7/head_ref"; echo opened > "$F/prs/gitlab-7/state"
    echo success > "$F/pipelines/$A"
    URL=$GL_URL
  fi
  LAB=$RUN/lab
  "$HEAD_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  cp "$HEAD_ROOT/.tasks.toml" "$LAB/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  printf '%s\n' window=fm-task-x1 "worktree=$RUN/dev" "project=$RUN/project" kind=ship mode=no-mistakes > "$LAB/state/task-x1.meta"
  mkdir -p "$RUN/user-home"
}

# push_b <github-rollup-json|gitlab-pipeline-status|none>: a newer head B lands
# on the PR branch; its own CI has not produced a red signal.
push_b() {
  echo 'unverified follow-up' > "$RUN/dev/late.txt"; git -C "$RUN/dev" add late.txt
  git -C "$RUN/dev" commit -qm 'B: pushed moments before the merge'
  git -C "$RUN/dev" push -q origin feature
  B=$(git -C "$RUN/dev" rev-parse HEAD)
  case "$PROV:$1" in
    github:none) ;;
    github:*) printf '%s\n' "$1" > "$F/checks/$B.json" ;;
    gitlab:none) ;;
    gitlab:*) echo "$1" > "$F/pipelines/$B" ;;
  esac
}

# merge <head|base> [args...]: run that tree's fm-pr-merge.sh as a caller would.
merge() {
  local which=$1 root rc; shift
  [ "$which" = base ] && root=$BASE_ROOT || root=$HEAD_ROOT
  printf '$ %s/bin/fm-pr-merge.sh task-x1 %s' "$( [ "$which" = base ] && echo '<base b062eb9>' || echo '<change 6bd3810>')" "$URL"
  [ "$#" -eq 0 ] || printf ' %s' "$@"; printf '\n'
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" HOME="$RUN/user-home" FORGE_ROOT="$F" PATH="$W/bin:$PATH" \
    "$root/bin/fm-pr-merge.sh" task-x1 "$URL" "$@" > "$RUN/out" 2> "$RUN/err"
  rc=$?
  sed 's/^/  stdout| /' "$RUN/out"
  if grep -q '^●' "$RUN/err"; then printf '  stderr| (fm-guard WATCHER DOWN banner elided: the lab home runs no watcher)\n'; fi
  grep -v '^●' "$RUN/err" | sed 's/^/  stderr| /'
  printf '  exit=%s\n' "$rc"
  return "$rc"
}

forge_report() {
  local n d
  [ "$PROV" = github ] && d=$F/prs/github-45 || d=$F/prs/gitlab-7
  printf '  forge merge calls:\n'
  n=$(grep -E '^(gh pr merge|glab .* mr merge)' "$F/forge.log" || true)
  if [ -n "$n" ]; then printf '%s\n' "$n" | sed 's/^/    /'; else printf '    (none)\n'; fi
  printf '  forge PR state: %s; merged head: %s\n' "$(cat "$d/state")" "$(cat "$d/merged_head" 2>/dev/null || echo '-')"
  printf '  main now contains: %s\n' "$(git --git-dir="$F/repo.git" ls-tree --name-only refs/heads/main | tr '\n' ' ')"
  printf '  lab pr= recorded: %s; leftover locks: %s\n' \
    "$(grep -c '^pr=' "$LAB/state/task-x1.meta" 2>/dev/null)" \
    "$(ls -a "$LAB/state" | grep -E '^\.(control-task-x1|afk-contract)\.lock$' | tr '\n' ' ' || true)"
}
