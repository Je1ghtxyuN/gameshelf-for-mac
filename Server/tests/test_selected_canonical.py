"""Unicode-equivalent selected paths keep actual names and fail closed."""
from pathlib import Path
from types import SimpleNamespace
import os
import sys
import unicodedata
import unittest
from unittest.mock import patch

import test_selected_fingerprint
from gameshelf_server.common import APIError


class SelectedCanonicalTests(unittest.TestCase):
    setUp = test_selected_fingerprint.SelectedFingerprintTests.setUp
    sha = test_selected_fingerprint.SelectedFingerprintTests.sha
    row = test_selected_fingerprint.SelectedFingerprintTests.row
    register = test_selected_fingerprint.SelectedFingerprintTests.register

    def assert_ambiguous(self, rows):
        with self.assertRaises(APIError) as caught:
            self.app.dispatch('POST', self.route, dict(games=rows), self.token)
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(caught.exception.message, 'Ambiguous Unicode path component')

    def fixture(self, form='NFC'):
        parent = self.source / unicodedata.normalize(form, 'Café')
        folder = parent / unicodedata.normalize(form, '神が造った少女')
        folder.mkdir(parents=True)
        entry = folder / unicodedata.normalize(form, 'Lancé.exe')
        entry.write_bytes(b'MZ canonical fixture')
        # Use the names actually enumerated by this filesystem, including on
        # normalization-insensitive macOS; the protocol must retain those bytes.
        parent = next(p for p in self.source.iterdir() if p.name != 'Example')
        folder = next(parent.iterdir())
        entry = next(folder.iterdir())
        return folder, entry

    def selection(self, folder, entry, form):
        return self.row(self.sha(entry), unicodedata.normalize(form, folder.relative_to(self.source).as_posix()),
                        unicodedata.normalize(form, entry.name))

    def test_nfd_request_resolves_nfc_directories_and_entry_to_actual_spelling(self):
        folder, entry = self.fixture('NFC')
        status, value = self.register([self.selection(folder, entry, 'NFD')])
        self.assertEqual(status, 200)
        candidate = value['candidates'][0]
        self.assertEqual(candidate['relative'].encode(), folder.relative_to(self.source).as_posix().encode())
        self.assertEqual(candidate['entries'][0]['path'].encode(), entry.name.encode())
        self.assertTrue(value['entryFingerprintsVerified'])

    def test_nfc_request_resolves_nfd_disk_spelling_and_preserves_session_identity(self):
        folder, entry = self.fixture('NFD')
        first_status, first = self.register([self.selection(folder, entry, 'NFD')])
        self.assertEqual(first_status, 200)
        original = first['candidates'][0]
        game = self.s.publish(original['id'])
        status, again = self.register([self.selection(folder, entry, 'NFC')])
        self.assertEqual(status, 200)
        candidate = again['candidates'][0]
        self.assertEqual(candidate['id'], original['id'])
        self.assertEqual(candidate['relative'].encode(), folder.relative_to(self.source).as_posix().encode())
        self.assertEqual(candidate['entries'][0]['path'].encode(), entry.name.encode())
        self.assertEqual(self.s.publish(candidate['id'])['id'], game['id'])
        self.s.grant(self.s.authenticate(self.token)['id'], game['id'], True)
        lease = self.s.session(self.s.authenticate(self.token), game['id'], 'fixture', token=self.token)
        self.assertEqual(lease['game']['id'], game['id'])

    def test_duplicate_nfc_nfd_requests_rejected_before_any_batch_write(self):
        folder, entry = self.fixture('NFC')
        rows = [self.selection(folder, entry, 'NFC'), self.selection(folder, entry, 'NFD')]
        self.assertNotEqual(rows[0]['relative'].encode(), rows[1]['relative'].encode())
        self.assert_ambiguous(rows)
        self.assertEqual(self.s.candidates(), [])

    def ambiguity(self, parent, extra):
        """Inject only a directory name for filesystems unable to store both."""
        original = os.scandir
        inode = parent.stat().st_ino
        class Entries:
            def __init__(self, entries): self.items = iter(entries)
            def __iter__(self): return self
            def __next__(self): return next(self.items)
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def close(self): pass
        def scanned(path):
            iterator = original(path)
            if not isinstance(path, int) or os.fstat(path).st_ino != inode:
                return iterator
            with iterator:
                entries = list(iterator)
            entries.append(SimpleNamespace(name=extra))
            return Entries(entries)
        return patch('gameshelf_server.workflow.os.scandir', scanned)

    def test_equivalent_sibling_directories_are_ambiguous_even_for_exact_input(self):
        folder, entry = self.fixture('NFC')
        extra = unicodedata.normalize('NFD', folder.parent.name)
        with self.ambiguity(self.source, extra):
            self.assert_ambiguous([self.selection(folder, entry, 'NFC')])
        self.assertEqual(self.s.candidates(), [])

    def test_equivalent_entry_names_are_ambiguous_and_whole_batch_stays_unchanged(self):
        folder, entry = self.fixture('NFC')
        self.assertEqual(self.register([self.row()])[0], 200)
        before = [tuple(r) for r in self.s.db.execute('SELECT * FROM candidates')]
        with self.ambiguity(folder, unicodedata.normalize('NFD', entry.name)):
            self.assert_ambiguous([self.row(self.sha(self.entry)), self.selection(folder, entry, 'NFC')])
        self.assertEqual([tuple(r) for r in self.s.db.execute('SELECT * FROM candidates')], before)

    def test_unique_equivalent_symlink_never_resolves_outside_or_inside(self):
        target = self.source / 'Target'
        target.mkdir()
        (target / 'Play.exe').write_bytes(b'MZ outside link fixture')
        link = self.source / 'Café'
        link.symlink_to(target, target_is_directory=True)
        self.assertEqual(self.register([self.row('0' * 64, unicodedata.normalize('NFD', link.name))])[0], 400)
        self.assertEqual(self.s.candidates(), [])

    def test_native_dot_and_app_directory_entries_resolve_canonical_names(self):
        app = self.source / 'Café.app'
        (app / 'Contents/Resources/autorun/renpy').mkdir(parents=True)
        info = app / 'Contents/Info.plist'
        info.write_bytes(b'fixture info')
        for relative, entry in [('.', unicodedata.normalize('NFD', app.name)), (unicodedata.normalize('NFD', app.name), '.')]:
            status, result = self.register([self.row(self.sha(info), relative, entry)])
            self.assertEqual(status, 200)
            self.assertTrue(result['entryFingerprintsVerified'])
            candidate = result['candidates'][0]
            self.assertEqual(candidate['relative'].encode(), ('.' if relative == '.' else app.name).encode())
            self.assertEqual(candidate['entries'][0]['path'].encode(), ('.' if entry == '.' else app.name).encode())

    def test_no_compatibility_case_or_punctuation_folding_and_traversal_stays_rejected(self):
        self.assertEqual(self.register([self.row('0' * 64, 'Ｅxample')])[0], 404)
        self.assertEqual(self.register([self.row('0' * 64, 'example')])[0], 404)
        for relative in ['../Example', 'Example/../Example', '/Example', 'Example//Child']:
            self.assertEqual(self.register([self.row('0' * 64, relative)])[0], 400)
        self.assertEqual(self.s.candidates(), [])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Real distinct NFC/NFD names require Linux filesystem')
    def test_linux_real_equivalent_directory_names_are_ambiguous(self):
        folder, entry = self.fixture('NFC')
        other = self.source / unicodedata.normalize('NFD', folder.parent.name)
        other.mkdir()
        self.assertEqual(len([p for p in self.source.iterdir() if unicodedata.normalize('NFC', p.name) == unicodedata.normalize('NFC', folder.parent.name)]), 2)
        for form in ('NFC', 'NFD'):
            self.assert_ambiguous([self.selection(folder, entry, form)])
        self.assertEqual(self.s.candidates(), [])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Real distinct NFC/NFD names require Linux filesystem')
    def test_linux_real_equivalent_entry_names_are_ambiguous(self):
        folder, entry = self.fixture('NFC')
        other = folder / unicodedata.normalize('NFD', entry.name)
        other.write_bytes(b'MZ other canonical entry')
        self.assertEqual(len(list(folder.iterdir())), 2)
        for form in ('NFC', 'NFD'):
            self.assert_ambiguous([self.selection(folder, entry, form)])
        self.assertEqual(self.s.candidates(), [])
