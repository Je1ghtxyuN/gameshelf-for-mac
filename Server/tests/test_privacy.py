import os
from pathlib import Path
import shutil
import tempfile
import unittest
from gameshelf_server.privacy import begin_initialization, finish_initialization, mask_seed_saves, detect_rules, normalize_rules
from gameshelf_server.service import APIError

class PrivacyTests(unittest.TestCase):
    def test_two_accounts_start_fresh_then_keep_own_progress_source_unchanged(self):
        # Fixture copies stand in for mounted views ONLY in this unprivileged test.
        # The privileged Linux suite checks actual OverlayFS whiteouts/copy-up.
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp).resolve(); source=base/'source'; source.mkdir()
            (source/'game'/'saves').mkdir(parents=True)
            for path in ('Save01.rvdata2','game/saves/persistent','Save02.sav'):
                (source/path).write_text('OWNER PROGRESS')
            (source/'Actors.rvdata2').write_text('asset')
            rules=detect_rules(source)
            for name in ('alice','bob'):
                private=base/name
                paths={k:private/k for k in ('merged','upper','work','lower')}
                private.mkdir(); paths['upper'].mkdir()
                shutil.copytree(source,paths['merged'])
                self.assertTrue(begin_initialization(paths,rules))
                mask_seed_saves(paths['merged'],rules,os.getuid(),chown=lambda *a:None)
                finish_initialization(paths)
                self.assertFalse((paths['merged']/'Save01.rvdata2').exists())
                self.assertEqual(list((paths['merged']/'game'/'saves').iterdir()),[])
                self.assertEqual((paths['merged']/'Actors.rvdata2').read_text(),'asset')
                (paths['merged']/'Save01.rvdata2').write_text(name)
                self.assertFalse(begin_initialization(paths,rules))
                self.assertEqual((paths['merged']/'Save01.rvdata2').read_text(),name)
            self.assertEqual((source/'Save01.rvdata2').read_text(),'OWNER PROGRESS')
            self.assertEqual((source/'game'/'saves'/'persistent').read_text(),'OWNER PROGRESS')
    def test_manifest_missing_or_changed_never_resets_existing_private_saves(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp).resolve()
            paths={k:base/k for k in ('upper','merged')}
            paths['upper'].mkdir(); (paths['upper']/'private.sav').write_text('keep')
            with self.assertRaises(RuntimeError):
                begin_initialization(paths,[])
            self.assertEqual((paths['upper']/'private.sav').read_text(),'keep')
            (paths['upper']/'private.sav').unlink()
            self.assertTrue(begin_initialization(paths,[]))
            finish_initialization(paths)
            with self.assertRaises(RuntimeError):
                begin_initialization(paths,[dict(path='custom',kind='directory')])
    def test_rules_reject_traversal_reserved_and_external_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve()
            (root/'escape').symlink_to('/etc',target_is_directory=True)
            for path in ('../x','/x','a/../x','.gameshelf-profile','a//x','escape/passwd'):
                with self.assertRaises(APIError):
                    normalize_rules([dict(path=path,kind='file')],root)
    def test_known_save_link_also_masks_its_internal_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve(); (root/'progress.custom').write_text('owner')
            (root/'Save01.sav').symlink_to('progress.custom')
            rules=detect_rules(root)
            self.assertIn(dict(path='progress.custom',kind='file'),rules)
