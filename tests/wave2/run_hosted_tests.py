"""Run prepared cases only in disposable GitHub-hosted CI; retain literal case outcomes."""
from __future__ import annotations
import json, os, pathlib, re, shutil, subprocess, sys, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'test-results/wave2'
MODE = sys.argv[1]
if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
    raise SystemExit('GitHub-hosted disposable CI required; never a lab/workstation runner')
OUT.mkdir(parents=True, exist_ok=True)
CASES = json.loads((ROOT/'docs/wave2/WAVE_2_B_PREPARED_CASES.json').read_text())['cases']
RESULTS = []

def call(args, cwd=ROOT, env=None):
    args=[str(a) for a in args]
    args[0]=shutil.which(args[0]) or args[0]
    return subprocess.check_output(args, cwd=cwd, env=env, text=True, stderr=subprocess.STDOUT).strip()

def suite(letter, args, cwd, env=None, setup=None):
    ids = [c['id'] for c in CASES if c['id'].startswith('W2-'+letter)]
    records = {i: {'id':i, 'status':'UNEXECUTED', 'suite':letter} for i in ids}
    case_names = {}
    log = OUT/f'{MODE}-{letter}.log'
    resource = None
    code = None
    error = None
    try:
        env = dict(os.environ, VENTIO_WAVE2_PREPARED_TESTS='yes', **(env or {}))
        if setup:
            resource = setup(env)
        with log.open('w',encoding='utf-8') as output:
            print('Starting suite '+letter, flush=True)
            command=[str(a) for a in args]
            command[0]=shutil.which(command[0]) or command[0]
            with subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace', bufsize=1) as process:
                for line in process.stdout:
                    output.write(line); output.flush()
                    print(line, end='', flush=True)
                    match=re.search(r'\b(PASS|FAIL) (W2-[A-Z]\d+)\b',line)
                    if match and match[2] in records:
                        records[match[2]]['status']='PASSED' if match[1]=='PASS' else 'FAILED'
                    try: event=json.loads(line)
                    except (ValueError,TypeError): continue
                    if not isinstance(event,dict): continue
                    if event.get('type')=='testStart':
                        test=event['test']; m=re.search(r'\bW2-[A-Z]\d+\b',test.get('name',''))
                        if m: case_names[test['id']]=m[0]
                    if event.get('type')=='testDone' and event.get('testID') in case_names:
                        cid=case_names[event['testID']]
                        if cid in records:
                            records[cid]['status']='UNEXECUTED_SKIPPED' if event.get('skipped') else ('PASSED' if event.get('result')=='success' else 'FAILED')
                code=process.wait()
        if code:
            for record in records.values():
                if record['status']=='UNEXECUTED': record['status']='UNEXECUTED_AFTER_SUITE_FAILURE'
    except Exception as exc:
        error=str(exc)
        # Setup failure is never promoted to an executed case failure or a pass.
        for record in records.values():
            if record['status']=='UNEXECUTED': record.update(status='BLOCKED_PREREQUISITE',reason=error)
        log.write_text((log.read_text() if log.exists() else '')+'\nSETUP/LAUNCH ERROR: '+error+'\n')
        print('Suite '+letter+' blocked: '+error,flush=True)
    finally:
        if callable(resource): resource()
    RESULTS.append({'suite':letter,'command':[str(a) for a in args],'exitCode':code,'setupError':error,'cases':list(records.values())})
    save()

def save():
    data={'commit':call(['git','rev-parse','HEAD']),'runId':os.environ['GITHUB_RUN_ID'],'attempt':os.environ['GITHUB_RUN_ATTEMPT'],'mode':MODE,'suites':RESULTS,
          'expectedUnexecuted':{'P':'BLOCKED_PREREQUISITE: separately provisioned installed Windows VM and normal local approval required'},
          'manualAcceptance':'W2-M001..M006 remain unexecuted; CI does not establish physical two-device or owner acceptance'}
    (OUT/f'{MODE}-results.json').write_text(json.dumps(data,indent=2)+'\n')

def bootstrap(env):
    host=ROOT/'packages/ventio_host_api'
    env.setdefault('VENTIO_MIGRATIONS_DIR','../../migrations/postgres')
    dart = pathlib.Path(env['VENTIO_HOST_DART_BIN'])/'dart.exe' if os.name=='nt' else 'dart'
    call([dart,'--packages=.dart_tool/package_config.json','../ventio_postgres/bin/migrate.dart'],host,env)
    sql=[('bootstrap.sql',['-v','expected_database=ventio_host_test']),('test_logins.sql',[])]
    for name,extra in sql:
        if env.get('VENTIO_TEST_POSTGRES_CONTAINER_ID'):
            cid=env['VENTIO_TEST_POSTGRES_CONTAINER_ID']
            call(['docker','cp',str(ROOT/'security/postgres'),cid+':/tmp/ventio-security']) if name=='bootstrap.sql' else None
            call(['docker','exec',cid,'psql','-X','-U','ventio','-d','ventio_host_test','-v','ON_ERROR_STOP=1',*extra,'-f','/tmp/ventio-security/'+name])
        else:
            call([pathlib.Path(env['VENTIO_TEST_POSTGRES_BIN_DIR'])/'psql.exe','-X','-h','127.0.0.1','-p',env['VENTIO_TEST_POSTGRES_PORT'],'-U','ventio','-d','ventio_host_test','-v','ON_ERROR_STOP=1',*extra,'-f',ROOT/'security/postgres'/name],env=dict(env,PGPASSWORD='ventio_test_only'))

def docker_fixture(env):
    label=os.environ['GITHUB_RUN_ID']+'-'+os.environ['GITHUB_RUN_ATTEMPT']
    cid=call(['docker','run','--pull=never','-d','--label','io.ventio.ci.fixture=postgres-test','--label','io.ventio.ci.run='+label,'-e','POSTGRES_DB=ventio_host_test','-e','POSTGRES_USER=ventio','-e','POSTGRES_PASSWORD=ventio_test_only','-p','127.0.0.1::5432','postgres:16','-c','max_prepared_transactions=20'])
    def cleanup():
        info=json.loads(call(['docker','inspect',cid]))[0]
        labels=info['Config']['Labels']
        if info['Id']!=cid or labels.get('io.ventio.ci.fixture')!='postgres-test' or labels.get('io.ventio.ci.run')!=label: raise RuntimeError('Refusing unrelated container cleanup')
        call(['docker','rm','-f',cid])
    try:
        for _ in range(40):
            ready=subprocess.run(['docker','exec',cid,'pg_isready','-U','ventio','-d','ventio_host_test'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if ready.returncode==0: break
            time.sleep(1)
        else: raise RuntimeError('Fixture PostgreSQL did not become ready')
        mapping=call(['docker','port',cid,'5432/tcp'])
        if not re.fullmatch(r'127\.0\.0\.1:\d+',mapping): raise RuntimeError('Loopback-only fixture mapping required')
        port=mapping.rsplit(':',1)[1]
        env.update(VENTIO_TEST_POSTGRES_CONTAINER_ID=cid,VENTIO_ALLOW_DATABASE_TESTS='yes',VENTIO_ALLOW_POSTGRES_CRASH_TEST='yes',VENTIO_CI_RUN_LABEL=label,VENTIO_MIGRATIONS_DIR='../../migrations/postgres')
        for key,auth in [('VENTIO_TEST_DATABASE_URL','ventio:ventio_test_only'),('VENTIO_TEST_RUNTIME_DATABASE_URL','ventio_runtime_test:runtime_test_only'),('VENTIO_TEST_ADMIN_DATABASE_URL','ventio_admin_test:admin_test_only'),('VENTIO_TEST_API_ADMIN_DATABASE_URL','ventio_user_api_test:user_api_test_only')]:
            env[key]=f'postgresql://{auth}@127.0.0.1:{port}/ventio_host_test?sslmode=disable'
        env['VENTIO_DATABASE_URL']=env['VENTIO_TEST_DATABASE_URL']
        bootstrap(env)
        psql=pathlib.Path('/usr/lib/postgresql/16/bin/psql')
        if psql.is_file(): env['VENTIO_TEST_PSQL']=str(psql)
        (OUT/f'{MODE}-fixture-{len(RESULTS)}.json').write_text(json.dumps({'container':cid,'image':json.loads(call(['docker','image','inspect','postgres:16']))[0]['RepoDigests'],'version':call(['docker','exec',cid,'postgres','--version']),'port':port},indent=2))
        return cleanup
    except Exception:
        cleanup(); raise

host=ROOT/'packages/ventio_host_api'
native=ROOT/'packages/ventio_native_client'
if MODE=='windows':
    suite('C',['dart','--packages=../ventio_native_client/.dart_tool/package_config.json','test/wave2_contracts_test.dart'],ROOT/'packages/ventio_core')
    suite('S',['flutter','test','--no-pub','--machine','test/wave2_workspace_store_test.dart'],native)
    suite('W',['pwsh','-NoLogo','-NoProfile','-File','tests/wave2/windows_integrity_tests.ps1','-PrivateFixtureParent',os.environ['RUNNER_TEMP']],ROOT)
elif MODE=='desktop':
    def desktop_setup(env):
        bootstrap(env)
        env['VENTIO_APP_SUPPORT_DIRECTORY']=str(pathlib.Path(os.environ['RUNNER_TEMP'])/('ventio-wave2-ui-'+os.environ['GITHUB_RUN_ID']))
    suite('G',['flutter','test','--no-pub','--machine','integration_test/wave2_workspace_acceptance_test.dart','-d','windows'],native,setup=desktop_setup)
elif MODE=='linux':
    for letter,name in [('H','gateway'),('J','jobs'),('D','database'),('O','operations'),('U','upgrade')]:
        suite(letter,['dart','--packages=.dart_tool/package_config.json',f'test/wave2_{name}_integration.dart'],host,setup=docker_fixture)
    def audit_setup(env):
        cleanup=docker_fixture(env)
        binary=pathlib.Path('/tmp/ventio-audit-host')
        call(['dart','compile','exe','test/support/audited_local_host.dart','-o',binary],host)
        binary.chmod(0o755)
        assembly=pathlib.Path('/tmp/ventio-audit-assembly')
        (assembly/'packages/ventio_host_api').mkdir(parents=True,exist_ok=True)
        shutil.copytree(ROOT/'spec',assembly/'spec',dirs_exist_ok=True)
        call(['chmod','-R','a+rX,go-w',assembly])
        env.update(VENTIO_AUDIT_HOST_BINARY=str(binary),VENTIO_AUDIT_HOST_WORKDIR=str(assembly/'packages/ventio_host_api'),VENTIO_AUDIT_PRIVILEGE_HELPER='/usr/local/libexec/ventio-ci-drop-to-nobody',VENTIO_AUDIT_RESULTS_FILE=str(OUT/'host-audit-results.json'))
        return cleanup
    suite('R',['dart','--packages=.dart_tool/package_config.json','test/engineering_audit.dart'],host,setup=audit_setup)
elif MODE=='offline':
    suite('E',['flutter','test','--no-pub','--machine','test/wave2_offline_integration.dart'],native,setup=docker_fixture)
elif MODE.startswith('verify-'):
    modes=['windows','desktop'] if MODE=='verify-windows' else ['linux','offline']
    files=[OUT/(m+'-results.json') for m in modes]
    if not all(p.is_file() for p in files): raise SystemExit('Required suite evidence missing')
    runs=[json.loads(p.read_text()) for p in files]
    failed=[s for run in runs for s in run['suites'] if s['exitCode']!=0 or any(c['status']!='PASSED' for c in s['cases'])]
    print(json.dumps({'applicableSuitesNotPassed':[s['suite'] for s in failed]},indent=2))
    raise SystemExit(bool(failed))
else: raise SystemExit('Unknown mode')
save()
raise SystemExit(any(s['exitCode']!=0 or any(c['status']!='PASSED' for c in s['cases']) for s in RESULTS))
