import unittest
from test_http import HTTPTests

class SharedWorkflowTests(unittest.TestCase):
    setUp=HTTPTests.setUp
    call=HTTPTests.call
    def root(self):
        return self.call('POST','/api/admin/roots',{'path':str(self.source),'title':'Library'},self.owner_token)[1]
    def test_selected_registration_uses_cached_paths_not_full_scan_and_cannot_publish(self):
        root=self.root()
        # Unrelated folders are never walked; only the selected known directory is probed.
        (self.source/'Other').mkdir();(self.source/'Other'/'Play.exe').write_bytes(b'MZfixture')
        route='/api/admin/roots/'+root['id']+'/candidates'
        status,value,_=self.call('POST',route,{'games':[{'relative':'Example','entryPath':'Play.exe'}]},self.owner_token)
        self.assertEqual(status,200);self.assertEqual(len(value['candidates']),1)
        candidate=value['candidates'][0];self.assertEqual(candidate['relative'],'Example');self.assertEqual(candidate['entries'][0]['path'],'Play.exe')
        self.assertEqual(self.call('GET','/api/admin/games',token=self.owner_token)[1]['games'],[])
        again=self.call('POST',route,{'games':[{'relative':'Example','entryPath':'Play.exe'}]},self.owner_token)[1]
        self.assertEqual(candidate['id'],again['candidates'][0]['id'])
        self.assertEqual(len(self.s.candidates()),1)
    def test_registration_confines_paths_rechecks_entry_and_admin_and_is_atomic(self):
        root=self.root();route='/api/admin/roots/'+root['id']+'/candidates'
        body={'games':[{'relative':'Example','entryPath':'Play.exe'}]}
        self.assertEqual(self.call('POST',route,body,self.token)[0],403)
        for bad in ['../outside','/absolute','Example/../Other','Example\\x']:
            self.assertEqual(self.call('POST',route,{'games':[{'relative':bad,'entryPath':'Play.exe'}]},self.owner_token)[0],400)
        (self.source/'Example'/'custom_CN.exe').write_bytes(b'MZfixture')
        self.assertEqual(self.call('POST',route,{'games':[{'relative':'Example','entryPath':'custom_CN.exe'}]},self.owner_token)[0],400)
        self.assertEqual(self.s.candidates(),[])
        body['games'].append({'relative':'Missing','entryPath':'Game.exe'})
        self.assertNotEqual(self.call('POST',route,body,self.owner_token)[0],200)
        self.assertEqual(self.s.candidates(),[])
    def test_own_password_change_old_password_tokens_and_identity(self):
        before=self.s.users()
        self.assertEqual(self.call('POST','/api/account/password',{'oldPassword':'wrong password','newPassword':'new player password'},self.token)[0],401)
        self.assertEqual(self.call('GET','/api/catalog',token=self.token)[0],200)
        self.assertEqual(self.call('POST','/api/account/password',{'oldPassword':'player test password','newPassword':'short'},self.token)[0],400)
        status,_,_=self.call('POST','/api/account/password',{'oldPassword':'player test password','newPassword':'new player password'},self.token)
        self.assertEqual(status,200);self.assertEqual(self.s.users(),before)
        self.assertEqual(self.call('GET','/api/catalog',token=self.token)[0],401)
        self.assertEqual(self.call('POST','/api/login',{'username':'player','password':'player test password'})[0],401)
        status,login,_=self.call('POST','/api/login',{'username':'player','password':'new player password'})
        self.assertEqual(status,200);self.assertEqual(login['user']['id'],self.user['id'])
    def test_admin_reset_only_others_and_preserves_grants_and_private_metadata(self):
        root=self.root();self.s.scan(root['id']);game=self.s.publish(self.s.candidates()[0]['id']);self.s.grant(self.user['id'],game['id'],True)
        route='/api/admin/users/'+self.user['id']+'/password';before=self.s.grants()
        self.assertEqual(self.call('POST',route,{'password':'another player password'},self.token)[0],403)
        self.assertEqual(self.call('POST','/api/admin/users/'+self.admin['id']+'/password',{'password':'another owner password'},self.owner_token)[0],400)
        self.assertEqual(self.call('POST',route,{'password':'another player password'},self.owner_token)[0],200)
        self.assertEqual(self.s.grants(),before);self.assertEqual(self.call('GET','/api/catalog',token=self.owner_token)[0],200)
        self.assertEqual(self.call('GET','/api/catalog',token=self.token)[0],401)
        status,login,_=self.call('POST','/api/login',{'username':'player','password':'another player password'});self.assertEqual(status,200)
        self.assertEqual(self.call('GET','/api/catalog',token=login['token'])[1]['games'][0]['id'],game['id'])
    def test_password_change_refuses_active_game_without_revoking_or_losing_saves(self):
        root=self.root();self.s.scan(root['id']);game=self.s.publish(self.s.candidates()[0]['id']);self.s.grant(self.user['id'],game['id'],True)
        lease=self.s.session(self.s.authenticate(self.token),game['id'],'fixture',token=self.token)
        status,_,_=self.call('POST','/api/account/password',{'oldPassword':'player test password','newPassword':'new player password'},self.token)
        self.assertEqual(status,409);self.assertEqual(self.call('GET','/api/catalog',token=self.token)[0],200)
        self.assertEqual(self.call('POST','/api/admin/users/'+self.user['id']+'/password',{'password':'new player password'},self.owner_token)[0],409)
        self.s.release(self.s.authenticate(self.token),lease['leaseID'])

    def test_selected_native_bundle_and_symlink_rejection(self):
        root=self.root();app=self.source/'Novel.app';(app/'Contents/Resources/autorun/renpy').mkdir(parents=True);(app/'Contents/Info.plist').write_text('fixture')
        route='/api/admin/roots/'+root['id']+'/candidates'
        status,result,_=self.call('POST',route,{'games':[{'relative':'Novel.app','entryPath':'.'}]},self.owner_token)
        self.assertEqual(status,200);self.assertEqual(result['candidates'][0]['entries'],[{'path':'.','backend':'native','engine':'renpy'}])
        (self.source/'Linked').symlink_to(self.source/'Example',target_is_directory=True)
        self.assertEqual(self.call('POST',route,{'games':[{'relative':'Linked','entryPath':'Play.exe'}]},self.owner_token)[0],400)
