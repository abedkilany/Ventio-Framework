"""Complete per-file manifest and ZIP verification; never executes payload code."""
import hashlib,json,pathlib,sys,zipfile
mode,root,delivery,identity=sys.argv[1:]
root=pathlib.Path(root); delivery=pathlib.Path(delivery)
def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()
if mode=='create':
    files=[{'path':p.relative_to(root).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(root.rglob('*')) if p.is_file()]
    (root/'payload-files.json').write_text(json.dumps({'identity':identity,'files':files},indent=2)+'\n')
    entries=sorted(p for p in root.rglob('*') if p.is_file())
    (root/'SHA256SUMS.txt').write_text(''.join(sha(p)+'  '+p.relative_to(root).as_posix()+'\n' for p in entries))
    with zipfile.ZipFile(delivery/(identity+'.zip'),'x',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for p in sorted(root.rglob('*')):
            if p.is_file(): archive.write(p,p.relative_to(root).as_posix())
    (delivery/(identity+'.zip.sha256')).write_text(sha(delivery/(identity+'.zip'))+'  '+identity+'.zip\n')
elif mode!='verify': raise SystemExit('Unknown mode')
archive_path=delivery/(identity+'.zip')
assert sha(archive_path)==(delivery/(identity+'.zip.sha256')).read_text().split()[0]
with zipfile.ZipFile(archive_path) as archive:
    names=archive.namelist(); assert len(names)==len(set(n.casefold() for n in names))
    assert set(names)=={p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
    manifest=dict((n,h) for h,n in (line.split('  ',1) for line in archive.read('SHA256SUMS.txt').decode().splitlines()))
    assert set(manifest)==set(names)-{'SHA256SUMS.txt'}
    for name in names:
        p=pathlib.PurePosixPath(name); assert not p.is_absolute() and '..' not in p.parts and ':' not in name and '\\' not in name
        data=archive.read(name); digest=hashlib.sha256(data).hexdigest()
        assert digest==sha(root/name),name
        if name in manifest: assert digest==manifest[name],name
    inventory=json.loads(archive.read('payload-files.json'))['files']
    assert {r['path'] for r in inventory}==set(names)-{'payload-files.json','SHA256SUMS.txt'}
    for record in inventory:
        assert sha(root/record['path'])==record['sha256']
        assert (root/record['path']).stat().st_size==record['bytes']
report={'identity':identity,'zipSha256':sha(archive_path),'zipBytes':archive_path.stat().st_size,'membersVerified':len(names),'checksumEntriesVerified':len(manifest),'completeInventoryEntriesVerified':len(inventory),'status':'INTEGRITY_VERIFIED','securityClearance':'NOT_ESTABLISHED_BY_HASHES'}
(delivery/'artifact-integrity.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
