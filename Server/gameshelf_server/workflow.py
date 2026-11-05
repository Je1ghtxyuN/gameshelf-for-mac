"""Selected scan handoff and account credentials; no client filesystem authority."""
import hashlib
import hmac
import json
from pathlib import Path
import secrets
from .common import APIError, locked, text
from .accounts import fields, utf8_text

class SharedWorkflow:
    @locked
    def change_password(self,user,data,target=None):
        own=target is None
        fields(data,('oldPassword','newPassword') if own else ('password',))
        target=user['id'] if own else target
        if not own and (not user['admin'] or target==user['id']):
            raise APIError(400 if user['admin'] else 403,'Use account password change for your own account')
        row=self.db.execute('SELECT * FROM users WHERE id=? AND disabled=0',(target,)).fetchone()
        if not row: raise APIError(404,'Account not found')
        if own:
            old=data['oldPassword'];utf8_text(old,1024)
            digest=hashlib.pbkdf2_hmac('sha256',old.encode(),bytes.fromhex(row['salt']),600000).hex()
            if not hmac.compare_digest(digest,row['password']): raise APIError(401,'Current password is incorrect')
        password=data['newPassword'] if own else data['password']
        utf8_text(password,1024)
        if len(password)<12: raise APIError(400,'Use a password of at least 12 characters')
        if self.db.execute("SELECT 1 FROM leases WHERE user_id=? AND status!='closed'",(target,)).fetchone():
            raise APIError(409,'Save and quit running games before changing the password')
        salt=secrets.token_hex(16)
        digest=hashlib.pbkdf2_hmac('sha256',password.encode(),bytes.fromhex(salt),600000).hex()
        self.db.execute('BEGIN IMMEDIATE')
        try:
            self.db.execute('UPDATE users SET salt=?,password=? WHERE id=?',(salt,digest,target))
            self.db.execute('DELETE FROM tokens WHERE user_id=?',(target,))
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK');raise
        return {}

    def register_selected(self,root_id,data,*,authorize):
        fields(data,('games',))
        games=data['games']
        if not isinstance(games,list) or not 1<=len(games)<=200: raise APIError(400,'Select 1 to 200 games')
        parsed=[]
        for game in games:
            fields(game,('relative','entryPath'))
            relative=text(game['relative'],4096);entry=text(game['entryPath'],4096)
            for value in (relative,entry):
                if value!='.' and (Path(value).is_absolute() or '\\' in value or ':' in value or any(p in ('','..','.') for p in value.split('/'))):
                    raise APIError(400,'Expected a confined relative path')
            if relative in [p[0] for p in parsed]: raise APIError(400,'Invalid or duplicate selected game')
            parsed.append((relative,entry))
        if not self.scan_lock.acquire(blocking=False): raise APIError(409,'Another scan is running')
        try:
            authorize();root=self._root(root_id)
            from .service import clean_path,tree_signature,uid
            from .discovery import discover
            from .privacy import detect_rules
            records=[]
            for relative,entry in parsed:
                folder=clean_path(root/relative)
                if folder!=root and root not in folder.parents: raise APIError(400,'Game escapes configured root')
                if not folder.is_dir(): raise APIError(404,'Selected game is unavailable on this server')
                if (folder/'.gameshelf-profile').exists() or (folder/'.gameshelf-profile').is_symlink(): raise APIError(400,'Reserved profile path')
                try:
                    nodes=list(folder.iterdir())
                    if len(nodes)>10000: raise APIError(400,'Too many directory entries')
                    entries,_=discover(folder,[p.name for p in nodes if p.is_dir() and not p.is_symlink()],[p.name for p in nodes if p.is_file() and not p.is_symlink()])
                    if entry=='.' and folder.suffix.lower()=='.app' and (folder/'Contents/Info.plist').is_file():
                        known=('Contents/Resources/autorun/renpy','Contents/Resources/renpy','Contents/Resources/app/renpy')
                        app_engine='renpy' if any((folder/p).is_dir() for p in known) else 'macOS'
                        entries=[dict(path='.',backend='native',engine=app_engine)]
                    if not any(e['path']==entry for e in entries): raise APIError(400,'Selected entry is not a game launcher on this server')
                    entries.sort(key=lambda value:value['path']!=entry)
                    title=folder.parent.name if folder.name.lower() in {'windows','win','win32','win64','pc','mac','macos','osx'} else folder.name
                    records.append((relative,title,json.dumps(entries),tree_signature(folder),json.dumps(detect_rules(folder))))
                except OSError: raise APIError(503,'Selected game cannot be read') from None
            with self.lock:
                authorize()
                current=self.db.execute('SELECT path FROM roots WHERE id=?',(root_id,)).fetchone()
                if not current or current['path']!=str(root): raise APIError(409,'Root changed')
                self.db.execute('BEGIN IMMEDIATE');ids=[]
                try:
                    for relative,title,entries,signature,saves in records:
                        old=self.db.execute('SELECT id FROM candidates WHERE root_id=? AND relative=?',(root_id,relative)).fetchone();key=old[0] if old else uid();ids.append(key)
                        self.db.execute('''INSERT INTO candidates(id,root_id,relative,title,entries,signature,available,save_paths) VALUES (?,?,?,?,?,?,1,?) ON CONFLICT(root_id,relative) DO UPDATE SET title=excluded.title,entries=excluded.entries,signature=excluded.signature,available=1,save_paths=excluded.save_paths''',(key,root_id,relative,title,entries,signature,saves))
                    self.db.execute('COMMIT')
                except BaseException:self.db.execute('ROLLBACK');raise
                return dict(candidates=[r for r in self.candidates() if r['id'] in ids])
        finally:self.scan_lock.release()
