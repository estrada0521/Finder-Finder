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
    (root / 'beta' / 'metadata.json').write_text('{')
    assert run('context', code=1)['diagnostics']
    # Environment overrides configured settings; absent settings are not created.
    home = pathlib.Path(tmp) / 'home'; home.mkdir()
    env = dict(os.environ, HOME=str(home), FINDER_FINDER_DB_ROOT=str(root))
    result = subprocess.run([str(binary),'--json','context'],env=env,capture_output=True,text=True)
    assert json.loads(result.stdout)['db_root'] == str(root.resolve())
    assert not (home / '.finder-finder').exists()
    assert (root / 'alpha' / 'metadata.json').read_bytes() == before[str(root / 'alpha' / 'metadata.json')]
    assert all((root / id / 'file.txt').read_text() == id for id in ['alpha','beta','gamma'])
print('CLI integration checks passed')
