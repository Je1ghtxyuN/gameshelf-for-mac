"""Root-private Unix socket for interactive docker exec administrator bootstrap.

Only account creation is supported. This is not a command execution interface.
"""
import json
import os
import socket
import socketserver
import stat
import struct
import threading
from .service import APIError

class ControlHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(10)
        try:
            if hasattr(socket,'SO_PEERCRED'):
                _,uid,_=struct.unpack('3i',self.connection.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12))
                if uid != 0:
                    raise APIError(403,'Container root required')
            line=self.rfile.readline(16385)
            if len(line)>16384:
                raise APIError(400,'Request too large')
            data=json.loads(line)
            if not isinstance(data,dict) or set(data) != {'username','password'}:
                raise APIError(400,'Username and password required')
            user=self.server.service.create_user(data['username'],data['password'],True)
            result=dict(user=user)
        except APIError as e:
            result=dict(error=e.message)
        except Exception:
            result=dict(error='Administrator creation failed')
        self.wfile.write(json.dumps(result).encode()+b'\n')

class AdminControl:
    def __init__(self,service):
        self.service=service
        self.path=service.state/'admin.sock'
        self.server=None
    def __enter__(self):
        if self.path.exists() or self.path.is_symlink():
            if not stat.S_ISSOCK(self.path.lstat().st_mode):
                raise RuntimeError('Unsafe admin socket path')
            self.path.unlink() # Caller holds the exclusive gateway process lock.
        self.server=socketserver.UnixStreamServer(str(self.path),ControlHandler)
        self.server.service=self.service
        self.server.timeout=1
        os.chmod(self.path,0o600)
        self.thread=threading.Thread(target=self.server.serve_forever,name='admin-control')
        self.thread.start()
        return self
    def __exit__(self,*args):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()
        self.path.unlink(missing_ok=True)

def create_live_admin(state,username,password):
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
        connection.settimeout(30)
        connection.connect(str(state/'admin.sock'))
        connection.sendall(json.dumps(dict(username=username,password=password)).encode()+b'\n')
        with connection.makefile('rb') as f:
            result=json.loads(f.readline(16385))
    if 'error' in result:
        raise ValueError(result['error'])
    return result['user']
