#!/usr/bin/env python3
"""Append two owned entries to a v3 archive without interpreting old payloads.

Format reference (index XOR and per-four-byte payload key recurrence only):
https://raw.githubusercontent.com/xi/rpg-extract/main/rpg_extract.py

No extraction, original-payload decryption, Ruby Marshal parsing, or execution.
An existing output is NEVER overwritten. All output parent components must be
real directories, not symlinks. Supplying a destination does not grant permission
to write there: the caller must separately authorize any NAS output.

Default atomic publication fails closed if unsupported. Explicit exclusive-copy
publication exposes an incomplete NEW cache file until completion. Consumers must
wait for successful tool exit before promoting/referencing that cache file.
"""
import argparse
import ctypes
import errno
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import struct
import sys

MAGIC = b"RGSSAD\x00\x03"
MASK = 0xffffffff
OWN_NAMES = (b"GameShelfBootstrap.rvdata2", b"GameShelfTranslations.rvdata2")
MAX_INDEX = 64 * 1024 * 1024
MAX_OWN_FILE = 64 * 1024 * 1024


@dataclass(frozen=True)
class Entry:
    offset: int
    size: int
    key: int
    name: bytes


@dataclass(frozen=True)
class Index:
    header: bytes
    key: int
    entries: tuple
    end: int


def normalized_name(name):
    if not name or b"\0" in name or b":" in name or name.startswith((b"/", b"\\")):
        raise ValueError("invalid archive entry name")
    parts = name.replace(b"\\", b"/").split(b"/")
    if b".." in parts:
        raise ValueError("traversal in archive entry name")
    return b"/".join(p.rstrip(b" .").lower() for p in parts if p not in (b"", b"."))


def read_index(stream, file_size):
    """Read only the table, stopping at the zero-offset word of the terminator.

    Some writers use a four-word terminator. Its remaining words, all padding,
    all ciphertext and any trailer remain in the opaque tail and are copied as-is.
    """
    if file_size > MASK:
        raise ValueError("archive exceeds v3 32-bit bounds")

    def exact(count):
        if stream.tell() + count > min(file_size, MAX_INDEX):
            raise ValueError("truncated or oversized archive index")
        data = stream.read(count)
        if len(data) != count:
            raise ValueError("truncated archive index")
        return data

    header = exact(12)
    if header[:8] != MAGIC:
        raise ValueError("expected RGSSAD version 3")
    key = (struct.unpack("<I", header[8:])[0] * 9 + 3) & MASK
    key_bytes = struct.pack("<I", key)
    entries, names = [], set()
    first_payload = file_size
    while True:
        if stream.tell() + 4 > first_payload:
            raise ValueError("index overlaps original payload")
        offset = struct.unpack("<I", exact(4))[0] ^ key
        if offset == 0:
            break
        if stream.tell() + 12 > first_payload:
            raise ValueError("index overlaps original payload")
        size, file_key, length = (v ^ key for v in struct.unpack("<III", exact(12)))
        if not 0 < length <= 65535 or stream.tell() + length > min(first_payload, offset):
            raise ValueError("invalid archive entry bounds")
        name = bytes(v ^ key_bytes[i % 4] for i, v in enumerate(exact(length)))
        normalized = normalized_name(name)
        if normalized in names:
            raise ValueError("duplicate archive entry name")
        names.add(normalized)
        if offset + size > file_size:
            raise ValueError("archive entry extends past EOF")
        entries.append(Entry(offset, size, file_key, name))
        first_payload = min(first_payload, offset)
        if len(entries) > 1_000_000:
            raise ValueError("too many archive entries")
    end = stream.tell()
    previous_end = end
    for item in sorted(entries, key=lambda e: (e.offset, e.size)):
        if item.offset < end or (item.size and item.offset < previous_end):
            raise ValueError("overlapping archive entry ranges")
        previous_end = max(previous_end, item.offset + item.size)
    return Index(header, key, tuple(entries), end)


def encrypt_added(data, initial_key):
    """Only for caller-owned new bytes. Never applied to the original payload."""
    encrypted = bytearray(len(data))
    key = initial_key
    for start in range(0, len(data), 4):
        key_bytes = struct.pack("<I", key)
        for i, byte in enumerate(data[start:start + 4]):
            encrypted[start + i] = byte ^ key_bytes[i]
        key = (key * 7 + 3) & MASK
    return bytes(encrypted)


def copy_opaque_tail(source, output, count):
    digest = hashlib.sha256()
    while count:
        chunk = source.read(min(count, 1024 * 1024))
        if not chunk:
            raise ValueError("source truncated while copying")
        output.write(chunk)
        digest.update(chunk)
        count -= len(chunk)
    return digest.hexdigest()


def open_output_parent(path):
    """Pin directories with no-follow descriptors, including every ancestor."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parent.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def file_signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def darwin_rename_exclusive(parent, temporary, destination):
    """Atomic no-clobber rename using the pinned directory fd, without hardlinks.

    Darwin sys/stdio.h: RENAME_EXCL = 0x00000004. An unsupported filesystem
    fails closed; never fall back to an overwrite-capable rename/replace.
    """
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(parent, os.fsencode(temporary), parent, os.fsencode(destination), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def identity(info):
    return info.st_dev, info.st_ino


def path_is_owned(parent, name, owned_identity):
    try:
        current = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return stat.S_ISREG(current.st_mode) and identity(current) == owned_identity


def unlink_if_owned(parent, name, owned_identity):
    # Never remove an observed replacement, including a symlink to the source.
    # SMB has no atomic compare-inode-and-unlink primitive: this check is not a
    # guarantee against a hostile directory writer racing the unlink syscall.
    if path_is_owned(parent, name, owned_identity):
        try:
            os.unlink(name, dir_fd=parent)
        except FileNotFoundError:
            pass


def validate_staging(staged, original_index, entries, size, delta, tail_hash, additions):
    """Read back the completed file: index, opaque bytes and owned ciphertext only."""
    before = os.fstat(staged.fileno())
    if before.st_size != size:
        raise ValueError("completed staging size mismatch")
    staged.seek(0)
    checked = read_index(staged, size)
    if checked.header != original_index.header or checked.entries != tuple(entries) or checked.end != original_index.end + delta:
        raise ValueError("completed staging index mismatch")
    staged.seek(0)
    digest = hashlib.sha256(staged.read(checked.end))
    opaque = hashlib.sha256()
    remaining = entries[len(original_index.entries)].offset - checked.end
    while remaining:
        chunk = staged.read(min(remaining, 1024 * 1024))
        if not chunk:
            raise ValueError("completed staging payload truncated")
        digest.update(chunk)
        opaque.update(chunk)
        remaining -= len(chunk)
    if opaque.hexdigest() != tail_hash:
        raise ValueError("completed staging opaque payload mismatch")
    for _, _, encrypted in additions:
        actual = staged.read(len(encrypted))
        if actual != encrypted:
            raise ValueError("completed staging owned entry mismatch")
        digest.update(actual)
    if staged.read(1) or file_signature(os.fstat(staged.fileno())) != file_signature(before):
        raise ValueError("completed staging changed during validation")
    return digest.hexdigest()


def copy_staged_to_fd(staged, fd, count):
    digest = hashlib.sha256()
    staged.seek(0)
    while count:
        chunk = staged.read(min(count, 1024 * 1024))
        if not chunk:
            raise ValueError("validated staging truncated during publication")
        digest.update(chunk)
        pending = memoryview(chunk)
        while pending:
            written = os.write(fd, pending)
            if written <= 0:
                raise OSError(errno.EIO, "short output write")
            pending = pending[written:]
        count -= len(chunk)
    return digest.hexdigest()


def publish_exclusive_copy(parent, name, staged, size, expected_hash):
    # O_EXCL is the commit-time no-clobber decision, not the earlier lstat.
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    owned_identity = identity(os.fstat(fd))
    try:
        if not path_is_owned(parent, name, owned_identity):
            raise OSError(errno.ESTALE, "output replaced before copying", name)
        copied_hash = copy_staged_to_fd(staged, fd, size)
        if copied_hash != expected_hash or os.fstat(fd).st_size != size:
            raise ValueError("exclusive-copy content verification failed")
        os.fsync(fd)
        if not path_is_owned(parent, name, identity(os.fstat(fd))):
            raise OSError(errno.ESTALE, "output replaced during copying", name)
    except BaseException:
        unlink_if_owned(parent, name, owned_identity)
        raise
    finally:
        os.close(fd)


def append_archive(source_path, output_path, bootstrap_path, dictionary_path, expected_entries=None, publish_mode="atomic"):
    if publish_mode not in ("atomic", "exclusive-copy"):
        raise ValueError("unknown publish mode")
    if ".." in Path(output_path).parts:
        raise ValueError("output parent traversal is not allowed")
    output_path = Path(os.path.abspath(output_path))
    if output_path == Path(os.path.abspath(source_path)):
        raise ValueError("output must differ from source")
    with open(source_path, "rb") as source:
        original_stat = os.fstat(source.fileno())
        if not stat.S_ISREG(original_stat.st_mode):
            raise ValueError("source must be a regular file")
        index = read_index(source, original_stat.st_size)
        if expected_entries is not None and len(index.entries) != expected_entries:
            raise ValueError("original entry count does not match expectation")
        existing = {normalized_name(e.name) for e in index.entries}
        if any(normalized_name(n) in existing for n in OWN_NAMES):
            raise ValueError("owned entry already exists; refusing to replace it")

        additions = []
        for name, path in zip(OWN_NAMES, (bootstrap_path, dictionary_path)):
            with open(path, "rb") as owned:
                if not stat.S_ISREG(os.fstat(owned.fileno()).st_mode):
                    raise ValueError("owned input must be a regular file")
                data = owned.read(MAX_OWN_FILE + 1)
            if len(data) > MAX_OWN_FILE:
                raise ValueError("owned entry exceeds size limit")
            key = secrets.randbits(32)
            additions.append((name, key, encrypt_added(data, key)))

        delta = sum(16 + len(name) for name in OWN_NAMES)
        cursor = original_stat.st_size + delta
        entries = [Entry(e.offset + delta, e.size, e.key, e.name) for e in index.entries]
        for name, key, encrypted in additions:
            entries.append(Entry(cursor, len(encrypted), key, name))
            cursor += len(encrypted)
        if cursor > MASK:
            raise ValueError("output exceeds v3 32-bit bounds")

        parent = open_output_parent(output_path)
        temporary = None
        try:
            # lstat also refuses dangling symlinks and hardlinks, without following.
            try:
                os.stat(output_path.name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise FileExistsError("output already exists; no overwrite allowed")
            candidate = ".rgss3a-" + secrets.token_hex(16)
            fd = os.open(candidate, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            temporary = candidate
            temporary_identity = identity(os.fstat(fd))
            with os.fdopen(fd, "w+b") as output:
                output.write(index.header)
                key_bytes = struct.pack("<I", index.key)
                for item in entries:
                    output.write(struct.pack("<IIII", *(value ^ index.key for value in (item.offset, item.size, item.key, len(item.name)))))
                    output.write(bytes(v ^ key_bytes[i % 4] for i, v in enumerate(item.name)))
                output.write(struct.pack("<I", index.key))  # zero offset, XOR encoded
                assert output.tell() == index.end + delta
                source.seek(index.end)
                tail_hash = copy_opaque_tail(source, output, original_stat.st_size - index.end)
                for _, _, encrypted in additions:
                    output.write(encrypted)
                output.flush()
                os.fsync(output.fileno())
                if file_signature(os.fstat(source.fileno())) != file_signature(original_stat):
                    raise ValueError("source changed during copying; output not published")
                if publish_mode == "exclusive-copy":
                    checked_hash = validate_staging(output, index, entries, cursor, delta, tail_hash, additions)
                    publish_exclusive_copy(parent, output_path.name, output, cursor, checked_hash)
                elif sys.platform == "darwin":
                    darwin_rename_exclusive(parent, temporary, output_path.name)
                    temporary = None  # Rename consumed the staging name.
                else:
                    os.link(temporary, output_path.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
        finally:
            try:
                if temporary is not None:
                    unlink_if_owned(parent, temporary, temporary_identity)
            finally:
                os.close(parent)

    return {"original_entries": len(index.entries), "output_entries": len(entries),
            "offset_delta": delta, "opaque_tail_bytes": original_stat.st_size - index.end,
            "opaque_tail_sha256": tail_hash, "output_bytes": cursor,
            "added_entries": [n.decode("ascii") for n in OWN_NAMES],
            "publish_mode": publish_mode, "publication_atomic": publish_mode == "atomic"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--bootstrap", type=Path, required=True)
    parser.add_argument("--dictionary", type=Path, required=True)
    parser.add_argument("--expected-entries", type=int)
    parser.add_argument("--publish-mode", choices=("atomic", "exclusive-copy"), default="atomic",
                        help="exclusive-copy exposes a partial new cache until successful exit; promote only after success")
    args = parser.parse_args()
    try:
        result = append_archive(args.source, args.output, args.bootstrap, args.dictionary, args.expected_entries, publish_mode=args.publish_mode)
    except (OSError, ValueError) as error:
        parser.exit(1, "error: " + str(error) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
