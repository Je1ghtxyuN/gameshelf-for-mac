"""Bounded stdlib HTTP API. Bearer auth only; UI credentials stay in memory."""
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
from pathlib import Path
import re
import socket
import ssl
import threading
import time

from .service import APIError, text
from .common import wire_json
from .accounts import UUID_PATTERN, SNAPSHOT_LIMIT, COVER_LIMIT

ID = r'([a-f0-9]{32})'
ASSETS = {'/': ('admin.html', 'text/html; charset=utf-8'),
          '/admin.js': ('admin.js', 'text/javascript; charset=utf-8'),
          '/admin.css': ('admin.css', 'text/css; charset=utf-8')}

class Application:
    def __init__(self, service, public_origin=None, public_address=None, certificate_sha256=None):
        self.service = service
        self.public_origin = public_origin
        from .invitation import public_address as normalize_address, certificate_pin
        configured_address=public_address or public_origin
        self.public_address=normalize_address(configured_address) if configured_address else None
        self.certificate_sha256=certificate_pin(certificate_sha256)
        self.login_attempts = deque()
        self.login_limit = 30  # Global per minute: bounds PBKDF2 work and memory.
        self.rate_lock = threading.Lock()
        service.prepare_setup(self.public_address,getattr(service,"display_name","GameShelf"),self.certificate_sha256)
    def throttle_login(self):
        with self.rate_lock:
            now = time.monotonic()
            while self.login_attempts and self.login_attempts[0] < now-60:
                self.login_attempts.popleft()
            if len(self.login_attempts) >= self.login_limit:
                raise APIError(429, 'Too many login attempts; retry in one minute')
            self.login_attempts.append(now)
    def require_admin(self,token):
        if not self.service.authenticate(token)['admin']:
            raise APIError(403,'Administrator required')
    def dispatch(self, method, path, data, token):
        s = self.service
        if method == 'GET' and path == '/api/server-info':
            return dict(name=getattr(s,'display_name','GameShelf'),serverID=s.server_id,version='1.1.0',setupRequired=s.setup_required())
        if method == 'POST' and path == '/api/login':
            self.throttle_login()
            return s.login(data.get('username'), data.get('password'))
        if method == 'POST' and path == '/api/setup':
            self.throttle_login()
            return s.setup_admin(data)
        scan=re.fullmatch('/api/admin/roots/'+ID+'/scan',path)
        if method=='POST' and scan:
            def authorize_scan():
                if not s.authenticate(token)['admin']:
                    raise APIError(403,'Administrator required')
            # The service authenticates both before walking and before committing.
            return s.scan(scan[1],authorize=authorize_scan)
        selected = re.fullmatch('/api/admin/roots/'+ID+'/candidates',path)
        if method=='POST' and selected:
            return s.register_selected(selected[1],data,authorize=lambda:self.require_admin(token))
        # Keep authorization and mutation within the SAME service authority lock.
        # A disabled admin cannot race a queued request after authentication.
        with s.lock:
            user = s.authenticate(token)
            if method=='POST' and path=='/api/account/password':
                return s.change_password(user,data)
            if path.startswith('/api/admin/'):
                if not user['admin']:
                    raise APIError(403, 'Administrator required')
                if method=='GET' and path=='/api/admin/invitation':
                    from .invitation import client_invitation
                    try:
                        return client_invitation(self.public_address,getattr(s,'display_name','GameShelf'),self.certificate_sha256)
                    except (ValueError,UnicodeError):
                        raise APIError(503,'Client invitation is not configured') from None
                if path == '/api/admin/roots':
                    if method == 'GET':
                        return dict(roots=s.roots())
                    if method == 'POST':
                        return s.add_root(text(data.get('path'), 4096), data.get('title'))
                if method == 'GET' and path == '/api/admin/candidates':
                    return dict(candidates=s.candidates())
                m = re.fullmatch('/api/admin/candidates/'+ID+'/publish', path)
                if method == 'POST' and m:
                    return s.publish(m[1],save_paths=data.get('savePaths'),authorize=lambda:self.require_admin(token))
                if method == 'GET' and path == '/api/admin/games':
                    return dict(games=[s._game(r) for r in s.db.execute('SELECT * FROM games ORDER BY title,id')])
                if path == '/api/admin/users':
                    if method == 'GET':
                        return dict(users=s.users())
                    if method == 'POST':
                        return s.create_user(data.get('username'), data.get('password'), data.get('admin',False))
                password = re.fullmatch('/api/admin/users/'+ID+'/password',path)
                if method=='POST' and password:
                    return s.change_password(user,data,password[1])
                m = re.fullmatch('/api/admin/users/'+ID+'/rename', path)
                if method == 'POST' and m:
                    return s.rename_self(user,m[1],data)
                m = re.fullmatch('/api/admin/games/'+ID+'/cover', path)
                if method == 'POST' and m:
                    return s.game_cover(user,m[1],data)
                m = re.fullmatch('/api/admin/games/'+ID+'/metadata', path)
                if method == 'POST' and m:
                    return s.game_metadata(user,m[1],data)
                m = re.fullmatch('/api/admin/users/'+ID+'/disable', path)
                if method == 'POST' and m:
                    s.disable_user(m[1]); return {}
                if path == '/api/admin/grants':
                    if method == 'GET':
                        return dict(grants=s.grants())
                    if method == 'POST':
                        s.grant(text(data.get('userID')), text(data.get('gameID')), data.get('allowed')); return {}
                raise APIError(404, 'Endpoint not found')
            if method == 'GET' and path == '/api/personal-library':
                return s.personal_libraries(user)
            m=re.fullmatch('/api/personal-library/'+UUID_PATTERN,path)
            if method in ('GET','POST') and m:
                return s.personal_library(user,m[1],data if method=='POST' else None)
            m=re.fullmatch('/api/personal-library/'+UUID_PATTERN+'/covers/'+UUID_PATTERN,path)
            if method in ('GET','POST') and m:
                return s.personal_cover(user,m[1],m[2],data if method=='POST' else None)
            m=re.fullmatch('/api/games/'+ID+'/cover',path)
            if method=='GET' and m:
                return s.game_cover(user,m[1])
            if method == 'GET' and path == '/api/catalog':
                return s.catalog(user)
            if method == 'POST' and path == '/api/logout':
                s.logout(token); return {}
            m = re.fullmatch('/api/games/'+ID+'/session', path)
            if method == 'POST' and m:
                return s.session(user, m[1], data.get('deviceID'),token=token)
            m = re.fullmatch('/api/sessions/'+ID+'/heartbeat', path)
            if method == 'POST' and m:
                return s.heartbeat(user,m[1])
            m = re.fullmatch('/api/sessions/'+ID, path)
            if method == 'DELETE' and m:
                s.release(user,m[1]); return {}
            raise APIError(404, 'Endpoint not found')

class Handler(BaseHTTPRequestHandler):
    server_version = 'GameShelf'
    sys_version = ''
    protocol_version = 'HTTP/1.0'  # one bounded request per connection
    def setup(self):
        super().setup()
        self.connection.settimeout(10)
    def log_message(self, *args):
        pass  # Never log URLs, credentials, request bodies or headers.
    def send_error(self, code, message=None, explain=None):
        self.reply(code, dict(error=dict(code=code, message='Request rejected')))
    def reply(self, status, data, content_type='application/json; charset=utf-8', *, download=None):
        body = wire_json(data) if isinstance(data, dict) else data
        self.send_response(status)
        self.send_header('Content-Type',content_type)
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Cache-Control','no-store')
        if download:
            self.send_header('Content-Disposition','attachment; filename="'+download+'"')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('X-Frame-Options','DENY')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        if isinstance(self.connection, ssl.SSLSocket):
            self.send_header('Strict-Transport-Security','max-age=31536000')
        if status == 429:
            self.send_header('Retry-After','60')
        self.end_headers()
        self.wfile.write(body)
    def handle_request(self):
        try:
            path = self.path
            if not path.startswith('/') or any(c in path for c in ('%', '?', '#', '\\')) or '..' in path.split('/'):
                raise APIError(400, 'Invalid request path')
            origin = self.headers.get('Origin')
            expected = self.server.application.public_origin or (
                ('https' if isinstance(self.connection,ssl.SSLSocket) else 'http')+'://'+self.headers.get('Host',''))
            if origin and origin != expected:
                raise APIError(403, 'Cross-origin requests are not allowed')
            if self.command == 'GET' and path in ASSETS:
                filename, content_type = ASSETS[path]
                self.reply(200, (Path(__file__).parent/'web'/filename).read_bytes(), content_type)
                return
            data = {}
            lengths = self.headers.get_all('Content-Length', [])
            if self.headers.get('Transfer-Encoding') or len(lengths)>1:
                raise APIError(400, 'Ambiguous request framing')
            if self.command in ('POST','DELETE'):
                try:
                    length = int(lengths[0]) if lengths else 0
                except ValueError:
                    raise APIError(400, 'Invalid content length') from None
                if length < 0:
                    raise APIError(400, 'Invalid content length')
                limit=16384
                if self.command=='POST' and re.fullmatch('/api/personal-library/'+UUID_PATTERN,path):
                    limit=SNAPSHOT_LIMIT+1024
                elif self.command=='POST' and (re.fullmatch('/api/personal-library/'+UUID_PATTERN+'/covers/'+UUID_PATTERN,path) or re.fullmatch('/api/admin/games/'+ID+'/cover',path)):
                    limit=4*((COVER_LIMIT+2)//3)+1024
                if length > limit:
                    raise APIError(413, 'Request body too large')
                if length:
                    if self.headers.get_content_type() != 'application/json':
                        raise APIError(415, 'JSON content type required')
                    raw = self.rfile.read(length)
                    try:
                        def unique_object(pairs):
                            result={}
                            for key,value in pairs:
                                if key in result: raise ValueError('Duplicate JSON key')
                                result[key]=value
                            return result
                        data = json.loads(raw,object_pairs_hook=unique_object,parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))
                    except (ValueError, UnicodeError, RecursionError):
                        raise APIError(400, 'Invalid JSON') from None
                    if not isinstance(data,dict):
                        raise APIError(400, 'JSON object required')
            auth = self.headers.get('Authorization','')
            token = auth[7:] if auth.startswith('Bearer ') else ''
            result = self.server.application.dispatch(self.command, path, data, token)
            download='gameshelf-invitation.json' if self.command=='GET' and path=='/api/admin/invitation' else None
            self.reply(200,result,download=download)
        except APIError as e:
            self.reply(e.status,dict(error=dict(code=e.status,message=e.message)))
        except (BrokenPipeError, ConnectionError, TimeoutError):
            pass
        except Exception:
            # Host paths and command diagnostics must never cross the API boundary.
            self.reply(503,dict(error=dict(code=503,message='Service unavailable')))
    do_GET = do_POST = do_DELETE = handle_request

class Server(ThreadingHTTPServer):
    daemon_threads = False
    block_on_close = True
    request_queue_size = 16
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(*args,**kwargs)
    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request,client_address)
        except Exception:
            self.slots.release()
            raise
    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request,client_address)
        finally:
            self.slots.release()
    def handle_error(self, request, client_address):
        pass

def make_server(service, host='127.0.0.1', port=8443, *, cert=None, key=None, public_origin=None, public_address=None, certificate_sha256=None):
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = False  # Numeric bind addresses only; no DNS trust assumption.
    if bool(cert) != bool(key) or (not loopback and not (cert and key)):
        raise ValueError('Off-loopback API requires configured TLS certificate and private key')
    context = None
    if cert and key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert,key)
    server_type = Server
    if ':' in host:
        class IPv6Server(Server):
            address_family = socket.AF_INET6
        server_type = IPv6Server
    server = server_type((host,port),Handler,bind_and_activate=False)
    try:
        server.application = Application(service,public_origin,public_address,certificate_sha256)
        if context:
            server.socket = context.wrap_socket(server.socket,server_side=True,do_handshake_on_connect=False)
        server.server_bind()
        server.server_activate()
    except Exception:
        server.server_close()
        raise
    return server
