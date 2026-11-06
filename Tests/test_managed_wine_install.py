"""Hostile archives exercise the production Swift preflight, not a Python clone."""
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ManagedWineArchiveTests(unittest.TestCase):
    def audit(self, entries, accepted):
        with tempfile.TemporaryDirectory(prefix='ManagedWineArchive-') as directory:
            archive = Path(directory) / 'fixture.tar'
            with tarfile.open(archive, 'w', format=tarfile.PAX_FORMAT) as out:
                for name, kind, target in entries:
                    entry = tarfile.TarInfo(name)
                    entry.mode = 0o755 if kind == 'dir' else 0o644
                    if kind == 'dir': entry.type = tarfile.DIRTYPE
                    elif kind == 'link': entry.type = tarfile.SYMTYPE; entry.linkname = target
                    elif kind == 'hard': entry.type = tarfile.LNKTYPE; entry.linkname = target
                    elif kind == 'fifo': entry.type = tarfile.FIFOTYPE
                    else: entry.size = 2
                    out.addfile(entry, io.BytesIO(b'OK') if kind == 'file' else None)
            result = subprocess.run(['python3', str(ROOT/'Tools/managed_wine_install.py'), '--audit', str(archive)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

    def test_valid_internal_framework_style_links(self):
        self.audit([('Wine.app','dir',''),('Wine.app/Versions/A/file','file',''),
                    ('Wine.app/Versions/Current','link','A'),('Wine.app/file','link','Versions/Current/file')],True)

    def test_absolute_traversal_and_wrong_root(self):
        for name in ['/tmp/escape','Wine.app/../escape','Other.app/file','Wine.app//file','Wine.app/./file','Wine.app/back\\slash']:
            with self.subTest(name=name): self.audit([(name,'file','')],False)

    def test_special_hardlinks_duplicate_entries(self):
        self.audit([('Wine.app/file','fifo','')],False)
        self.audit([('Wine.app/a','file',''),('Wine.app/b','hard','Wine.app/a')],False)
        self.audit([('Wine.app/a','file',''),('Wine.app/a','file','')],False)

    def test_links_cannot_escape_or_be_write_ancestors(self):
        for target in ['/tmp','../outside','../../outside']:
            self.audit([('Wine.app/a','link',target)],False)
        self.audit([('Wine.app/a','link','.'),('Wine.app/a/file','file','')],False)

    def test_indirect_escape_cycle_and_dangling_links(self):
        self.audit([('Wine.app/a','link','.'),('Wine.app/b','link','a/../outside')],False)
        self.audit([('Wine.app/a','link','b'),('Wine.app/b','link','a')],False)
        self.audit([('Wine.app/a','link','missing')],False)

    def test_corrupt_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            archive=Path(directory)/'bad.tar';archive.write_bytes(b'not an archive')
            result=subprocess.run([str(ROOT/'build/ManagedWineTests'),'--audit',str(archive),'Wine.app'],capture_output=True)
            self.assertNotEqual(result.returncode,0)

if __name__ == '__main__': unittest.main()
