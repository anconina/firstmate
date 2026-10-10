#!/usr/bin/env bash
# Shared helpers for the live-validation lab of bin/fm-pr-merge.sh's stacked-PR
# publication check. Everything here is disposable test scaffolding: a marked
# lab FM_HOME (bin/fm-lab-home.sh), a real bare git repository standing in for
# the forge's remote, a real project clone, and a real worker copy (a git
# worktree of that clone) that pushes to the remote with plain `git push`.
# The product scripts run unmodified from a source root: the gate worktree for
# the change under test, or an extracted copy of the base commit for the
# before-the-fix reproduction.
set -u

LAB_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIXED_SRC=${FIXED_SRC:?FIXED_SRC must be the gate worktree}
BASE_COMMIT=${BASE_COMMIT:-fb75c1f94170df7e0751147ea61afabcf5d4e104}
OWNER=fm-lab-forge
REPO=stacked-demo
TASK=stack-task
PR_URL="https://github.com/$OWNER/$REPO/pull/4"
FAILS=0
SCENARIO=

export GIT_AUTHOR_NAME=lab-worker GIT_AUTHOR_EMAIL=worker@lab.invalid
export GIT_COMMITTER_NAME=lab-worker GIT_COMMITTER_EMAIL=worker@lab.invalid
export GIT_CONFIG_NOSYSTEM=1

# Replace this run's temp paths with stable names so the transcript reads the
# same from run to run.
scrub() {
  sed -e "s|${LAB:-@@none@@}|<LAB_HOME>|g" -e "s|${BOX:-@@none@@}|<BOX>|g" \
    -e "s|$FIXED_SRC|<worktree>|g"
}

scenario() {
  SCENARIO=$1
  printf '\n================================================================\n'
  printf 'SCENARIO %s\n' "$1"
  printf '================================================================\n'
}
step() { printf '\n--- %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }

# A fresh lab: marked FM_HOME, forge remote with one commit on main, a project
# clone under the home's projects/, and the worker copy as a worktree of it.
lab_new() {
  local seed
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$FIXED_SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "could not mint lab home" >&2; exit 1; }
  BOX=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-box.XXXXXX")
  export GIT_CONFIG_GLOBAL="$BOX/gitconfig"
  : > "$GIT_CONFIG_GLOBAL"
  FORGE="$BOX/forge"
  FORGE_GIT="$FORGE/${FORGE_REL:-$OWNER/$REPO.git}"
  mkdir -p "$(dirname "$FORGE_GIT")" "$BOX/bin" "$BOX/gh-empty" "$BOX/tasktmp"
  cp "$LAB_LIB_DIR/forge-standin/gh" "$LAB_LIB_DIR/forge-standin/gh-axi" \
    "$LAB_LIB_DIR/forge-standin/glab" "$BOX/bin/"
  # The merge path under test must never reach the no-mistakes CLI; a call
  # would show up in this log and fail the run.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/no-mistakes.log"\nexit 1\n' "$BOX" > "$BOX/bin/no-mistakes"
  chmod +x "$BOX/bin/gh" "$BOX/bin/gh-axi" "$BOX/bin/glab" "$BOX/bin/no-mistakes"
  : > "$FORGE/gh.log"
  : > "$FORGE/gh-axi.log"
  : > "$FORGE/glab.log"
  git init -q --bare -b main "$FORGE_GIT"
  seed="$BOX/seed"
  git clone -q "$FORGE_GIT" "$seed" 2>/dev/null
  git -C "$seed" checkout -q -b main 2>/dev/null || true
  printf 'stacked demo\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -q -m 'initial commit'
  git -C "$seed" push -q origin main
  PROJECT="$LAB/projects/${PROJECT_NAME:-$REPO}"
  git clone -q "$FORGE_GIT" "$PROJECT"
  WT="$BOX/wt"
  git -C "$PROJECT" worktree add -q -b fm/stack-task "$WT" origin/main
  META="$LAB/state/$TASK.meta"
}

lab_destroy() {
  [ -n "${LAB:-}" ] && [ -d "$LAB" ] && rm -rf "$LAB"
  [ -n "${BOX:-}" ] && [ -d "$BOX" ] && rm -rf "$BOX"
  LAB=; BOX=
}

# The task record, with the fields bin/fm-spawn.sh writes for a ship task.
write_meta() {  # <mode>
  cat > "$META" <<EOF
window=firstmate:fm-$TASK
endpoint_task_id=$TASK
worktree=$WT
project=$PROJECT
harness=claude
kind=ship
mode=$1
yolo=off
branch=fm/stack-task
tasktmp=$BOX/tasktmp
model=default
effort=default
spawn_gen=1
EOF
  chmod 600 "$META"
}

seed_secondmate_home() {
  printf '%s\n' mate-lab > "$LAB/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$LAB/.fm-secondmate-parent"
}

# Forge-side events that are not the product's doing: a PR being opened for a
# pushed branch, and CI reporting green at the branch's current remote head.
forge_open_pr() {  # <number> <head-branch>
  local d="$FORGE/$OWNER/$REPO.prs/$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/branch"
  printf 'main\n' > "$d/base"
  printf 'OPEN\n' > "$d/state"
  printf 'false\n' > "$d/draft"
  printf '(forge) pull request #%s opened: %s -> main\n' "$1" "$2"
}
forge_ci_green() {  # <head-branch>
  local sha
  sha=$(git -C "$FORGE_GIT" rev-parse "refs/heads/$1")
  mkdir -p "$FORGE/$OWNER/$REPO.checks"
  printf 'SUCCESS\n' > "$FORGE/$OWNER/$REPO.checks/$sha"
  printf '(forge) check "ci" is green at %s (head of %s)\n' "$sha" "$1"
}
forge_pr_state() { cat "$FORGE/$OWNER/$REPO.prs/${1:-4}/state"; }
forge_main_files() { git -C "$FORGE_GIT" ls-tree -r --name-only refs/heads/main | tr '\n' ' '; }
forge_merge_calls() { grep -c '^pr merge ' "$FORGE/gh.log" || true; }

show_forge() {
  printf '(forge) PR #4 state: %s\n' "$(forge_pr_state 4)"
  printf '(forge) remote branches:\n'
  git -C "$FORGE_GIT" for-each-ref --format='          %(refname:short) %(objectname:short=12) %(subject)' refs/heads
  printf '(forge) files on main: %s\n' "$(forge_main_files)"
}
show_copy() {
  local b sha r st
  printf '(worker copy) current branch: %s  HEAD: %s\n' \
    "$(git -C "$WT" symbolic-ref --short HEAD)" "$(git -C "$WT" rev-parse HEAD)"
  printf '(worker copy) local branches, compared with the same-named remote branch:\n'
  git -C "$WT" for-each-ref --format='%(refname:short) %(objectname)' --exclude=refs/heads/main refs/heads \
    | while read -r b sha; do
      r=$(git -C "$FORGE_GIT" rev-parse --verify --quiet "refs/heads/$b") || r=
      if [ -z "$r" ]; then
        st='not on the remote'
      elif [ "$r" = "$sha" ]; then
        st='pushed'
      elif ! git -C "$WT" cat-file -e "$r^{commit}" 2>/dev/null; then
        st='remote branch is at a commit this copy has not fetched'
      else
        st="$(git -C "$WT" rev-list --count "$r..$sha") commit(s) not pushed"
      fi
      printf '          %-22s %s  %s\n' "$b" "${sha:0:12}" "$st"
    done
}

# Run a worker-side git command in the worker copy and show it.
wgit() {
  printf '$ git %s\n' "$*" | scrub
  git -C "$WT" "$@" 2>&1 | sed 's/^/    /' | scrub
}
# A worker commit that adds or extends one file.
wcommit() {  # <file> <message>
  printf '%s\n' "$2" >> "$WT/$1"
  git -C "$WT" add "$1"
  git -C "$WT" commit -q -m "$2"
  printf '$ git commit -m "%s"   # -> %s\n' "$2" "$(git -C "$WT" rev-parse HEAD)"
}

# Run one firstmate script from <src> (fixed | base) against the lab home, the
# way a firstmate runs it: from its checkout, with FM_HOME naming the home. The
# stand-in forge CLIs come first on PATH; the real gh login is kept out of
# reach. Sets RC and OUT.
BASE_SRC=
fm() {  # <fixed|base> <script> [args...]
  local which=$1 script=$2 src
  shift 2
  if [ "$which" = base ]; then
    if [ -z "$BASE_SRC" ]; then
      BASE_SRC=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-base.XXXXXX")
      git -C "$FIXED_SRC" archive "$BASE_COMMIT" bin | tar -x -C "$BASE_SRC"
    fi
    src=$BASE_SRC
    printf '$ bin/%s %s      [base commit %s, before the fix]\n' "$script" "$*" "${BASE_COMMIT:0:8}"
  else
    src=$FIXED_SRC
    printf '$ bin/%s %s\n' "$script" "$*"
  fi
  RC=0
  OUT=$(cd "$src" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_LAB_FORGE="$FORGE" PATH="$BOX/bin:$PATH" \
    GH_TOKEN=fm-lab-no-network GH_CONFIG_DIR="$BOX/gh-empty" \
    "$src/bin/$script" "$@" 2>&1) || RC=$?
  printf '%s\n' "$OUT" | grep -v -e '^●' -e '^WARNING: watcher still down' | sed 's/^/    /' | scrub
  printf '    [exit %s]\n' "$RC"
}

expect_rc() {  # <want> <what>
  if [ "$RC" -eq "$1" ]; then ok "$2 (exit $RC)"; else bad "$2: expected exit $1, got $RC"; fi
}
expect_out() {  # <needle> <what>
  case "$OUT" in
    *"$1"*) ok "$2" ;;
    *) bad "$2: output did not contain: $1" ;;
  esac
}
expect_eq() {  # <got> <want> <what>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3: got '$1', wanted '$2'"; fi
}
# Lines of <file> containing <text>; 0 when the file does not exist.
count_in() {  # <text> <file>
  if [ -f "$2" ]; then grep -cF -- "$1" "$2" || true; else printf '0\n'; fi
}
expect_no_nm_call() {
  if [ -e "$BOX/no-mistakes.log" ]; then bad "the merge path invoked the no-mistakes CLI: $(cat "$BOX/no-mistakes.log")"; fi
}
