"""Synthetic-only acceptance: existing wine64 engine + locally compiled fixtures.
No game arguments allowed. Always creates a NEW prefix and only stops that prefix.
Usage: python3 Tools/test_wine_window.py /path/to/engine/bin/wine64 /path/to/Frameworks
"""
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    wine, frameworks = map(Path, sys.argv[1:])
    build = Path(__file__).resolve().parents[1] / 'build'
    launcher, fixture = build / 'GameShelfWineWindow.exe', build / 'WineWindowFixture.exe'
    assert wine.is_file() and launcher.is_file() and fixture.is_file()
    unicode_fixture = build / "WineWindowFixture 日本語 spaced.exe"
    shutil.copyfile(fixture, unicode_fixture)
    fixture = unicode_fixture
    prefix = tempfile.mkdtemp(prefix='GameShelf-WineWindow-Acceptance-', dir='/private/tmp')
    env = dict(os.environ, WINEPREFIX=prefix, WINEDEBUG='-all', WINEMSYNC='0', WINEESYNC='0',
               DYLD_FALLBACK_LIBRARY_PATH=str(frameworks), WINEDLLOVERRIDES='winemenubuilder.exe=d')
    log_path = Path(prefix) / 'acceptance.log'
    print('Evidence:', log_path, flush=True)
    with log_path.open('w') as log:
        try:
            args = [str(fixture), '日本語 spaced argument', 'quote"slash\\']
            cases = [('without-helper RED', args, 23),
                     ('normal center and one-shot GREEN', [str(launcher)] + args, 0),
                     ('maximized unchanged', [str(launcher)] + args + ['maximized'], 0),
                     ('fullscreen unchanged', [str(launcher)] + args + ['fullscreen'], 0)]
            fixture32 = build / 'WineWindowFixture32.exe'
            if fixture32.is_file():
                cases.append(('64-bit helper to 32-bit window', [str(launcher), str(fixture32)] + args[1:], 0))
            for label, argv, expected in cases:
                result = subprocess.run([str(wine)] + argv, env=env, stdout=log, stderr=log, timeout=90)
                print(label, 'exit', result.returncode, 'expected', expected, flush=True)
                assert result.returncode == expected, label
            # Explorer may return before its child. Require the synthetic child's
            # own receipt, rather than treating explorer exit 0 as a test success.
            receipt = Path(prefix) / 'virtual-desktop.receipt'
            windows = lambda p: 'Z:' + str(p).replace('/', '\\')
            virtual_env = dict(env, GAMESHELF_SYNTHETIC_RECEIPT=windows(receipt))
            desktop_args = ['explorer', '/desktop=GameShelfSynthetic,1600x1000',
                            windows(launcher), windows(fixture)] + args[1:] + ['virtual']
            subprocess.run([str(wine)] + desktop_args, env=virtual_env,
                           stdout=log, stderr=log, timeout=45, check=True)
            import time
            deadline = time.monotonic() + 15
            while not receipt.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            assert receipt.read_bytes() == b'1', 'virtual desktop window moved'
            print('virtual desktop skipped: child receipt PASS', flush=True)
        finally:
            subprocess.run([str(wine.with_name('wineserver')), '-k'], env=env,
                           stdout=log, stderr=log, timeout=15)
    print('PASS isolated synthetic acceptance', flush=True)


if __name__ == '__main__':
    main()
