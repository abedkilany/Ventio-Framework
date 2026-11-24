"""Hosted data-only evidence export. Never executes a candidate or test case."""
import collections, hashlib, json, os, pathlib, shutil, subprocess, tempfile, zipfile
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
# Git archive applies Git's checkout representation (including core.autocrlf).
# Require the complete archive to equal a fresh archive of this exact commit;
# do not ignore whitespace or compare different source representations as bytes.
with tempfile.TemporaryDirectory(prefix='ventio-source-proof-', dir=os.environ['RUNNER_TEMP']) as temporary:
    regenerated = pathlib.Path(temporary)/'source.zip'
    subprocess.run(['git', 'archive', '--format=zip', '--output='+str(regenerated), commit], check=True)
    assert regenerated.read_bytes() == source.read_bytes(), 'Source archive differs from independently regenerated Git archive'
raw_blobs_identical = 0
checkout_representation_paths = []
with zipfile.ZipFile(source) as archive:
    names = {n for n in archive.namelist() if not n.endswith('/')}
    assert names == set(gitfiles), 'Source archive/tree paths differ'
    for name in names:
        data = archive.read(name)
        if hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest() == gitfiles[name]:
            raw_blobs_identical += 1
        else:
            checkout_representation_paths.append(name)
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
transport = pathlib.Path(context['root'])/'transport'
# These sidecars are deliberately outside the immutable inner ZIP (a scan/ZIP
# digest cannot be embedded in the same ZIP it describes). Preserve them from
# the already SHA-256-verified outer Actions artifact as well as inner evidence.
for name in ('artifact-integrity.json', 'security-scan-evidence.json',
             'effective-exclusion-checks.json', context['identity']+'.zip.sha256'):
    matches = [p for p in transport.rglob(name) if p.is_file()]
    assert len(matches) == 1, 'Required unique external evidence missing: '+name
    assert not (out/name).exists(), 'External evidence name collision'
    shutil.copyfile(matches[0], out/name)
for path in sorted(transport.rglob('*-results.json')):
    data = json.loads(path.read_text(encoding='utf-8-sig'))
    if 'suites' not in data or data.get('runId') != context['candidateRunId']:
        continue
    assert not (out/path.name).exists()
    shutil.copyfile(path, out/path.name)
    reports.append({'path': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
review = dict(context, sourceTree=tree, sourceEntriesMatchedRegeneratedGitArchive=len(gitfiles),
    sourceArchiveRecreatedExactly=True, rawGitBlobsIdentical=raw_blobs_identical,
    gitVersion=subprocess.check_output(['git', '--version'], text=True).strip(),
    gitAutocrlf=subprocess.check_output(['git', 'config', '--get', 'core.autocrlf'], text=True).strip(),
    gitCheckoutRepresentationPaths=sorted(checkout_representation_paths),
    sourceArchiveSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    executableSignatureCounts=dict(collections.Counter(r['status'] for r in signatures)),
    clientFiles=sum(r['path'].startswith('Client/') for r in inventory),
    hostFiles=sum(r['path'].startswith('HostPayload/') for r in inventory),
    selectedPayloadHashes={r['path']: r['sha256'] for r in inventory if r['path'] in ('Client/ventio_native_client.exe', 'Client/data/app.so', 'HostPayload/ventio_host.exe') or r['path'].startswith('Ventio-Setup-')},
    copiedTestReports=reports, evidenceOnly=True, securityClearance='NOT_ESTABLISHED_BY_DATA_EXPORT')
(out/'exported-artifact-review.json').write_text(json.dumps(review, indent=2)+'\n')
# The verified installer is sufficient for on-device installation. Retain it
# separately so disposable devices need not download the source/tools archive.
# All outer/inner members and archived source were verified above before export.
installers = [r for r in inventory if r['path'].startswith('Ventio-Setup-') and r['path'].endswith('.exe')]
assert len(installers) == 1
installer = installers[0]
assert pathlib.PurePosixPath(installer['path']).name == installer['path']
installer_source = payload/installer['path']
assert hashlib.sha256(installer_source.read_bytes()).hexdigest() == installer['sha256']
installer_out = pathlib.Path(os.environ['RUNNER_TEMP'])/'wave2-reviewed-installer'
installer_out.mkdir(exist_ok=False)
shutil.copyfile(installer_source, installer_out/installer['path'])
installed_files = [
    {'installedPath': r['path'][7:] if r['path'].startswith('Client/') else 'host-payload/'+r['path'][12:],
     'bytes': r['bytes'], 'sha256': r['sha256']}
    for r in inventory if r['path'].startswith(('Client/', 'HostPayload/'))
]
installed_manifest = dict(sourceCommit=commit, identity=context['identity'],
    installerSha256=installer['sha256'], expectedFiles=installed_files)
(installer_out/'installed-files.json').write_text(json.dumps(installed_manifest, indent=2)+'\n')
delivery = dict(candidateRunId=context['candidateRunId'], sourceCommit=commit,
    verificationCommit=context['verificationCommit'], identity=context['identity'],
    githubArtifactSha256=context['githubArtifactSha256'], zipSha256=context['zipSha256'],
    allPackageMembersVerified=context['membersVerified'], sourceArchiveRecreatedExactly=True,
    installer=installer, installedManifestSha256=hashlib.sha256((installer_out/'installed-files.json').read_bytes()).hexdigest(),
    installerExecuted=False, releaseSigning='DEFERRED_OWNER_PREREQUISITE')
(installer_out/'reviewed-installer.json').write_text(json.dumps(delivery, indent=2)+'\n')
shutil.copyfile(installer_out/'reviewed-installer.json', out/'reviewed-installer.json')
print(json.dumps({k:v for k,v in review.items() if k != 'gitCheckoutRepresentationPaths'}, indent=2))
