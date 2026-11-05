"""Single-process, serialized SQLite authority. No game bytes are written here."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import threading
import time
import uuid

from .common import APIError, locked, text

def uid():
    return uuid.uuid4().hex

def clean_path(value):
    value = text(str(value), 4096)
    p = Path(value)
    if not p.is_absolute() or '..' in p.parts or any(c in value for c in '\\,:\n\r'):
        raise APIError(400, 'Unsafe path')
    current = Path(p.anchor)
    for part in p.parts[1:]:
        current /= part
        if current.is_symlink():
            raise APIError(400, 'Symlink roots are not allowed')
    return p.resolve()

def overlaps(a, b):
    return a == b or a in b.parents or b in a.parents

def link_target(path, root, source_root=None):
    """Resolve chains strictly. Absolute lower links may be mapped into a view."""
    try:
        target = path.resolve(strict=True)
        if target == root or root in target.parents:
            mapped = target
        elif source_root is not None and (target == source_root or source_root in target.parents):
            mapped = root/target.relative_to(source_root)
        else:
            raise APIError(400, 'Game symlink escapes its directory')
        mode = target.stat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise APIError(400, 'Symlink targets a special file')
        return mapped
    except (OSError, RuntimeError):
        raise APIError(400, 'Broken or cyclic game symlink') from None

def tree_signature(root, limit=100000, source_root=None):
    """Read-only metadata signature and complete internal-link validation.

    Edition immutability is an administrator contract; this detects ordinary
    changes, not hostile host modifications preserving size/mtime/mode.
    """
    items = []
    def onerror(error):
        raise APIError(503, 'Game tree unavailable')
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=onerror):
        for name in sorted(dirs + files):
            p = Path(directory)/name
            st = p.lstat()
            target = None
            if stat.S_ISLNK(st.st_mode):
                link_target(p,root,source_root)
                target = os.readlink(p)
            elif not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
                raise APIError(400, 'Game contains special files')
            items.append((p.relative_to(root).as_posix(), st.st_size if stat.S_ISREG(st.st_mode) else 0,
                          st.st_mtime_ns, stat.S_IMODE(st.st_mode), target))
            if len(items) > limit:
                raise APIError(400, 'Game exceeds scan limit')
    return hashlib.sha256(json.dumps(sorted(items)).encode()).hexdigest()

from .accounts import AccountFeatures

class Service(AccountFeatures):
    def __init__(self, state, driver, allowed_sources, clock=time.time, token_ttl=86400, lease_ttl=90):
        self.state = clean_path(state)
        self.allowed = [clean_path(p) for p in allowed_sources]
        from .driver import mount_table, physical_overlap
        mounts=mount_table()
        if not self.allowed or any(overlaps(self.state, p) or physical_overlap(self.state,p,mounts) for p in self.allowed):
            raise APIError(400, 'Sources and writable state must be disjoint')
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.driver, self.clock = driver, clock
        self.token_ttl, self.lease_ttl = token_ttl, lease_ttl
        self.lock = threading.RLock()
        self.scan_lock = threading.Lock()
        self.driver_lock = threading.Lock()
        # State is gateway-owned. Reject linked DB/journal files before SQLite
        # can open them; no metadata path is derived from an API selector.
        for name in ('gateway.sqlite3','gateway.sqlite3-wal','gateway.sqlite3-shm','gateway.sqlite3-journal'):
            path=self.state/name
            try: info=path.lstat()
            except FileNotFoundError: continue
            if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:
                raise APIError(400,'Unsafe state database file')
        self.db = sqlite3.connect(self.state/'gateway.sqlite3', check_same_thread=False, isolation_level=None)
        os.chmod(self.state/'gateway.sqlite3', 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA foreign_keys=ON;
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL,
            salt TEXT NOT NULL, password TEXT NOT NULL, admin INTEGER NOT NULL, disabled INTEGER NOT NULL DEFAULT 0,
            uid INTEGER UNIQUE NOT NULL);
        CREATE TABLE IF NOT EXISTS tokens(digest TEXT PRIMARY KEY, user_id TEXT REFERENCES users(id), expires REAL);
        CREATE TABLE IF NOT EXISTS roots(id TEXT PRIMARY KEY, path TEXT UNIQUE, title TEXT);
        CREATE TABLE IF NOT EXISTS candidates(id TEXT PRIMARY KEY, root_id TEXT REFERENCES roots(id),
            relative TEXT, title TEXT, entries TEXT, signature TEXT, available INTEGER DEFAULT 1,
            UNIQUE(root_id, relative));
        CREATE TABLE IF NOT EXISTS games(id TEXT PRIMARY KEY, candidate_id TEXT, root_id TEXT REFERENCES roots(id),
            relative TEXT, title TEXT, entries TEXT, signature TEXT);
        CREATE TABLE IF NOT EXISTS grants(user_id TEXT REFERENCES users(id), game_id TEXT REFERENCES games(id),
            PRIMARY KEY(user_id,game_id));
        CREATE TABLE IF NOT EXISTS leases(id TEXT PRIMARY KEY, user_id TEXT REFERENCES users(id),
            game_id TEXT REFERENCES games(id), device TEXT, expires REAL, status TEXT);
        CREATE UNIQUE INDEX IF NOT EXISTS one_writer ON leases(user_id,game_id) WHERE status != 'closed';
        ''')
        # Additive schema migration: existing identities and private state stay intact.
        for table in ('candidates','games'):
            if 'save_paths' not in {r[1] for r in self.db.execute('PRAGMA table_info('+table+')')}:
                self.db.execute("ALTER TABLE "+table+" ADD COLUMN save_paths TEXT NOT NULL DEFAULT '[]'")
        if 'token_digest' not in {r[1] for r in self.db.execute('PRAGMA table_info(leases)')}:
            self.db.execute("ALTER TABLE leases ADD COLUMN token_digest TEXT NOT NULL DEFAULT ''")
        self.db.execute("INSERT OR IGNORE INTO settings VALUES ('serverID',?)", (uid(),))
        self.server_id = self.db.execute("SELECT value FROM settings WHERE key='serverID'").fetchone()[0]
        self.dummy_salt = secrets.token_hex(16)
        self.initialize_accounts()
    def _external(self,operation):
        """Run slow I/O without retaining ANY recursive authority lock levels.

        Condition.wait_for uses the public stdlib RLock release/restore protocol,
        including an HTTP authorization frame. Driver changes have their own
        serializer; heartbeat and account-state transactions remain independent.
        """
        condition=threading.Condition(self.lock)
        result={}
        def run_operation():
            try:
                result['value']=operation()
            except BaseException as error:
                result['error']=error
            finally:
                with condition:
                    result['done']=True
                    condition.notify()
        worker=threading.Thread(target=run_operation,name='gateway-io')
        worker.start()
        condition.wait_for(lambda:result.get('done',False))
        worker.join()
        if 'error' in result:
            raise result['error']
        return result.get('value')
    def _open_driver(self,lease,lower,user,rules):
        with self.driver_lock:
            return self.driver.open(lease,lower,user,save_paths=rules)
    def close(self):
        self.db.close()
    def _user(self, row):
        return dict(id=row['id'], username=row['username'], admin=bool(row['admin']), uid=row['uid'])
    @locked
    def create_user(self, username, password, admin=False):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', text(username, 64)):
            raise APIError(400, 'Invalid username')
        text(password, 1024)
        if len(password) < 12 or type(admin) is not bool:
            raise APIError(400, 'Use a password of at least 12 characters')
        salt = secrets.token_hex(16)
        digest = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), 600000).hex()
        account_id = uid()
        unix_uid = self.db.execute('SELECT COALESCE(MAX(uid),19999)+1 FROM users').fetchone()[0]
        try:
            self.db.execute('INSERT INTO users(id,username,salt,password,admin,uid) VALUES (?,?,?,?,?,?)',
                            (account_id, username, salt, digest, int(admin), unix_uid))
        except sqlite3.IntegrityError:
            raise APIError(409, 'Username already exists') from None
        if not self.db.in_transaction:
            self.db.execute("DELETE FROM settings WHERE key='setupDigest'")
            (self.state/'administrator-setup.json').unlink(missing_ok=True)
        return dict(id=account_id, username=username, admin=admin, uid=unix_uid)
    @locked
    def users(self):
        return [dict(self._user(r), disabled=bool(r['disabled'])) for r in self.db.execute('SELECT * FROM users')]
    @locked
    def login(self, username, password):
        text(username, 64)
        text(password, 1024)
        row = self.db.execute('SELECT * FROM users WHERE username=?', (username,)).fetchone()
        salt = row['salt'] if row else self.dummy_salt
        digest = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), 600000).hex()
        if not row or not hmac.compare_digest(digest, row['password']) or row['disabled']:
            raise APIError(401, 'Invalid credentials')
        token = secrets.token_urlsafe(32)
        expiry = float(self.clock()+self.token_ttl)
        self.db.execute('INSERT INTO tokens VALUES (?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), row['id'], expiry))
        user = self._user(row)
        user.pop('uid')
        return dict(token=token, expiresAt=expiry, user=user, serverID=self.server_id)
    @locked
    def authenticate(self, token):
        if not isinstance(token, str) or len(token) > 256:
            raise APIError(401, 'Authentication required')
        row = self.db.execute('SELECT users.* FROM users JOIN tokens ON user_id=users.id WHERE digest=? AND expires>? AND disabled=0',
                              (hashlib.sha256(token.encode()).hexdigest(), self.clock())).fetchone()
        if not row:
            raise APIError(401, 'Authentication required')
        return self._user(row)
    @locked
    def logout(self, token):
        user = self.authenticate(token)
        digest=hashlib.sha256(token.encode()).hexdigest()
        self.db.execute('DELETE FROM tokens WHERE digest=?',(digest,))
        self._close_matching("token_digest=?",(digest,))
    def _close_user(self,user_id):
        self._close_matching('user_id=?',(user_id,))
    def _close_matching(self,condition,params):
        failures=0
        for row in list(self.db.execute("SELECT * FROM leases WHERE status!='closed' AND "+condition,params)):
            try:
                self._revoke(row)
            except APIError:
                failures+=1
        if failures:
            raise APIError(503,'Share shutdown pending; retry later')
    @locked
    def disable_user(self, user_id):
        self.db.execute('UPDATE users SET disabled=1 WHERE id=?', (user_id,))
        self.db.execute('DELETE FROM tokens WHERE user_id=?', (user_id,))
        self._close_user(user_id)
    @locked
    def add_root(self, path, title):
        p = clean_path(path)
        if overlaps(p, self.state) or not any(p == r or r in p.parents for r in self.allowed) or not p.is_dir():
            raise APIError(400, 'Root must be within configured read-only sources')
        root_id = uid()
        try:
            self.db.execute('INSERT INTO roots VALUES (?,?,?)', (root_id, str(p), text(title)))
        except sqlite3.IntegrityError:
            raise APIError(409, 'Root already registered') from None
        return dict(id=root_id, title=title, path=str(p))
    @locked
    def roots(self):
        return [dict(r) for r in self.db.execute('SELECT * FROM roots')]
    def _root(self, root_id):
        with self.lock:
            row = self.db.execute('SELECT * FROM roots WHERE id=?', (root_id,)).fetchone()
        if not row:
            raise APIError(404, 'Root not found')
        p = clean_path(row['path'])
        if not any(p == a or a in p.parents for a in self.allowed) or overlaps(p, self.state):
            raise APIError(400, 'Root no longer allowed')
        if not p.is_dir():
            raise APIError(503, 'Source unavailable')
        return p
    def scan(self,root_id,*,authorize=None):
        if not self.scan_lock.acquire(blocking=False):
            raise APIError(409,'Another scan is running')
        try:
            return self._scan(root_id,authorize)
        finally:
            self.scan_lock.release()
    def _scan(self,root_id,authorize):
        with self.lock:
            if authorize:
                authorize()
            root=self._root(root_id)
        initial=root.stat()
        root_identity=(initial.st_dev,initial.st_ino,initial.st_mtime_ns)
        records,issues,visited=[],[],0
        from .discovery import discover
        from .privacy import detect_rules
        def scan_error(error):
            issues.append('A source directory became unreadable')
        for directory,dirs,files in os.walk(root,followlinks=False,onerror=scan_error):
            visited+=1
            if visited>50000:
                issues.append('Directory limit reached'); break
            d=Path(directory)
            if len(d.relative_to(root).parts)>32 or len(dirs)+len(files)>10000:
                dirs[:]=[]
                issues.append('Directory depth or entry limit reached'); continue
            try:
                entries,children=discover(d,dirs,files)
                dirs[:]=children
                if not entries:
                    continue
                if (d/'.gameshelf-profile').exists() or (d/'.gameshelf-profile').is_symlink():
                    raise APIError(400,'Reserved profile path exists in source')
                signature=tree_signature(d)
                save_paths=json.dumps(detect_rules(d))
                title=d.parent.name if d.name.lower() in {'windows','win','win32','win64','pc','mac','macos','osx'} else d.name
                records.append((d.relative_to(root).as_posix(),title,json.dumps(entries),signature,save_paths))
            except APIError as error:
                issues.append('Skipped '+d.relative_to(root).as_posix()+': '+error.message)
            except OSError:
                issues.append('Skipped unavailable candidate: '+d.relative_to(root).as_posix())
        # Filesystem operations are outside the authority lock, including the
        # final root identity check. Publication revalidates each game edition.
        current=clean_path(root).stat()
        if (current.st_dev,current.st_ino,current.st_mtime_ns)!=root_identity:
            raise APIError(409,'Source root changed during scan; retry')
        with self.lock:
            if authorize:
                authorize()
            row=self.db.execute('SELECT path FROM roots WHERE id=?',(root_id,)).fetchone()
            if not row or row['path']!=str(root):
                raise APIError(409,'Root registration changed during scan')
            found=[]
            self.db.execute('BEGIN IMMEDIATE')
            try:
                for relative,title,entries,signature,save_paths in records:
                    old=self.db.execute('SELECT id FROM candidates WHERE root_id=? AND relative=?',(root_id,relative)).fetchone()
                    candidate_id=old[0] if old else uid()
                    found.append(candidate_id)
                    self.db.execute("""INSERT INTO candidates(id,root_id,relative,title,entries,signature,available,save_paths)
                        VALUES (?,?,?,?,?,?,1,?) ON CONFLICT(root_id,relative) DO UPDATE SET
                        title=excluded.title,entries=excluded.entries,signature=excluded.signature,available=1,save_paths=excluded.save_paths""",
                        (candidate_id,root_id,relative,title,entries,signature,save_paths))
                if not issues:
                    found_set=set(found)
                    for row in list(self.db.execute('SELECT id FROM candidates WHERE root_id=?',(root_id,))):
                        if row['id'] not in found_set:
                            self.db.execute('UPDATE candidates SET available=0 WHERE id=?',(row['id'],))
                self.db.execute('COMMIT')
            except Exception:
                self.db.execute('ROLLBACK')
                raise
        return dict(complete=not issues,discovered=len(found),issues=issues)
    @locked
    def candidates(self):
        return [dict(dict(r), entries=json.loads(r['entries']), available=bool(r['available']),
                     detectedSavePaths=json.loads(r['save_paths']))
                for r in self.db.execute('SELECT * FROM candidates')]
    def _lower(self, row):
        root = self._root(row['root_id'])
        rel = Path(row['relative'])
        if rel.is_absolute() or '..' in rel.parts:
            raise APIError(400, 'Invalid relative path')
        lower = clean_path(root/rel)
        if lower != root and root not in lower.parents:
            raise APIError(400, 'Game escapes root')
        if not lower.is_dir():
            raise APIError(503, 'Game unavailable')
        if (lower/'.gameshelf-profile').exists() or (lower/'.gameshelf-profile').is_symlink():
            raise APIError(400, 'Reserved profile path exists in source')
        if tree_signature(lower) != row['signature']:
            raise APIError(409, 'Edition changed; scan and publish a new edition')
        return lower
    def _game(self, row):
        game=dict(id=row['id'], title=row['title'], entries=json.loads(row['entries']),
                    savePaths=json.loads(row['save_paths']),saveIsolation='known-rules-plus-admin-config; arbitrary saves require review')
        cover=self.db.execute('SELECT data FROM game_covers WHERE game_id=?',(row['id'],)).fetchone()
        if cover: game['coverSHA256']=hashlib.sha256(cover[0]).hexdigest()
        return game
    @locked
    def publish(self, candidate_id, save_paths=None, *, authorize=None):
        row = self.db.execute('SELECT * FROM candidates WHERE id=? AND available=1', (candidate_id,)).fetchone()
        if not row:
            raise APIError(404, 'Candidate not found')
        lower = self._external(lambda:self._lower(row))
        if authorize:
            authorize()
        from .privacy import normalize_rules
        if save_paths is not None and not isinstance(save_paths,list):
            raise APIError(400,'savePaths must be an array')
        rules = normalize_rules(json.loads(row['save_paths'])+(save_paths or []),lower)
        encoded = json.dumps(rules,sort_keys=True)
        existing = self.db.execute('SELECT * FROM games WHERE candidate_id=? AND signature=? AND save_paths=?', (candidate_id, row['signature'],encoded)).fetchone()
        if existing:
            # Explicit selected publication may add a newly validated launcher
            # to unchanged source bytes. Keep edition identity/private saves and
            # grants and canonical display title; scanning alone never changes
            # an already published catalog. An admin's metadata rename must not
            # be replaced by a later scan-derived directory name.
            if existing['entries'] != row['entries']:
                self.db.execute('UPDATE games SET entries=? WHERE id=?',(row['entries'],existing['id']))
                existing=self.db.execute('SELECT * FROM games WHERE id=?',(existing['id'],)).fetchone()
            return self._game(existing)
        game_id = uid()
        self.db.execute('INSERT INTO games(id,candidate_id,root_id,relative,title,entries,signature,save_paths) VALUES (?,?,?,?,?,?,?,?)',
                        (game_id, candidate_id, row['root_id'], row['relative'], row['title'], row['entries'], row['signature'],encoded))
        return self._game(self.db.execute('SELECT * FROM games WHERE id=?', (game_id,)).fetchone())
    @locked
    def grant(self, user_id, game_id, allowed):
        if type(allowed) is not bool:
            raise APIError(400, 'allowed must be boolean')
        if not self.db.execute('SELECT 1 FROM users WHERE id=?', (user_id,)).fetchone() or not self.db.execute('SELECT 1 FROM games WHERE id=?', (game_id,)).fetchone():
            raise APIError(404, 'User or game not found')
        if allowed:
            self.db.execute('INSERT OR IGNORE INTO grants VALUES (?,?)', (user_id, game_id))
        else:
            self.db.execute('DELETE FROM grants WHERE user_id=? AND game_id=?', (user_id, game_id))
            for row in list(self.db.execute("SELECT * FROM leases WHERE user_id=? AND game_id=? AND status!='closed'", (user_id, game_id))):
                self._revoke(row)
    @locked
    def grants(self):
        return [dict(userID=r[0], gameID=r[1]) for r in self.db.execute('SELECT * FROM grants')]
    @locked
    def catalog(self, user):
        return dict(games=[self._game(r) for r in self.db.execute('SELECT games.* FROM games JOIN grants ON games.id=game_id WHERE user_id=?', (user['id'],))])
    def _permitted(self, user, game_id):
        if not self.db.execute('SELECT 1 FROM grants JOIN users ON users.id=user_id WHERE user_id=? AND game_id=? AND disabled=0', (user['id'], game_id)).fetchone():
            raise APIError(403, 'Game not granted')
    def _revoke(self,row):
        current=self.db.execute('SELECT status FROM leases WHERE id=?',(row['id'],)).fetchone()
        if not current or current['status']=='closed':
            return
        self.db.execute("UPDATE leases SET status='revoking' WHERE id=?",(row['id'],))
        def close_share():
            with self.driver_lock:
                # Two revoke requests can queue while I/O is pending. The second
                # must NOT unmount a replacement using the same workspace paths.
                with self.lock:
                    status=self.db.execute('SELECT status FROM leases WHERE id=?',(row['id'],)).fetchone()
                    if status['status']=='closed':
                        return
                self.driver.close(dict(row))
                with self.lock:
                    self.db.execute("UPDATE leases SET status='closed' WHERE id=?",(row['id'],))
        try:
            self._external(close_share)
        except Exception:
            raise APIError(503,'Share shutdown pending; retry later') from None
    @locked
    def session(self, user, game_id, device, *, token=None):
        text(device, 128)
        if token is not None and self.authenticate(token)['id'] != user['id']:
            raise APIError(401,'Token/account mismatch')
        self._permitted(user, game_id)
        old = self.db.execute("SELECT * FROM leases WHERE user_id=? AND game_id=? AND status!='closed'", (user['id'], game_id)).fetchone()
        if old:
            if old['status']=='opening':
                raise APIError(409,'Workspace is being provisioned')
            if old['status'] == 'active' and old['expires'] > self.clock():
                raise APIError(409, 'Game already has a write lease; release it first')
            self._revoke(old)
        game = self.db.execute('SELECT * FROM games WHERE id=?', (game_id,)).fetchone()
        lower = self._external(lambda:self._lower(game))
        if token is not None:
            self.authenticate(token)
        self._permitted(user,game_id)
        # Another request may have reserved the writer during metadata reads.
        if self.db.execute("SELECT 1 FROM leases WHERE user_id=? AND game_id=? AND status!='closed'",(user['id'],game_id)).fetchone():
            raise APIError(409,'Game already has a write lease')
        lease = dict(id=uid(), user_id=user['id'], game_id=game_id, device=device,
                     expires=float(self.clock()+self.lease_ttl), status='opening',
                     token_digest=hashlib.sha256(token.encode()).hexdigest() if token else '')
        self.db.execute('INSERT INTO leases(id,user_id,game_id,device,expires,status,token_digest) VALUES (:id,:user_id,:game_id,:device,:expires,:status,:token_digest)', lease)
        try:
            share = self._external(lambda:self._open_driver(lease,lower,user,json.loads(game['save_paths'])))
        except Exception:
            self._revoke(lease)
            raise APIError(503, 'Workspace could not be exported') from None
        try:
            if token is not None:
                self.authenticate(token)
            self._permitted(user,game_id)
            status=self.db.execute('SELECT status FROM leases WHERE id=?',(lease['id'],)).fetchone()[0]
            if status!='opening':
                raise APIError(409,'Lease was revoked during provisioning')
        except APIError:
            self._revoke(lease)
            raise
        lease['expires'] = float(self.clock()+self.lease_ttl)
        self.db.execute("UPDATE leases SET status='active', expires=? WHERE id=?", (lease['expires'], lease['id']))
        return dict(leaseID=lease['id'], expiresAt=lease['expires'], serverID=self.server_id,
                    userID=user['id'], game=self._game(game), profileKey=f'{self.server_id}/{user["id"]}/{game_id}', share=share)
    def _lease(self, user, lease_id):
        row = self.db.execute("SELECT * FROM leases WHERE id=? AND user_id=? AND status!='closed'", (lease_id, user['id'])).fetchone()
        if not row:
            raise APIError(404, 'Lease not found')
        return row
    @locked
    def heartbeat(self, user, lease_id):
        row = self._lease(user, lease_id)
        if row['status'] != 'active' or row['expires'] <= self.clock():
            self._revoke(row)
            raise APIError(409, 'Lease expired')
        self._permitted(user, row['game_id'])
        expiry = float(self.clock()+self.lease_ttl)
        self.db.execute('UPDATE leases SET expires=? WHERE id=?', (expiry, lease_id))
        return dict(leaseID=lease_id, expiresAt=expiry)
    @locked
    def release(self, user, lease_id):
        self._revoke(self._lease(user, lease_id))
    @locked
    def reap(self):
        errors = 0
        for row in list(self.db.execute("SELECT * FROM leases WHERE (status='active' AND expires<=?) OR status='revoking'", (self.clock(),))):
            try:
                self._revoke(row)
            except APIError:
                errors += 1
        return errors
    @locked
    def recover(self):
        for row in list(self.db.execute("SELECT * FROM leases WHERE status!='closed'")):
            self._revoke(row)
