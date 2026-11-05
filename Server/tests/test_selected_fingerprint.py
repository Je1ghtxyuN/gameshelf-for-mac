"""Selected-entry proof gates registration; fixtures never touch real source data."""
import hashlib
import json
import os
from unittest.mock import patch
from pathlib import Path
import tempfile
import unittest

from gameshelf_server.common import APIError
from gameshelf_server.http_api import Application
from gameshelf_server.service import Service
from test_service import FakeDriver


class SelectedFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.source = self.base / 'source'
        self.source.mkdir()
        self.game = self.source / 'Example'
        self.game.mkdir()
        self.entry = self.game / 'Play.exe'
        self.entry.write_bytes(b'MZselected fixture')
        self.s = Service(self.base / 'state', FakeDriver(self.base / 'state'), [self.source])
        self.addCleanup(self.s.close)
        self.s.create_user('owner', 'owner fixture password', True)
        self.s.create_user('reader', 'reader fixture password')
        self.token = self.s.login('owner', 'owner fixture password')['token']
        self.reader = self.s.login('reader', 'reader fixture password')['token']
        self.app = Application(self.s)
        self.root = self.s.add_root(str(self.source), 'Game')
        self.route = '/api/admin/roots/' + self.root['id'] + '/candidates'

    def sha(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def row(self, digest=None, relative='Example', entry='Play.exe'):
        row = dict(relative=relative, entryPath=entry)
        if digest is not None:
            row['entrySHA256'] = digest
        return row

    def register(self, rows, token=None):
        try:
            return 200, self.app.dispatch('POST', self.route, dict(games=rows), token or self.token)
        except APIError as e:
            return e.status, {}

    def test_changed_same_named_executable_is_conflict_before_any_registration(self):
        before = self.entry.read_bytes()
        self.assertEqual(self.register([self.row('0' * 64)])[0], 412)
        self.assertEqual(self.s.candidates(), [])
        self.assertEqual(self.entry.read_bytes(), before)

    def test_matching_digest_registers_without_publish_and_legacy_remains_supported(self):
        status, result = self.register([self.row(self.sha(self.entry))])
        self.assertEqual(status, 200)
        self.assertTrue(result['entryFingerprintsVerified'])
        candidate = result['candidates'][0]
        self.assertEqual(candidate['relative'], 'Example')
        self.assertEqual(candidate['root_id'], self.root['id'])
        status, legacy = self.register([self.row()])
        self.assertEqual(status, 200)
        self.assertFalse(legacy['entryFingerprintsVerified'])
        self.assertEqual(len(self.s.candidates()), 1)
        self.assertEqual(self.s.db.execute('SELECT COUNT(*) FROM games').fetchone()[0], 0)
        self.assertEqual(self.s.grants(), [])

    def test_mismatch_rolls_back_whole_batch_and_preserves_old_candidate(self):
        self.assertEqual(self.register([self.row()])[0], 200)
        before = [tuple(r) for r in self.s.db.execute('SELECT * FROM candidates')]
        other = self.source / 'Other'
        other.mkdir()
        (other / 'Game.exe').write_bytes(b'MZother')
        rows = [self.row(self.sha(self.entry)), self.row('0' * 64, 'Other', 'Game.exe')]
        self.assertEqual(self.register(rows)[0], 412)
        self.assertEqual([tuple(r) for r in self.s.db.execute('SELECT * FROM candidates')], before)

    def test_digest_is_strict_lower_hex_and_cannot_bypass_admin_or_path_rules(self):
        for value in [None, '', 'f' * 63, 'G' * 64, 'A' * 64, 7, True, {}, '0' * 64 + ' ']:
            row = self.row()
            row['entrySHA256'] = value
            self.assertEqual(self.register([row])[0], 400, repr(value))
        self.assertEqual(self.register([self.row(self.sha(self.entry))], self.reader)[0], 403)
        self.assertEqual(self.register([self.row('0' * 64, '../outside')])[0], 400)
        self.assertEqual(self.s.candidates(), [])

    def native(self):
        app = self.source / 'Agent17.app'
        (app / 'Contents/Resources/autorun/renpy').mkdir(parents=True)
        info = app / 'Contents/Info.plist'
        info.write_bytes(b'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Launcher</string></dict></plist>')
        return app, info

    def test_native_bundle_selected_as_directory_and_dot_hashes_info_plist(self):
        app, info = self.native()
        for relative, entry in [('.', 'Agent17.app'), ('Agent17.app', '.')]:
            status, result = self.register([self.row(self.sha(info), relative, entry)])
            self.assertEqual(status, 200)
            self.assertTrue(result['entryFingerprintsVerified'])
            selected = next(e for e in result['candidates'][0]['entries'] if e['path'] == entry)
            self.assertEqual(selected['backend'], 'native')
        self.assertEqual(self.register([self.row('0' * 64, '.', 'Agent17.app')])[0], 412)

    def test_native_plist_limit_and_links_are_rejected_without_reading_target(self):
        app, info = self.native()
        with info.open('r+b') as f:
            f.truncate(1024 * 1024 + 1)
        self.assertEqual(self.register([self.row('0' * 64, '.', 'Agent17.app')])[0], 400)
        info.unlink()
        outside = self.base / 'outside.plist'
        outside.write_bytes(b'outside unchanged')
        info.symlink_to(outside)
        self.assertEqual(self.register([self.row(self.sha(outside), '.', 'Agent17.app')])[0], 400)
        self.assertEqual(outside.read_bytes(), b'outside unchanged')
        self.assertEqual(self.s.candidates(), [])

    def test_entry_size_limit_and_directory_symlink_are_rejected(self):
        with self.entry.open('r+b') as f:
            f.truncate(128 * 1024 * 1024 + 1)
        self.assertEqual(self.register([self.row('0' * 64)])[0], 400)
        self.entry.write_bytes(b'MZselected fixture')
        linked = self.source / 'Linked'
        linked.symlink_to(self.game, target_is_directory=True)
        self.assertEqual(self.register([self.row(self.sha(self.entry), 'Linked')])[0], 400)
        self.assertEqual(self.s.candidates(), [])

    def test_other_backend_hashes_the_selected_file(self):
        web = self.source / 'Web'
        web.mkdir()
        entry = web / 'index.html'
        entry.write_text('<html>fixture</html>')
        self.assertEqual(self.register([self.row(self.sha(entry), 'Web', 'index.html')])[0], 200)
        self.assertEqual(self.register([self.row('0' * 64, 'Web', 'index.html')])[0], 412)

    def test_mixed_legacy_batch_never_acknowledges_every_entry_as_verified(self):
        other = self.source / 'Other'
        other.mkdir()
        (other / 'Game.exe').write_bytes(b'MZother')
        status, result = self.register([self.row(self.sha(self.entry)), self.row(relative='Other', entry='Game.exe')])
        self.assertEqual(status, 200)
        self.assertFalse(result['entryFingerprintsVerified'])

    def test_internal_native_info_symlink_and_ancestor_symlink_are_rejected(self):
        app, info = self.native()
        payload = info.read_bytes()
        info.unlink()
        real = app / 'Info-real.plist'
        real.write_bytes(payload)
        info.symlink_to(real)
        self.assertEqual(self.register([self.row(self.sha(real), '.', 'Agent17.app')])[0], 400)
        info.unlink()
        contents = app / 'Contents'
        contents.rename(app / 'OriginalContents')
        (app / 'OriginalContents/Info.plist').write_bytes(payload)
        contents.symlink_to(app / 'OriginalContents', target_is_directory=True)
        self.assertEqual(self.register([self.row(self.sha(real), '.', 'Agent17.app')])[0], 400)
        self.assertEqual(self.s.candidates(), [])

    def test_executable_inside_app_is_hashed_as_selected_file(self):
        app, info = self.native()
        directory = app / 'Contents/MacOS'
        directory.mkdir()
        executable = directory / 'Run.exe'
        executable.write_bytes(b'MZnested fixture')
        self.assertEqual(self.register([self.row(self.sha(executable), 'Agent17.app/Contents/MacOS', 'Run.exe')])[0], 200)
        self.assertEqual(self.register([self.row(self.sha(info), 'Agent17.app/Contents/MacOS', 'Run.exe')])[0], 412)

    def test_replaced_entry_while_hashing_fails_without_registration(self):
        import gameshelf_server.workflow as workflow
        original = workflow.hashlib.sha256
        replaced = False
        fixture = self.entry
        class ReplacingDigest:
            def __init__(self, data=b''):
                self.inner = original(data)
            def update(self, data):
                nonlocal replaced
                self.inner.update(data)
                if not replaced:
                    replaced = True
                    replacement = fixture.with_suffix('.replacement')
                    replacement.write_bytes(b'MZdifferent bytes')
                    os.replace(replacement, fixture)
            def hexdigest(self):
                return self.inner.hexdigest()
        expected = self.sha(self.entry)
        with patch.object(workflow.hashlib, 'sha256', ReplacingDigest):
            self.assertEqual(self.register([self.row(expected)])[0], 412)
        self.assertEqual(self.s.candidates(), [])
