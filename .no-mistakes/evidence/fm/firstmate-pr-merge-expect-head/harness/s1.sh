. ./drive.sh
echo "################ S1: GitHub - caller verified head A, newer head B (no checks reported yet) pushed just before the merge"
echo
echo "=== S1a  BEFORE (base b062eb9, no way to name the verified head): B is merged"
world s1a github; echo "verified head A=$A"; push_b none; echo "pushed head  B=$B  (statusCheckRollup: [])"
merge base; forge_report
echo
echo "=== S1b  BEFORE (base b062eb9): a caller trying --expect-head A gets it forwarded to gh as an unknown flag"
world s1b github; echo "verified head A=$A"; push_b none; echo "pushed head  B=$B  (statusCheckRollup: [])"
merge base --expect-head "$A"; forge_report
echo
echo "=== S1c  AFTER (change 6bd3810): --expect-head A refuses the moved head before any forge merge call"
world s1c github; echo "verified head A=$A"; push_b none; echo "pushed head  B=$B  (statusCheckRollup: [])"
merge head --expect-head "$A"; forge_report
echo
echo "=== S1d  AFTER: same, but B's checks all completed as SKIPPED (green to the live check)"
world s1d github; echo "verified head A=$A"
push_b '[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"CheckRun","name":"e2e","status":"COMPLETED","conclusion":"SKIPPED"}]'
echo "pushed head  B=$B  (ci=SKIPPED, e2e=SKIPPED)"
merge head --expect-head "$A"; forge_report
echo
echo "=== S1e  AFTER: omitting --expect-head keeps the existing behavior unchanged (B merges, bound to the head it read)"
world s1e github; echo "verified head A=$A"; push_b none; echo "pushed head  B=$B  (statusCheckRollup: [])"
merge head; forge_report
