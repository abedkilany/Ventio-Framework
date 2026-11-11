"""Check that the reviewed SQL profile exactly matches migration sources."""
import hashlib
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sources = {
    p.name: hashlib.sha256(
        p.read_bytes().replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    ).hexdigest()
    for p in (root / 'migrations/postgres').glob('*.sql')
}
profile = (root / 'security/postgres/schema_profile.sql').read_text()
reviewed_profile = profile.split('    legacy(name,sha256) AS (VALUES', 1)[0]
entries = re.findall(r"\('([^']+)','([a-f0-9]{64})'\)", reviewed_profile)
if len(entries) != len(sources) or dict(entries) != sources:
    raise SystemExit('Schema profile differs from reviewed migration sources')
print('Schema profile matches all migration sources')
