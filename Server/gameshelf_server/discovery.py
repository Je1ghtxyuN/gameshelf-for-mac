"""Small read-only probes; complete-directory grouping, never executable import."""
import hashlib
import os
from pathlib import Path
import re
import stat
import unicodedata

# Exact metadata/script whitelist shared with MZWebProfile.sakura in Core.swift.
# This is a developer-maintained compatibility profile, not an admin/API opt-in.
MZ_WEB_PROFILE_SAKURA = {
    'package.json':'7a5f59321b3d8f6c6a657b3018d2f78cc7b542722b1673a0c4fcbb0a32d35fb7',
    'js/main.js':'122d02193c3e89c81e21cb5e7bee698f1f473ea55af31b91c3e29e28c04f871f',
    'js/plugins.js':'827678222c355214b53f8ce300aff11bef3321a6e732232975d23f2eb099402b',
    'js/rmmz_core.js':'03c5a7454c2f9303ccced4589304c341c12bbed6c24c6132e1a4e627347d6569',
    'js/rmmz_managers.js':'d1575c2ee01d1ecc3aa7dc88e1a04f5028717f7e807f4662d47daf94d79b7f7d',
}
MZ_PROFILE_FILE_LIMIT = 2*1024*1024


def _open_profile_root(directory):
    path=Path(directory)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Profile root must be absolute and confined')
    descriptor=os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        for component in path.parts[1:]:
            child=os.open(component,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            os.close(descriptor); descriptor=child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _open_profile_file(root,name):
    path=Path(name)
    if not isinstance(name,str) or not path.parts or path.is_absolute() or '..' in path.parts or name!=path.as_posix() or '\\' in name:
        raise ValueError('Unsafe profile-relative filename')
    descriptor=os.dup(root)
    try:
        for component in path.parts[:-1]:
            child=os.open(component,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            os.close(descriptor); descriptor=child
        file=os.open(path.parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=descriptor)
    finally:
        os.close(descriptor)
    try:
        if not stat.S_ISREG(os.fstat(file).st_mode):
            raise ValueError('Profile requires regular files')
        return file
    except BaseException:
        os.close(file)
        raise


def matches_mz_web_profile(directory,fingerprints=None):
    """Read only the five small whitelisted metadata files, at most 2 MiB each.

    All root/relative components use descriptor-relative O_NOFOLLOW. HTML needs
    only a regular-file check; no game asset, archive or executable is hashed.
    Empty, changed, unavailable, linked, oversized or nonregular profiles fail
    closed and leave ordinary Wine entrances available.
    """
    profile=MZ_WEB_PROFILE_SAKURA if fingerprints is None else fingerprints
    if not isinstance(profile,dict) or not 1<=len(profile)<=5:
        return False
    root=None
    try:
        root=_open_profile_root(directory)
        index=_open_profile_file(root,'index.html')
        os.close(index)
        for name,expected in sorted(profile.items()):
            if not isinstance(expected,str) or not re.fullmatch('[0-9a-f]{64}',expected):
                return False
            file=_open_profile_file(root,name)
            try:
                before=os.fstat(file)
                if not 0<=before.st_size<=MZ_PROFILE_FILE_LIMIT:
                    return False
                digest=hashlib.sha256(); size=0
                while size<=MZ_PROFILE_FILE_LIMIT:
                    data=os.read(file,min(65536,MZ_PROFILE_FILE_LIMIT+1-size))
                    if not data:
                        break
                    size+=len(data); digest.update(data)
                after=os.fstat(file)
                if size!=before.st_size or size>MZ_PROFILE_FILE_LIMIT or (before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_size,after.st_mtime_ns,after.st_ctime_ns):
                    return False
                if digest.hexdigest()!=expected:
                    return False
            finally:
                os.close(file)
        return True
    except (OSError,ValueError,TypeError):
        return False
    finally:
        if root is not None:
            os.close(root)


RESOURCES = set('data gamedata graphics audio image images movies video sound sounds save saves savedata fonts font www js game renpy lib libs runtime runtimes node_modules locales plugins system cache logs tools redist _commonredist prerequisites directx resources contents'.split())
AUXILIARY = set('thprac replayview cs2conf filecheck helper checker config configuration custom setting settings setup setup32 setup64 install installer unins uninstall uninstaller dxsetup vcredist vcredist_x86 vcredist_x64 vc_redist.x86 vc_redist.x64 dotnet dotnetfx unitycrashhandler unitycrashhandler32 unitycrashhandler64 crashreport crashreporter'.split()) | {'エンジン設定','設定','设置','環境設定','环境设置','环境设定','游戏设置','遊戲設定','ゲーム設定'}
CONVENTIONAL = re.compile(r'^(?:(?:config|configuration|custom|settings?|replayview|thprac)(?:[0-9]+|[._ -](?:tool|settings?|x86|x64|32|64|jp|ja|en|cn|chs|c|sc|zh[_-]cn))|th[0-9]+[._ -]update[0-9][a-z0-9._-]*|(?:unins|uninstall|uninstaller)[0-9]*(?:[._ -][a-z0-9]+)*)$')
CHINESE = re.compile(r'(?:^|[_\- .\[\(【（])(?:cn|chs|sc|zh[_-]cn)[\]\)】）]*$|(?:中文版|汉化(?:版)?|漢化(?:版)?|简体中文(?:版)?|簡體中文(?:版)?)[\]\)】）]*$')

def header(directory,name,count=2):
    # Each component is opened without following symlinks; reads stay bounded.
    descriptor=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        parts=Path(name).parts
        for part in parts[:-1]:
            child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            os.close(descriptor); descriptor=child
        fd=os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=descriptor)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return b''
            return os.read(fd,count)
        finally:
            os.close(fd)
    except OSError:
        return b''
    finally:
        os.close(descriptor)

def auxiliary(name):
    stem=unicodedata.normalize('NFC',Path(name).stem).lower()
    return stem in AUXILIARY or CONVENTIONAL.fullmatch(stem) is not None

def order(name):
    normalized=unicodedata.normalize('NFC',Path(name).stem).lower()
    natural=tuple((1,int(p)) if p.isdigit() else (0,p) for p in re.split(r'(\d+)',normalized))
    return (not bool(CHINESE.search(normalized)),natural,name)

def discover(directory,dirs,files):
    names={n.lower() for n in files if not (directory/n).is_symlink()}
    renpy=(directory/'renpy').is_dir() and not (directory/'renpy').is_symlink()
    engine='unknown'
    if renpy:
        engine='renpy'
    elif header(directory,'js/rmmz_core.js') or header(directory,'www/js/rmmz_core.js'):
        engine='RPG Maker MZ'
    elif header(directory,'js/rpg_core.js') or header(directory,'www/js/rpg_core.js'):
        engine='RPG Maker MV'
    elif 'game.rgss3a' in names:
        engine='RPG Maker VX Ace'
    elif 'game.rgss2a' in names:
        engine='RPG Maker VX'
    elif 'game.rgssad' in names:
        engine='RPG Maker XP'
    elif 'unityplayer.dll' in names:
        engine='Unity'
    entries=[]
    for name in sorted(files,key=order):
        p=directory/name
        if name.startswith('.') or p.is_symlink() or not p.is_file():
            continue
        if p.suffix.lower()=='.exe' and not auxiliary(name) and header(directory,name)==b'MZ':
            entries.append(dict(path=name,backend='renpy' if renpy else 'wine',engine=engine))
        elif p.suffix.lower()=='.sh' and renpy and header(directory,name)==b'#!':
            entries.append(dict(path=name,backend='renpy',engine='renpy'))
    if engine=='RPG Maker MZ' and any(e['path']=='Game.exe' and e['backend']=='wine' for e in entries) and matches_mz_web_profile(directory):
        entries.insert(0,dict(path='index.html',backend='rpgmz',engine='RPG Maker MZ'))
    apps=[]
    for name in sorted(dirs):
        app=directory/name
        if name.lower().endswith('.app') and not app.is_symlink():
            known=('Contents/Resources/autorun/renpy','Contents/Resources/renpy','Contents/Resources/app/renpy')
            app_engine='renpy' if any((app/p).is_dir() for p in known) else 'unknown'
            apps.append(dict(path=name,backend='native',engine=app_engine))
    # A raw NW.js package is not automatically a safe web backend.
    if not entries and not apps and 'index.html' in names and not names.intersection({'package.json','nw.dll'}):
        entries.append(dict(path=next(n for n in files if n.lower()=='index.html'),backend='web',engine='webkit'))
    entries+=apps
    strong=(engine not in ('unknown','renpy')) or (renpy and bool(header(directory,'renpy/__init__.py')))
    context=bool(entries) or strong
    children=sorted(n for n in dirs if not n.startswith('.') and not (directory/n).is_symlink()
                    and not n.lower().endswith('.app') and (not context or (n.lower() not in RESOURCES and not n.lower().endswith('_data'))))
    return entries,children
