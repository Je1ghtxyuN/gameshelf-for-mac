"""Explicit disposable-container integration; never runs in the default suite.

Requires an empty dedicated ext4 state mount and no host-network or SMB mappings.
See README. No production source or save is used, even when enabled.
"""
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

ENABLED = os.environ.get('GAMESHELF_LINUX_TESTS') == '1'

@unittest.skipUnless(ENABLED and sys.platform=='linux','opt-in isolated Linux mount/SMB test')
class LinuxIntegrationTests(unittest.TestCase):
    def test_real_overlay_smb_api_seed_privacy_copyup_and_revocation_barrier(self):
        from gameshelf_server.driver import LinuxDriver, run, is_mountpoint
        from gameshelf_server.http_api import make_server
        from gameshelf_server.service import Service
        self.assertEqual(os.environ.get('GAMESHELF_CONTAINER'),'1','Use only the supplied disposable container')
        self.assertEqual(os.geteuid(),0)
        scratch=Path(os.environ['GAMESHELF_INTEGRATION_DIR']).resolve()
        self.assertTrue(scratch.stat().st_mode & 0o001,'Dedicated test root and ancestors must allow uid traversal (0711)')
        self.assertEqual(run(['findmnt','-n','-o','FSTYPE','--target',str(scratch)]).stdout.strip(),'ext4')
        base=Path(tempfile.mkdtemp(prefix='gameshelf-fixture-',dir=scratch))
        base.chmod(0o711)
        rw=base/'fixture'; ro=base/'source'; state=base/'private-state'
        rw.mkdir(); ro.mkdir()
        novel=rw/'Novel'; novel.mkdir()
        (novel/'game'/'saves').mkdir(parents=True)
        for p,data in [('Game.exe',b'MZfixture program'),('Actors.rvdata2',b'asset'),
                       ('Save01.rvdata2',b'OWNER PROGRESS'),('game/saves/persistent',b'OWNER RENPY')]:
            (novel/p).write_bytes(data)
        (novel/'asset-link').symlink_to('Actors.rvdata2')
        before={p.relative_to(rw).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in rw.rglob('*') if p.is_file()}
        run(['mount','--bind',str(rw),str(ro)])
        run(['mount','-o','remount,bind,ro,nosuid,nodev,noexec',str(ro)])
        driver=None; service=None; server=None; server_thread=None
        try:
            driver=LinuxDriver(state,'127.0.0.1',445)
            driver.validate([ro]); driver.start()
            service=Service(state,driver,[ro])
            owner_password=secrets.token_urlsafe(24)
            service.create_user('owner',owner_password,True)
            for name in ('alice','bob'):
                service.create_user(name,name+' fixture password')
            server=make_server(service,'127.0.0.1',0)
            server_thread=threading.Thread(target=server.serve_forever)
            server_thread.start()
            def api(method,path,body=None,token=None):
                connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=45)
                headers={'Content-Type':'application/json'}
                if token: headers['Authorization']='Bearer '+token
                connection.request(method,path,json.dumps(body) if body is not None else None,headers)
                response=connection.getresponse(); payload=json.loads(response.read()); status=response.status
                connection.close(); return status,payload
            owner=api('POST','/api/login',dict(username='owner',password=owner_password))[1]['token']
            root=api('POST','/api/admin/roots',dict(path=str(ro),title='Fixture'),owner)[1]
            self.assertEqual(api('POST',f'/api/admin/roots/{root["id"]}/scan',{},owner)[0],200)
            c=api('GET','/api/admin/candidates',token=owner)[1]['candidates'][0]
            game=api('POST',f'/api/admin/candidates/{c["id"]}/publish',{},owner)[1]
            accounts={u['username']:u for u in api('GET','/api/admin/users',token=owner)[1]['users']}
            tokens={}; leases={}
            for name in ('alice','bob'):
                tokens[name]=api('POST','/api/login',dict(username=name,password=name+' fixture password'))[1]['token']
                self.assertEqual(api('GET','/api/catalog',token=tokens[name])[1]['games'],[])
                self.assertEqual(api('POST','/api/admin/grants',dict(userID=accounts[name]['id'],gameID=game['id'],allowed=True),owner)[0],200)
                status,leases[name]=api('POST',f'/api/games/{game["id"]}/session',dict(deviceID=name),tokens[name])
                self.assertEqual(status,200,'Workspace mount/export must succeed')
                row=dict(service.db.execute('SELECT * FROM leases WHERE id=?',(leases[name]['leaseID'],)).fetchone())
                options=run(['findmnt','-n','-o','OPTIONS','--target',str(driver.paths(row)['merged'])]).stdout
                self.assertIn('metacopy=on',options)
                self.assertNotIn('redirect_dir=off',options)
            def smb(lease,commands,ok=True,credentials=None):
                share=lease['share']; auth=base/'smb-auth'
                selected=credentials or share
                auth.write_text('username = '+selected['username']+'\npassword = '+selected['password']+'\n')
                auth.chmod(0o600)
                try:
                    result=subprocess.run(['smbclient','//127.0.0.1/'+share['name'],'-A',str(auth),
                        '--client-protection=encrypt','-m','SMB3','-c',commands],capture_output=True,text=True,timeout=30)
                finally:
                    auth.unlink(missing_ok=True)
                self.assertEqual(result.returncode==0,ok,'SMB operation success/denial mismatch (details intentionally redacted)')
            upload=base/'upload'; downloaded=base/'download'
            for name in ('alice','bob'):
                smb(leases[name],'get Save01.rvdata2 '+str(downloaded),ok=False)
                smb(leases[name],'get game/saves/persistent '+str(downloaded),ok=False)
                smb(leases[name],'get asset-link '+str(downloaded))
                self.assertEqual(downloaded.read_bytes(),b'asset')
                upload.write_text(name)
                smb(leases[name],'put '+str(upload)+' Save01.rvdata2; put '+str(upload)+' .gameshelf-profile/account.txt')
            smb(leases['bob'],'ls',credentials=leases['alice']['share'],ok=False)
            upload.write_text('private new')
            smb(leases['alice'],'put '+str(upload)+' new.save; rename new.save renamed.save; del Actors.rvdata2')
            smb(leases['bob'],'get Actors.rvdata2 '+str(downloaded))
            self.assertEqual(downloaded.read_bytes(),b'asset')
            # A live OS descriptor forces EBUSY after SMB credential/share revocation.
            a=leases['alice']; row=dict(service.db.execute('SELECT * FROM leases WHERE id=?',(a['leaseID'],)).fetchone())
            held=open(driver.paths(row)['merged']/'.gameshelf-profile'/'account.txt','rb')
            try:
                self.assertEqual(api('DELETE',f'/api/sessions/{a["leaseID"]}',token=tokens['alice'])[0],503)
                self.assertEqual(api('POST',f'/api/games/{game["id"]}/session',dict(deviceID='new'),tokens['alice'])[0],503)
            finally:
                held.close()
            status,new=api('POST',f'/api/games/{game["id"]}/session',dict(deviceID='new'),tokens['alice'])
            self.assertEqual(status,200)
            smb(a,'ls',ok=False)
            smb(new,'get Save01.rvdata2 '+str(downloaded))
            self.assertEqual(downloaded.read_text(),'alice')
            smb(new,'get .gameshelf-profile/account.txt '+str(downloaded))
            self.assertEqual(downloaded.read_text(),'alice')
            smb(leases['bob'],'get Save01.rvdata2 '+str(downloaded))
            self.assertEqual(downloaded.read_text(),'bob')
            after={p.relative_to(rw).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in rw.rglob('*') if p.is_file()}
            self.assertEqual(before,after)
            self.assertEqual(api('POST','/api/admin/grants',dict(userID=accounts['bob']['id'],gameID=game['id'],allowed=False),owner)[0],200)
            self.assertEqual(api('DELETE',f'/api/sessions/{new["leaseID"]}',token=tokens['alice'])[0],200)
            smb(leases['bob'],'ls',ok=False)
            driver.stop()
            self.assertIsNotNone(driver.process.poll())
            self.assertEqual(api('GET','/api/catalog',token=tokens['alice'])[0],200,'Stopping smbd must not signal the API/test process group')
        finally:
            original_failure=sys.exc_info()[0] is not None
            errors=[]
            def attempt(label,operation):
                try:
                    operation()
                except Exception as error:
                    # Never replace the original assertion/503 with a cleanup
                    # exception. Diagnostics contain operation/class only.
                    errors.append(label+': '+type(error).__name__)
            if server:
                attempt('HTTP shutdown',server.shutdown)
                attempt('HTTP close',server.server_close)
                attempt('HTTP join',server_thread.join)
            rows=[]
            if service:
                rows=list(service.db.execute('SELECT * FROM leases'))
                attempt('lease recovery',service.recover)
            if driver:
                attempt('isolated Samba stop',driver.stop)
            if service:
                attempt('database close',service.close)
            for row in rows:
                paths=driver.paths(dict(row))
                for key in ('merged','lower'):
                    if is_mountpoint(paths[key]):
                        attempt('normal '+key+' unmount',lambda p=paths[key]:run(['umount',str(p)]))
            if is_mountpoint(ro):
                attempt('normal fixture source unmount',lambda:run(['umount',str(ro)]))
            remaining=any(is_mountpoint(p) for row in rows for p in driver.paths(dict(row)).values()) if driver else False
            remaining=remaining or is_mountpoint(ro)
            if not remaining:
                attempt('scratch cleanup',lambda:shutil.rmtree(base))
            if errors:
                report='Integration cleanup diagnostics (primary failure preserved): '+', '.join(errors)
                if remaining:
                    report+='; test-owned mounts remain; scratch preserved'
                if original_failure:
                    print(report,file=sys.stderr)
                else:
                    self.fail(report)
