"""Default republication must not drop an edition's private-save boundary."""
import json
import unittest
import test_http


class RepublishRulesTests(unittest.TestCase):
    setUp = test_http.HTTPTests.setUp
    call = test_http.HTTPTests.call

    def prepare(self):
        self.seed = self.source / 'Example' / 'private_progress.bin'
        self.seed.write_bytes(b'owner seed must stay excluded')
        (self.seed.parent / 'other_progress.bin').write_bytes(b'other seed')
        self.root = self.s.add_root(str(self.source), 'Fixture')
        self.s.scan(self.root['id'])
        self.candidate = self.s.candidates()[0]
        self.route = '/api/admin/candidates/' + self.candidate['id'] + '/publish'
        self.rule = {'path': 'private_progress.bin', 'kind': 'file'}
        status, game, _ = self.call('POST', self.route, {'savePaths': [self.rule]}, self.owner_token)
        self.assertEqual(status, 200)
        return game

    def test_empty_and_omitted_republish_retain_rules_id_grants_and_private_workspace(self):
        game = self.prepare()
        self.s.grant(self.user['id'], game['id'], True)
        user = self.s.authenticate(self.token)
        lease = self.s.session(user, game['id'], 'fixture', token=self.token)
        view = self.s.driver.active[lease['leaseID']]
        save = view / '.gameshelf-profile' / 'account.save'
        save.write_bytes(b'account private progress')
        grants = self.s.grants()
        # Follow the new selected-scan HTTP handoff before re-sharing.
        status, selected, _ = self.call('POST', '/api/admin/roots/' + self.root['id'] + '/candidates',
            {'games': [{'relative': 'Example', 'entryPath': 'Play.exe'}]}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertEqual(selected['candidates'][0]['id'], self.candidate['id'])
        for body in ({'savePaths': []}, {}):
            status, again, _ = self.call('POST', self.route, body, self.owner_token)
            self.assertEqual(status, 200)
            self.assertEqual(again['id'], game['id'])
            self.assertEqual(again['savePaths'], game['savePaths'])
            self.assertEqual(self.s.grants(), grants)
            self.assertEqual(save.read_bytes(), b'account private progress')
        self.s.release(user, lease['leaseID'])
        received = []
        original = self.s.driver.open
        def capture(lease, lower, user, *, save_paths=None):
            received.append(save_paths)
            return original(lease, lower, user, save_paths=save_paths)
        self.s.driver.open = capture
        reopened = self.s.session(user, game['id'], 'fixture', token=self.token)
        self.assertIn(self.rule, received[0])
        self.assertEqual(self.s.driver.active[reopened['leaseID']], view)
        self.assertEqual(save.read_bytes(), b'account private progress')
        self.assertEqual(self.seed.read_bytes(), b'owner seed must stay excluded')
        self.assertEqual(self.s.db.execute('SELECT COUNT(*) FROM games').fetchone()[0], 1)

    def test_nonempty_explicit_rules_keep_original_new_edition_semantics(self):
        first = self.prepare()
        rule = {'path': 'other_progress.bin', 'kind': 'file'}
        status, second, _ = self.call('POST', self.route, {'savePaths': [rule]}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertNotEqual(second['id'], first['id'])
        self.assertIn(rule, second['savePaths'])
        self.assertNotIn(self.rule, second['savePaths'])
        status, repeated, _ = self.call('POST', self.route, {'savePaths': [rule]}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertEqual(repeated['id'], second['id'])

    def test_ambiguous_previous_rule_editions_fail_closed_without_creating_or_granting(self):
        self.prepare()
        self.call('POST', self.route, {'savePaths': [{'path': 'other_progress.bin', 'kind': 'file'}]}, self.owner_token)
        before = [tuple(r) for r in self.s.db.execute('SELECT * FROM games ORDER BY id')]
        for body in ({'savePaths': []}, {}):
            self.assertEqual(self.call('POST', self.route, body, self.owner_token)[0], 409)
        self.assertEqual([tuple(r) for r in self.s.db.execute('SELECT * FROM games ORDER BY id')], before)
        self.assertEqual(self.s.grants(), [])

    def test_new_detected_exclusions_require_review_without_weakening_retained_boundary(self):
        game = self.prepare()
        detected = {'path': 'other_progress.bin', 'kind': 'file'}
        self.s.db.execute('UPDATE candidates SET save_paths=? WHERE id=?',
                          (json.dumps([detected]), self.candidate['id']))
        status, _, _ = self.call('POST', self.route, {'savePaths': []}, self.owner_token)
        self.assertEqual(status, 409)
        stored = self.s.db.execute('SELECT * FROM games WHERE id=?', (game['id'],)).fetchone()
        self.assertEqual(json.loads(stored['save_paths']), game['savePaths'])
        self.assertEqual(self.s.db.execute('SELECT COUNT(*) FROM games').fetchone()[0], 1)
        status, reviewed, _ = self.call('POST', self.route, {'savePaths': [self.rule]}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertIn(self.rule, reviewed['savePaths'])
        self.assertIn(detected, reviewed['savePaths'])

    def test_changed_source_signature_is_a_new_edition(self):
        first = self.prepare()
        (self.seed.parent / 'Play.exe').write_bytes(b'MZ changed fixture edition')
        self.s.scan(self.root['id'])
        status, second, _ = self.call('POST', self.route, {'savePaths': []}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertNotEqual(first['id'], second['id'])
