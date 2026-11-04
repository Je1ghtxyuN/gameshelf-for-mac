"""Conservative seed-save exclusion rules. Never infer generic asset extensions."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat

from .service import APIError, text

SAVE_FILE = re.compile(r'(\.(sav|save|rpgsave|rmmzsave)$|^save[0-9]+\.(rxdata|rvdata|rvdata2)$)',re.I)
SAVE_DIRS = ('save','saves','savedata','game/saves','www/save')

def normalize_rules(rules, root=None):
    if not isinstance(rules,list) or len(rules)>2048:
        raise APIError(400,'savePaths must be an array of at most 2048 {path,kind} rules')
    result = {}
    pending = list(rules)
    while pending:
        rule = pending.pop()
        if not isinstance(rule,dict) or set(rule) != {'path','kind'} or rule['kind'] not in ('file','directory'):
            raise APIError(400,'Save rule requires path and kind (file or directory)')
        value = text(rule['path'],4096)
        p = PurePosixPath(value)
        if p.is_absolute() or value != p.as_posix() or any(x in ('..','.') for x in value.split('/')) or any(c in value for c in '\\:') or p.parts[0] == '.gameshelf-profile':
            raise APIError(400,'Save path must be relative, canonical and outside the reserved profile')
        kind = rule['kind']
        if value in result:
            if result[value] != kind:
                raise APIError(400,'Conflicting save path kinds')
            continue
        result[value] = kind
        if root is not None:
            path = root/value
            # Resolve existing parents too: a configured path cannot traverse a link outside the game.
            try:
                resolved = path.resolve(strict=False)
            except (OSError,RuntimeError):
                raise APIError(400,'Invalid save path link') from None
            if resolved == root or root not in resolved.parents:
                raise APIError(400,'Save path escapes game')
            if path.exists():
                if path.is_dir() != (kind=='directory'):
                    raise APIError(400,'Save path kind does not match source')
                canonical = resolved.relative_to(root).as_posix()
                if canonical != value:
                    pending.append(dict(path=canonical,kind=kind))
    return [dict(path=p,kind=result[p]) for p in sorted(result)]

def detect_rules(root):
    rules=[]
    for directory,dirs,files in os.walk(root,followlinks=False):
        for name in dirs:
            p=Path(directory)/name
            rel=p.relative_to(root).as_posix()
            if rel.lower() in SAVE_DIRS:
                rules.append(dict(path=rel,kind='directory'))
        for name in files:
            if SAVE_FILE.search(name):
                p=Path(directory)/name
                rules.append(dict(path=p.relative_to(root).as_posix(),kind='file'))
    return normalize_rules(rules,root)

def rules_digest(rules):
    return hashlib.sha256(json.dumps(normalize_rules(rules),sort_keys=True).encode()).hexdigest()

def atomic_json(path,data):
    tmp=path.with_suffix('.tmp')
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as f:
        json.dump(data,f,sort_keys=True)
        f.flush(); os.fsync(f.fileno())
    tmp.replace(path)

def begin_initialization(paths,rules):
    """A missing manifest on an existing upper is corruption, never a reset."""
    base=paths['upper'].parent
    expected=dict(version=1,saveRulesSHA256=rules_digest(rules))
    complete,started=base/'initialized.json',base/'initializing.json'
    for marker in (complete,started):
        if marker.is_symlink():
            raise RuntimeError('Unsafe initialization marker')
        if marker.exists():
            if json.loads(marker.read_text()) != expected:
                raise RuntimeError('Workspace privacy manifest mismatch')
            return marker == started
    if any(paths['upper'].iterdir()):
        raise RuntimeError('Existing workspace has no privacy manifest; manual review required')
    atomic_json(started,expected)
    return True

def mask_seed_saves(view,rules,unix_uid,*,chown=os.chown):
    """Run ONLY in a mounted private overlay, before any share is published.

    Unlink/rmtree causes overlay whiteouts; an empty directory retains opacity.
    No source copy, migration, delete or chmod is performed outside this view.
    """
    for rule in sorted(normalize_rules(rules),key=lambda r:len(PurePosixPath(r['path']).parts),reverse=True):
        path=view/rule['path']
        parent=path.parent.resolve(strict=False)
        if parent != view and view not in parent.parents:
            raise RuntimeError('Save exclusion escapes private view')
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        if rule['kind']=='directory':
            path.mkdir(mode=0o700,parents=True,exist_ok=True)
            ancestor=path
            while ancestor != view:
                chown(ancestor,unix_uid,unix_uid)
                ancestor=ancestor.parent
    # Sync upper changes before the durable manifest permits export.
    fd=os.open(view,os.O_RDONLY|os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def finish_initialization(paths):
    base=paths['upper'].parent
    (base/'initializing.json').replace(base/'initialized.json')
    fd=os.open(base,os.O_RDONLY|os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
