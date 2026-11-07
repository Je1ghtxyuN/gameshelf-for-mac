#!/usr/bin/env python3
"""Fetch a checksum-pinned official Sparkle distribution; never execute fetched scripts."""
import hashlib
import pathlib
import subprocess
import urllib.request

VERSION = '2.10.1'
SHA256 = '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
URL = f'https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-{VERSION}.tar.xz'

def main():
    root = pathlib.Path(__file__).resolve().parents[1] / 'build/sparkle'
    root.mkdir(parents=True, exist_ok=True)
    archive = root / f'Sparkle-{VERSION}.tar.xz'
    if not archive.exists():
        tmp = archive.with_suffix('.download')
        with urllib.request.urlopen(URL,timeout=120) as response, tmp.open('wb') as output:
            import shutil
            shutil.copyfileobj(response, output)
        tmp.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit('Sparkle archive checksum mismatch; refusing to use it')
    target = root / 'distribution'
    target.mkdir(exist_ok=True)
    # The pinned vendor archive contains framework symlinks. bsdtar preserves
    # these and executable bits; never unpack an unverified archive.
    subprocess.run(['/usr/bin/tar','-xf',str(archive),'-C',str(target)],check=True)
    print(target)
if __name__=='__main__':main()
