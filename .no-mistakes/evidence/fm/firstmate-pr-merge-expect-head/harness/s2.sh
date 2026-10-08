. ./drive.sh
echo "################ S2: GitHub - the forge merge call is bound to the caller's expected head"
echo
echo "=== S2a  live head == expected head A: merges, and gh pr merge carries --match-head-commit A"
world s2a github; echo "verified head A=$A"
merge head --expect-head "$A"; forge_report
echo
echo "=== S2b  race: live read sees A (== expected), then head B is pushed between the read and the forge merge call"
world s2b github; echo "verified head A=$A"
git -C "$RUN/dev" checkout -q -b late; echo 'raced in' > "$RUN/dev/late.txt"; git -C "$RUN/dev" add late.txt; git -C "$RUN/dev" commit -qm 'B: raced in'
B=$(git -C "$RUN/dev" rev-parse HEAD); git -C "$RUN/dev" push -q origin late
echo "$B" > "$F/prs/github-45/push-on-merge"; echo "head B=$B will land on the PR branch at the moment gh pr merge runs"
merge head --expect-head "$A"; forge_report
echo
echo "=== S2c  --expect-head combined with --attended-override, --allow-red and forge extra args, in any order"
world s2c github; echo "verified head A=$A"
printf '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"flaky-lint","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$F/checks/$A.json"
echo "head A checks: ci=SUCCESS, flaky-lint=FAILURE"
merge head --allow-red flaky-lint --expect-head "$A" --attended-override -- --merge; forge_report
