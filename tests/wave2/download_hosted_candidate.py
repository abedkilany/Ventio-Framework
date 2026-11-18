"""Fetch a new hosted candidate as data; verify GitHub digest and every package member."""
import hashlib,json,os,pathlib,re,shutil,sys,urllib.parse,urllib.request,zipfile
if os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('RUNNER_ENVIRONMENT')!='github-hosted' or os.name!='nt':
    raise SystemExit('Disposable hosted Windows verification only')
runid=sys.argv[1]
assert re.fullmatch(r'\d+',runid)
repo=os.environ['GITHUB_REPOSITORY']; assert repo=='abedkilany/Ventio-Framework'
base='https://api.github.com/repos/'+repo+'/'
class Redirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        result=super().redirect_request(req,fp,code,msg,headers,newurl)
        if result is not None and urllib.parse.urlparse(newurl).netloc!='api.github.com': result.remove_header('Authorization')
        return result
opener=urllib.request.build_opener(Redirect())
def request(path):
    return urllib.request.Request(base+path,headers={'Authorization':'Bearer '+os.environ['GITHUB_TOKEN'],'Accept':'application/vnd.github+json','User-Agent':'Ventio-protected-verification'})
def api(path):
    with opener.open(request(path),timeout=45) as response:return json.load(response)
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
run=api('actions/runs/'+runid)
assert run['head_branch']=='feature/wave-2-a' and run['event']=='workflow_dispatch' and run['status']=='completed'
jobs=api('actions/runs/'+runid+'/jobs?per_page=100')['jobs']
build=next(j for j in jobs if j['name'].endswith('/ windows-candidate'))
assert 'windows-2025' in build['labels']
assert any(s['name']=='Package complete candidate, manifests, source and security evidence' and s['conclusion']=='success' for s in build['steps'])
artifacts=api('actions/runs/'+runid+'/artifacts?per_page=100')['artifacts']
selected=[a for a in artifacts if a['name'].startswith('wave2-hosted-windows-'+run['head_sha']+'-')]
assert len(selected)==1
artifact=selected[0]
root=pathlib.Path('C:/VentioWave2Verify-'+os.environ['GITHUB_RUN_ID']+'-'+os.environ['GITHUB_RUN_ATTEMPT'])
root.mkdir(exist_ok=False)
outer=root/'github-artifact.zip'
with opener.open(request(f"actions/artifacts/{artifact['id']}/zip"),timeout=90) as response,outer.open('xb') as target:shutil.copyfileobj(response,target,1024*1024)
assert artifact['digest']=='sha256:'+sha(outer)
def extract(archive,target):
    with zipfile.ZipFile(archive) as zipped:
        names=zipped.namelist(); assert len(names)==len(set(n.casefold() for n in names))
        for item in zipped.infolist():
            name=pathlib.PurePosixPath(item.filename)
            assert not name.is_absolute() and '..' not in name.parts and ':' not in item.filename and '\\' not in item.filename
            assert ((item.external_attr>>16)&0o170000)!=0o120000
            if item.is_dir():continue
            path=target.joinpath(*name.parts); path.parent.mkdir(exist_ok=True,parents=True)
            with zipped.open(item) as source,path.open('xb') as dest:shutil.copyfileobj(source,dest)
extract(outer,root/'transport')
inner=list((root/'transport').rglob('Ventio-W2B-*.zip')); assert len(inner)==1
inner=inner[0]; sidecar=inner.with_suffix('.zip.sha256')
assert sha(inner)==sidecar.read_text().split()[0]
extract(inner,root/'Payload')
identity=inner.stem
manifest={n:h for h,n in (line.split('  ',1) for line in (root/'Payload/SHA256SUMS.txt').read_text().splitlines())}
actual={p.relative_to(root/'Payload').as_posix():p for p in (root/'Payload').rglob('*') if p.is_file()}
assert set(actual)==set(manifest)|{'SHA256SUMS.txt'}
for name,digest in manifest.items():assert sha(actual[name])==digest,name
metadata=json.loads((root/'Payload/Evidence/build-metadata.json').read_text(encoding='utf-8-sig'))
assert metadata['commit']==run['head_sha'] and metadata['runId']==runid and metadata['runnerEnvironment']=='github-hosted'
context={'candidateRunId':runid,'candidateCommit':run['head_sha'],'artifactId':artifact['id'],'githubArtifactSha256':sha(outer),'zipSha256':sha(inner),'membersVerified':len(actual),'identity':identity,'root':str(root),'zip':str(inner),'payload':str(root/'Payload'),'verificationCommit':os.environ['GITHUB_SHA']}
out=pathlib.Path(os.environ['RUNNER_TEMP'])/'wave2-protected-evidence';out.mkdir()
(out/'verified-candidate-input.json').write_text(json.dumps(context,indent=2))
with open(os.environ['GITHUB_ENV'],'a',encoding='utf-8') as env:env.write('VENTIO_VERIFY_CONTEXT='+str(out/'verified-candidate-input.json')+'\n')
print(json.dumps(context,indent=2))
