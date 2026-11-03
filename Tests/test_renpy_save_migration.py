"""Hermetic migration tests: synthetic ZIPs and temporary directories only."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import warnings
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / 'Tools/migrate_renpy_saves.py'
spec = importlib.util.spec_from_file_location('migration', SCRIPT)
m = importlib.util.module_from_spec(spec)
if SCRIPT.exists():
    spec.loader.exec_module(m)


def save_bytes(label='old', metadata=None):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w') as z:
        for name, data in [
            ('log', b'opaque pickle -- never deserialize: ' + label.encode()),
            ('json', json.dumps(metadata if metadata is not None else
                                {'_renpy_version': [8, 3, 1], 'label': label})),
            ('renpy_version', 'RenPy synthetic 8.3.1'),
            ('signature', b'untouched signature'),
        ]:
            z.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data)
    return stream.getvalue()


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.dest = self.root / 'destination'
        self.backup = self.root / 'backups'

    def test_new_slots_preserve_original_file_time(self):
        source = self.source / '1-1-LT1.save'
        source.write_bytes(save_bytes('time'))
        original = 1600000000123456789
        os.utime(source, ns=(original, original))
        report = self.run_migration()
        self.assertEqual(report['status'], 'ok')
        self.assertEqual((self.dest / source.name).stat().st_mtime_ns, source.stat().st_mtime_ns)

    def run_migration(self, seeds=()):
        self.assertTrue(callable(getattr(m, 'migrate', None)), 'migrate API missing')
        return m.migrate(self.source, self.dest, self.backup, list(seeds))

    def snapshot(self, directory):
        return {p.name: p.read_bytes() for p in directory.iterdir() if p.is_file()}

    def receipt(self, report):
        return json.loads(Path(report['receipt']).read_text())

    def test_empty_import(self):
        report = self.run_migration()
        self.assertEqual(report['status'], 'ok')
        self.assertEqual(report['created'], [])
        self.assertEqual(self.receipt(report)['status'], 'ok')

    def test_source_unchanged_whitelist_and_metadata(self):
        data = save_bytes(metadata={'_renpy_version': [7, 4, 11], 'profile': {'v': 2}})
        for name, blob in [('auto-1-LT1.save', data), ('persistent', b'\x80opaque'),
                           ('persistent.bak', b'\x00opaque'), ('keys', b'secret'),
                           ('tokens', b'secret'), ('log', b'log')]:
            (self.source / name).write_bytes(blob)
        before = self.snapshot(self.source)
        report = self.run_migration()
        self.assertEqual(report['status'], 'ok')
        self.assertEqual(self.snapshot(self.source), before)
        self.assertEqual(set(self.snapshot(self.dest)),
                         {'auto-1-LT1.save', 'persistent', 'persistent.bak'})
        self.assertEqual((self.dest / 'auto-1-LT1.save').read_bytes(), data)
        self.assertEqual(report['inputs'][0]['saves'][0]['metadata']['profile'], {'v': 2})
        self.assertEqual(report['counts']['source']['auto'], 1)
        backed = Path(report['transaction']) / 'source'
        self.assertEqual(set(self.snapshot(backed)), set(self.snapshot(self.dest)))

    def test_conflict_remap_seed_first_and_preserve_destination(self):
        seed = self.root / 'seed'
        seed.mkdir()
        self.dest.mkdir()
        existing, new, old = save_bytes('existing'), save_bytes('new'), save_bytes('old')
        (self.dest / '1-1-LT1.save').write_bytes(existing)
        (seed / '1-2-LT1.save').write_bytes(new)
        (self.source / '1-2-LT1.save').write_bytes(old)
        report = self.run_migration([seed])
        self.assertEqual(report['status'], 'ok')
        self.assertEqual((self.dest / '1-1-LT1.save').read_bytes(), existing)
        self.assertEqual((self.dest / '1-2-LT1.save').read_bytes(), new)
        self.assertEqual((self.dest / '1-3-LT1.save').read_bytes(), old)
        self.assertEqual((Path(report['transaction']) / 'destination/1-1-LT1.save').read_bytes(), existing)
        self.assertEqual((Path(report['transaction']) / 'seed-000/1-2-LT1.save').read_bytes(), new)

    def test_auto_quick_manual_original_names_and_remap(self):
        self.dest.mkdir()
        names = ['auto-1-LT1.save', 'quick-2-LT1.save', '4-6-LT1.save']
        for name in names:
            (self.source / name).write_bytes(save_bytes(name))
        (self.dest / names[0]).write_bytes(save_bytes('different'))
        report = self.run_migration()
        self.assertEqual(report['status'], 'ok')
        self.assertEqual((self.dest / '1-1-LT1.save').read_bytes(), (self.source / names[0]).read_bytes())
        self.assertTrue((self.dest / names[1]).exists())
        self.assertTrue((self.dest / names[2]).exists())

    def test_remap_does_not_steal_another_free_original_slot(self):
        self.dest.mkdir()
        (self.dest / '1-1-LT1.save').write_bytes(save_bytes('existing'))
        (self.source / '1-1-LT1.save').write_bytes(save_bytes('conflict'))
        original = save_bytes('free original')
        (self.source / '1-2-LT1.save').write_bytes(original)
        report = self.run_migration()
        self.assertEqual(report['status'], 'ok')
        self.assertEqual((self.dest / '1-2-LT1.save').read_bytes(), original)
        self.assertEqual((self.dest / '1-3-LT1.save').read_bytes(), save_bytes('conflict'))

    def test_remap_rolls_to_next_manual_page(self):
        self.dest.mkdir()
        for slot in range(1, 7):
            (self.dest / f'1-{slot}-LT1.save').write_bytes(save_bytes(f'existing {slot}'))
        (self.source / '1-1-LT1.save').write_bytes(save_bytes('old'))
        self.assertEqual(self.run_migration()['status'], 'ok')
        self.assertEqual((self.dest / '2-1-LT1.save').read_bytes(), save_bytes('old'))

    def test_repeated_import_deduplicates_across_names(self):
        self.dest.mkdir()
        data = save_bytes()
        (self.source / 'quick-1-LT1.save').write_bytes(data)
        (self.source / '1-2-LT1.save').write_bytes(data)
        (self.dest / 'quick-1-LT1.save').write_bytes(save_bytes('collision'))
        first = self.run_migration()
        before = self.snapshot(self.dest)
        second = self.run_migration()
        self.assertEqual(first['status'], 'ok')
        self.assertEqual(len(first['created']), 1)
        self.assertEqual(second['created'], [])
        self.assertEqual(self.snapshot(self.dest), before)
        self.assertNotEqual(first['transaction'], second['transaction'])

    def test_persistent_is_opaque_and_existing_is_preserved(self):
        self.dest.mkdir()
        (self.dest / 'persistent').write_bytes(b'new\x80not-a-pickle')
        (self.source / 'persistent').write_bytes(b'old\xffnot-a-pickle')
        report = self.run_migration()
        self.assertEqual(report['status'], 'ok')
        self.assertEqual((self.dest / 'persistent').read_bytes(), b'new\x80not-a-pickle')
        self.assertEqual((Path(report['transaction']) / 'source/persistent').read_bytes(), b'old\xffnot-a-pickle')
        self.assertEqual(report['persistent'][0]['decision'], 'preserve_destination')
        destination_manifest = next(item for item in report['inputs'] if item['role'] == 'destination')
        self.assertEqual(destination_manifest['persistent'][0]['name'], 'persistent')
        self.assertEqual(destination_manifest['persistent'][0]['bytes'], 16)

    def assert_rejected_without_mutation(self):
        report = self.run_migration()
        self.assertEqual(report['status'], 'failed')
        self.assertTrue(report['error'])
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.backup.exists())

    def test_invalid_zip_rejected_before_mutation(self):
        (self.source / '1-1-LT1.save').write_bytes(b'not a zip')
        self.assert_rejected_without_mutation()

    def test_zip_missing_members_bad_json_and_crc_rejected(self):
        for kind in ['missing', 'list', 'large_json', 'crc', 'traversal', 'duplicate', 'nan']:
            with self.subTest(kind=kind):
                stream = io.BytesIO()
                with zipfile.ZipFile(stream, 'w') as z:
                    z.writestr('log', 'UNIQUE_LOG_PAYLOAD')
                    z.writestr('json', '{"bad": NaN}' if kind == 'nan' else '[]' if kind == 'list' else
                               ' ' * (1024 * 1024) if kind == 'large_json' else '{}')
                    if kind != 'missing':
                        z.writestr('renpy_version', '8')
                    if kind == 'traversal':
                        z.writestr('../outside', 'bad')
                    if kind == 'duplicate':
                        with warnings.catch_warnings():
                            warnings.simplefilter('ignore', UserWarning)
                            z.writestr('log', 'duplicate')
                data = stream.getvalue()
                if kind == 'crc':
                    data = data.replace(b'UNIQUE_LOG_PAYLOAD', b'CORRUPT_LOG_BYTES!')
                (self.source / '1-1-LT1.save').write_bytes(data)
                self.assert_rejected_without_mutation()

    def test_symlink_accepted_file_and_parent_rejected(self):
        external = self.root / 'external'
        external.write_bytes(save_bytes())
        (self.source / '1-1-LT1.save').symlink_to(external)
        self.assert_rejected_without_mutation()
        (self.source / '1-1-LT1.save').unlink()
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        self.dest = alias / 'dest'
        self.assert_rejected_without_mutation()

    def test_backup_symlink_and_nested_source_symlink_rejected(self):
        target = self.root / 'target'
        target.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(target, target_is_directory=True)
        self.backup = alias / 'backup'
        self.assert_rejected_without_mutation()

    def test_same_nested_and_seed_overlap_rejected(self):
        cases = [(self.source, self.root / 'backup'),
                 (self.source / 'dest', self.root / 'backup'),
                 (self.root / 'dest', self.source / 'backup'),
                 (self.root / 'dest', self.root / 'dest/backup'),
                 (self.root / 'dest', self.root)]
        for dest, backup in cases:
            with self.subTest(dest=dest, backup=backup):
                report = m.migrate(self.source, dest, backup)
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(list(self.source.iterdir()), [])
        self.assertEqual(self.run_migration([self.source])['status'], 'failed')

    def test_unsafe_filename_and_nonregular_accepted_rejected(self):
        for name in ['bad\\name.save', 'folder.save']:
            path = self.source / name
            if name == 'folder.save':
                path.mkdir()
            else:
                path.write_bytes(save_bytes())
            self.assert_rejected_without_mutation()
            path.rmdir() if path.is_dir() else path.unlink()

    def test_resource_limits_reject_before_mutation(self):
        (self.source / '1-1-LT1.save').write_bytes(save_bytes())
        for setting, value in [('MAX_FILE_BYTES', 10), ('MAX_TOTAL_BYTES', 10), ('MAX_FILES', 0)]:
            with self.subTest(setting=setting), patch.object(m, setting, value):
                self.assert_rejected_without_mutation()

    def test_expanded_zip_limit_rejected(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr('log', b'x' * 4096)
            z.writestr('json', '{}')
            z.writestr('renpy_version', '8')
        (self.source / '1-1-LT1.save').write_bytes(stream.getvalue())
        with patch.object(m, 'MAX_FILE_BYTES', 2048):
            self.assert_rejected_without_mutation()

    def test_backup_precedes_publish_and_failure_rolls_back_second_file(self):
        self.dest.mkdir()
        existing = save_bytes('existing')
        (self.dest / '9-1-LT1.save').write_bytes(existing)
        for i in [1, 2]:
            (self.source / f'1-{i}-LT1.save').write_bytes(save_bytes(str(i)))
        before = self.snapshot(self.source)
        original = m._publish
        calls = []

        def fail_after_second(*args, **kwargs):
            txns = list(self.backup.iterdir())
            self.assertEqual(len(txns), 1)
            txn = txns[0]
            self.assertEqual(self.snapshot(txn / 'source'), before)
            self.assertEqual((txn / 'destination/9-1-LT1.save').read_bytes(), existing)
            self.assertEqual(json.loads((txn / 'receipt.json').read_text())['status'], 'prepared')
            original(*args, **kwargs)
            calls.append(1)
            if len(calls) == 2:
                raise OSError('injected after second publish')

        with patch.object(m, '_publish', side_effect=fail_after_second):
            report = self.run_migration()
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(self.snapshot(self.dest), {'9-1-LT1.save': existing})
        self.assertEqual(self.snapshot(self.source), before)
        self.assertIn('injected', self.receipt(report)['error'])
        self.assertTrue((Path(report['transaction']) / 'source/1-2-LT1.save').exists())

    def test_cli_json_and_optional_report(self):
        (self.source / '1-1-LT1.save').write_bytes(save_bytes(metadata={
            '_renpy_version': [8, 3, 1], 'private_payload': 'PRIVATE_MARKER'}))
        report_path = self.root / 'report.json'
        result = subprocess.run([sys.executable, str(SCRIPT), '--source', str(self.source),
                                 '--destination', str(self.dest), '--backup-root', str(self.backup),
                                 '--report', str(report_path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(summary['status'], 'ok')
        report = json.loads(report_path.read_text())
        self.assertEqual(report['created'], ['1-1-LT1.save'])
        self.assertEqual(summary['receipt'], report['receipt'])
        self.assertEqual(summary['created_count'], 1)
        self.assertNotIn('PRIVATE_MARKER', result.stdout)
        self.assertNotIn('opaque pickle', result.stdout)

    def test_racing_target_creation_is_never_overwritten(self):
        self.dest.mkdir()
        (self.source / '1-1-LT1.save').write_bytes(save_bytes())
        original = m._publish

        def race(stage, target, data, created):
            target.write_bytes(b'concurrent writer')
            return original(stage, target, data, created)

        with patch.object(m, '_publish', side_effect=race):
            report = self.run_migration()
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(self.snapshot(self.dest), {'1-1-LT1.save': b'concurrent writer'})
        self.assertEqual(self.receipt(report)['status'], 'failed')

    def test_backup_failure_never_touches_destination(self):
        (self.source / '1-1-LT1.save').write_bytes(save_bytes())
        original = m._atomic_write

        def fail_backup(path, data):
            if path.name.endswith('.save'):
                raise OSError('backup disk full')
            return original(path, data)

        with patch.object(m, '_atomic_write', side_effect=fail_backup):
            report = self.run_migration()
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(self.dest.exists())
        self.assertIn('backup disk full', self.receipt(report)['error'])

    def test_seed_persistent_priority_and_opaque_backup(self):
        seed = self.root / 'seed'
        seed.mkdir()
        (seed / 'persistent').write_bytes(b'new opaque')
        (self.source / 'persistent').write_bytes(b'old opaque')
        report = self.run_migration([seed])
        self.assertEqual(report['status'], 'ok')
        self.assertEqual((self.dest / 'persistent').read_bytes(), b'new opaque')
        self.assertEqual([item['decision'] for item in report['persistent']],
                         ['copy_if_missing', 'preserve_destination'])

    def test_invalid_destination_and_seed_abort_before_backup(self):
        self.dest.mkdir()
        (self.dest / 'auto-1-LT1.save').write_bytes(b'bad destination zip')
        report = self.run_migration()
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(self.backup.exists())
        (self.dest / 'auto-1-LT1.save').unlink()
        seed = self.root / 'seed'
        seed.mkdir()
        (seed / 'persistent').symlink_to(self.source / 'missing')
        self.assertEqual(self.run_migration([seed])['status'], 'failed')
        self.assertFalse(self.backup.exists())

    def test_missing_inputs_and_traversal_are_rejected(self):
        report = m.migrate(self.root / 'missing', self.dest, self.backup)
        self.assertEqual(report['status'], 'failed')
        report = m.migrate(self.source / '..' / 'source', self.dest, self.backup)
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.backup.exists())

    def test_cli_refuses_report_inside_source_without_mutation(self):
        existing = self.source / 'keys'
        existing.write_bytes(b'secret')
        result = subprocess.run([sys.executable, str(SCRIPT), '--source', str(self.source),
                                 '--destination', str(self.dest), '--backup-root', str(self.backup),
                                 '--report', str(existing)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['status'], 'failed')
        self.assertEqual(existing.read_bytes(), b'secret')
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.backup.exists())

    def test_destination_symlink_introduced_during_backup_is_rejected(self):
        (self.source / '1-1-LT1.save').write_bytes(save_bytes())
        outside = self.root / 'outside'
        outside.mkdir()
        original = m._write_receipt

        def swap_destination(report):
            original(report)
            if report['status'] == 'prepared':
                self.dest.symlink_to(outside, target_is_directory=True)

        with patch.object(m, '_write_receipt', side_effect=swap_destination):
            report = self.run_migration()
        self.assertEqual(report['status'], 'failed')
        self.assertIn('symlink path component', report['error'])
        self.assertEqual(list(outside.iterdir()), [])
        self.assertTrue(Path(report['transaction']).is_dir())


if __name__ == '__main__':
    unittest.main()
