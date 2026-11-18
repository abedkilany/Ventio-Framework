"""Hosted data-only evidence export. Never executes a candidate or test case."""
import collections, hashlib, json, os, pathlib, shutil, subprocess, zipfile
if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
    raise SystemExit('Disposable hosted evidence export only')
context_path = pathlib.Path(os.environ['VENTIO_VERIFY_CONTEXT'])
context = json.loads(context_path.read_text())
out = context_path.parent
payload = pathlib.Path(context['payload'])
commit = context['candidateCommit']
tree = subprocess.check_output(['git', 'rev-parse', commit+'^{tree}'], text=True).strip()
entries = subprocess.check_output(['git', 'ls-tree', '-r', '-z', commit]).split(b'\0')
gitfiles = {e.split(b'\t', 1)[1].decode(): e.split(b'\t', 1)[0].split()[2].decode() for e in entries if e}
source = payload/'Evidence'/('source-'+commit+'.zip')
with zipfile.ZipFile(source) as archive:
    names = {n for n in archive.namelist() if not n.endswith('/')}
    assert names == set(gitfiles), 'Source archive/tree paths differ'
    for name in names:
        data = archive.read(name)
        assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest() == gitfiles[name], name
metadata = json.loads((payload/'Evidence/build-metadata.json').read_text(encoding='utf-8-sig'))
assert metadata['commit'] == commit and metadata['sourceTree'] == tree
inventory = json.loads((payload/'payload-files.json').read_text())['files']
signatures = json.loads((payload/'Evidence/executable-signatures.json').read_text(encoding='utf-8-sig'))
pe = {r['path']: r for r in inventory if pathlib.PurePosixPath(r['path']).suffix.lower() in ('.exe', '.dll')}
assert set(pe) == {r['path'] for r in signatures}
for row in signatures:
    assert row['sha256'] == pe[row['path']]['sha256']
for path in [payload/'SHA256SUMS.txt', payload/'payload-files.json', payload/'HostPayload/payload-manifest.json', *sorted((payload/'Evidence').glob('*'))]:
    if path.suffix == '.zip':
        continue
    assert path.is_file() and not (out/path.name).exists(), 'Evidence name collision'
    shutil.copyfile(path, out/path.name)
reports = []
for path in sorted((pathlib.Path(context['root'])/'transport').rglob('*-results.json')):
    data = json.loads(path.read_text(encoding='utf-8-sig'))
    if 'suites' not in data or data.get('runId') != context['candidateRunId']:
        continue
    assert not (out/path.name).exists()
    shutil.copyfile(path, out/path.name)
    reports.append({'path': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
review = dict(context, sourceTree=tree, sourceGitBlobsMatched=len(gitfiles),
    sourceArchiveSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    executableSignatureCounts=dict(collections.Counter(r['status'] for r in signatures)),
    clientFiles=sum(r['path'].startswith('Client/') for r in inventory),
    hostFiles=sum(r['path'].startswith('HostPayload/') for r in inventory),
    selectedPayloadHashes={r['path']: r['sha256'] for r in inventory if r['path'] in ('Client/ventio_native_client.exe', 'Client/data/app.so', 'HostPayload/ventio_host.exe') or r['path'].startswith('Ventio-Setup-')},
    copiedTestReports=reports, evidenceOnly=True, securityClearance='NOT_ESTABLISHED_BY_DATA_EXPORT')
(out/'exported-artifact-review.json').write_text(json.dumps(review, indent=2)+'\n')
print(json.dumps(review, indent=2))
