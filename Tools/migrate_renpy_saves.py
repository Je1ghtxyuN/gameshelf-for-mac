#!/usr/bin/env python3
"""Copy opaque Ren'Py saves without overwriting existing progress (stdlib only).

API errors return status='failed'; CLI errors also exit nonzero. Preflight errors
make no changes. Once a transaction exists its backups and receipt are retained,
including on failure. Stop the game and other save writers before running this
offline tool. It checks archive integrity, not engine compatibility or trust:
no pickle is loaded, signatures/ZIP bytes are copied verbatim, and no engine
security setting is changed. Backups contain private progress; protect them.

Limits cover all accepted files across source, seeds and destination together.
ZIP expanded sizes are bounded too, before testzip() reads compressed members.
Only immediate children are considered; nothing is recursively imported.

Staging uses temp + flush/fsync + os.replace. Publication uses an exclusive hard
link from staging on the destination filesystem: unlike replace(target), this
cannot overwrite a concurrently created target. Linux/NAS must support hard
links and directory fsync; failure is reported and rolls back this transaction.
This is exception rollback, not automatic crash/power-loss recovery. A retained
receipt and backups permit manual recovery after interruption.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import zipfile


MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_TOTAL_BYTES = 500 * 1024 * 1024
MAX_FILES = 1000
MAX_JSON_BYTES = 1024 * 1024
PERSISTENTS = {'persistent', 'persistent.bak'}
STANDARD = re.compile(r'(?P<page>[1-9][0-9]*|auto|quick)-(?P<slot>[1-9][0-9]{0,2})-LT1\.save\Z')


def _safe_path(value):
    """Reject symlinks in every component, except exact macOS system aliases."""
    raw = Path(value).expanduser()
    if '..' in raw.parts:
        raise ValueError('parent traversal is not allowed: ' + str(raw))
    raw = Path(os.path.abspath(raw))
    current = Path(raw.anchor)
    aliases = {'/tmp': '/private/tmp', '/var': '/private/var'} if sys.platform == 'darwin' else {}
    for part in raw.parts[1:]:
        current /= part
        if current.is_symlink():
            if str(current) not in aliases or str(current.resolve()) != aliases[str(current)]:
                raise ValueError('symlink path component: ' + str(current))
            current = Path(aliases[str(current)])
    return current


def _overlaps(a, b):
    return a == b or a in b.parents or b in a.parents


def _accepted(name):
    return name.endswith('.save') or name in PERSISTENTS


def _read_regular(path):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError('not a private regular file (symlink/hardlink/device): ' + str(path))
        if before.st_size > MAX_FILE_BYTES:
            raise ValueError('file exceeds 20 MiB cap: ' + str(path))
        chunks, remaining = [], MAX_FILE_BYTES + 1
        while remaining:
            chunk = os.read(fd, min(remaining, 1024 * 1024))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b''.join(chunks)
        after = os.fstat(fd)
        if len(data) > MAX_FILE_BYTES:
            raise ValueError('file exceeds size cap: ' + str(path))
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('file changed during read: ' + str(path))
        return data
    finally:
        os.close(fd)


def _validate_save(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        names = [info.filename for info in members]
        if len(names) != len(set(names)) or not {'log', 'json', 'renpy_version'} <= set(names):
            raise ValueError('ZIP needs unique log/json/renpy_version members')
        expanded = sum(info.file_size for info in members)
        if expanded > MAX_FILE_BYTES:
            raise ValueError('expanded ZIP exceeds file size cap')
        for info in members:
            name = info.filename
            mode = info.external_attr >> 16
            if ('\\' in name or name.startswith('/') or '..' in name.split('/')
                    or ':' in name or stat.S_ISLNK(mode) or info.flag_bits & 1):
                raise ValueError('unsafe/encrypted ZIP member')
        if archive.getinfo('json').file_size >= MAX_JSON_BYTES:
            raise ValueError('ZIP json must be smaller than 1 MiB')
        bad = archive.testzip()
        if bad is not None:
            raise ValueError('ZIP CRC failed: ' + bad)
        metadata = json.loads(archive.read('json').decode('utf-8'),
                              parse_constant=lambda value: (_ for _ in ()).throw(
                                  ValueError('nonfinite JSON constant: ' + value)))
        if not isinstance(metadata, dict):
            raise ValueError('ZIP json must be a dict')
        # renpy_version is opaque text, never evaluated or unpickled.
        version = archive.read('renpy_version')
        if len(version) > 4096:
            raise ValueError('unreasonable renpy_version length')
        return metadata, version.decode('utf-8', errors='replace'), expanded


def _inventory(root, role, budget):
    if not root.is_dir():
        raise ValueError('input must be a directory: ' + str(root))
    files = []
    for path in sorted(root.iterdir(), key=lambda p: p.name):
        if not _accepted(path.name):
            continue
        if '/' in path.name or '\\' in path.name or '\x00' in path.name:
            raise ValueError('unsafe filename: ' + repr(path.name))
        budget['count'] += 1
        if budget['count'] > MAX_FILES:
            raise ValueError('accepted file count exceeds cap')
        data = _read_regular(path)
        metadata, version, expanded = ({}, None, 0)
        if path.name.endswith('.save'):
            metadata, version, expanded = _validate_save(data)
        budget['bytes'] += len(data)
        budget['expanded'] += max(len(data), expanded)
        if max(budget['bytes'], budget['expanded']) > MAX_TOTAL_BYTES:
            raise ValueError('accepted data exceeds total size cap')
        files.append({'name': path.name, 'data': data,
                      'sha256': hashlib.sha256(data).hexdigest(),
                      'metadata': metadata, 'engine_version': version, 'mtime_ns': path.stat().st_mtime_ns})
    return {'role': role, 'path': root, 'files': files}


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_write(path, data):
    """Only called in private staging/backup areas, never on existing saves."""
    _safe_path(path.parent)
    fd, temporary = tempfile.mkstemp(prefix='.tmp-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        _fsync_dir(path.parent)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def _write_receipt(report):
    _atomic_write(Path(report['receipt']),
                  (json.dumps(report, ensure_ascii=True, indent=2, allow_nan=False) + '\n').encode())


def _publish(stage, target, data, created):
    _safe_path(stage)
    _safe_path(target.parent)
    staged = stage / target.name
    _atomic_write(staged, data)
    identity = staged.stat()
    os.link(staged, target, follow_symlinks=False)  # EEXIST is always a failure.
    created.append((target, identity.st_dev, identity.st_ino))
    staged.unlink()
    _fsync_dir(target.parent)


def _summary(inventory):
    return {'role': inventory['role'], 'path': str(inventory['path']),
            'persistent': [{'name': f['name'], 'sha256': f['sha256'], 'bytes': len(f['data'])}
                           for f in inventory['files'] if f['name'] in PERSISTENTS],
            'saves': [{'name': f['name'], 'sha256': f['sha256'],
                       'bytes': len(f['data']), 'metadata': f['metadata'],
                       'engine_version': f['engine_version']}
                      for f in inventory['files'] if f['name'].endswith('.save')]}


def _counts(inventory):
    counts = {'manual': 0, 'auto': 0, 'quick': 0, 'other': 0, 'persistent': 0}
    for file in inventory['files']:
        name = file['name']
        match = STANDARD.fullmatch(name)
        kind = ('persistent' if name in PERSISTENTS else
                match['page'] if match and match['page'] in ('auto', 'quick') else
                'manual' if match else 'other')
        counts[kind] += 1
    return counts


def _plan(inputs, destination, occupied, report):
    """Plan everything before backup or destination writes, including slot exhaustion."""
    known = {file['name']: file for file in destination['files']}
    hashes = {}
    for name, file in known.items():
        if name.endswith('.save'):
            hashes.setdefault(file['sha256'], name)
    # A conflicting earlier save must not consume a later save's free original
    # name. Reserve input names for the whole plan; seeds still win same names.
    reserved = {file['name'] for inventory in inputs for file in inventory['files']}
    planned = []
    for inventory in inputs:  # seeds, then legacy source
        for file in inventory['files']:
            name, digest = file['name'], file['sha256']
            action = {'role': inventory['role'], 'source_name': name, 'sha256': digest, 'mtime_ns': file['mtime_ns']}
            if name in PERSISTENTS:
                decision = 'preserve_destination' if name in occupied else 'copy_if_missing'
                report['persistent'].append(dict(action, decision=decision))
                if name in occupied:
                    report['actions'].append(dict(action, decision=decision, target_name=name))
                    continue
            elif digest in hashes:
                report['actions'].append(dict(action, decision='reuse_sha256', target_name=hashes[digest]))
                continue
            target = name
            if target in occupied:
                target = next((f'{page}-{slot}-LT1.save'
                               for page in range(1, 1000) for slot in range(1, 7)
                               if f'{page}-{slot}-LT1.save' not in occupied | reserved), None)
                if target is None:
                    raise ValueError('no free manual slot in pages 1..999, slots 1..6')
            occupied.add(target)
            if name.endswith('.save'):
                hashes[digest] = target
            report['actions'].append(dict(action, decision='copy' if name == target else 'remap',
                                          target_name=target))
            planned.append((target, file['data']))
    return planned


def migrate(source: Path, destination: Path, backup_root: Path,
            seed_sources: list[Path] = []) -> dict:
    """Return a JSON-safe report. The default seed list is never mutated.

    receipt/transaction are null on preflight rejection. Existing persistent
    wins; otherwise first seed wins, then source. No persistent data is merged.
    Rejected accepted inputs abort the entire operation, rather than silently
    dropping progress. Nonaccepted files are ignored and never backed up.
    """
    report = {'status': 'validating', 'transaction': None, 'receipt': None,
              'created': [], 'actions': [], 'persistent': [], 'inputs': [],
              'counts': {}, 'error': None, 'rollback_errors': []}
    created, stage, dest_created = [], None, False
    try:
        source, destination, backup_root = map(_safe_path, (source, destination, backup_root))
        seeds = [_safe_path(seed) for seed in seed_sources]
        roots = [source, *seeds, destination, backup_root]
        for index, root in enumerate(roots):
            for other in roots[index + 1:]:
                if _overlaps(root, other) or (root.exists() and other.exists() and os.path.samefile(root, other)):
                    raise ValueError('same or overlapping paths: ' + str(root) + ' / ' + str(other))
        if destination.exists() and not destination.is_dir():
            raise ValueError('destination must be a directory')
        if backup_root.exists() and not backup_root.is_dir():
            raise ValueError('backup_root must be a directory')
        budget = {'count': 0, 'bytes': 0, 'expanded': 0}
        legacy = _inventory(source, 'source', budget)
        inputs = [_inventory(seed, f'seed-{index:03d}', budget) for index, seed in enumerate(seeds)]
        inputs.append(legacy)
        dest = (_inventory(destination, 'destination', budget) if destination.exists()
                else {'role': 'destination', 'path': destination, 'files': []})
        all_inputs = [legacy, *inputs[:-1], dest]
        report['inputs'] = [_summary(item) for item in all_inputs]
        report['counts'] = {item['role']: _counts(item) for item in all_inputs}
        report['total_bytes'] = budget['bytes']
        occupied = {p.name for p in destination.iterdir()} if destination.exists() else set()
        planned = _plan(inputs, dest, occupied, report)

        _safe_path(backup_root)
        backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        transaction = Path(tempfile.mkdtemp(prefix='renpy-', dir=backup_root))
        report.update(transaction=str(transaction), receipt=str(transaction / 'receipt.json'), status='backing_up')
        _write_receipt(report)
        for inventory in all_inputs:
            directory = transaction / inventory['role']
            directory.mkdir(mode=0o700)
            for file in inventory['files']:
                _atomic_write(directory / file['name'], file['data'])
                os.utime(directory / file['name'], ns=(file['mtime_ns'], file['mtime_ns']), follow_symlinks=False)
            _fsync_dir(directory)
        _fsync_dir(transaction)
        _fsync_dir(backup_root)
        report['status'] = 'prepared'
        _write_receipt(report)  # Complete backups + durable receipt before any destination mutation.

        _safe_path(destination)
        if not destination.exists():
            destination.mkdir(parents=True, mode=0o700)
            dest_created = True
        stage = Path(tempfile.mkdtemp(prefix='.renpy-stage-', dir=destination))
        times = {action['target_name']: action['mtime_ns'] for action in report['actions'] if action['decision'] in ('copy', 'remap')}
        for name, data in planned:
            _publish(stage, destination / name, data, created)
            os.utime(destination / name, ns=(times[name], times[name]), follow_symlinks=False)
            report['created'].append(name)
        shutil.rmtree(stage)
        stage = None
        _fsync_dir(destination)
        report['status'] = 'ok'
        _write_receipt(report)
    except Exception as error:
        report['status'] = 'failed'
        report['error'] = f'{type(error).__name__}: {error}'
        for path, device, inode in reversed(created):
            try:
                current = path.lstat()
                if (current.st_dev, current.st_ino) != (device, inode):
                    raise RuntimeError('rollback refused: file replaced by another writer: ' + str(path))
                path.unlink()
            except Exception as rollback_error:
                report['rollback_errors'].append(str(rollback_error))
        if stage is not None:
            try:
                shutil.rmtree(stage)
            except OSError as cleanup_error:
                report['rollback_errors'].append(str(cleanup_error))
        report['rolled_back'] = [str(path.name) for path, _, _ in created]
        report['created'] = []
        try:
            if created:
                _fsync_dir(destination)
            if dest_created:
                destination.rmdir()
        except OSError as cleanup_error:
            report['rollback_errors'].append(str(cleanup_error))
        if report['receipt']:
            try:
                _write_receipt(report)
            except Exception as receipt_error:
                report['receipt_error'] = str(receipt_error)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--backup-root', type=Path, required=True)
    parser.add_argument('--seed', type=Path, action='append', default=[])
    parser.add_argument('--report', type=Path)
    args = parser.parse_args(argv)
    # Validate the optional report before migration; it must never modify inputs,
    # destination, backups or an existing file, including ignored keys/tokens.
    report = None
    try:
        report_path = _safe_path(args.report) if args.report else None
        if report_path is not None:
            roots = [_safe_path(p) for p in [args.source, args.destination, args.backup_root, *args.seed]]
            if any(_overlaps(report_path, root) for root in roots) or os.path.lexists(report_path):
                raise ValueError('report must be a new file outside migration roots')
            if not report_path.parent.is_dir():
                raise ValueError('report parent must exist')
        report = migrate(args.source, args.destination, args.backup_root, args.seed)
        if report_path is not None:
            # Exclusive report publication, same semantics as progress files.
            stage = Path(tempfile.mkdtemp(prefix='.renpy-report-', dir=report_path.parent))
            try:
                _publish(stage, report_path,
                         (json.dumps(report, ensure_ascii=True, indent=2, allow_nan=False) + '\n').encode(), [])
            finally:
                shutil.rmtree(stage)
    except Exception as error:
        if report is None:
            report = {'status': 'failed', 'error': f'{type(error).__name__}: {error}'}
        else:
            # An optional report export failure does not erase migration evidence.
            report['report_error'] = f'{type(error).__name__}: {error}'
    summary = {key: report[key] for key in
               ('status', 'transaction', 'receipt', 'counts', 'total_bytes',
                'error', 'rollback_errors', 'receipt_error', 'report_error') if key in report}
    summary['created_count'] = len(report.get('created', []))
    summary['reuse_count'] = sum(action['decision'] == 'reuse_sha256'
                                 for action in report.get('actions', []))
    summary['remap_count'] = sum(action['decision'] == 'remap'
                                 for action in report.get('actions', []))
    print(json.dumps(summary, ensure_ascii=True, allow_nan=False))
    return 0 if report['status'] == 'ok' and 'report_error' not in report else 1


if __name__ == '__main__':
    sys.exit(main())
