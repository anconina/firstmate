#!/usr/bin/env bash
# Disposable gh-axi stand-in: only the post-merge `pr view` fallback.
set -u
F=${FORGE_ROOT:?FORGE_ROOT unset}
printf 'gh-axi %s\n' "$*" >> "$F/forge.log"
case "${1:-} ${2:-}" in
  "pr view")
    st=$(cat "$F/prs/github-$3/state")
    case "$st" in MERGED) st=merged ;; *) st=open ;; esac
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "$st"
    ;;
  *) exit 0 ;;
esac
