import json, os, pathlib, shlex, shutil, subprocess, sys, time

ROOT = pathlib.Path('/Users/mosheanconina/.no-mistakes/worktrees/954444e3c755/01M412K529Y0VANR7WJEGK4EGQ')
EVIDENCE = pathlib.Path('/Users/mosheanconina/.no-mistakes/evidence/01M412K529Y0VANR7WJEGK4EGQ/test-phase-current')
AREA = ROOT / '.test-merge-stacked/live'
AREA.mkdir(parents=True, exist_ok=False)
DATA = json.loads((EVIDENCE / 'green-pr-initial.json').read_text())
PR = 'https://github.com/kunchenguid/firstmate/pull/6489'
BRANCH = DATA['headRefName']
HEAD = DATA['headRefOid']
ORIGIN = 'https://github.com/' + DATA['headRepositoryOwner']['login'] + '/firstmate.git'
STOP = '--fm-validation-read-only-stop'
BASE_ENV = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
BASE_ENV.update(TMPDIR=str(ROOT / '.test-merge-stacked/tmp'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0', GIT_AUTHOR_NAME='Live validation', GIT_AUTHOR_EMAIL='validation@example.invalid', GIT_COMMITTER_NAME='Live validation', GIT_COMMITTER_EMAIL='validation@example.invalid')
log = (EVIDENCE / 'live-preflight-transcript.txt').open('w')
results = []

def note(s):
    print(s, file=log, flush=True)
    print(s, flush=True)

def run(args, env=None, check=True, cwd=ROOT):
    args = [str(a) for a in args]
    print('$ ' + shlex.join(args), file=log, flush=True)
    proc = subprocess.run(args, cwd=cwd, env=env or BASE_ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=100)
    for stream in (proc.stdout, proc.stderr):
        if stream:
            print(stream.rstrip(), file=log, flush=True)
    print('exit=' + str(proc.returncode), file=log, flush=True)
    if check and proc.returncode:
        raise RuntimeError('Command failed: ' + shlex.join(args) + '\n' + proc.stderr)
    return proc

def git(repo, *args, **kwargs):
    return run(['git','-C',repo,*args], **kwargs)

def snapshot(repo):
    return {'branch':git(repo,'symbolic-ref','--short','HEAD').stdout.strip(), 'head':git(repo,'rev-parse','HEAD').stdout.strip(), 'refs':git(repo,'for-each-ref','--format=%(refname) %(objectname)','refs/heads','refs/remotes').stdout, 'status':git(repo,'status','--porcelain').stdout}

def setup(name, mode='direct-PR', initial=None):
    folder = AREA / name
    folder.mkdir()
    home = folder / 'home'
    run([ROOT/'bin/fm-lab-home.sh','create',home])
    (home/'config/backlog-backend').write_text('manual\n')
    repo = folder / 'worker'
    git(folder,'init','-q',repo)
    git(repo,'remote','add','origin',ORIGIN)
    tip = initial or HEAD
    git(repo,'fetch','-q','--depth=3','origin',tip)
    git(repo,'checkout','-q','-b',BRANCH,'FETCH_HEAD')
    git(repo,'update-ref','refs/remotes/origin/'+BRANCH,tip)
    meta = home/'state/live-task.meta'
    meta.write_text(f'window=firstmate:fm-live-task\nendpoint_task_id=live-task\nworktree={repo}\nproject={repo}\nkind=ship\nmode={mode}\npr={PR}\n')
    meta.chmod(0o600)
    return home, repo

def later(repo):
    git(repo,'checkout','-q','-b','part-2')
    git(repo,'commit','-q','--allow-empty','-m','later part kept only in disposable worker')

def invoke(name, home, repo, expect, registration=False):
    note('\nSCENARIO: ' + name)
    before = snapshot(repo)
    env = dict(BASE_ENV, FM_HOME=str(home))
    script = 'fm-pr-check.sh' if registration else 'fm-pr-merge.sh'
    args = [ROOT/'bin'/script,'live-task',PR]
    if not registration:
        args += ['--',STOP]
    proc = run(args, env=env, check=False)
    combined = proc.stdout + proc.stderr
    after = snapshot(repo)
    assert before == after, 'The operation moved branches, HEAD, refs, or changed the worker files'
    assert proc.returncode != 0, 'The deliberate CLI stop/refusal must exit nonzero'
    assert expect in combined, f'Expected {expect!r}, got:\n{combined}'
    if expect != 'unknown flag: ' + STOP:
        assert 'unknown flag: ' + STOP not in combined, 'Refusal occurred too late'
    assert not (home/'state/live-task.pr-poll-merge-notified').exists(), 'Refusal must not record a merge'
    note('Observed: ' + expect + '; worker branch, HEAD, refs and files unchanged; no merge recorded.')
    results.append({'name':name,'result':'pass','live':True,'expected_output':expect,'exit_code':proc.returncode})

try:
    note('Real Firstmate entrypoints, Git, gh and GitHub API. No fake executables or responses.')
    note('The unsupported gh flag stops every potentially eligible merge before any mutation. These are preflight/refusal proofs, not completed merges.')
    stop = run(['gh','pr','merge','6489','--repo','kunchenguid/firstmate',STOP], check=False)
    assert stop.returncode != 0 and 'unknown flag: '+STOP in stop.stderr
    for mode in ('direct-PR','no-mistakes'):
        home, repo = setup('stacked-'+mode,mode)
        later(repo)
        invoke('Pushed PR with later unpushed branch: '+mode,home,repo,'unknown flag: '+STOP)
        if mode == 'direct-PR':
            local_head = git(repo,'rev-parse','HEAD').stdout.strip()
            invoke('Ordinary PR-ready registration still checks worker HEAD',home,repo,'named head '+local_head+' is unreachable outside the worker copy',registration=True)
        git(repo,'checkout','-q',BRANCH)
        git(repo,'commit','-q','--allow-empty','-m','unpublished fix on PR branch')
        fix = git(repo,'rev-parse','HEAD').stdout.strip()
        git(repo,'checkout','-q','part-2')
        invoke('Unpublished PR-branch fix, unpushed later HEAD: '+mode,home,repo,'named head '+fix+' could not be verified in pull request head '+HEAD)
        git(repo,'checkout','-q','-b','published-head',HEAD)
        invoke('Unpublished PR-branch fix, already published current HEAD: '+mode,home,repo,'named head '+fix+' could not be verified in pull request head '+HEAD)
        git(repo,'checkout','-q',BRANCH)
        invoke('Unpublished fix on checked-out PR branch: '+mode,home,repo,'named head '+fix+' could not be verified in pull request head '+HEAD)
        parent = git(repo,'rev-parse',HEAD+'^').stdout.strip()

    for mode in ('direct-PR','no-mistakes'):
        home,repo = setup('pipeline-'+mode,mode,initial=parent)
        stale = git(repo,'rev-parse',parent+'^').stdout.strip()
        git(repo,'update-ref','refs/remotes/origin/'+BRANCH,stale)
        later(repo)
        assert git(repo,'cat-file','-e',HEAD+'^{commit}',check=False).returncode != 0
        assert not git(repo,'for-each-ref','--format=%(refname)','--contains='+parent,'refs/remotes').stdout.strip()
        invoke('Missing pipeline head is fetched with stale refs: '+mode,home,repo,'unknown flag: '+STOP)
        git(repo,'cat-file','-e',HEAD+'^{commit}')
        note('Observed: formerly missing real GitHub PR head exists after the preflight.')

    home,repo = setup('absent-direct')
    git(repo,'branch','-m',BRANCH,'local-part-1')
    later(repo)
    local_head = git(repo,'rev-parse','HEAD').stdout.strip()
    invoke('Absent PR branch retains direct-PR unpublished-HEAD refusal',home,repo,'named head '+local_head+' is unreachable outside the worker copy')
    git(repo,'checkout','-q','local-part-1')
    invoke('Absent PR branch accepts direct-PR published HEAD',home,repo,'unknown flag: '+STOP)

    home,repo = setup('absent-no-mistakes','no-mistakes')
    git(repo,'branch','-m',BRANCH,'local-part-1')
    later(repo)
    invoke('Absent PR branch keeps no-mistakes forge-head behavior',home,repo,'unknown flag: '+STOP)
    final = run(['gh','pr','view','6489','--repo','kunchenguid/firstmate','--json','state,headRefOid,mergedAt']).stdout
    (EVIDENCE/'green-pr-final.json').write_text(final)
    state = json.loads(final)
    assert state['state'] == 'OPEN' and state['headRefOid'] == HEAD and state['mergedAt'] is None
    note('Remote PR remains OPEN, unmerged, and at the same head.')
except Exception as error:
    note('DRIVER ERROR: ' + repr(error))
    results.append({'name':'Driver/setup','result':'fail','error':str(error)})
    raise
finally:
    (EVIDENCE/'live-preflight-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(AREA)
    note('Disposable homes and worker repositories removed.')
    log.close()
