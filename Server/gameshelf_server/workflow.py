"""Selected scan handoff and account credentials; no client filesystem authority."""
import hashlib
import hmac
import json
import os
import re
import stat
import unicodedata
from pathlib import Path
import secrets
from .common import APIError, locked, text
from .accounts import fields, utf8_text

def _canonical_relative(root, value, *, directory=False):
    """Resolve unique NFC-equivalent names, retaining bytes on disk, never links."""
    value = text(value, 4096)
    if value != '.' and (Path(value).is_absolute() or any(c in value for c in '\\:') or
                         any(part in ('', '.', '..') for part in value.split('/'))):
        raise APIError(400, 'Expected a confined relative path')
    parts = () if value == '.' else value.split('/')
    descriptor = None
    actual = []
    try:
        descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        for part in root.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        for index, part in enumerate(parts):
            key = unicodedata.normalize('NFC', part)
            matches = []
            with os.scandir(descriptor) as items:
                for count, item in enumerate(items, 1):
                    if count > 10000:
                        raise APIError(400, 'Too many directory entries')
                    if unicodedata.normalize('NFC', item.name) == key:
                        matches.append(item.name)
                        # Even an exact spelling cannot select between distinct
                        # canonically equivalent names in a case-sensitive NAS.
                        if len(matches) > 1:
                            raise APIError(409, 'Ambiguous Unicode path component')
            if not matches:
                raise APIError(404, 'Selected path is unavailable on this server')
            name = matches[0]
            info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):
                raise APIError(400, 'Symlink roots are not allowed')
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise APIError(400, 'Selected path contains a special file')
            need_directory = directory or index < len(parts)-1
            if need_directory and not stat.S_ISDIR(info.st_mode):
                raise APIError(404, 'Selected directory is unavailable on this server')
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
            if need_directory:
                flags |= os.O_DIRECTORY
            child = os.open(name, flags, dir_fd=descriptor)
            opened = os.fstat(child)
            if (info.st_dev, info.st_ino, info.st_mode) != (opened.st_dev, opened.st_ino, opened.st_mode):
                os.close(child)
                raise APIError(409, 'Selected path changed')
            os.close(descriptor)
            descriptor = child
            actual.append(name)
        return '/'.join(actual) if actual else '.'
    except FileNotFoundError:
        raise APIError(404, 'Selected path is unavailable on this server') from None
    except OSError:
        raise APIError(400, 'Selected path cannot be read without following links') from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _entry_sha256(folder, selected):
    """Bounded full-file proof; no writes, no symlinks, no authority lock."""
    entry = selected['path']
    target = folder if entry == '.' else folder/entry
    if selected['backend'] == 'native' and target.suffix.lower() == '.app':
        parts = (() if entry == '.' else Path(entry).parts) + ('Contents', 'Info.plist')
        limit = 1024 * 1024
    else:
        parts = Path(entry).parts
        limit = 128 * 1024 * 1024
    descriptor = None
    file = None
    try:
        descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        # Reopen ancestors relative to descriptors; resolving a link and then
        # inspecting its target would not meet the no-follow contract.
        for part in folder.parts[1:] + parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        if not parts:
            raise APIError(400, 'Entry fingerprint requires a regular file')
        file = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=descriptor)
        before = os.fstat(file)
        if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= limit:
            raise APIError(400, 'Entry fingerprint file type or size is unsupported')
        digest = hashlib.sha256()
        count = 0
        while True:
            block = os.read(file, min(1024 * 1024, limit + 1 - count))
            if not block:
                break
            count += len(block)
            if count > limit:
                raise APIError(400, 'Entry fingerprint file exceeds its limit')
            digest.update(block)
        after = os.fstat(file)
        identity = lambda st: (st.st_dev, st.st_ino, st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        named = os.stat(parts[-1], dir_fd=descriptor, follow_symlinks=False)
        if count != before.st_size or identity(before) != identity(after) or identity(before) != identity(named):
            raise APIError(412, 'Entry changed during fingerprint verification')
        return digest.hexdigest()
    except OSError:
        raise APIError(400, 'Entry fingerprint cannot read a regular unlinked file') from None
    finally:
        if file is not None:
            os.close(file)
        if descriptor is not None:
            os.close(descriptor)


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
            fields(game,('relative','entryPath'),('entrySHA256',))
            relative=text(game['relative'],4096);entry=text(game['entryPath'],4096)
            for value in (relative,entry):
                if value!='.' and (Path(value).is_absolute() or '\\' in value or ':' in value or any(p in ('','..','.') for p in value.split('/'))):
                    raise APIError(400,'Expected a confined relative path')
            if relative in [p[0] for p in parsed]: raise APIError(400,'Invalid or duplicate selected game')
            fingerprint = game.get('entrySHA256')
            if 'entrySHA256' in game and (not isinstance(fingerprint,str) or not re.fullmatch(r'[0-9a-f]{64}',fingerprint)):
                raise APIError(400,'entrySHA256 must be 64 lowercase hexadecimal characters')
            parsed.append((relative,entry,fingerprint))
        if not self.scan_lock.acquire(blocking=False): raise APIError(409,'Another scan is running')
        try:
            authorize();root=self._root(root_id)
            from .service import clean_path,tree_signature,uid
            from .discovery import discover
            from .privacy import detect_rules
            records=[]
            resolved = set()
            for relative,entry,fingerprint in parsed:
                relative = _canonical_relative(root, relative, directory=True)
                if relative in resolved:
                    raise APIError(409, 'Ambiguous Unicode path component')
                resolved.add(relative)
                folder=clean_path(root/relative)
                if folder!=root and root not in folder.parents: raise APIError(400,'Game escapes configured root')
                if not folder.is_dir(): raise APIError(404,'Selected game is unavailable on this server')
                if (folder/'.gameshelf-profile').exists() or (folder/'.gameshelf-profile').is_symlink(): raise APIError(400,'Reserved profile path')
                entry = _canonical_relative(folder, entry)
                try:
                    nodes=list(folder.iterdir())
                    if len(nodes)>10000: raise APIError(400,'Too many directory entries')
                    entries,_=discover(folder,[p.name for p in nodes if p.is_dir() and not p.is_symlink()],[p.name for p in nodes if p.is_file() and not p.is_symlink()])
                    if entry=='.' and folder.suffix.lower()=='.app' and (folder/'Contents/Info.plist').is_file():
                        known=('Contents/Resources/autorun/renpy','Contents/Resources/renpy','Contents/Resources/app/renpy')
                        app_engine='renpy' if any((folder/p).is_dir() for p in known) else 'macOS'
                        entries=[dict(path='.',backend='native',engine=app_engine)]
                    selected = next((e for e in entries if e['path']==entry), None)
                    if selected is None: raise APIError(400,'Selected entry is not a game launcher on this server')
                    if fingerprint is not None and not hmac.compare_digest(_entry_sha256(folder,selected),fingerprint):
                        raise APIError(412,'Selected entry fingerprint does not match')
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
                return dict(candidates=[r for r in self.candidates() if r['id'] in ids],
                            entryFingerprintsVerified=all(fingerprint is not None for _,_,fingerprint in parsed))
        finally:self.scan_lock.release()
