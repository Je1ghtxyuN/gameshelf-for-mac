"""Private onboarding capability and metadata; no game paths or source I/O."""
import base64
import binascii
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import sqlite3
import stat
import tempfile
import unicodedata
import uuid

from .common import APIError, locked, text, wire_json

SNAPSHOT_LIMIT = 512 * 1024
COVER_LIMIT = 256 * 1024
LIBRARY_LIMIT = 8
LIBRARY_LIST_LIMIT = 4 * 1024 * 1024
UUID_PATTERN = r'([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

def identifier(value):
    if not isinstance(value,str) or not re.fullmatch(UUID_PATTERN,value):
        raise APIError(400,'UUID required')
    return str(uuid.UUID(value))

def fields(value, required, optional=()):
    if not isinstance(value,dict) or not set(required)<=value.keys() or value.keys()-set(required)-set(optional):
        raise APIError(400,'Unexpected or missing fields')

def finite(value, maximum):
    if type(value) not in (int,float) or not 0<=value<=maximum or not math.isfinite(value):
        raise APIError(400,'Invalid numeric metadata')
    return value

def utf8_text(value, maximum):
    text(value,maximum)
    try: size=len(value.encode('utf-8'))
    except UnicodeError: raise APIError(400,'Invalid UTF-8 metadata') from None
    if size>maximum: raise APIError(400,'Text exceeds UTF-8 byte limit')

def validate_snapshot(value):
    fields(value,('version','games','collections'))
    if type(value['version']) is not int or value['version']!=1:
        raise APIError(400,'Unsupported snapshot version')
    games,collections=value['games'],value['collections']
    if not isinstance(games,list) or len(games)>1000 or not isinstance(collections,list) or len(collections)>200:
        raise APIError(400,'Metadata count limit exceeded')
    collection_ids=set(); game_ids=set()
    for c in collections:
        fields(c,('id','name')); key=identifier(c['id']); utf8_text(c['name'],240)
        if key in collection_ids: raise APIError(400,'Duplicate collection')
        collection_ids.add(key)
    for g in games:
        fields(g,('id','title','favorite','collectionIDs','playtimeSeconds'),('lastPlayed',))
        key=identifier(g['id']); utf8_text(g['title'],1024)
        if key in game_ids: raise APIError(400,'Duplicate game')
        game_ids.add(key)
        if type(g['favorite']) is not bool or not isinstance(g['collectionIDs'],list) or len(g['collectionIDs'])>200:
            raise APIError(400,'Invalid game metadata')
        ids=[identifier(i) for i in g['collectionIDs']]
        if len(set(ids))!=len(ids) or not set(ids)<=collection_ids:
            raise APIError(400,'Invalid collection references')
        finite(g['playtimeSeconds'],31557600000)
        if g.get('lastPlayed') is not None: finite(g['lastPlayed'],253402300799)
    normalized=dict(version=1,games=[dict(g,id=identifier(g['id']),collectionIDs=[identifier(i) for i in g['collectionIDs']]) for g in games],
                    collections=[dict(c,id=identifier(c['id'])) for c in collections])
    try: encoded=json.dumps(normalized,ensure_ascii=False,allow_nan=False,separators=(',',':')).encode('utf-8')
    except (ValueError,UnicodeError,RecursionError): raise APIError(400,'Invalid snapshot encoding') from None
    if len(encoded)>SNAPSHOT_LIMIT: raise APIError(413,'Snapshot exceeds 512 KiB')
    return encoded.decode('utf-8')

def jpeg(data):
    """Bound marker structure and dimensions without decoding untrusted pixels.

    The client still decodes JPEG. No subprocess or optional image library is
    invoked by the gateway, and metadata/covers never become executable files.
    """
    if not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'):
        raise APIError(400,'JPEG required')
    pos=2; frame=False; scan=False
    while pos<len(data):
        if data[pos]!=255: raise APIError(400,'Invalid JPEG marker')
        while pos<len(data) and data[pos]==255: pos+=1
        if pos>=len(data): break
        marker=data[pos]; pos+=1
        if marker==0xd9:
            if frame and scan and pos==len(data): return data
            break
        if marker in (0,0xd8) or 0xd0<=marker<=0xd7: break
        if pos+2>len(data): break
        size=int.from_bytes(data[pos:pos+2],'big')
        if size<2 or pos+size>len(data): break
        segment=data[pos+2:pos+size]; pos+=size
        if marker in (0xc0,0xc1,0xc2):
            if frame or len(segment)<6: break
            height=int.from_bytes(segment[1:3],'big'); width=int.from_bytes(segment[3:5],'big'); components=segment[5]
            if segment[0]!=8 or not 1<=width<=2048 or not 1<=height<=2048 or components not in (1,3) or len(segment)!=6+3*components: break
            frame=True
        elif marker==0xda:
            if not frame or len(segment)<4 or len(segment)!=4+2*segment[0]: break
            scan=True
            # Entropy-coded bytes: FF00 stuffing and restart markers are data.
            while pos<len(data):
                if data[pos]!=255: pos+=1; continue
                end=pos+1
                while end<len(data) and data[end]==255: end+=1
                if end>=len(data): break
                if data[end]==0 or 0xd0<=data[end]<=0xd7: pos=end+1; continue
                break
    raise APIError(400,'Invalid or oversized JPEG dimensions')

def decode_cover(value):
    fields(value,('data',))
    encoded=value['data']
    if not isinstance(encoded,str): raise APIError(400,'Base64 JPEG required')
    if len(encoded)>4*((COVER_LIMIT+2)//3): raise APIError(413,'Cover exceeds 256 KiB')
    try: raw=base64.b64decode(encoded,validate=True)
    except (ValueError,binascii.Error): raise APIError(400,'Invalid base64 JPEG') from None
    if len(raw)>COVER_LIMIT: raise APIError(413,'Cover exceeds 256 KiB')
    return jpeg(raw)

def cover_response(raw):
    return dict(data=base64.b64encode(raw).decode('ascii'),mime='image/jpeg',sha256=hashlib.sha256(raw).hexdigest())

class AccountFeatures:
    def initialize_accounts(self):
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS personal_libraries(user_id TEXT REFERENCES users(id),device_id TEXT,
            revision INTEGER NOT NULL,snapshot TEXT NOT NULL,PRIMARY KEY(user_id,device_id));
        CREATE TABLE IF NOT EXISTS personal_covers(user_id TEXT REFERENCES users(id),device_id TEXT,game_id TEXT,
            data BLOB NOT NULL,PRIMARY KEY(user_id,device_id,game_id));
        CREATE TABLE IF NOT EXISTS game_covers(game_id TEXT PRIMARY KEY REFERENCES games(id),data BLOB NOT NULL);
        ''')
    @locked
    def setup_required(self):
        return self.db.execute('SELECT 1 FROM users LIMIT 1').fetchone() is None
    @locked
    def prepare_setup(self,address,name,pin):
        path=self.state/'administrator-setup.json'
        if not self.setup_required():
            self.db.execute("DELETE FROM settings WHERE key='setupDigest'")
            # unlink never follows a stale link or touches its target.
            path.unlink(missing_ok=True)
            return
        if not address:
            self.db.execute("DELETE FROM settings WHERE key='setupDigest'")
            path.unlink(missing_ok=True)
            return
        from .invitation import client_invitation
        invitation=dict(client_invitation(address,name,pin),kind="administrator-setup")
        previous=self.db.execute("SELECT value FROM settings WHERE key='setupDigest'").fetchone()
        try:
            fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        except FileNotFoundError: fd=None
        if fd is not None:
            try:
                info=os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_size>4096 or stat.S_IMODE(info.st_mode)!=0o600 or info.st_nlink!=1:
                    raise ValueError('Unsafe setup invitation file')
                with os.fdopen(fd,'rb',closefd=False) as f: current=json.loads(f.read(4097))
                token=current.get('setupToken')
                if (previous and isinstance(token,str) and len(token)<=256 and
                    hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(),previous[0]) and
                    {k:v for k,v in current.items() if k!='setupToken'}==invitation): return
            finally: os.close(fd)
        token=secrets.token_urlsafe(32); invitation['setupToken']=token
        fd,temp=tempfile.mkstemp(prefix='.setup-',dir=self.state)
        try:
            with os.fdopen(fd,'wb') as f:
                f.write((json.dumps(invitation,ensure_ascii=False)+'\n').encode()); f.flush(); os.fsync(f.fileno())
            os.replace(temp,path)
            directory=os.open(self.state,os.O_RDONLY|os.O_DIRECTORY)
            try: os.fsync(directory)
            finally: os.close(directory)
            self.db.execute("INSERT OR REPLACE INTO settings VALUES ('setupDigest',?)",(hashlib.sha256(token.encode()).hexdigest(),))
        finally:
            if os.path.exists(temp): os.unlink(temp)
    @locked
    def setup_admin(self,data):
        fields(data,('setupToken','username','password'))
        self.db.execute('BEGIN IMMEDIATE')
        try:
            if not self.setup_required(): raise APIError(409,'Service is already initialized')
            digest=self.db.execute("SELECT value FROM settings WHERE key='setupDigest'").fetchone()
            token=data['setupToken']
            if not digest or not isinstance(token,str) or len(token)>256 or not hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(),digest[0]):
                raise APIError(403,'Private setup invitation required')
            self.create_user(data['username'],data['password'],True)
            result=self.login(data['username'],data['password'])
            self.db.execute("DELETE FROM settings WHERE key='setupDigest'")
            self.db.execute('COMMIT')
        except BaseException:
            self.db.execute('ROLLBACK'); raise
        # The authority is consumed transactionally even if later cleanup fails.
        (self.state/'administrator-setup.json').unlink(missing_ok=True)
        return result
    @locked
    def rename_self(self,user,user_id,data):
        fields(data,('username',))
        if not user['admin'] or user['id']!=user_id: raise APIError(403,'Only your own administrator account can be renamed')
        name=text(data['username'],64)
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}',name): raise APIError(400,'Invalid username')
        try: self.db.execute('UPDATE users SET username=? WHERE id=?',(name,user_id))
        except sqlite3.IntegrityError: raise APIError(409,'Username already exists') from None
        result=self._user(self.db.execute('SELECT * FROM users WHERE id=?',(user_id,)).fetchone()); result.pop('uid')
        return result
    def _personal_document(self,user_id,device):
        info=self.db.execute('SELECT revision,length(CAST(snapshot AS BLOB)) AS bytes FROM personal_libraries WHERE user_id=? AND device_id=?',(user_id,device)).fetchone()
        if not info: raise APIError(404,'Personal library not found')
        if info['bytes']>SNAPSHOT_LIMIT: raise APIError(413,'Stored snapshot exceeds 512 KiB')
        row=self.db.execute('SELECT snapshot FROM personal_libraries WHERE user_id=? AND device_id=? AND length(CAST(snapshot AS BLOB))<=?',(user_id,device,SNAPSHOT_LIMIT)).fetchone()
        if not row: raise APIError(413,'Stored snapshot exceeds 512 KiB')
        return dict(deviceID=device,revision=info['revision'],snapshot=json.loads(row['snapshot']))
    def _personal_devices(self,user_id):
        # Fetch only a bounded number of small descriptors, never all snapshot
        # bodies. Reject legacy overquota accounts before decoding any content.
        rows=list(self.db.execute('SELECT device_id FROM personal_libraries WHERE user_id=? ORDER BY device_id LIMIT ?',
                                  (user_id,LIBRARY_LIMIT+1)))
        if len(rows)>LIBRARY_LIMIT: raise APIError(413,'Account exceeds 8 personal libraries')
        return rows
    def _personal_listing(self,user_id):
        rows=self._personal_devices(user_id)
        libraries=[]; size=len(wire_json(dict(libraries=[])))
        for row in rows:
            document=self._personal_document(user_id,row['device_id'])
            size+=len(wire_json(document))+(2 if libraries else 0)
            if size>LIBRARY_LIST_LIMIT: raise APIError(413,'Personal library list exceeds 4 MiB')
            libraries.append(document)
        return dict(libraries=libraries)
    @locked
    def personal_libraries(self,user):
        return self._personal_listing(user['id'])
    @locked
    def personal_library(self,user,device,data=None):
        device=identifier(device)
        if data is not None:
            fields(data,('expectedRevision','snapshot'))
            expected=data['expectedRevision']
            if type(expected) is not int or not 0<=expected<2**53-1: raise APIError(400,'Invalid expectedRevision')
            encoded=validate_snapshot(data['snapshot'])
            self.db.execute('BEGIN IMMEDIATE')
            try:
                row=self.db.execute('SELECT revision FROM personal_libraries WHERE user_id=? AND device_id=?',(user['id'],device)).fetchone()
                if (row[0] if row else 0)!=expected: raise APIError(409,'Personal library revision conflict')
                self.db.execute('INSERT INTO personal_libraries VALUES (?,?,?,?) ON CONFLICT(user_id,device_id) DO UPDATE SET revision=excluded.revision,snapshot=excluded.snapshot',
                    (user['id'],device,expected+1,encoded))
                # Quotas include this prospective revision and its exact HTTP
                # representation; a failure rolls back the snapshot and pruning.
                self._personal_listing(user['id'])
                game_ids=[g['id'] for g in json.loads(encoded)['games']]
                placeholders=','.join('?' for _ in game_ids)
                query='DELETE FROM personal_covers WHERE user_id=? AND device_id=?'
                if game_ids: query+=' AND game_id NOT IN ('+placeholders+')'
                self.db.execute(query,(user['id'],device,*game_ids))
                self.db.execute('COMMIT')
            except BaseException:
                self.db.execute('ROLLBACK'); raise
        return self._personal_document(user['id'],device)
    @locked
    def personal_cover(self,user,device,game,data=None):
        device,game=identifier(device),identifier(game)
        parent=self._personal_document(user['id'],device)
        if game not in {identifier(g['id']) for g in parent['snapshot']['games']}:
            raise APIError(404,'Personal game not found')
        if data is not None:
            # Legacy accounts above the device cap may still read individually,
            # but cannot grow their cover storage through old parent rows.
            self._personal_devices(user['id'])
            raw=decode_cover(data)
            self.db.execute('INSERT INTO personal_covers VALUES (?,?,?,?) ON CONFLICT(user_id,device_id,game_id) DO UPDATE SET data=excluded.data',
                (user['id'],device,game,raw))
        row=self.db.execute('SELECT data FROM personal_covers WHERE user_id=? AND device_id=? AND game_id=?',(user['id'],device,game)).fetchone()
        if not row: raise APIError(404,'Cover not found')
        return cover_response(row[0])
    @locked
    def game_metadata(self,user,game,data):
        if not user['admin']: raise APIError(403,'Administrator required')
        if not self.db.execute('SELECT 1 FROM games WHERE id=?',(game,)).fetchone(): raise APIError(404,'Game not found')
        fields(data,('title',))
        title=data['title']
        if not isinstance(title,str) or any(unicodedata.category(c) in ('Cc','Cf','Cs') for c in title):
            raise APIError(400,'Invalid display title')
        title=title.strip()
        utf8_text(title,1024)
        # Published presentation metadata is independent of edition identity,
        # permissions, launcher paths and private workspaces.
        self.db.execute('UPDATE games SET title=? WHERE id=?',(title,game))
        return self._game(self.db.execute('SELECT * FROM games WHERE id=?',(game,)).fetchone())
    @locked
    def game_cover(self,user,game,data=None):
        if data is None: self._permitted(user,game)
        elif not user['admin']: raise APIError(403,'Administrator required')
        if not self.db.execute('SELECT 1 FROM games WHERE id=?',(game,)).fetchone(): raise APIError(404,'Game not found')
        if data is not None:
            raw=decode_cover(data)
            self.db.execute('INSERT INTO game_covers VALUES (?,?) ON CONFLICT(game_id) DO UPDATE SET data=excluded.data',(game,raw))
        row=self.db.execute('SELECT data FROM game_covers WHERE game_id=?',(game,)).fetchone()
        if not row: raise APIError(404,'Cover not found')
        return cover_response(row[0])
