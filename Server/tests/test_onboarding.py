import base64
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import stat
import tempfile
import unittest
import uuid

from gameshelf_server.service import Service, APIError
from gameshelf_server.http_api import Application
import test_http

# Bounded marker fixture: SOF0, SOS, one scan and EOI (no external assets).
JPEG = bytes.fromhex('ffd8ffc0000b080001000101011100ffda0008010100003f0000ffd9')

def snapshot(title='Private title'):
    return dict(version=1,games=[dict(id=str(uuid.UUID(int=2)),title=title,favorite=True,
        collectionIDs=[str(uuid.UUID(int=3))],playtimeSeconds=12.5,lastPlayed=None)],
        collections=[dict(id=str(uuid.UUID(int=3)),name='Private collection')])

class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        base=Path(self.tmp.name).resolve(); self.source=base/'source'; self.source.mkdir()
        self.s=Service(base/'state',None,[self.source]); self.addCleanup(self.s.close)
    def app(self):
        return Application(self.s,public_address='https://library.example:8787',certificate_sha256='ab'*32)
    def test_private_setup_invitation_one_use_and_restart_stability(self):
        app=self.app(); path=self.s.state/'administrator-setup.json'
        self.assertTrue(path.is_file(),'empty service must create private setup invitation')
        invite=json.loads(path.read_text()); self.assertEqual(invite['version'],1)
        self.assertEqual({k:v for k,v in invite.items() if k!='setupToken'},dict(version=1,kind='administrator-setup',address='https://library.example:8787',name='GameShelf',certificateSHA256='ab'*32))
        self.assertEqual(invite['address'],'https://library.example:8787')
        self.assertEqual(invite['certificateSHA256'],'ab'*32)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode),0o600)
        self.app(); self.assertEqual(json.loads(path.read_text()),invite)
        self.assertTrue(app.dispatch('GET','/api/server-info',{},'')['setupRequired'])
        for token in ('', 'wrong'):
            with self.assertRaises(APIError) as e:
                app.dispatch('POST','/api/setup',dict(setupToken=token,username='owner',password='private password'),'')
            self.assertEqual(e.exception.status,403)
        result=app.dispatch('POST','/api/setup',dict(setupToken=invite['setupToken'],username='owner',password='private password'),'')
        self.assertEqual(set(result['user']),{'id','username','admin'}); self.assertTrue(result['user']['admin'])
        self.assertEqual(self.s.authenticate(result['token'])['id'],result['user']['id'])
        self.assertFalse(path.exists()); self.app(); self.assertFalse(path.exists())
        self.assertFalse(app.dispatch('GET','/api/server-info',{},'')['setupRequired'])
        with self.assertRaises(APIError) as e:
            app.dispatch('POST','/api/setup',dict(setupToken=invite['setupToken'],username='second',password='private password'),'')
        self.assertEqual(e.exception.status,409)
        normal=app.dispatch('GET','/api/admin/invitation',{},result['token'])
        self.assertNotIn('setupToken',normal)
        self.assertNotIn('kind',normal)
        self.assertNotIn(invite['setupToken'],str(list(self.s.db.execute('SELECT * FROM settings'))))
    def test_setup_claim_race_serializes_one_admin_and_invalid_input_retains_capability(self):
        app=self.app(); token=json.loads((self.s.state/'administrator-setup.json').read_text())['setupToken']
        with self.assertRaises(APIError):
            app.dispatch('POST','/api/setup',dict(setupToken=token,username='owner',password='short'),'')
        def claim(name):
            try: return app.dispatch('POST','/api/setup',dict(setupToken=token,username=name,password='private password'),'')['user']['id']
            except APIError as e: return e.status
        with ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(claim,['alice','bob']))
        self.assertEqual(sum(isinstance(r,str) for r in results),1); self.assertIn(409,results)
        self.assertEqual(len(self.s.users()),1)
    def test_no_setup_file_without_address_or_for_initialized_service_and_symlink_rejected(self):
        Application(self.s); path=self.s.state/'administrator-setup.json'; self.assertFalse(path.exists())
        outside=self.source/'untouched'; outside.write_text('original'); path.symlink_to(outside)
        with self.assertRaises((APIError,ValueError,OSError)): self.app()
        self.assertEqual(outside.read_text(),'original'); path.unlink()
        self.s.create_user('existing','existing password',True); self.app(); self.assertFalse(path.exists())

class MetadataHTTPTests(unittest.TestCase):
    setUp=test_http.HTTPTests.setUp
    call=test_http.HTTPTests.call
    def test_rename_self_keeps_identity_token_password_and_role(self):
        root=self.s.add_root(str(self.source),'Rename fixture'); self.s.scan(root['id'])
        game=self.s.publish(self.s.candidates()[0]['id']); self.s.grant(self.admin['id'],game['id'],True)
        lease=self.s.session(self.s.authenticate(self.owner_token),game['id'],'synthetic-device',token=self.owner_token)
        before=dict(self.s.db.execute('SELECT * FROM users WHERE id=?',(self.admin['id'],)).fetchone())
        status,user,_=self.call('POST',f'/api/admin/users/{self.admin["id"]}/rename',dict(username='Je1ght'),self.owner_token)
        self.assertEqual(status,200); self.assertEqual(user['id'],self.admin['id']); self.assertTrue(user['admin'])
        self.assertEqual(self.s.authenticate(self.owner_token)['username'],'Je1ght')
        after=dict(self.s.db.execute('SELECT * FROM users WHERE id=?',(self.admin['id'],)).fetchone())
        self.assertEqual({k:v for k,v in before.items() if k!='username'},{k:v for k,v in after.items() if k!='username'})
        self.assertEqual(self.call('POST',f'/api/sessions/{lease["leaseID"]}/heartbeat',{},self.owner_token)[0],200)
        self.assertEqual(self.call('GET','/api/catalog',token=self.owner_token)[1]['games'][0]['id'],game['id'])
        self.assertEqual(self.call('POST','/api/login',dict(username='Je1ght',password='owner test password'))[0],200)
        self.assertEqual(self.call('POST',f'/api/admin/users/{self.user["id"]}/rename',dict(username='other'),self.owner_token)[0],403)
        self.assertEqual(self.call('POST',f'/api/admin/users/{self.admin["id"]}/rename',dict(username='player'),self.owner_token)[0],409)
        self.assertEqual(self.call('POST',f'/api/admin/users/{self.user["id"]}/rename',dict(username='new'),self.token)[0],403)
    def test_personal_metadata_isolation_cas_and_race(self):
        device=str(uuid.UUID(int=1)); route='/api/personal-library/'+device
        self.assertEqual(self.call('GET','/api/personal-library')[0],401)
        self.assertEqual(self.call('GET',route,token=self.token)[0],404)
        status,first,_=self.call('POST',route,dict(expectedRevision=0,snapshot=snapshot()),self.token)
        self.assertEqual(status,200); self.assertEqual(first,dict(deviceID=device,revision=1,snapshot=snapshot()))
        self.assertEqual(self.call('GET','/api/personal-library',token=self.owner_token)[1],{'libraries':[]})
        self.assertEqual(self.call('GET',route,token=self.owner_token)[0],404)
        self.assertEqual(self.call('POST',route,dict(expectedRevision=0,snapshot=snapshot()),self.token)[0],409)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda t:self.call('POST',route,dict(expectedRevision=1,snapshot=snapshot(t)),self.token)[0],['a','b']))
        self.assertEqual(sorted(results),[200,409])
        self.assertEqual(self.call('GET','/api/personal-library',token=self.token)[1]['libraries'][0]['revision'],2)
        self.assertEqual((self.source/'Example'/'Play.exe').read_bytes(),b'MZfixture')
    def test_personal_validation_rejects_paths_unknown_keys_nonfinite_duplicates_and_bounds(self):
        route='/api/personal-library/'+str(uuid.UUID(int=1))
        bad=[]
        for key,value in [('path','/private/game'),('playtimeSeconds',float('nan')),('playtimeSeconds',-1),('favorite',1),('title','x'*1025),('id','../escape')]:
            s=snapshot(); s['games'][0][key]=value; bad.append(s)
        s=snapshot(); s['games']*=2; bad.append(s)
        s=snapshot(); s['collections'][0]['extra']='x'; bad.append(s)
        s=snapshot(); s['games'][0]['collectionIDs']=[str(uuid.UUID(int=99))]; bad.append(s)
        for s in bad:
            self.assertEqual(self.call('POST',route,dict(expectedRevision=0,snapshot=s),self.token)[0],400)
        self.assertEqual(self.call('POST',route,dict(expectedRevision=True,snapshot=snapshot()),self.token)[0],400)
        self.assertEqual(self.call('POST',route,dict(expectedRevision=0,snapshot=snapshot(),userID=self.admin['id']),self.token)[0],400)
        s=dict(version=1,games=[dict(id=str(uuid.UUID(int=i+10)),title='x'*500,favorite=False,collectionIDs=[],playtimeSeconds=0) for i in range(100)])
        s['collections']=[]
        self.assertEqual(self.call('POST',route,dict(expectedRevision=0,snapshot=s),self.token)[0],200)
        s['games']*=20
        self.assertEqual(self.call('POST',route,{},self.token,extra={'Content-Length':str(600000)})[0],413)
        self.assertEqual(self.call('POST','/api/login',{'username':'x'*17000})[0],413)
    def test_swift_uuid_utf8_limits_and_missing_get_contract(self):
        device='ABCDEF01-ABCD-ABCD-ABCD-ABCDEF012345'
        game='ABCDEF02-ABCD-ABCD-ABCD-ABCDEF012345'
        group='ABCDEF03-ABCD-ABCD-ABCD-ABCDEF012345'
        route='/api/personal-library/'+device
        self.assertEqual(self.call('GET',route,token=self.token)[0],404)
        value=dict(version=1,games=[dict(id=game,title='x'*1024,favorite=False,collectionIDs=[group],playtimeSeconds=31557600000,lastPlayed=1730000000.25)],collections=[dict(id=group,name='x'*240)])
        status,result,_=self.call('POST',route,dict(expectedRevision=0,snapshot=value),self.token)
        self.assertEqual(status,200)
        self.assertEqual(set(result),{'deviceID','revision','snapshot'})
        self.assertEqual(result['deviceID'],device.lower())
        self.assertEqual(result['snapshot']['games'][0]['id'],game.lower())
        self.assertEqual(result['snapshot']['collections'][0]['id'],group.lower())
        self.assertEqual(result['snapshot']['games'][0]['collectionIDs'],[group.lower()])
        self.assertEqual(self.call('GET',route.lower(),token=self.token)[1],result)
        for field,bad in [('title','é'*513),('playtimeSeconds',31557600001)]:
            changed=json.loads(json.dumps(value)); changed['games'][0][field]=bad
            self.assertEqual(self.call('POST',route,dict(expectedRevision=1,snapshot=changed),self.token)[0],400)
        value['collections'][0]['name']='é'*121
        self.assertEqual(self.call('POST',route,dict(expectedRevision=1,snapshot=value),self.token)[0],400)
    def test_cover_exact_decoded_limit_is_accepted_above_normal_request_limit(self):
        device=str(uuid.UUID(int=20)); game=str(uuid.UUID(int=21))
        value=snapshot(); value['games'][0]['id']=game
        self.assertEqual(self.call('POST','/api/personal-library/'+device,dict(expectedRevision=0,snapshot=value),self.token)[0],200)
        route='/api/personal-library/'+device+'/covers/'+game
        remaining=256*1024-len(JPEG); segments=[]
        while remaining:
            total=min(65537,remaining)
            segments.append(b'\xff\xe1'+(total-2).to_bytes(2,'big')+b'x'*(total-4))
            remaining-=total
        raw=JPEG[:2]+b''.join(segments)+JPEG[2:]
        self.assertEqual(len(raw),256*1024)
        status,result,_=self.call('POST',route,dict(data=base64.b64encode(raw).decode()),self.token)
        self.assertEqual(status,200); self.assertEqual(base64.b64decode(result['data']),raw)
        self.assertEqual(self.call('GET',route,token=self.owner_token)[0],404)
        # Header-only oversized framing avoids sending an unbounded request body.
        self.assertEqual(self.call('POST',route,{},self.token,extra={'Content-Length':'350553'})[0],413)
        self.assertEqual(self.call('GET',route,token=self.token)[1],result)
    def test_personal_list_actual_http_bytes_and_cover_parent_authorization(self):
        from test_account_bounds import AccountBoundsTests
        from gameshelf_server.common import wire_json
        user=self.s.authenticate(self.token); value=AccountBoundsTests().large()
        for i in range(1,9):
            self.s.personal_library(user,str(uuid.UUID(int=i)),dict(expectedRevision=0,snapshot=value))
        status,listing,headers=self.call('GET','/api/personal-library',token=self.token)
        self.assertEqual(status,200); self.assertEqual(len(listing['libraries']),8)
        self.assertEqual(int(headers['Content-Length']),len(wire_json(listing)))
        self.assertLessEqual(int(headers['Content-Length']),4*1024*1024)
        self.assertEqual(self.call('POST','/api/personal-library/'+str(uuid.UUID(int=9)),dict(expectedRevision=0,snapshot=snapshot()),self.token)[0],413)
        image=dict(data=base64.b64encode(JPEG).decode())
        route='/api/personal-library/'+str(uuid.UUID(int=1))+'/covers/'+str(uuid.UUID(int=100))
        self.assertEqual(self.call('POST',route,image,self.owner_token)[0],404)
        self.assertEqual(self.call('GET',route,token=self.owner_token)[0],404)
        self.assertEqual(self.call('POST',route,image,self.token)[0],200)
        unknown='/api/personal-library/'+str(uuid.UUID(int=1))+'/covers/'+str(uuid.UUID(int=9999))
        self.assertEqual(self.call('POST',unknown,image,self.token)[0],404)
        self.assertEqual(self.call('GET',unknown,token=self.token)[0],404)
    def test_private_and_canonical_covers_authorization_integrity_and_sizes(self):
        device=str(uuid.UUID(int=1)); game=str(uuid.UUID(int=2)); route=f'/api/personal-library/{device}/covers/{game}'
        self.assertEqual(self.call('POST','/api/personal-library/'+device,dict(expectedRevision=0,snapshot=snapshot()),self.token)[0],200)
        image=dict(data=base64.b64encode(JPEG).decode())
        self.assertEqual(self.call('POST',route,image,self.token)[0],200)
        cover=self.call('GET',route,token=self.token)[1]
        import hashlib
        self.assertEqual(cover,dict(data=image['data'],mime='image/jpeg',sha256=hashlib.sha256(JPEG).hexdigest()))
        self.assertEqual(self.call('GET',route,token=self.owner_token)[0],404)
        for data in ('notbase64',base64.b64encode(b'not jpeg').decode(),base64.b64encode(JPEG+b'extra').decode()):
            self.assertEqual(self.call('POST',route,dict(data=data),self.token)[0],400)
        large=base64.b64encode(b'x'*(256*1024+1)).decode()
        self.assertEqual(self.call('POST',route,dict(data=large),self.token)[0],413)
        root=self.s.add_root(str(self.source),'Fixture'); self.s.scan(root['id']); published=self.s.publish(self.s.candidates()[0]['id'])
        canonical=f'/api/games/{published["id"]}/cover'; admin=f'/api/admin/games/{published["id"]}/cover'
        self.assertEqual(self.call('POST',admin,image,self.token)[0],403)
        other_image=dict(data=base64.b64encode(JPEG[:-3]+b'\x01'+JPEG[-2:]).decode())
        self.assertEqual(self.call('POST',admin,other_image,self.owner_token)[0],200)
        self.assertEqual(self.call('GET',canonical,token=self.token)[0],403)
        self.s.grant(self.user['id'],published['id'],True)
        canonical_cover=self.call('GET',canonical,token=self.token)[1]
        self.assertEqual(canonical_cover['data'],other_image['data'])
        self.assertNotEqual(canonical_cover['sha256'],cover['sha256'])
        self.assertEqual(self.call('GET',route,token=self.token)[1],cover)
        self.assertEqual(self.call('GET','/api/catalog',token=self.token)[1]['games'][0]['coverSHA256'],canonical_cover['sha256'])
        self.s.grant(self.user['id'],published['id'],False)
        self.assertEqual(self.call('GET',canonical,token=self.token)[0],403)
        self.assertEqual((self.source/'Example'/'Play.exe').read_bytes(),b'MZfixture')

class AccountSafetyTests(unittest.TestCase):
    setUp=SetupTests.setUp
    app=SetupTests.app
    def test_direct_snapshot_size_and_cover_structure_bounds(self):
        from gameshelf_server.accounts import validate_snapshot, decode_cover
        value=dict(version=1,games=[dict(id=str(uuid.UUID(int=i+100)),title='x'*512,favorite=False,
            collectionIDs=[],playtimeSeconds=0) for i in range(1000)],collections=[])
        with self.assertRaises(APIError) as e: validate_snapshot(value)
        self.assertEqual(e.exception.status,413)
        for raw in (b'\xff\xd8\xff\xd9', JPEG[:-2], JPEG[:8]+b'\xff\xff'+JPEG[10:], JPEG[:4]+b'\xff\xff'+JPEG[6:]):
            with self.assertRaises(APIError): decode_cover(dict(data=base64.b64encode(raw).decode()))
    def test_cover_dimensions_match_client_2048_limit(self):
        from gameshelf_server.accounts import decode_cover
        def image(width,height):
            raw=bytearray(JPEG); raw[7:9]=height.to_bytes(2,'big'); raw[9:11]=width.to_bytes(2,'big')
            return dict(data=base64.b64encode(raw).decode())
        self.assertTrue(decode_cover(image(2048,2048)))
        for width,height in ((2049,1),(1,2049),(3000,2000),(4096,4096)):
            with self.assertRaises(APIError) as e: decode_cover(image(width,height))
            self.assertEqual(e.exception.status,400)
    def test_setup_capability_is_hash_only_in_sqlite_and_database_links_rejected(self):
        self.app(); invitation=json.loads((self.s.state/'administrator-setup.json').read_text())
        values=[r['value'] for r in self.s.db.execute('SELECT value FROM settings')]
        self.assertNotIn(invitation['setupToken'],str(values))
        other=self.s.state.parent/'other'; other.mkdir()
        original=self.source/'original'; original.write_text('source bytes')
        (other/'gateway.sqlite3').symlink_to(original)
        with self.assertRaises((APIError,ValueError,OSError)): Service(other,None,[self.source])
        self.assertEqual(original.read_text(),'source bytes')
    def test_live_cli_account_creation_consumes_setup_capability(self):
        self.app(); self.s.create_user('cli-owner','private password',True)
        self.assertFalse((self.s.state/'administrator-setup.json').exists())
        self.assertIsNone(self.s.db.execute("SELECT value FROM settings WHERE key='setupDigest'").fetchone())

class PersistenceTests(unittest.TestCase):
    setUp=SetupTests.setUp
    app=SetupTests.app
    def test_metadata_and_private_cover_survive_restart_and_cover_replacement_is_atomic(self):
        app=self.app(); token=json.loads((self.s.state/'administrator-setup.json').read_text())['setupToken']
        login=app.dispatch('POST','/api/setup',dict(setupToken=token,username='owner',password='private password'),'')
        user=self.s.authenticate(login['token']); device=str(uuid.UUID(int=1)); game=str(uuid.UUID(int=2))
        self.s.personal_library(user,device,dict(expectedRevision=0,snapshot=snapshot()))
        first=self.s.personal_cover(user,device,game,dict(data=base64.b64encode(JPEG).decode()))
        with self.assertRaises(APIError): self.s.personal_cover(user,device,game,dict(data='bad'))
        self.assertEqual(self.s.personal_cover(user,device,game),first)
        # A second connection also exercises SQLite persistence, not Python caches.
        other=Service(self.s.state,None,[self.source]); self.addCleanup(other.close)
        self.assertEqual(other.personal_library(user,device)['revision'],1)
        self.assertEqual(other.personal_cover(user,device,game),first)
        self.assertEqual(other.authenticate(login['token'])['id'],user['id'])
    def test_large_integer_is_invalid_metadata_not_server_error(self):
        from gameshelf_server.accounts import validate_snapshot
        s=snapshot(); s['games'][0]['playtimeSeconds']=10**1000
        with self.assertRaises(APIError) as e: validate_snapshot(s)
        self.assertEqual(e.exception.status,400)
    def test_setup_over_http_and_duplicate_json_rejection(self):
        import threading
        from gameshelf_server.http_api import make_server
        server=make_server(self.s,'127.0.0.1',0,public_address='https://library.example:8787')
        self.addCleanup(server.server_close)
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        self.addCleanup(server.shutdown); self.server=server
        call=lambda *args,**kw:test_http.HTTPTests.call(self,*args,**kw)
        invitation=json.loads((self.s.state/'administrator-setup.json').read_text())
        self.assertTrue(call('GET','/api/server-info')[1]['setupRequired'])
        status,login,_=call('POST','/api/setup',dict(setupToken=invitation['setupToken'],username='owner',password='private password'))
        self.assertEqual(status,200); self.assertTrue(login['user']['admin'])
        self.assertFalse(call('GET','/api/server-info')[1]['setupRequired'])
        import http.client
        connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=5)
        self.addCleanup(connection.close)
        connection.request('POST','/api/login',b'{"username":"owner","username":"other","password":"private password"}',{'Content-Type':'application/json'})
        response=connection.getresponse(); response.read(); self.assertEqual(response.status,400)

class ConfigurationTests(unittest.TestCase):
    setUp=SetupTests.setUp
    app=SetupTests.app
    def test_removing_public_address_disables_previous_setup_capability(self):
        self.app(); token=json.loads((self.s.state/'administrator-setup.json').read_text())['setupToken']
        unconfigured=Application(self.s)
        with self.assertRaises(APIError) as e:
            unconfigured.dispatch('POST','/api/setup',dict(setupToken=token,username='owner',password='private password'),'')
        self.assertEqual(e.exception.status,403)
        self.assertFalse((self.s.state/'administrator-setup.json').exists())
    def test_accounts_helpers_are_importable_without_prior_service_import(self):
        import os, subprocess, sys
        result=subprocess.run([sys.executable,'-c','from gameshelf_server.accounts import validate_snapshot; validate_snapshot(dict(version=1,games=[],collections=[]))'],
                              capture_output=True,env=os.environ.copy(),timeout=5)
        self.assertEqual(result.returncode,0,result.stderr.decode())
