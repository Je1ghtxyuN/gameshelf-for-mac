"""Synthetic metadata only: no game assets or NAS reads."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from gameshelf_server import discovery

PROFILE_FILES=('package.json','js/main.js','js/plugins.js','js/rmmz_core.js','js/rmmz_managers.js')
WEB_ENTRY=dict(path='index.html',backend='rpgmz',engine='RPG Maker MZ')

class MZDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name).resolve()
        self.root=self.base/'Game'; self.root.mkdir()
        self.hashes={}
        for path in PROFILE_FILES:
            file=self.root/path; file.parent.mkdir(parents=True,exist_ok=True)
            data=('synthetic metadata '+path).encode()
            file.write_bytes(data)
            self.hashes[path]=hashlib.sha256(data).hexdigest()
        (self.root/'index.html').write_text('<!doctype html><title>synthetic</title>')
        for name in ('Game.exe','Game_CN.exe','custom.exe','helper.exe','CustomAdventure.exe'):
            (self.root/name).write_bytes(b'MZsynthetic')
        # Tests replace only a trusted developer profile, never a production env/API opt-in.
        self.profile=patch.object(discovery,'MZ_WEB_PROFILE_SAKURA',self.hashes,create=True)
        self.profile.start(); self.addCleanup(self.profile.stop)
    def entries(self,root=None):
        root=root or self.root
        children=list(root.iterdir())
        return discovery.discover(root,[p.name for p in children if p.is_dir()],
                                   [p.name for p in children if not p.is_dir()])[0]
    def test_matching_profile_is_first_and_preserves_wine_translations_and_exact_filters(self):
        before={p:hashlib.sha256((self.root/p).read_bytes()).hexdigest() for p in PROFILE_FILES}
        entries=self.entries()
        self.assertEqual(entries[0],WEB_ENTRY)
        self.assertEqual([e['path'] for e in entries[1:]],['Game_CN.exe','CustomAdventure.exe','Game.exe'])
        self.assertTrue(all(e['backend']=='wine' for e in entries[1:]))
        self.assertEqual(before,{p:hashlib.sha256((self.root/p).read_bytes()).hexdigest() for p in PROFILE_FILES})
    def test_changed_missing_or_unknown_metadata_never_opts_desktop_package_into_webkit(self):
        script=self.root/'js'/'plugins.js'; original=script.read_bytes()
        script.write_bytes(original+b' changed')
        self.assertNotIn('rpgmz',[e['backend'] for e in self.entries()])
        self.assertTrue(all(e['backend']=='wine' for e in self.entries()))
        self.assertIn('Game.exe',[e['path'] for e in self.entries()])
        script.unlink()
        self.assertTrue(all(e['backend']=='wine' for e in self.entries()))
        script.write_bytes(original)
        with patch.object(discovery,'MZ_WEB_PROFILE_SAKURA',{}):
            self.assertTrue(all(e['backend']=='wine' for e in self.entries()))
    def test_profile_file_or_directory_links_cannot_enable_webkit(self):
        for path in ('package.json','js/main.js','index.html'):
            file=self.root/path; data=file.read_bytes()
            outside=self.base/'outside'; outside.write_bytes(data)
            file.unlink(); file.symlink_to(outside)
            self.assertNotIn('rpgmz',[e['backend'] for e in self.entries()])
            file.unlink(); file.write_bytes(data)
        js=self.root/'js'; moved=self.base/'outside-js'; js.rename(moved); js.symlink_to(moved,target_is_directory=True)
        self.assertNotIn('rpgmz',[e['backend'] for e in self.entries()])
    def test_matcher_rejects_root_ancestor_links_special_files_and_oversized_metadata(self):
        self.assertTrue(hasattr(discovery,'matches_mz_web_profile'),'bounded no-follow matcher is required')
        root_link=self.base/'link'; root_link.symlink_to(self.root,target_is_directory=True)
        self.assertFalse(discovery.matches_mz_web_profile(root_link))
        parent_link=self.base/'parent-link'; parent_link.symlink_to(self.base,target_is_directory=True)
        self.assertFalse(discovery.matches_mz_web_profile(parent_link/'Game'))
        script=self.root/'js'/'plugins.js'; original=script.read_bytes()
        script.unlink(); os.mkfifo(script)
        self.assertFalse(discovery.matches_mz_web_profile(self.root))
        script.unlink()
        with script.open('wb') as f: f.truncate(2*1024*1024+1)
        oversized_hash=hashlib.sha256(script.read_bytes()).hexdigest() # synthetic fixture only
        with patch.dict(self.hashes,{'js/plugins.js':oversized_hash}):
            self.assertFalse(discovery.matches_mz_web_profile(self.root))
        script.write_bytes(original)
        with patch.object(discovery,'MZ_WEB_PROFILE_SAKURA',{'../outside':'0'*64}):
            self.assertFalse(discovery.matches_mz_web_profile(self.root))
    def test_index_and_verified_desktop_executable_are_required(self):
        (self.root/'index.html').unlink()
        self.assertTrue(all(e['backend']=='wine' for e in self.entries()))
        (self.root/'index.html').write_text('<html>synthetic</html>')
        (self.root/'Game.exe').write_text('not executable')
        self.assertTrue(all(e['backend']=='wine' for e in self.entries()))
    def test_platform_editions_stay_distinct_and_service_publishes_rpgmz(self):
        from gameshelf_server.service import Service
        from test_service import FakeDriver
        windows=self.root/'Windows'; windows.mkdir()
        (windows/'Game.exe').write_bytes(b'MZsynthetic')
        service=Service(self.base/'state',FakeDriver(self.base/'state'),[self.root])
        self.addCleanup(service.close)
        user=service.create_user('reader','synthetic reader password')
        root=service.add_root(str(self.root),'Library')
        # A previously published Wine-only edition gets a new entrance only on
        # explicit selected re-publication, without changing identity or grants.
        with patch.object(discovery,'MZ_WEB_PROFILE_SAKURA',{}):
            self.assertTrue(service.scan(root['id'])['complete'])
            old=service.publish(next(c['id'] for c in service.candidates() if c['relative']=='.'))
        service.grant(user['id'],old['id'],True)
        self.assertTrue(all(e['backend']=='wine' for e in service.catalog(user)['games'][0]['entries']))
        self.assertTrue(service.scan(root['id'])['complete'])
        self.assertTrue(all(e['backend']=='wine' for e in service.catalog(user)['games'][0]['entries']))
        candidates=service.candidates()
        self.assertEqual({c['relative'] for c in candidates},{'.','Windows'})
        game=service.publish(next(c['id'] for c in candidates if c['relative']=='.'))
        self.assertEqual(game['id'],old['id'])
        self.assertEqual(game['entries'][0],WEB_ENTRY)
        service.grant(user['id'],game['id'],True)
        self.assertEqual(service.catalog(user)['games'][0]['entries'][0],WEB_ENTRY)
        self.assertEqual(service.session(user,game['id'],'device')['game']['entries'][0],WEB_ENTRY)
        self.assertIn('rpgmz',json.dumps(game))

if __name__=='__main__':
    unittest.main()
