import base64
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from gameshelf_server.service import APIError, Service
from test_onboarding import JPEG, snapshot

class AccountBoundsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        base=Path(self.tmp.name).resolve(); source=base/'source'; source.mkdir()
        self.s=Service(base/'state',None,[source]); self.addCleanup(self.s.close)
        self.alice=self.s.create_user('alice','private test password')
        self.bob=self.s.create_user('bob','private test password')
    def put(self,device,value=None,revision=0,user=None):
        return self.s.personal_library(user or self.alice,str(uuid.UUID(int=device)),dict(expectedRevision=revision,snapshot=value or snapshot()))
    def rejects(self,status,call):
        with self.assertRaises(APIError) as error: call()
        self.assertEqual(error.exception.status,status)
    def large(self,title='x'*1024,count=425):
        return dict(version=1,games=[dict(id=str(uuid.UUID(int=i+100)),title=title,favorite=False,collectionIDs=[],playtimeSeconds=0) for i in range(count)],collections=[])
    def test_eight_libraries_accept_legal_large_snapshots_ninth_rejected_account_private(self):
        large=self.large()
        for device in range(1,9): self.put(device,large)
        listing=self.s.personal_libraries(self.alice)
        self.assertEqual(len(listing['libraries']),8)
        self.assertLessEqual(len(json.dumps(listing,ensure_ascii=False,allow_nan=False).encode()),4*1024*1024)
        self.rejects(413,lambda:self.put(9,large))
        self.assertEqual(len(self.s.personal_libraries(self.alice)['libraries']),8)
        self.put(9,large,user=self.bob)
        self.assertEqual(len(self.s.personal_libraries(self.bob)['libraries']),1)
    def test_actual_wire_bytes_not_compact_snapshot_sum_enforced_atomically(self):
        # Each compact snapshot fits 512 KiB, but spaces in the real response
        # envelope make eight exceed 4 MiB. Also cover JSON string escaping.
        value=self.large(title='"\\'*500,count=248)
        compact=len(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode())
        self.assertLessEqual(compact,512*1024)
        self.assertGreater(len(json.dumps(dict(libraries=[dict(deviceID=str(uuid.UUID(int=1)),revision=2,snapshot=value)]*8),ensure_ascii=False).encode()),4*1024*1024)
        for device in range(1,9): self.put(device,snapshot())
        for device in range(1,8): self.put(device,value,revision=1)
        before=self.s.personal_library(self.alice,str(uuid.UUID(int=8)))
        image=dict(data=base64.b64encode(JPEG).decode())
        cover=self.s.personal_cover(self.alice,str(uuid.UUID(int=8)),str(uuid.UUID(int=2)),image)
        self.rejects(413,lambda:self.put(8,value,revision=1))
        self.assertEqual(self.s.personal_library(self.alice,str(uuid.UUID(int=8))),before)
        self.assertEqual(self.s.personal_cover(self.alice,str(uuid.UUID(int=8)),str(uuid.UUID(int=2))),cover)
        self.assertLessEqual(len(json.dumps(self.s.personal_libraries(self.alice),ensure_ascii=False,allow_nan=False).encode()),4*1024*1024)
    def test_legacy_overquota_list_rejects_before_decoding_snapshots(self):
        # Simulate old versions' unlimited UUID rows, without deleting any data.
        for device in range(1,21):
            self.s.db.execute('INSERT INTO personal_libraries VALUES (?,?,?,?)',(self.alice['id'],str(uuid.UUID(int=device)),1,json.dumps(self.large())))
        from unittest.mock import patch
        with patch('gameshelf_server.accounts.json.loads',side_effect=AssertionError('must not decode overquota list')):
            self.rejects(413,lambda:self.s.personal_libraries(self.alice))
        self.assertEqual(self.s.db.execute('SELECT count(*) FROM personal_libraries').fetchone()[0],20)
        image=dict(data=base64.b64encode(JPEG).decode())
        self.rejects(413,lambda:self.s.personal_cover(self.alice,str(uuid.UUID(int=1)),str(uuid.UUID(int=100)),image))
        self.assertEqual(self.s.db.execute('SELECT count(*) FROM personal_covers').fetchone()[0],0)
    def test_cover_requires_own_parent_and_game_and_cas_prunes_orphans(self):
        device=str(uuid.UUID(int=1)); game=str(uuid.UUID(int=2)); image=dict(data=base64.b64encode(JPEG).decode())
        self.rejects(404,lambda:self.s.personal_cover(self.alice,device,game,image))
        self.put(1)
        self.rejects(404,lambda:self.s.personal_cover(self.bob,device,game,image))
        self.rejects(404,lambda:self.s.personal_cover(self.alice,device,str(uuid.UUID(int=99)),image))
        cover=self.s.personal_cover(self.alice,device,game,image)
        empty=dict(version=1,games=[],collections=[])
        self.rejects(409,lambda:self.put(1,empty,revision=0))
        self.assertEqual(self.s.personal_cover(self.alice,device,game),cover)
        self.put(1,empty,revision=1)
        self.rejects(404,lambda:self.s.personal_cover(self.alice,device,game))
        self.rejects(404,lambda:self.s.personal_cover(self.alice,device,game,image))
        self.assertEqual(self.s.db.execute('SELECT count(*) FROM personal_covers').fetchone()[0],0)
    def test_concurrent_eighth_and_ninth_library_cannot_overrun_cap(self):
        for device in range(1,8): self.put(device)
        def create(device):
            try: self.put(device); return 200
            except APIError as error: return error.status
        with ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(sorted(pool.map(create,[8,9])),[200,413])
        self.assertEqual(len(self.s.personal_libraries(self.alice)['libraries']),8)
