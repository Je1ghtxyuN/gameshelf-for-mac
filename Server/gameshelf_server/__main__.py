"""Entrypoint for a dedicated container; never invoke against a host Samba."""
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import getpass
import hashlib
import ssl
import ipaddress
import json
import os
from pathlib import Path
import signal
import sys
import threading

from .driver import LinuxDriver, mount_table, physical_overlap
from .http_api import make_server
from .service import Service, clean_path

@dataclass(frozen=True)
class Settings:
    state: Path
    sources: list
    host: str
    port: int
    smb_host: str
    smb_port: int
    cert: str | None
    key: str | None
    public_origin: str | None
    token_ttl: int
    lease_ttl: int
    bootstrap_user: str | None
    bootstrap_file: str | None
    public_address: str | None = None
    certificate_sha256: str | None = None
    @classmethod
    def from_env(cls, env):
        def number(name, default, low, high):
            value = int(env.get(name,str(default)))
            if not low <= value <= high:
                raise ValueError('Invalid '+name)
            return value
        try:
            sources = json.loads(env['GAMESHELF_SOURCE_ROOTS'])
            if not isinstance(sources,list) or not sources or any(not isinstance(p,str) or not Path(p).is_absolute() for p in sources):
                raise ValueError('GAMESHELF_SOURCE_ROOTS must be a nonempty JSON array of absolute paths')
            state = Path(env.get('GAMESHELF_STATE','/state'))
            if not state.is_absolute():
                raise ValueError('State must be absolute')
            host = env.get('GAMESHELF_BIND','127.0.0.1')
            loopback = ipaddress.ip_address(host).is_loopback
            cert, key = env.get('GAMESHELF_TLS_CERT') or None, env.get('GAMESHELF_TLS_KEY') or None
            if bool(cert) != bool(key) or (not loopback and not cert):
                raise ValueError('TLS certificate and key are required off loopback')
            smb_host = env['GAMESHELF_SMB_HOST']
            if not smb_host or any(c.isspace() or c in '/\\@?#' for c in smb_host):
                raise ValueError('Invalid SMB hostname')
            origin = env.get('GAMESHELF_PUBLIC_ORIGIN') or None
            if origin:
                from urllib.parse import urlsplit
                parsed = urlsplit(origin)
                if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
                    raise ValueError('Public origin must be https://hostname[:port] without path')
            from .invitation import public_address, certificate_pin
            invitation_address=env.get('GAMESHELF_PUBLIC_ADDRESS') or origin
            invitation_address=public_address(invitation_address) if invitation_address else None
            invitation_pin=certificate_pin(env.get('GAMESHELF_CERTIFICATE_SHA256'))
            user, file = env.get('GAMESHELF_BOOTSTRAP_USERNAME'), env.get('GAMESHELF_BOOTSTRAP_PASSWORD_FILE')
            if bool(user) != bool(file):
                raise ValueError('Bootstrap requires username and a secret file (never a password environment variable)')
            return cls(state, [Path(p) for p in sources], host, number('GAMESHELF_PORT',8443,1,65535),
                       smb_host,number('GAMESHELF_SMB_PORT',1445,1,65535),cert,key,origin,
                       number('GAMESHELF_TOKEN_TTL',86400,60,2592000),number('GAMESHELF_LEASE_TTL',90,15,600),user,file,invitation_address,invitation_pin)
        except (KeyError,TypeError,json.JSONDecodeError) as e:
            raise ValueError('Missing or invalid gateway configuration') from e

@contextmanager
def state_lock(state):
    state = clean_path(state)
    state.mkdir(mode=0o700,parents=True,exist_ok=True)
    fd = os.open(state/'.gateway.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        try:
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another gateway owns this state') from None
        yield
    finally:
        os.close(fd)

def bootstrap(service, username, password_file):
    if service.users() or not username:
        return
    if not password_file:
        raise ValueError('Bootstrap needs a password file')
    with open(password_file,'r',encoding='utf-8') as f:
        password = f.read(1026).rstrip('\r\n')
    service.create_user(username,password,True)

def serve(cfg):
    if sys.platform != 'linux' or os.geteuid() != 0 or os.environ.get('GAMESHELF_CONTAINER') != '1':
        raise RuntimeError('Gateway driver runs only as root inside the supplied isolated Linux container')
    # Validate source/state separation BEFORE a driver can create files in state.
    state = clean_path(cfg.state)
    sources = [clean_path(p) for p in cfg.sources]
    from .service import overlaps
    if any(overlaps(state,p) or physical_overlap(state,p,mount_table()) for p in sources):
        raise ValueError('Source/state overlap')
    with state_lock(state):
        driver = LinuxDriver(state,cfg.smb_host,cfg.smb_port)
        driver.validate(sources)
        service = Service(state,driver,sources,token_ttl=cfg.token_ttl,lease_ttl=cfg.lease_ttl)
        service.display_name = os.environ.get('GAMESHELF_SERVER_NAME','GameShelf').strip()[:80] or 'GameShelf'
        server = None
        stopping = threading.Event()
        def stop(signum,frame):
            stopping.set()
        previous = {sig:signal.signal(sig,stop) for sig in (signal.SIGTERM,signal.SIGINT)}
        reaper = None
        control = None
        try:
            bootstrap(service,cfg.bootstrap_user,cfg.bootstrap_file)
            driver.start()
            service.recover()  # No API is listening until stale writers close.
            from .control import AdminControl
            pending_control = AdminControl(service)
            pending_control.__enter__()
            control = pending_control
            server = make_server(service,cfg.host,cfg.port,cert=cfg.cert,key=cfg.key,public_origin=cfg.public_origin,
                                 public_address=cfg.public_address,certificate_sha256=cfg.certificate_sha256)
            server.timeout = 0.5
            def reap():
                while not stopping.wait(2):
                    service.reap()
            reaper = threading.Thread(target=reap,name='lease-reaper')
            reaper.start()
            print('GameShelf gateway ready',flush=True)
            while not stopping.is_set():
                if not reaper.is_alive():
                    raise RuntimeError('Lease reaper stopped; stopping API')
                if driver.process.poll() is not None:
                    raise RuntimeError('Dedicated Samba exited; stopping API')
                server.handle_request()
        finally:
            stopping.set()
            if server:
                server.server_close()
            if reaper:
                reaper.join()
            if control:
                control.__exit__(None,None,None)
            try:
                service.recover()
            finally:
                try:
                    driver.stop()
                finally:
                    service.close()
                    for sig,handler in previous.items():
                        signal.signal(sig,handler)

def cert_fingerprint(path):
    pem=Path(path).read_text()
    start=pem.index('-----BEGIN CERTIFICATE-----')
    end=pem.index('-----END CERTIFICATE-----',start)+len('-----END CERTIFICATE-----')
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem[start:end])).hexdigest()

def main():
    os.umask(0o077)
    if sys.argv[1:2] == ['cert-fingerprint']:
        if len(sys.argv)>3:
            raise ValueError('Usage: cert-fingerprint [certificate.pem]')
        print(cert_fingerprint(sys.argv[2] if len(sys.argv)==3 else os.environ['GAMESHELF_TLS_CERT']))
        return
    cfg = Settings.from_env(os.environ)
    from .service import overlaps
    state=clean_path(cfg.state)
    if any(overlaps(state,clean_path(p)) or physical_overlap(state,clean_path(p),mount_table()) for p in cfg.sources):
        raise ValueError('Source/state overlap')
    if sys.argv[1:] == ['create-admin']:
        username = input('Admin username: ')
        password = getpass.getpass('New password (12+ characters): ')
        if password != getpass.getpass('Repeat password: '):
            raise ValueError('Passwords do not match')
        socket_path=cfg.state/'admin.sock'
        if socket_path.exists():
            from .control import create_live_admin
            create_live_admin(cfg.state,username,password)
        else:
            with state_lock(cfg.state):
                s = Service(cfg.state,None,cfg.sources)
                try:
                    s.create_user(username,password,True)
                finally:
                    s.close()
        print('Administrator created')
    elif not sys.argv[1:]:
        serve(cfg)
    else:
        raise ValueError('Usage: python -m gameshelf_server [create-admin | cert-fingerprint [certificate.pem]]')

if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('Gateway stopped: configuration or runtime operation failed. Check mounts, TLS, capabilities and isolated state.',file=sys.stderr)
        sys.exit(1)
