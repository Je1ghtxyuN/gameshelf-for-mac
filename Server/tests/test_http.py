import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest

from test_service import FakeDriver

AVAILABLE = importlib.util.find_spec('gameshelf_server.http_api') is not None

class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(AVAILABLE, 'HTTP API must exist')
        from gameshelf_server.service import Service
        from gameshelf_server.http_api import make_server
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.source = base/'source'
        self.source.mkdir()
        (self.source/'Example').mkdir()
        (self.source/'Example'/'Play.exe').write_bytes(b'MZfixture')
        self.s = Service(base/'state', FakeDriver(base/'state'), [self.source])
        self.addCleanup(self.s.close)
        self.admin = self.s.create_user('owner', 'owner test password', True)
        self.user = self.s.create_user('player', 'player test password')
        self.server = make_server(self.s, '127.0.0.1', 0)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.shutdown)
        self.owner_token = self.call('POST','/api/login',dict(username='owner',password='owner test password'))[1]['token']
        self.token = self.call('POST','/api/login',dict(username='player',password='player test password'))[1]['token']
    def call(self, method, path, body=None, token=None, extra=None):
        c = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        headers = {'Content-Type':'application/json'}
        if token:
            headers['Authorization'] = 'Bearer '+token
        headers.update(extra or {})
        c.request(method, path, json.dumps(body).encode() if body is not None else None, headers)
        r = c.getresponse()
        data = r.read()
        status, response_headers = r.status, dict(r.getheaders())
        c.close()
        return status, json.loads(data) if data and 'application/json' in response_headers.get('Content-Type','') else data, response_headers
    def test_swift_contract_full_admin_publish_grant_session_lifecycle(self):
        status, login, _ = self.call('POST','/api/login',dict(username='player',password='player test password'))
        self.assertEqual(status,200)
        self.assertEqual(set(login['user']), {'id','username','admin'})
        self.assertIsInstance(login['expiresAt'],float)
        a = self.owner_token
        status, root, _ = self.call('POST','/api/admin/roots',dict(path=str(self.source),title='Library'),a)
        self.assertEqual(status,200)
        self.assertEqual(self.call('POST',f'/api/admin/roots/{root["id"]}/scan',{},a)[0],200)
        self.assertEqual(self.call('GET','/api/catalog',token=self.token)[1],{'games':[]})
        candidate = self.call('GET','/api/admin/candidates',token=a)[1]['candidates'][0]
        status, game, _ = self.call('POST',f'/api/admin/candidates/{candidate["id"]}/publish',{},a)
        self.assertEqual(status,200)
        self.assertEqual(self.call('GET','/api/admin/games',token=a)[1]['games'],[game])
        self.assertEqual(self.call('POST','/api/admin/grants',dict(userID=self.user['id'],gameID=game['id'],allowed=True),a)[0],200)
        self.assertEqual(self.call('GET','/api/catalog',token=self.token)[1],{'games':[game]})
        status, lease, _ = self.call('POST',f'/api/games/{game["id"]}/session',dict(deviceID='mac'),self.token)
        self.assertEqual(status,200)
        self.assertEqual(set(lease['share']),{'host','port','name','username','password'})
        self.assertEqual(lease['userID'],self.user['id'])
        self.assertEqual(lease['serverID'],login['serverID'])
        self.assertIsInstance(lease['expiresAt'],float)
        self.assertEqual(self.call('POST',f'/api/sessions/{lease["leaseID"]}/heartbeat',{},self.token)[0],200)
        self.assertEqual(self.call('DELETE',f'/api/sessions/{lease["leaseID"]}',token=self.token)[0],200)
        self.assertEqual(self.call('POST','/api/logout',{},self.token)[0],200)
        self.assertEqual(self.call('GET','/api/catalog',token=self.token)[0],401)
    def test_admin_auth_validation_no_cors_or_details(self):
        self.assertEqual(self.call('GET','/api/catalog')[0],401)
        for path in ('roots','users','grants','candidates','games'):
            self.assertEqual(self.call('GET','/api/admin/'+path,token=self.token)[0],403)
        for body in ([],{}, {'username':'new','password':'short'}, {'username':{},'password':'long password'}, {'username':'new','password':'long password','admin':'false'}):
            self.assertEqual(self.call('POST','/api/admin/users',body,self.owner_token)[0],400)
        status, data, headers = self.call('POST','/api/login',{'username':'player','password':'player test password'}, extra={'Origin':'https://evil.invalid'})
        self.assertEqual(status,403)
        self.assertNotIn('Access-Control-Allow-Origin',headers)
        self.assertNotIn(str(self.source),str(data))
        self.assertEqual(self.call('GET','/api/../admin/roots',token=self.token)[0],400)
        self.assertEqual(self.call('GET','/api/%2e%2e/admin/roots',token=self.token)[0],400)
    def test_public_server_identity_needs_no_credentials_and_exposes_no_library(self):
        self.s.display_name='Home library'
        status,info,headers=self.call('GET','/api/server-info')
        self.assertEqual(status,200)
        self.assertEqual(set(info),{'name','serverID','version','setupRequired'})
        self.assertEqual(info['name'],'Home library')
        self.assertEqual(info['serverID'],self.s.server_id)
        self.assertNotIn(str(self.source),json.dumps(info))
        self.assertNotIn(self.user['username'],json.dumps(info))
        self.assertNotIn('Access-Control-Allow-Origin',headers)
        self.assertEqual(self.call('GET','/api/catalog')[0],401)
    def test_admin_ui_and_password_not_persisted_in_browser(self):
        status, html, headers = self.call('GET','/')
        self.assertEqual(status,200)
        self.assertIn(b'GameShelf',html)
        self.assertIn("default-src 'self'",headers['Content-Security-Policy'])
        self.assertEqual(headers['Cache-Control'],'no-store')
        status, js, _ = self.call('GET','/admin.js')
        self.assertEqual(status,200)
        self.assertNotIn(b'localStorage',js)
        self.assertNotIn(b'innerHTML',js)
    def test_tls_required_before_bind_off_loopback(self):
        from gameshelf_server.http_api import make_server
        with self.assertRaises(ValueError):
            make_server(self.s, '0.0.0.0', 0)
    def test_oversized_invalid_json_and_login_rate_limit(self):
        self.assertEqual(self.call('POST','/api/login',{'password':'x'*17000})[0],413)
        self.assertEqual(self.call('POST','/api/login',{},extra={'Content-Type':'text/plain'})[0],415)
        self.server.application.login_limit = 2
        self.server.application.login_attempts.clear()
        self.assertEqual(self.call('POST','/api/login',{'username':'player','password':'wrong'})[0],401)
        self.assertEqual(self.call('POST','/api/login',{'username':'player','password':'wrong'})[0],401)
        self.assertEqual(self.call('POST','/api/login',{'username':'player','password':'wrong'})[0],429)

    def test_tls_uses_own_cert_and_verified_client_trust(self):
        import hashlib, shutil, ssl, subprocess
        from gameshelf_server.http_api import make_server
        from gameshelf_server.__main__ import cert_fingerprint
        if not shutil.which('openssl'):
            self.skipTest('openssl needed to generate ephemeral TLS fixture')
        base=Path(self.tmp.name); cert=base/'server.crt'; key=base/'server.key'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                        '-keyout',str(key),'-out',str(cert),'-subj','/CN=localhost',
                        '-addext','subjectAltName=IP:127.0.0.1,DNS:localhost'],
                       check=True,capture_output=True,timeout=20)
        tls=make_server(self.s,'127.0.0.1',0,cert=str(cert),key=str(key))
        thread=threading.Thread(target=tls.serve_forever,daemon=True); thread.start()
        try:
            connection=http.client.HTTPSConnection('127.0.0.1',tls.server_port,timeout=5)
            try:
                with self.assertRaises(ssl.SSLCertVerificationError):
                    connection.request('GET','/')
            finally:
                connection.close()
            context=ssl.create_default_context(cafile=str(cert))
            connection=http.client.HTTPSConnection('127.0.0.1',tls.server_port,context=context,timeout=5)
            connection.request('GET','/')
            response=connection.getresponse()
            self.assertEqual(response.status,200)
            self.assertEqual(response.getheader('Strict-Transport-Security'),'max-age=31536000')
            response.read(); connection.close()
            der=subprocess.run(['openssl','x509','-in',str(cert),'-outform','DER'],capture_output=True,check=True).stdout
            self.assertEqual(cert_fingerprint(cert),hashlib.sha256(der).hexdigest())
        finally:
            tls.shutdown(); tls.server_close(); thread.join()
    def test_http_scan_route_releases_authority_during_filesystem_walk(self):
        from concurrent.futures import ThreadPoolExecutor, TimeoutError
        from unittest.mock import patch
        import os
        root=self.s.add_root(str(self.source),'source'); self.s.scan(root['id'])
        game=self.s.publish(self.s.candidates()[0]['id'])
        self.s.grant(self.user['id'],game['id'],True)
        lease=self.call('POST',f'/api/games/{game["id"]}/session',dict(deviceID='mac'),self.token)[1]
        entered=threading.Event(); unblock=threading.Event(); actual=os.walk
        def blocked(root,*args,**kw):
            if Path(root)==self.source:
                entered.set(); unblock.wait(4)
            yield from actual(root,*args,**kw)
        with ThreadPoolExecutor(max_workers=2) as pool, patch('gameshelf_server.service.os.walk',blocked):
            scan=pool.submit(self.call,'POST',f'/api/admin/roots/{root["id"]}/scan',{},self.owner_token)
            try:
                self.assertTrue(entered.wait(1))
                heartbeat=pool.submit(self.call,'POST',f'/api/sessions/{lease["leaseID"]}/heartbeat',{},self.token)
                self.assertEqual(heartbeat.result(timeout=1)[0],200)
            finally:
                unblock.set(); self.assertEqual(scan.result(timeout=4)[0],200)
    def test_admin_invitation_is_public_only_and_ignores_request_host(self):
        from gameshelf_server.http_api import Application
        app=Application(self.s,public_address='https://games.example.invalid:8787/',certificate_sha256='AB'*32)
        self.server.application=app
        self.s.display_name='Family library'
        status,invitation,headers=self.call('GET','/api/admin/invitation',token=self.owner_token,
                                          extra={'Host':'attacker.invalid','X-Forwarded-Host':'attacker.invalid','X-Forwarded-Proto':'http'})
        self.assertEqual(status,200)
        self.assertEqual(invitation,dict(version=1,address='https://games.example.invalid:8787',
                                        name='Family library',certificateSHA256='ab'*32))
        self.assertLessEqual(len(json.dumps(invitation).encode()),4096)
        self.assertEqual(headers['Content-Disposition'],'attachment; filename="gameshelf-invitation.json"')
        self.assertEqual(headers['Cache-Control'],'no-store')
        for secret in (self.owner_token,self.token,str(self.source),self.admin['id'],self.s.server_id):
            self.assertNotIn(secret,json.dumps(invitation))
        self.assertEqual(self.call('GET','/api/admin/invitation')[0],401)
        self.assertEqual(self.call('GET','/api/admin/invitation',token=self.token)[0],403)
    def test_invitation_optional_pin_missing_config_and_invalid_config_fail_closed(self):
        app=self.server.application
        self.assertEqual(self.call('GET','/api/admin/invitation',token=self.owner_token)[0],503)
        app.public_address='https://games.example.invalid:8787'
        status,invitation,_=self.call('GET','/api/admin/invitation',token=self.owner_token)
        self.assertEqual(status,200)
        self.assertEqual(set(invitation),{'version','address','name'})
        app.public_address='https://user:secret@games.example.invalid'
        status,result,_=self.call('GET','/api/admin/invitation',token=self.owner_token)
        self.assertEqual(status,503)
        self.assertNotIn('secret',json.dumps(result))
    def test_invitation_download_button_is_available_in_admin_toolbar(self):
        self.assertIn(b'id="download-invitation"',self.call('GET','/')[1])
if __name__ == '__main__':
    unittest.main()
