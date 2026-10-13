#!/usr/bin/env python3
"""End-to-end CLI checks against an isolated, domain-neutral database."""
import json, os, pathlib, subprocess, sys, tempfile
binary = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp) / 'db'; root.mkdir()
    def record(id, category, links):
        d = root / id; d.mkdir()
        (d / 'metadata.json').write_text(json.dumps({'category': category, 'display_name': id, 'payload': 'file.txt', 'custom': {'keep': True}, 'links': links}))
        (d / 'file.txt').write_text(id)
    record('alpha', 'arbitrary-a', [{'id': 'beta', 'role': 'component', 'extra': 42}])
    record('beta', 'arbitrary-b', [{'id': 'gamma'}])
    record('gamma', 'arbitrary-a', [{'id': 'alpha'}])
    before = {str(p): p.read_bytes() for p in root.rglob('*') if p.is_file()}
    def run(*args, code=0, env=None):
        result = subprocess.run([str(binary), '--json', '--db-root', str(root), *args], capture_output=True, text=True, env=env)
        assert result.returncode == code, (args, result.returncode, result.stderr)
        return json.loads(result.stdout)
    assert run('context')['result']['record_count'] == 3
    assert run('list', '--category', 'arbitrary-b')['result']['total'] == 1
    assert run('list', '--query', 'ALPHA', '--limit', '0')['result']['records'] == []
    assert run('show', str(root / 'alpha' / 'metadata.json'))['result']['record']['metadata']['custom']['keep']
    r = run('links', 'alpha')['result']
    assert [n['id'] for n in r['records']] == ['beta']
    assert r['edges'][0]['link']['extra'] == 42
    assert [n['id'] for n in run('links', 'alpha', '--direction', 'in')['result']['records']] == ['gamma']
    assert len(run('links', 'alpha', '--depth', '99')['result']['records']) == 2
    assert run('links', 'alpha', '--depth', '0')['result']['records'] == []
    assert len(run('links', 'alpha', 'gamma', '--direction', 'both')['result']['records']) == 1
    assert {str(p): p.read_bytes() for p in root.rglob('*') if p.is_file()} == before
    # Category return is cut on a chain, while unrestricted links follows it.
    (root / 'gamma' / 'metadata.json').write_text(json.dumps({'category':'arbitrary-a','links':[]}))
    assert [n['id'] for n in run('related', 'alpha')['result']['records']] == ['beta']
    assert len(run('links', 'alpha', '--depth', '3')['result']['records']) == 2
    run('show', 'missing', code=1)
    run('related', 'alpha', '--depth', '3', code=2)
    run('links', 'alpha', '--direction', 'invalid', code=2)
    record('broken-target', 'unknown', [{'id':'absent'}])
    r = run('links', 'broken-target', code=1)
    assert r['result']['records'][0]['record'] is None and r['diagnostics']
    # An unrelated broken edge is visible without failing valid queries.
    clean = run('show', 'alpha')
    assert clean['schema_version'] == 2 and not clean['diagnostics']
    assert clean['database_diagnostics']
    assert not run('links', 'alpha')['diagnostics']
    brief = run('related', 'alpha', '--summary')['result']
    assert 'metadata' not in brief['records'][0]['record']
    assert brief['records'][0]['record']['paths']['payload'][0]['exists']
    assert run('links', 'alpha', '--summary')['result']['edges'][0]['link']['extra'] == 42
    # Search only the documented fields; custom scientific metadata stays opaque.
    meta = json.loads((root / 'alpha' / 'metadata.json').read_text())
    meta['preview'] = 'unique-preview.png'
    meta['conditions'] = {'temperature': 'unsupported-search-token'}
    (root / 'alpha' / 'metadata.json').write_text(json.dumps(meta))
    assert run('list', '--query', 'unique-preview')['result']['total'] == 1
    assert run('list', '--query', 'arbitrary-b')['result']['total'] == 1
    assert run('list', '--query', 'unsupported-search-token')['result']['total'] == 0
    assert run('show', 'alpha')['result']['record']['metadata']['conditions'] == meta['conditions']
    run('show', 'alpha', '--summary', code=2)
    (root / 'alpha' / 'metadata.json').write_bytes(before[str(root / 'alpha' / 'metadata.json')])
    (root / 'beta' / 'metadata.json').write_text('{')
    assert run('context', code=1)['diagnostics']
    assert run('links', 'alpha', '--direction', 'in', code=1)['diagnostics']
    # Environment overrides configured settings; absent settings are not created.
    home = pathlib.Path(tmp) / 'home'; home.mkdir()
    env = dict(os.environ, HOME=str(home), FINDER_FINDER_DB_ROOT=str(root))
    result = subprocess.run([str(binary),'--json','context'],env=env,capture_output=True,text=True)
    assert json.loads(result.stdout)['db_root'] == str(root.resolve())
    assert not (home / '.finder-finder').exists()
    assert (root / 'alpha' / 'metadata.json').read_bytes() == before[str(root / 'alpha' / 'metadata.json')]
    assert all((root / id / 'file.txt').read_text() == id for id in ['alpha','beta','gamma'])
print('CLI integration checks passed')
