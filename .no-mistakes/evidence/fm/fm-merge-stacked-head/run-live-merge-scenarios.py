"""Drive bin/fm-pr-merge.sh and bin/fm-pr-check.sh live against a real open,
green GitHub pull request, from disposable lab homes and disposable worker
copies, without ever submitting a merge.

Safety boundary:
  * Every forge read is the real gh against the real pull request.
  * Every merge call is passed `-- --help`, so the real `gh pr merge` prints its
    usage instead of merging.
  * A pass-through gh guard on PATH logs every gh invocation, execs the real gh,
    and hard-refuses any `pr merge` that lacks --help (belt and braces).
  * Lab homes and worker copies live under the system temp dir and are removed
    at the end of the run.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path(sys.argv[1])
PR_NUMBER = sys.argv[2]
BASE_COMMIT = sys.argv[3]
URL = 'https://github.com/kunchenguid/firstmate/pull/' + PR_NUMBER
ORIGIN = 'https://github.com/kunchenguid/firstmate.git'
REAL_GH = shutil.which('gh')

TMP = Path(tempfile.mkdtemp(prefix='fm-live-merge.'))
GUARD = TMP / 'guard-bin'
GUARD.mkdir()
GH_LOG = TMP / 'gh-invocations.log'
(GUARD / 'gh').write_text(f'''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{GH_LOG}"
if [ "${{1:-}} ${{2:-}}" = "pr merge" ]; then
  case " $* " in *" --help "*) ;; *) echo "gh-guard: refusing a real merge" >&2; exit 97 ;; esac
fi
exec "{REAL_GH}" "$@"
''')
(GUARD / 'gh').chmod(0o755)

env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_') or key in ['BASH_ENV', 'ENV', 'SHELLOPTS']:
        env.pop(key)
env.update(PATH=str(GUARD) + os.pathsep + env['PATH'], GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_TERMINAL_PROMPT='0', GH_PROMPT_DISABLED='1',
           GIT_AUTHOR_NAME='Validation', GIT_AUTHOR_EMAIL='validation@example.invalid',
           GIT_COMMITTER_NAME='Validation', GIT_COMMITTER_EMAIL='validation@example.invalid')

transcript = (EVIDENCE / 'live-merge-transcript.txt').open('w')
results = []


def note(s=''):
    print(s, flush=True)
    transcript.write(s + '\n')
    transcript.flush()


def run(args, cwd=None, check=True, extra=None):
    proc = subprocess.run(args, cwd=cwd or ROOT, env=dict(env, **(extra or {})), text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode:
        raise RuntimeError(str(args) + '\n' + proc.stdout + proc.stderr)
    return proc


def git(wt, *args):
    return run(['git', '-C', str(wt), *args]).stdout.strip()


pr = json.loads(run([REAL_GH, 'pr', 'view', URL, '--json',
                     'url,state,isDraft,mergeable,mergeStateStatus,headRefName,headRefOid,baseRefName,mergedAt']).stdout)
(EVIDENCE / 'live-pr-before.json').write_text(json.dumps(pr, indent=2) + '\n')
BRANCH, HEAD = pr['headRefName'], pr['headRefOid']

BASE_TREE = TMP / 'base-tree'
BASE_TREE.mkdir()
subprocess.run(f'git archive {BASE_COMMIT} | tar -x -C {BASE_TREE}', shell=True, check=True, cwd=ROOT)


def new_lab(name, secondmate=False):
    lab = TMP / ('fm-lab.' + name)
    run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)])
    if secondmate:
        (lab / '.fm-secondmate-home').write_text('mate-x\n')
        (lab / '.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=remote\n')
    return lab


def new_copy(lab, start, depth=4):
    wt = lab / 'worker'
    wt.mkdir()
    git(wt, 'init', '-q')
    git(wt, 'remote', 'add', 'origin', ORIGIN)
    git(wt, 'fetch', '-q', f'--depth={depth}', '--no-tags', 'origin', start)
    git(wt, 'checkout', '-q', '-b', BRANCH, start)
    return wt


def write_meta(lab, wt, mode, with_pr=True):
    meta = lab / 'state' / 'stacked.meta'
    lines = ['window=fm-stacked', 'worktree=' + str(wt), 'project=' + str(wt), 'kind=ship', 'mode=' + mode]
    if with_pr:
        lines.append('pr=' + URL)
    meta.write_text('\n'.join(lines) + '\n')
    meta.chmod(0o600)


def later_branch(wt):
    git(wt, 'checkout', '-q', '-b', 'part-2')
    git(wt, 'commit', '-q', '--allow-empty', '-m', 'part 2, only in this disposable copy')
    return git(wt, 'rev-parse', 'HEAD')


def state_of(lab, wt):
    meta = (lab / 'state' / 'stacked.meta').read_text()
    replies = lab / 'state' / 'parent-replies.status'
    return dict(
        current=git(wt, 'symbolic-ref', '--short', 'HEAD') + ' @ ' + git(wt, 'rev-parse', 'HEAD'),
        pr_branch_tip=git(wt, 'rev-parse', 'refs/heads/' + BRANCH) if run(
            ['git', '-C', str(wt), 'rev-parse', '--verify', '--quiet', 'refs/heads/' + BRANCH], check=False).returncode == 0 else '(absent)',
        meta_pr=[l for l in meta.splitlines() if l.startswith('pr=') or l.startswith('pr_head=')],
        poll_armed=(lab / 'state' / 'stacked.check.sh').exists(),
        parent_replies=replies.read_text().strip() if replies.exists() else '(none)',
    )


def drive(name, lab, wt, cmd, expect, tree=ROOT):
    """cmd is 'merge' or 'check'; expect is a predicate over (rc, stderr, gh_lines)."""
    note('=' * 78)
    note('SCENARIO ' + name)
    before = state_of(lab, wt)
    note('worker copy HEAD:   ' + before['current'])
    note('PR branch ' + BRANCH + ' tip in copy: ' + before['pr_branch_tip'])
    note('forge head (live):  ' + HEAD)
    if cmd == 'merge':
        args = ['bash', str(tree / 'bin/fm-pr-merge.sh'), 'stacked', URL, '--', '--help']
    else:
        args = ['bash', str(tree / 'bin/fm-pr-check.sh'), 'stacked', URL]
    shown = ' '.join(a if a != str(tree / ('bin/fm-pr-merge.sh' if cmd == 'merge' else 'bin/fm-pr-check.sh'))
                     else ('<base ' + BASE_COMMIT[:8] + '>/' if tree != ROOT else '') + 'bin/fm-pr-' + cmd + '.sh'
                     for a in args[1:])
    note('$ FM_HOME=<lab ' + lab.name + '> ' + shown)
    GH_LOG.write_text('')
    proc = run(args, check=False, extra=dict(FM_HOME=str(lab)))
    gh_lines = GH_LOG.read_text().splitlines()
    after = state_of(lab, wt)
    (EVIDENCE / (name + '.stderr.txt')).write_text(proc.stderr)
    note('exit: ' + str(proc.returncode))
    note('stderr (product):')
    for line in proc.stderr.strip().splitlines():
        if line.startswith('●') or line.startswith('error: >'):
            continue
        note('  ' + line)
    if proc.stdout.strip():
        note('stdout (product):')
        for line in proc.stdout.strip().splitlines():
            note('  ' + line)
    note('real gh calls:')
    for line in gh_lines:
        note('  gh ' + line)
    note('after: meta ' + ' '.join(after['meta_pr']) + '; merge poll armed=' + str(after['poll_armed']))
    note('after: worker copy HEAD ' + after['current'] + '; PR branch tip ' + after['pr_branch_tip'])
    note('after: parent channel: ' + after['parent_replies'])
    ok, why = expect(proc.returncode, proc.stderr, gh_lines, before, after)
    note('RESULT ' + ('PASS' if ok else 'FAIL') + ': ' + why)
    results.append(dict(name=name, passed=ok, why=why, exit=proc.returncode, live=True, actual_merge=False))
    return proc, after


def reached_merge(gh_lines):
    return [l for l in gh_lines if l.startswith('pr merge ')]


def expect_reaches_merge(rc, err, gh, before, after):
    merges = reached_merge(gh)
    want = f'pr merge {PR_NUMBER} --repo kunchenguid/firstmate --match-head-commit {HEAD} --squash --help'
    ok = merges == [want] and 'unreachable outside the worker copy' not in err \
        and 'could not be verified' not in err and before['current'] == after['current']
    return ok, ('publication check passed; real gh pr merge reached bound to live head (as --help, so nothing merged)'
                if ok else 'expected to reach `gh ' + want + '`, saw ' + repr(merges))


def expect_publication_refusal(named):
    def check(rc, err, gh, before, after):
        msg = f'named head {named} could not be verified in pull request head {HEAD}'
        ok = rc == 1 and msg in err and not reached_merge(gh) \
            and ('pr=' + URL) in after['meta_pr'] and after['poll_armed']
        return ok, ('refused before gh pr merge with "' + msg + '"; pr= recorded and poll armed'
                    if ok else 'expected refusal "' + msg + '" with pr= and poll armed')
    return check


def expect_head_gate_refusal(named):
    def check(rc, err, gh, before, after):
        msg = f'named head {named} is unreachable outside the worker copy'
        ok = rc != 0 and msg in err and not reached_merge(gh)
        return ok, ('refused with "' + msg + '"' if ok else 'expected refusal "' + msg + '"')
    return check


def no_ready_line(inner):
    def check(rc, err, gh, before, after):
        ok, why = inner(rc, err, gh, before, after)
        quiet = 'PR ready' not in after['parent_replies']
        return ok and quiet, why + ('; parent channel got no PR-ready line' if quiet else '; BUT a PR-ready line went upward')
    return check


try:
    note('Live run against ' + URL + ' (' + pr['state'] + ', ' + pr['mergeable'] + ', ' + pr['mergeStateStatus'] + ')')
    note('head branch ' + BRANCH + ' @ ' + HEAD + '; origin of every worker copy: ' + ORIGIN)
    note('Every merge call carries `-- --help`; a gh guard refuses any real `pr merge`. No push, PR, or merge is made.')

    # S1 + baseline: the reported bug. Part-1 (the PR branch) is pushed and green;
    # the worker moved on to part-2, a new local branch with an unpushed commit.
    lab = new_lab('stacked')
    wt = new_copy(lab, HEAD)
    git(wt, 'update-ref', 'refs/remotes/origin/' + BRANCH, HEAD)
    later = later_branch(wt)
    write_meta(lab, wt, 'direct-PR')
    drive('baseline-before-fix-refuses-stacked-merge', lab, wt, 'merge', expect_head_gate_refusal(later), tree=BASE_TREE)
    write_meta(lab, wt, 'direct-PR')
    drive('stacked-merge-ignores-later-unpushed-branch', lab, wt, 'merge', expect_reaches_merge)

    # S6: ordinary PR-ready registration (not merge) keeps its HEAD gate.
    write_meta(lab, wt, 'direct-PR', with_pr=False)
    drive('ordinary-registration-still-gates-copy-head', lab, wt, 'check', expect_head_gate_refusal(later))

    # S2: the PR's own branch has an unpushed fix; HEAD back on part-2.
    git(wt, 'checkout', '-q', BRANCH)
    git(wt, 'commit', '-q', '--allow-empty', '-m', 'part 1 fix, never pushed')
    fix = git(wt, 'rev-parse', 'HEAD')
    git(wt, 'checkout', '-q', 'part-2')
    write_meta(lab, wt, 'direct-PR', with_pr=False)
    drive('unpushed-fix-on-pr-branch-refuses', lab, wt, 'merge', expect_publication_refusal(fix))

    # S2b adversarial: a remote-tracking ref for another branch contains the fix.
    git(wt, 'update-ref', 'refs/remotes/origin/other-fixes', fix)
    drive('fix-on-another-remote-branch-still-refuses', lab, wt, 'merge', expect_publication_refusal(fix))

    # S2c: HEAD is on the PR branch itself, with the unpushed fix.
    git(wt, 'checkout', '-q', BRANCH)
    drive('unpushed-fix-with-head-on-pr-branch-refuses', lab, wt, 'merge', expect_publication_refusal(fix))

    # S4 (F1): no-mistakes mode, the pipeline rebased the branch; the copy's PR
    # branch holds a commit the live head does not contain, HEAD on part-2.
    git(wt, 'reset', '-q', '--hard', HEAD + '~2')
    git(wt, 'commit', '-q', '--allow-empty', '-m', 'part 1 as the worker left it, before the pipeline rebased it')
    stale = git(wt, 'rev-parse', 'HEAD')
    in_head = run(['git', '-C', str(wt), 'merge-base', '--is-ancestor', stale, HEAD], check=False).returncode == 0
    note('=' * 78)
    note('rebased setup: copy PR branch tip ' + stale + ' contained in live head = ' + str(in_head))
    git(wt, 'checkout', '-q', 'part-2')
    write_meta(lab, wt, 'no-mistakes', with_pr=False)
    drive('no-mistakes-stale-rebased-branch-merges', lab, wt, 'merge', expect_reaches_merge)

    # S3 (R2/F3): stale remote-tracking refs, the live head not in the copy, and
    # the copy's PR branch tip is its ancestor; the fork PR's head must be
    # fetched by SHA from the base repository.
    lab2 = new_lab('stale-refs')
    parent = run([REAL_GH, 'api', f'repos/kunchenguid/firstmate/commits/{HEAD}', '--jq', '.parents[0].sha']).stdout.strip()
    wt2 = new_copy(lab2, parent, depth=2)
    git(wt2, 'update-ref', 'refs/remotes/origin/' + BRANCH, git(wt2, 'rev-parse', parent + '^'))
    later2 = later_branch(wt2)
    missing = run(['git', '-C', str(wt2), 'cat-file', '-e', HEAD + '^{commit}'], check=False).returncode != 0
    refs_before = git(wt2, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/remotes')
    note('=' * 78)
    note('stale-refs setup: live head present in copy before run = ' + str(not missing)
         + '; remote refs containing PR branch tip = '
         + (git(wt2, 'for-each-ref', '--format=%(refname)', '--contains=' + parent, 'refs/remotes') or '(none)'))
    write_meta(lab2, wt2, 'direct-PR')
    drive('stale-refs-fetches-live-head-by-sha', lab2, wt2, 'merge', expect_reaches_merge)
    fetched = run(['git', '-C', str(wt2), 'cat-file', '-e', HEAD + '^{commit}'], check=False).returncode == 0
    refs_same = refs_before == git(wt2, 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/remotes')
    head_same = later2 == git(wt2, 'rev-parse', 'HEAD') and git(wt2, 'symbolic-ref', '--short', 'HEAD') == 'part-2'
    note('after: live head fetched=' + str(fetched) + '; local and remote-tracking refs unchanged=' + str(refs_same)
         + '; worker still on part-2 @ later commit=' + str(head_same))
    results[-1]['passed'] = results[-1]['passed'] and missing and fetched and refs_same and head_same

    # S7: the PR branch is absent from the copy, so the HEAD gate applies.
    lab3 = new_lab('absent-branch')
    wt3 = new_copy(lab3, HEAD)
    git(wt3, 'branch', '-m', BRANCH, 'local-part-1')
    git(wt3, 'commit', '-q', '--allow-empty', '-m', 'local fix, only in the copy')
    later3 = git(wt3, 'rev-parse', 'HEAD')
    write_meta(lab3, wt3, 'direct-PR')
    note('=' * 78)
    note('absent-branch setup: PR branch ' + BRANCH + ' renamed away locally; HEAD local-part-1 @ ' + later3)
    drive('absent-pr-branch-uses-head-gate', lab3, wt3, 'merge', expect_head_gate_refusal(later3))

    # S5 (R5-1): secondmate home. A merge-time re-record records pr= and arms the
    # poll but tells the parent nothing, both on refusal and on acceptance,
    # while ordinary registration still reports the PR ready upward.
    lab4 = new_lab('secondmate', secondmate=True)
    wt4 = new_copy(lab4, HEAD)
    git(wt4, 'update-ref', 'refs/remotes/origin/' + BRANCH, HEAD)
    later_branch(wt4)
    git(wt4, 'checkout', '-q', BRANCH)
    git(wt4, 'commit', '-q', '--allow-empty', '-m', 'part 1 fix, never pushed')
    fix4 = git(wt4, 'rev-parse', 'HEAD')
    git(wt4, 'checkout', '-q', 'part-2')
    write_meta(lab4, wt4, 'direct-PR', with_pr=False)
    drive('secondmate-refused-merge-sends-no-ready-line', lab4, wt4, 'merge',
          no_ready_line(expect_publication_refusal(fix4)))
    git(wt4, 'checkout', '-q', BRANCH)
    git(wt4, 'reset', '-q', '--hard', HEAD)
    git(wt4, 'checkout', '-q', 'part-2')
    drive('secondmate-accepted-merge-sends-no-ready-line', lab4, wt4, 'merge', no_ready_line(expect_reaches_merge))

    def expect_ready_line(rc, err, gh, before, after):
        ok = rc == 0 and 'child stacked PR ready: ' + URL in after['parent_replies']
        return ok, ('ordinary registration reported the child PR ready upward' if ok else 'no ready line from ordinary registration')
    git(wt4, 'checkout', '-q', BRANCH)
    write_meta(lab4, wt4, 'direct-PR', with_pr=False)
    (lab4 / 'state' / 'parent-replies.status').unlink(missing_ok=True)
    drive('secondmate-ordinary-registration-still-sends-ready-line', lab4, wt4, 'check', expect_ready_line)

    post = json.loads(run([REAL_GH, 'pr', 'view', URL, '--json', 'url,state,headRefOid,mergedAt,autoMergeRequest']).stdout)
    (EVIDENCE / 'live-pr-after.json').write_text(json.dumps(post, indent=2) + '\n')
    note('=' * 78)
    note('Forge state after the run (unchanged, nothing merged): ' + json.dumps(post))
finally:
    (EVIDENCE / 'live-merge-results.json').write_text(json.dumps(results, indent=2) + '\n')
    shutil.rmtree(TMP)
    note('Removed every disposable lab home, worker copy, and the base tree (' + TMP.name + ').')
    transcript.close()
raise SystemExit(not results or not all(r['passed'] for r in results))
