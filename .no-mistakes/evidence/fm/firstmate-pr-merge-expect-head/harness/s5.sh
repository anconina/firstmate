. ./drive.sh
echo "################ S5: anything but one full commit SHA, given once as a separate argument, is refused before any state is recorded or forge is read"
probe() {
  local label=$1; shift
  echo
  echo "=== $label"
  world "s5-$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-' | cut -c1-40)" github
  local args=() a up; up=$(printf '%s' "$A" | tr a-f A-F)
  for a in "$@"; do a=${a//@A@/$A}; a=${a//@A7@/${A:0:7}}; a=${a//@A39@/${A:0:39}}; a=${a//@UP@/$up}; args+=("$a"); done
  echo "live head of this PR: $A"
  merge head "${args[@]}"
  printf '  forge calls (any): %s\n' "$(wc -l < "$F/forge.log" | tr -d ' ')"
  printf '  lab pr= recorded: %s\n' "$(grep -c '^pr=' "$LAB/state/task-x1.meta")"
  printf '  main now contains: %s\n' "$(git --git-dir="$F/repo.git" ls-tree --name-only refs/heads/main | tr '\n' ' ')"
}
probe "short SHA (abbreviated 7 hex)" --expect-head @A7@
probe "39 hex" --expect-head @A39@
probe "41 hex" --expect-head @A@0
probe "uppercase of the live head" --expect-head @UP@
probe "non-hex 40 chars" --expect-head gggggggggggggggggggggggggggggggggggggggg
probe "trailing newline" --expect-head "@A@"$'\n'
probe "empty value" --expect-head ''
probe "flag given with no value" --expect-head
probe "= form" --expect-head=@A@
probe "given twice" --expect-head @A@ --expect-head @A@
probe "a ref name instead of a SHA" --expect-head refs/heads/feature
echo
echo "=== adversarial: --expect-head A plus a smuggled forge head override (-- --match-head-commit B) is refused"
world s5-smuggle github; echo "verified head A=$A"; push_b none; echo "pushed head  B=$B"
merge head --expect-head "$A" -- --match-head-commit "$B"; forge_report
