import json
import unittest

import test_http
from gameshelf_server.service import APIError, tree_signature


class GameMetadataHTTPTests(unittest.TestCase):
    setUp = test_http.HTTPTests.setUp
    call = test_http.HTTPTests.call

    def publish(self):
        root = self.s.add_root(str(self.source), 'Metadata fixture')
        self.s.scan(root['id'])
        self.candidate = self.s.candidates()[0]
        return self.s.publish(self.candidate['id'])

    def test_admin_title_only_preserves_identity_grants_paths_sources_and_private_save(self):
        game = self.publish()
        route = '/api/admin/games/' + game['id'] + '/metadata'
        self.assertEqual(self.call('GET', '/api/catalog', token=self.token)[1], {'games': []})
        before = dict(self.s.db.execute('SELECT * FROM games WHERE id=?', (game['id'],)).fetchone())
        source_signature = tree_signature(self.source)
        status, changed, _ = self.call('POST', route, {'title': '  Official display title　'}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertEqual(changed, dict(game, title='Official display title'))
        after = dict(self.s.db.execute('SELECT * FROM games WHERE id=?', (game['id'],)).fetchone())
        self.assertEqual({k: v for k, v in before.items() if k != 'title'}, {k: v for k, v in after.items() if k != 'title'})
        self.assertEqual(self.s.grants(), [])
        self.assertEqual(self.call('GET', '/api/catalog', token=self.token)[1], {'games': []})
        self.assertNotIn(str(self.source), json.dumps(changed))
        self.assertNotIn(str(self.s.state), json.dumps(changed))
        self.s.grant(self.user['id'], game['id'], True)
        user = self.s.authenticate(self.token)
        lease = self.s.session(user, game['id'], 'fixture-device', token=self.token)
        save = self.s.driver.active[lease['leaseID']] / '.gameshelf-profile' / 'fixture.save'
        save.write_bytes(b'private save bytes')
        grants = self.s.grants()
        status, result, _ = self.call('POST', route, {'title': 'Another title'}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertEqual(result['id'], game['id'])
        self.assertEqual(self.s.grants(), grants)
        self.assertEqual(save.read_bytes(), b'private save bytes')
        self.assertEqual(tree_signature(self.source), source_signature)
        self.assertEqual(self.call('GET', '/api/catalog', token=self.token)[1]['games'][0]['title'], 'Another title')

    def test_auth_exact_fields_utf8_controls_and_unknown_id(self):
        game = self.publish()
        route = '/api/admin/games/' + game['id'] + '/metadata'
        self.assertEqual(self.call('POST', route, {'title': 'blocked'})[0], 401)
        self.assertEqual(self.call('POST', route, {'title': 'blocked'}, self.token)[0], 403)
        self.assertEqual(self.call('POST', '/api/admin/games/' + '0' * 32 + '/metadata', {'title': 'unknown'}, self.owner_token)[0], 404)
        for body in ({}, {'title': ''}, {'title': '　  '}, {'title': None}, {'title': 1}, {'title': ['x']},
                     {'title': 'bad\nname'}, {'title': '\ttrimmed'}, {'title': 'bad\x7fname'}, {'title': 'bad\u202ename'},
                     {'title': 'é' * 513}, {'title': 'x' * 1025}, {'title': 'name', 'path': '/private/escape'},
                     {'title': 'name', 'grants': []}, {'title': 'name', 'entries': []}, []):
            status, reply, _ = self.call('POST', route, body, self.owner_token)
            self.assertEqual(status, 400, repr(body))
            self.assertNotIn(str(self.source), json.dumps(reply))
            self.assertEqual(self.s.db.execute('SELECT title FROM games WHERE id=?', (game['id'],)).fetchone()[0], game['title'])
        exact = '😀' * 256
        self.assertEqual(len(exact.encode()), 1024)
        status, result, _ = self.call('POST', route, {'title': exact}, self.owner_token)
        self.assertEqual(status, 200)
        self.assertEqual(result['title'], exact)
        with self.assertRaises(APIError) as error:
            self.s.game_metadata(self.s.authenticate(self.token), game['id'], {'title': 'direct non-admin'})
        self.assertEqual(error.exception.status, 403)

    def test_republish_unchanged_edition_preserves_canonical_title_but_refreshes_entries(self):
        game = self.publish()
        route = '/api/admin/games/' + game['id'] + '/metadata'
        self.assertEqual(self.call('POST', route, {'title': 'Canonical title'}, self.owner_token)[0], 200)
        self.s.grant(self.user['id'], game['id'], True)
        entries = json.loads(json.dumps(game['entries']))
        entries[0]['engine'] = 'Refined fixture detection'
        self.s.db.execute('UPDATE candidates SET title=?,entries=? WHERE id=?', ('Scan-derived name', json.dumps(entries), self.candidate['id']))
        again = self.s.publish(self.candidate['id'])
        self.assertEqual(again['id'], game['id'])
        self.assertEqual(again['title'], 'Canonical title')
        self.assertEqual(again['entries'], entries)
        self.assertEqual(len(self.s.grants()), 1)
