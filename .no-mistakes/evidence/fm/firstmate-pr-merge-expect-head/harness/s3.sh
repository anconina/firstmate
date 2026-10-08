. ./drive.sh
echo "################ S3: GitLab - the same guard and binding on a merge request"
echo
echo "=== S3a  BEFORE (base b062eb9): newer head B with a succeeded pipeline is merged in place of the verified A"
world s3a gitlab; echo "verified head A=$A"; push_b success; echo "pushed head  B=$B  (head_pipeline: success)"
merge base; forge_report
echo
echo "=== S3b  AFTER: --expect-head A refuses the moved head before glab mr merge"
world s3b gitlab; echo "verified head A=$A"; push_b success; echo "pushed head  B=$B  (head_pipeline: success)"
merge head --expect-head "$A"; forge_report
echo
echo "=== S3c  AFTER: live head == expected head A merges, and glab mr merge carries --sha A"
world s3c gitlab; echo "verified head A=$A"
merge head --expect-head "$A"; forge_report
echo
echo "=== S3d  AFTER: race - B lands between the live read and glab mr merge; the --sha binding refuses it"
world s3d gitlab; echo "verified head A=$A"
git -C "$RUN/dev" checkout -q -b late; echo 'raced in' > "$RUN/dev/late.txt"; git -C "$RUN/dev" add late.txt; git -C "$RUN/dev" commit -qm 'B: raced in'
B=$(git -C "$RUN/dev" rev-parse HEAD); git -C "$RUN/dev" push -q origin late
echo "$B" > "$F/prs/gitlab-7/push-on-merge"; echo "head B=$B will land on the MR branch at the moment glab mr merge runs"
merge head --expect-head "$A"; forge_report
