#!/usr/bin/env python3
"""Development audit front-end, NEVER bundled/required by the macOS app.
All archive validation is delegated to the actual Swift implementation.
Build Sources/ManagedWine.swift + Tests/ManagedWineTests.swift first.
"""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', type=Path, required=True)
    parser.add_argument('--root-name', default='Wine.app')
    parser.add_argument('--probe', type=Path, default=Path(__file__).resolve().parents[1] / 'build/ManagedWineTests')
    args = parser.parse_args()
    if not args.probe.is_file():
        parser.error('Build the Swift ManagedWineTests audit probe first')
    return subprocess.run([str(args.probe.resolve()), '--audit', str(args.audit.resolve()), args.root_name],
                          timeout=120, check=False).returncode


if __name__ == '__main__':
    raise SystemExit(main())
