"""Exercise SharedAPI from a real app bundle, where macOS ATS differs from CLI.

No UI is launched, no real accounts or NAS are read, and TLS trust stays local
to each probe. All certificate keys and bundle files are disposable fixtures.
"""
import hashlib
import http.server
import json
from pathlib import Path
import plistlib
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'macOS app-bundle networking')
class SharedHTTPSBundleTests(unittest.TestCase):
    def test_explicit_pin_works_in_bundle_without_global_trust_exceptions(self):
        with tempfile.TemporaryDirectory(prefix='gameshelf-bundle-tls-') as temporary:
            root = Path(temporary)
            cert, key = root / 'server.crt', root / 'server.key'
            # Use a hostname, not a raw loopback IP, to exercise app policy.
            host = 'localhost'
            config = root / 'openssl.cnf'
            config.write_text(('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=127.0.0.1\n[extensions]\nsubjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n').replace('127.0.0.1', host))
            subprocess.run([
                shutil.which('openssl'), 'req', '-x509', '-newkey', 'rsa:2048',
                '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1',
                '-config', str(config),
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            key.chmod(0o600)
            pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    data = json.dumps(dict(name='Fixture', serverID='isolated-fixture', version='1.1.0')).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

                def log_message(self, *args):
                    pass

            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            mismatch = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            mismatch.socket = context.wrap_socket(mismatch.socket, server_side=True)
            mismatch_worker = threading.Thread(target=mismatch.serve_forever, daemon=True)
            mismatch_worker.start()
            try:
                app = root / 'Probe.app'
                executable = app / 'Contents/MacOS/Probe'
                executable.parent.mkdir(parents=True)
                info = dict(CFBundleIdentifier='local.gameshelf.https-regression',
                            CFBundleExecutable='Probe', CFBundlePackageType='APPL',
                            LSMinimumSystemVersion='15.0', LSUIElement=True)
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                sources = ['Sources/Core.swift', 'Sources/VisualNovelProbe.swift',
                           'Sources/SharedLibrary.swift', 'Sources/PinnedHTTP.swift',
                           'Tests/SharedHTTPSBundleProbe.swift']
                subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path',
                                'build/module-cache', *sources, '-o', str(executable)], check=True)
                subprocess.run(['codesign', '--force', '--sign', '-', str(app)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                port = server.server_address[1]
                cases = [
                    (host, port, pin, 'success'),
                    (host, port, '00' * 32, 'failure'),
                    ('127.0.0.1', mismatch.server_address[1], pin, 'failure'),
                    (host, port, '-', 'failure'),
                ]
                for target, target_port, fingerprint, expected in cases:
                    with self.subTest(host=target, explicit_pin=fingerprint != '-', expected=expected):
                        result = subprocess.run([str(executable), f'https://{target}:{target_port}',
                                                 fingerprint, expected], timeout=25,
                                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        self.assertEqual(result.returncode, 0, result.stdout.decode() + result.stderr.decode())
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=5)
                mismatch.shutdown()
                mismatch.server_close()
                mismatch_worker.join(timeout=5)


if __name__ == '__main__':
    unittest.main()
