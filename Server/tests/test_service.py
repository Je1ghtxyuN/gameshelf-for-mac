import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

AVAILABLE = importlib.util.find_spec('gameshelf_server.service') is not None

class FakeDriver:
    def __init__(self, state):
        self.state = Path(state)
        self.active = {}
        self.fail_revoke = False
        self.events = []
    def open(self, lease, lower, user, *, save_paths=None):
        view = self.state / 'views' / user['id'] / lease['game_id']
        view.mkdir(parents=True, exist_ok=True)
        (view / '.gameshelf-profile').mkdir(exist_ok=True)
        self.active[lease['id']] = view
        self.events.append(('open', lease['id']))
        return dict(host='localhost', port=445, name='gs'+lease['id'], username='gs'+lease['id'], password='ephemeral-test')
    def close(self, lease):
        self.events.append(('close', lease['id']))
        if self.fail_revoke:
            raise RuntimeError('busy')
        self.active.pop(lease['id'], None)

class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(AVAILABLE, 'service module must exist')
        from gameshelf_server.service import Service, APIError
        self.APIError = APIError
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.source = base/'source'
        self.source.mkdir()
        (self.source/'Novel').mkdir()
        (self.source/'Novel'/'Game.exe').write_bytes(b'MZfixture')
        (self.source/'Novel'/'uninstall.exe').write_bytes(b'MZtool')
        (self.source/'Novel'/'翻译.exe').write_bytes(b'MZfixture')
        self.now = 1000
        self.driver = FakeDriver(base/'state')
        self.s = Service(base/'state', self.driver, [self.source], clock=lambda: self.now, token_ttl=60, lease_ttl=20)
        self.addCleanup(self.s.close)
        self.admin = self.s.create_user('owner', 'correct horse battery staple', admin=True)
        self.a = self.s.create_user('alice', 'alice password long')
        self.b = self.s.create_user('bob', 'bob password long')
        self.root = self.s.add_root(str(self.source), 'Games')
    def publish(self):
        result = self.s.scan(self.root['id'])
        self.assertTrue(result['complete'])
        candidates = self.s.candidates()
        self.assertEqual(len(candidates), 1)
        self.assertEqual(len(candidates[0]['entries']), 2)
        return self.s.publish(candidates[0]['id'])
    def denied(self, fn, code):
        with self.assertRaises(self.APIError) as ctx:
            fn()
        self.assertEqual(ctx.exception.status, code)
    def test_token_hash_expiry_revoke(self):
        login = self.s.login('alice', 'alice password long')
        token = login['token']
        row = self.s.db.execute('select digest from tokens').fetchone()
        self.assertEqual(row[0], hashlib.sha256(token.encode()).hexdigest())
        self.assertEqual(self.s.authenticate(token)['id'], self.a['id'])
        self.s.logout(token)
        self.denied(lambda: self.s.authenticate(token), 401)
        token = self.s.login('alice', 'alice password long')['token']
        self.now += 61
        self.denied(lambda: self.s.authenticate(token), 401)
        self.denied(lambda: self.s.login('alice', 'wrong'), 401)
        self.assertNotIn('alice password long', str(list(self.s.db.execute('select * from users'))))
    def test_scan_selected_publish_grants_and_no_source_paths(self):
        self.s.scan(self.root['id'])
        self.assertEqual(self.s.catalog(self.a)['games'], [])
        game = self.publish()
        self.denied(lambda: self.s.session(self.a, game['id'], 'device'), 403)
        self.s.grant(self.a['id'], game['id'], True)
        catalog = self.s.catalog(self.a)
        self.assertEqual(catalog['games'][0]['id'], game['id'])
        self.assertNotIn(str(self.source), json.dumps(catalog))
        self.assertEqual(self.s.catalog(self.b)['games'], [])
    def test_containment_overlap_and_symlink_rejection(self):
        self.denied(lambda: self.s.add_root(str(self.s.state), 'bad'), 400)
        (self.source/'link').symlink_to(self.source/'Novel', target_is_directory=True)
        self.denied(lambda: self.s.add_root(str(self.source/'link'), 'link'), 400)
        self.denied(lambda: self.s.add_root(str(self.source/'Novel'/'..'), 'dotdot'), 400)
        game = self.publish()
        self.s.grant(self.a['id'], game['id'], True)
        (self.source/'Novel'/'bad').symlink_to('/etc')
        self.denied(lambda: self.s.session(self.a, game['id'], 'device'), 400)
    def test_expired_writer_must_close_before_reassignment(self):
        game = self.publish()
        self.s.grant(self.a['id'], game['id'], True)
        lease = self.s.session(self.a, game['id'], 'one')
        self.denied(lambda: self.s.session(self.a, game['id'], 'two'), 409)
        self.denied(lambda: self.s.heartbeat(self.b, lease['leaseID']), 404)
        self.now += 21
        self.driver.fail_revoke = True
        self.denied(lambda: self.s.session(self.a, game['id'], 'two'), 503)
        self.driver.fail_revoke = False
        new = self.s.session(self.a, game['id'], 'two')
        self.assertNotEqual(lease['leaseID'], new['leaseID'])
        self.assertEqual(self.driver.events[-2:], [('close', lease['leaseID']), ('open', new['leaseID'])])
    def test_grant_revocation_disconnects_and_account_views_private(self):
        game = self.publish()
        for user in (self.a, self.b):
            self.s.grant(user['id'], game['id'], True)
        a = self.s.session(self.a, game['id'], 'a')
        b = self.s.session(self.b, game['id'], 'b')
        va, vb = self.driver.active[a['leaseID']], self.driver.active[b['leaseID']]
        (va/'save').write_text('alice')
        (va/'.gameshelf-profile'/'save').write_text('private')
        self.assertFalse((vb/'save').exists())
        self.assertFalse((self.source/'Novel'/'save').exists())
        self.s.grant(self.a['id'], game['id'], False)
        self.assertNotIn(a['leaseID'], self.driver.active)
        self.assertIn(b['leaseID'], self.driver.active)
        self.denied(lambda: self.s.heartbeat(self.a, a['leaseID']), 404)
    def test_logout_revokes_writers(self):
        game = self.publish()
        self.s.grant(self.a['id'], game['id'], True)
        token = self.s.login('alice', 'alice password long')['token']
        lease = self.s.session(self.a, game['id'], 'a', token=token)
        self.s.logout(token)
        self.assertNotIn(lease['leaseID'], self.driver.active)
    def test_restart_reconciles_active_leases(self):
        game = self.publish()
        self.s.grant(self.a['id'], game['id'], True)
        lease = self.s.session(self.a, game['id'], 'a')
        self.s.recover()
        self.assertNotIn(lease['leaseID'], self.driver.active)
    def test_disabled_account_tokens_and_leases_revoked(self):
        game = self.publish()
        self.s.grant(self.a['id'], game['id'], True)
        token = self.s.login('alice', 'alice password long')['token']
        lease = self.s.session(self.a, game['id'], 'a')
        self.s.disable_user(self.a['id'])
        self.denied(lambda: self.s.authenticate(token), 401)
        self.assertNotIn(lease['leaseID'], self.driver.active)


    def test_source_reserved_profile_rejected(self):
        (self.source/'Novel'/'.gameshelf-profile').mkdir()
        result = self.s.scan(self.root['id'])
        self.assertFalse(result['complete'])
        self.assertEqual(self.s.candidates(), [])
    def test_lease_expiry_starts_after_driver_finishes(self):
        game=self.publish()
        self.s.grant(self.a['id'],game['id'],True)
        original=self.driver.open
        def slow_open(*args, **kw):
            self.now+=30
            return original(*args, **kw)
        self.driver.open=slow_open
        lease=self.s.session(self.a,game['id'],'slow')
        self.assertGreater(lease['expiresAt'],self.now)
    def test_source_offline_scan_keeps_candidates_and_catalog(self):
        game=self.publish()
        self.s.grant(self.a['id'],game['id'],True)
        self.source.rename(self.source.with_name('offline'))
        self.denied(lambda:self.s.scan(self.root['id']),503)
        self.assertEqual(len(self.s.candidates()),1)
        self.assertEqual(self.s.catalog(self.a)['games'][0]['id'],game['id'])
    def test_overlapping_state_rejected_before_creation(self):
        from gameshelf_server.service import Service
        target=self.source/'should-not-exist'
        self.denied(lambda:Service(target,self.driver,[self.source]),400)
        self.assertFalse(target.exists())
    def test_logout_attempts_every_share_even_if_first_is_busy(self):
        first=self.publish()
        (self.source/'Other').mkdir()
        (self.source/'Other'/'Play.exe').write_bytes(b'MZother')
        self.s.scan(self.root['id'])
        second=self.s.publish(next(c['id'] for c in self.s.candidates() if c['title']=='Other'))
        token=self.s.login('alice','alice password long')['token']
        for g in (first,second):
            self.s.grant(self.a['id'],g['id'],True)
            self.s.session(self.a,g['id'],'a',token=token)
        self.driver.fail_revoke=True
        self.denied(lambda:self.s.logout(token),503)
        self.assertEqual(len([e for e in self.driver.events if e[0]=='close']),2)

    def test_internal_chained_links_and_renpy_app_are_publishable(self):
        app=self.source/'Novel'/'Novel.app'
        (app/'Contents'/'Resources'/'autorun'/'renpy').mkdir(parents=True)
        (app/'Contents'/'Frameworks'/'Python.framework'/'Versions'/'3.12').mkdir(parents=True)
        (app/'Contents'/'Frameworks'/'Python.framework'/'Versions'/'Current').symlink_to('3.12')
        (self.source/'Novel'/'alias.exe').symlink_to('Game.exe')
        (self.source/'Novel'/'chain').symlink_to('alias.exe')
        (self.source/'Novel'/'absolute').symlink_to(self.source/'Novel'/'Game.exe')
        self.assertTrue(self.s.scan(self.root['id'])['complete'])
        candidate=self.s.candidates()[0]
        self.assertIn(dict(path='Novel.app',backend='native',engine='renpy'),candidate['entries'])
        game=self.s.publish(candidate['id'])
        self.s.grant(self.a['id'],game['id'],True)
        self.assertIn('share',self.s.session(self.a,game['id'],'mac'))
    def test_broken_loop_and_special_link_rejected(self):
        from gameshelf_server.service import tree_signature
        for name,target in [('broken','absent'),('loop','loop')]:
            link=self.source/'Novel'/name
            link.symlink_to(target)
            self.denied(lambda:tree_signature(self.source/'Novel'),400)
            link.unlink()
        import os
        fifo=self.source/'Novel'/'fifo'
        os.mkfifo(fifo)
        self.denied(lambda:tree_signature(self.source/'Novel'),400)
    def test_save_rules_detected_persisted_and_explicit_config_new_edition(self):
        novel=self.source/'Novel'
        (novel/'Save01.rvdata2').write_text('OWNER PROGRESS')
        (novel/'Actors.rvdata2').write_text('asset')
        (novel/'data.json').write_text('asset')
        (novel/'custom.dat').write_text('OWNER CUSTOM')
        (novel/'game'/'saves').mkdir(parents=True)
        (novel/'game'/'saves'/'persistent').write_text('OWNER RENPY')
        self.s.scan(self.root['id'])
        c=self.s.candidates()[0]
        self.assertIn(dict(path='Save01.rvdata2',kind='file'),c['detectedSavePaths'])
        self.assertIn(dict(path='game/saves',kind='directory'),c['detectedSavePaths'])
        self.assertNotIn('Actors.rvdata2',str(c['detectedSavePaths']))
        game=self.s.publish(c['id'],save_paths=[dict(path='custom.dat',kind='file')])
        self.assertIn(dict(path='custom.dat',kind='file'),game['savePaths'])
        self.assertEqual(len(game['savePaths']),3)
        default=self.s.publish(c['id'])
        self.assertNotEqual(game['id'],default['id'])
        self.denied(lambda:self.s.publish(c['id'],save_paths=[dict(path='../escape',kind='file')]),400)
        self.denied(lambda:self.s.publish(c['id'],save_paths=[dict(path='.gameshelf-profile',kind='directory')]),400)
    def test_logout_only_current_token_and_its_leases(self):
        game=self.publish()
        self.s.grant(self.a['id'],game['id'],True)
        client=self.s.login('alice','alice password long')['token']
        browser=self.s.login('alice','alice password long')['token']
        lease=self.s.session(self.a,game['id'],'mac',token=client)
        self.s.logout(browser)
        self.denied(lambda:self.s.authenticate(browser),401)
        self.assertEqual(self.s.authenticate(client)['id'],self.a['id'])
        self.assertIn(lease['leaseID'],self.driver.active)
        self.s.heartbeat(self.a,lease['leaseID'])
        self.s.logout(client)
        self.assertNotIn(lease['leaseID'],self.driver.active)
    def test_mz_filter_exact_helpers_chinese_order_and_platform_grouping(self):
        novel=self.source/'Novel'
        for name in ('custom.exe','helper.exe','CustomAdventure.exe','ConfigurationStory.exe','Game_CN.exe'):
            (novel/name).write_bytes(b'MZprogram')
        (novel/'not-game.exe').write_text('not an executable')
        (novel/'Mac.app'/'Contents').mkdir(parents=True)
        for platform in ('Windows','Mac'):
            sub=novel/platform; sub.mkdir()
            (sub/'Play.exe').write_bytes(b'MZprogram')
        self.assertTrue(self.s.scan(self.root['id'])['complete'])
        candidates=self.s.candidates()
        parent=next(c for c in candidates if c['relative']=='Novel')
        names=[e['path'] for e in parent['entries']]
        self.assertEqual(names[0],'Game_CN.exe')
        self.assertIn('CustomAdventure.exe',names)
        self.assertIn('ConfigurationStory.exe',names)
        self.assertIn('Mac.app',names)
        for unwanted in ('custom.exe','helper.exe','not-game.exe'):
            self.assertNotIn(unwanted,names)
        self.assertEqual({c['relative'] for c in candidates},{'Novel','Novel/Windows','Novel/Mac'})
    def test_data_category_walked_but_game_resource_executables_pruned(self):
        category=self.source/'Data'/'Another'; category.mkdir(parents=True)
        (category/'Play.exe').write_bytes(b'MZprogram')
        nested=self.source/'Novel'/'data'; nested.mkdir()
        (nested/'resource.exe').write_bytes(b'MZtool')
        self.s.scan(self.root['id'])
        self.assertEqual({c['relative'] for c in self.s.candidates()},{'Novel','Data/Another'})
    def test_long_scan_does_not_block_active_lease_heartbeat(self):
        from concurrent.futures import ThreadPoolExecutor, TimeoutError
        import threading
        from unittest.mock import patch
        import os
        game=self.publish(); self.s.grant(self.a['id'],game['id'],True)
        lease=self.s.session(self.a,game['id'],'mac')
        entered=threading.Event(); unblock=threading.Event(); actual=os.walk
        def slow_walk(root,*args,**kw):
            if Path(root)==self.source:
                entered.set(); unblock.wait(4)
            yield from actual(root,*args,**kw)
        with ThreadPoolExecutor(max_workers=2) as pool, patch('gameshelf_server.service.os.walk',slow_walk):
            scan=pool.submit(self.s.scan,self.root['id'])
            try:
                self.assertTrue(entered.wait(1))
                beat=pool.submit(self.s.heartbeat,self.a,lease['leaseID'])
                try:
                    response=beat.result(timeout=0.4)
                except TimeoutError:
                    self.fail('Filesystem scan blocked a live lease heartbeat')
                self.assertEqual(response['leaseID'],lease['leaseID'])
            finally:
                unblock.set()
                scan.result(timeout=4)
    def test_scan_reauthorizes_before_any_candidate_commit(self):
        calls=[]
        def authorize():
            calls.append(1)
            if len(calls)>1:
                raise self.APIError(401,'revoked during scan')
        self.denied(lambda:self.s.scan(self.root['id'],authorize=authorize),401)
        self.assertEqual(self.s.candidates(),[])
    def test_root_changed_during_scan_does_not_commit(self):
        import os
        from unittest.mock import patch
        actual=os.walk
        def changed(root,*args,**kw):
            yield from actual(root,*args,**kw)
            if Path(root)==self.source:
                (self.source/'new-root-entry').mkdir()
        with patch('gameshelf_server.service.os.walk',changed):
            self.denied(lambda:self.s.scan(self.root['id']),409)
        self.assertEqual(self.s.candidates(),[])
    def test_slow_workspace_provisioning_does_not_block_other_heartbeats(self):
        from concurrent.futures import ThreadPoolExecutor
        import threading
        game=self.publish()
        for u in (self.a,self.b): self.s.grant(u['id'],game['id'],True)
        active=self.s.session(self.a,game['id'],'one')
        entered=threading.Event(); unblock=threading.Event(); original=self.driver.open
        def slow(*args,**kw):
            entered.set(); unblock.wait(4)
            return original(*args,**kw)
        self.driver.open=slow
        with ThreadPoolExecutor(max_workers=2) as pool:
            provisioning=pool.submit(self.s.session,self.b,game['id'],'two')
            try:
                self.assertTrue(entered.wait(1))
                heartbeat=pool.submit(self.s.heartbeat,self.a,active['leaseID'])
                self.assertEqual(heartbeat.result(timeout=0.4)['leaseID'],active['leaseID'])
            finally:
                unblock.set(); provisioning.result(timeout=4)
    def test_platform_leaf_title_uses_parent_without_merging_editions(self):
        title_root=self.source/'Named Game'; title_root.mkdir()
        for platform in ('Windows','win','win32','win64','pc','Mac','macOS','osx','Linux'):
            leaf=title_root/platform; leaf.mkdir()
            (leaf/'Play.exe').write_bytes(b'MZfixture')
        self.s.scan(self.root['id'])
        editions=[c for c in self.s.candidates() if c['relative'].startswith('Named Game/')]
        ids={c['relative']:c['id'] for c in editions}
        self.assertEqual(len(ids),9)
        for candidate in editions:
            expected='Linux' if candidate['relative'].endswith('/Linux') else 'Named Game'
            self.assertEqual(candidate['title'],expected)
            self.assertEqual(self.s.publish(candidate['id'])['title'],expected)
        self.s.scan(self.root['id'])
        self.assertEqual(ids,{c['relative']:c['id'] for c in self.s.candidates() if c['relative'].startswith('Named Game/')})
if __name__ == '__main__':
    unittest.main()
