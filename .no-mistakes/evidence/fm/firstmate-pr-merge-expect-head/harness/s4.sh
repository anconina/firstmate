. ./drive.sh
echo "################ S4: SHA-256 object-format repository (64-hex heads), as fm_pr_head_valid accepts a live head"
echo
echo "=== S4a  GitHub, 64-hex live head == expected head: merges bound to the 64-hex head"
world s4a github sha256; echo "verified head A=$A (${#A} hex)"
merge head --expect-head "$A"; forge_report
echo
echo "=== S4b  GitHub, newer 64-hex head B pushed: --expect-head A refuses"
world s4b github sha256; echo "verified head A=$A"; push_b none; echo "pushed head  B=$B  (statusCheckRollup: [])"
merge head --expect-head "$A"; forge_report
echo
echo "=== S4c  adversarial: the first 40 hex of the 64-hex live head is well-formed but is not the head - refused, never prefix-matched"
world s4c github sha256; echo "verified head A=$A"
merge head --expect-head "${A:0:40}"; forge_report
echo
echo "=== S4d  GitLab, 64-hex live head == expected head: merges with --sha bound to it"
world s4d gitlab sha256; echo "verified head A=$A"
merge head --expect-head "$A"; forge_report
