import Foundation
import CryptoKit
import Darwin
// Compile with Core, VisualNovelProbe, NativeAppIdentity, NativeAppCache and NativeRenpyBootstrap.

@main struct NativeRenpyBootstrapTests {
 static let fm=FileManager.default
 struct Failure:Error,CustomStringConvertible {let description:String}
 static func check(_ ok:Bool,_ message:String)throws{if !ok{throw Failure(description:message)}}
 static func write(_ url:URL,_ text:String)throws {try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url)}
 static let launcher = #"""
#!/usr/bin/env python

# This file is part of Ren'Py. The license below applies to Ren'Py only.
# Games and other projects that use Ren'Py may use a different license.

# Copyright 2004-2025 Tom Rothamel <pytom@bishoujo.us>
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software,
# and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

from __future__ import print_function, absolute_import

import os
import sys
import warnings

# Functions to be customized by distributors. ################################

def path_to_gamedir(basedir, name):
    """
    Returns the absolute path to the directory containing the game
    scripts an assets. (This becomes config.gamedir.)

    `basedir`
        The base directory (config.basedir)
    `name`
        The basename of the executable, with the extension removed.
    """

    # A list of candidate game directory names.
    candidates = [ name ]

    # Add candidate names that are based on the name of the executable,
    # split at spaces and underscores.
    game_name = name

    while game_name:
        prefix = game_name[0]
        game_name = game_name[1:]

        if prefix == ' ' or prefix == '_':
            candidates.append(game_name)

    # Add default candidates.
    candidates.extend([ 'game', 'data', 'launcher/game' ])

    # Take the first candidate that exists.
    for i in candidates:

        if i == "renpy":
            continue

        gamedir = os.path.join(basedir, i)

        if os.path.isdir(gamedir):
            break

    else:
        gamedir = basedir

    return gamedir


def path_to_common(renpy_base):
    """
    Returns the absolute path to the Ren'Py common directory.

    `renpy_base`
        The absolute path to the Ren'Py base directory, the directory
        containing this file.
    """
    path = renpy_base + "/renpy/common"

    if os.path.isdir(path):
        return path
    return None


def path_to_saves(gamedir, save_directory=None): # type: (str, str|None) -> str
    """
    Given the path to a Ren'Py game directory, and the value of config.
    save_directory, returns absolute path to the directory where save files
    will be placed.

    `gamedir`
        The absolute path to the game directory.

    `save_directory`
        The value of config.save_directory.
    """

    import renpy # @UnresolvedImport

    if save_directory is None:
        save_directory = renpy.config.save_directory
        save_directory = renpy.exports.fsencode(save_directory) # type: ignore

    # Makes sure the permissions are right on the save directory.
    def test_writable(d):
        try:
            fn = os.path.join(d, "test.txt")
            open(fn, "w").close()
            open(fn, "r").close()
            os.unlink(fn)
            return True
        except Exception:
            return False

    # Android.
    if renpy.android:
        paths = [
            os.path.join(os.environ["ANDROID_OLD_PUBLIC"], "game/saves"),
            os.path.join(os.environ["ANDROID_PRIVATE"], "saves"),
            os.path.join(os.environ["ANDROID_PUBLIC"], "saves"),
            ]

        for rv in paths:
            if os.path.isdir(rv) and test_writable(rv):
                break
        else:
            rv = paths[-1]

        print("Saving to", rv)
        return rv

    if renpy.ios:
        from pyobjus import autoclass # type: ignore
        from pyobjus.objc_py_types import enum # type: ignore

        NSSearchPathDirectory = enum("NSSearchPathDirectory", NSDocumentDirectory=9)
        NSSearchPathDomainMask = enum("NSSearchPathDomainMask", NSUserDomainMask=1)

        NSFileManager = autoclass('NSFileManager')
        manager = NSFileManager.defaultManager()
        url = manager.URLsForDirectory_inDomains_(
            NSSearchPathDirectory.NSDocumentDirectory,
            NSSearchPathDomainMask.NSUserDomainMask,
            ).lastObject()

        # url.path seems to change type based on iOS version, for some reason.
        try:
            rv = url.path().UTF8String()
        except Exception:
            rv = url.path.UTF8String()


        if isinstance(rv, bytes):
            rv = rv.decode("utf-8")

        print("Saving to", rv)
        return rv

    # No save directory given.
    if not save_directory:
        return os.path.join(gamedir, "saves")

    if "RENPY_PATH_TO_SAVES" in os.environ:
        return os.environ["RENPY_PATH_TO_SAVES"] + "/" + save_directory

    # Search the path above Ren'Py for a directory named "Ren'Py Data".
    # If it exists, then use that for our save directory.
    path = renpy.config.renpy_base

    while True:
        if os.path.isdir(path + "/Ren'Py Data"):
            return path + "/Ren'Py Data/" + save_directory

        newpath = os.path.dirname(path)
        if path == newpath:
            break
        path = newpath

    # Otherwise, put the saves in a platform-specific location.
    if renpy.macintosh:
        rv = "~/Library/RenPy/" + save_directory
        return os.path.expanduser(rv)

    elif renpy.windows:
        if 'APPDATA' in os.environ:
            return os.environ['APPDATA'] + "/RenPy/" + save_directory
        else:
            rv = "~/RenPy/" + renpy.config.save_directory # type: ignore
            return os.path.expanduser(rv)

    else:
        rv = "~/.renpy/" + save_directory
        return os.path.expanduser(rv)


# Returns the path to the Ren'Py base directory (containing common and
# the launcher, usually.)
def path_to_renpy_base():
    """
    Returns the absolute path to the Ren'Py base directory.
    """

    renpy_base = os.path.dirname(os.path.abspath(__file__))
    renpy_base = os.path.abspath(renpy_base)

    return renpy_base

def path_to_logdir(basedir):
    """
    Returns the absolute path to the log directory.
    `basedir`
        The base directory (config.basedir)
    """

    import renpy # @UnresolvedImport

    if renpy.android:
        return os.environ['ANDROID_PUBLIC']

    return basedir

def predefined_searchpath(commondir):
    import renpy # @UnresolvedImport

    # The default gamedir, in private.
    searchpath = [ renpy.config.gamedir ]

    if renpy.android:
        # The public android directory.
        if "ANDROID_PUBLIC" in os.environ:
            android_game = os.path.join(os.environ["ANDROID_PUBLIC"], "game")

            if os.path.exists(android_game):
                searchpath.insert(0, android_game)

        # Asset packs.
        packs = [
            "ANDROID_PACK_FF1", "ANDROID_PACK_FF2",
            "ANDROID_PACK_FF3", "ANDROID_PACK_FF4",
        ]

        for i in packs:
            if i not in os.environ:
                continue

            assets = os.environ[i]

            for i in [ "renpy/common", "game" ]:
                dn = os.path.join(assets, i)
                if os.path.isdir(dn):
                    searchpath.append(dn)
    else:
        # Add path from env variable, if any
        if "RENPY_SEARCHPATH" in os.environ:
            searchpath.extend(os.environ["RENPY_SEARCHPATH"].split("::"))

    if commondir and os.path.isdir(commondir):
        searchpath.append(commondir)

    if renpy.android or renpy.ios:
        print("Mobile search paths:" , " ".join(searchpath))

    return searchpath

##############################################################################


android = ("ANDROID_PRIVATE" in os.environ)

def main():

    renpy_base = path_to_renpy_base()

    sys.path.append(renpy_base)

    # Ignore warnings.
    warnings.simplefilter("ignore", DeprecationWarning)

    # Start Ren'Py proper.
    try:
        import renpy.bootstrap
    except ImportError:
        print("Could not import renpy.bootstrap. Please ensure you decompressed Ren'Py", file=sys.stderr)
        print("correctly, preserving the directory structure.", file=sys.stderr)
        raise

    # Set renpy.__main__ to this module.
    renpy.__main__ = sys.modules[__name__] # type: ignore

    renpy.bootstrap.bootstrap(renpy_base)


if __name__ == "__main__":
    main()

"""#
 static let errorModule = #"""
# Copyright 2004-2025 Tom Rothamel <pytom@bishoujo.us>
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software,
# and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# This file contains code for formatting tracebacks.

from __future__ import division, absolute_import, with_statement, print_function, unicode_literals
from renpy.compat import PY2, basestring, bchr, bord, chr, open, pystr, range, round, str, tobytes, unicode # *



import traceback
import sys
import io
import platform
import linecache
import time
import os

import renpy

FSENCODING = sys.getfilesystemencoding() or "utf-8"


def write_traceback_list(out, l):
    """
    Given the traceback list, writes it to out as unicode.
    """

    ul = [ ]

    for filename, line, what, text in l:

        # Filename is either unicode or fsecoded bytes.
        if isinstance(filename, bytes):
            filename = filename.decode(FSENCODING)

        # Line is a number.

        # Assume what is in a unicode encoding, since it is either python,
        # or comes from inside Ren'Py.

        if isinstance(text, bytes):
            text = text.decode("utf-8")

        ul.append((filename, line, what, text))

    for t in traceback.format_list(ul):
        out.write(t)


def traceback_list(tb):
    """
    Given `tb`, returns a list of (filename, line_number, function, line_text)
    tuples.
    """

    l = [ ]

    while tb:
        frame = tb.tb_frame
        line_number = tb.tb_lineno
        code = frame.f_code
        filename = code.co_filename
        name = code.co_name

        tb = tb.tb_next

        if ('self' in frame.f_locals) and (not renpy.config.raw_tracebacks):
            obj = frame.f_locals['self']

            last = (tb is None)

            try:
                report = obj.report_traceback(name, last)

                if report is not None:
                    l.extend(report)
                    continue
            except Exception:
                pass

        l.append((filename, line_number, name, None))

    rv = [ ]

    for filename, line_number, name, line in l:
        if line is None:
            try:
                line = linecache.getline(filename, line_number)
            except Exception:
                line = ''

        rv.append((filename, line_number, name, line))

    return rv


def filter_traceback_list(tl):
    """
    Returns the subset of `tl` that originates in creator-written files, as
    opposed to those portions that come from Ren'Py itself.
    """

    rv = [ ]

    for t in tl:
        filename = t[0]
        if filename.endswith(".rpy") and not filename.replace("\\", "/").startswith("common/"):
            rv.append(t)

    return rv


def open_error_file(fn, mode):
    """
    Opens an error/log/file. Returns the open file, and the filename that
    was opened.
    """

    try:
        new_fn = os.path.join(renpy.config.logdir, fn) # type: ignore
        f = open(new_fn, mode)
        return f, new_fn
    except Exception:
        pass

    try:
        f = open(fn, mode)
        return f, fn
    except Exception:
        pass

    import tempfile

    new_fn = os.path.join(tempfile.gettempdir(), "renpy-" + fn)
    return open(new_fn, mode), new_fn


def report_exception(e, editor=True):
    """
    Reports an exception by writing it to standard error and
    traceback.txt. If `editor` is True, opens the traceback
    up in a text editor.

    Returns a three-item tuple, with the first item being
    a simplified traceback, the second being a full traceback,
    and the third being the traceback filename.
    """

    # Note: Doki Doki Literature club calls this as ("Words...", False).
    # For what it's worth.

    if not int(os.environ.get("RENPY_REPORT_EXCEPTIONS", "1")):
        raise

    # The sound system may not be ready during exception handling.
    renpy.config.debug_sound = False

    import codecs

    type, _value, tb = sys.exc_info() # @ReservedAssignment

    # Return values - which can be displayed to the user.
    simple = io.StringIO()
    full = io.StringIO()

    full_tl = traceback_list(tb)
    simple_tl = filter_traceback_list(full_tl)

    print(str(renpy.game.exception_info), file=simple)
    write_traceback_list(simple, simple_tl)
    print(type.__name__ + ":", end=' ', file=simple)
    print(str(e), file=simple)

    print("Full traceback:", file=full)
    write_traceback_list(full, full_tl)
    print(type.__name__ + ":", end=' ', file=full)
    print(str(e), file=full)

    # Write to stdout/stderr.
    try:
        sys.stdout.write("\n")
        sys.stdout.write(full.getvalue())
        sys.stdout.write("\n")
        sys.stdout.write(simple.getvalue())
    except Exception:
        pass

    print('', file=full)

    try:
        print(str(platform.platform()), str(platform.machine()), file=full)
        print(renpy.version, file=full)
        print(renpy.config.name + " " + renpy.config.version, file=full)
        print(str(time.ctime()), file=full)
    except Exception:
        pass

    simple = simple.getvalue()
    full = full.getvalue()

    # Inside of the file, which may not be openable.
    try:

        f, traceback_fn = open_error_file("traceback.txt", "w")

        with f:
            f.write("\ufeff") # BOM

            print("I'm sorry, but an uncaught exception occurred.", file=f)
            print('', file=f)

            f.write(simple)

            print('', file=f)
            print("-- Full Traceback ------------------------------------------------------------", file=f)
            print('', file=f)

            f.write(full)

        try:
            renpy.util.expose_file(traceback_fn)
        except Exception:
            pass

        try:
            if editor and ((renpy.game.args.command == "run") or (renpy.game.args.errors_in_editor)): # type: ignore
                renpy.exports.launch_editor([ traceback_fn ], 1, transient=True)
        except Exception:
            pass

    except Exception:
        traceback_fn = os.path.join(renpy.config.basedir, "traceback.txt") # type: ignore

    return simple, full, traceback_fn

"""#
 static let version = #"""
branch = 'fix'
nightly = False
official = True
version = '8.3.7.25031702'
version_name = 'Second Star to the Right'

"""#
 static let driver = #"""
import sys, os, json, types, builtins, runpy, importlib
# Model an embedded interpreter ignoring PYTHONDONTWRITEBYTECODE.
sys.dont_write_bytecode = False
base, forced, filename = sys.argv[1:4]
os.chdir(base)
sys.path.insert(0, base)
launcher = runpy.run_path(os.path.join(base, 'NewHorizon.py'), run_name='synthetic_launcher')
import renpy
import renpy.synthetic_module
compat = types.ModuleType('renpy.compat')
for name in ['str','range','round','chr','open']:
    setattr(compat, name, getattr(builtins,name))
compat.PY2=False
compat.basestring=str;compat.bchr=lambda x:bytes([x]);compat.bord=ord
compat.pystr=str;compat.tobytes=lambda x:x.encode();compat.unicode=str
sys.modules['renpy.compat']=compat
error = importlib.import_module('renpy.error')
logdir = launcher['path_to_logdir'](base)
renpy.config = types.SimpleNamespace(logdir=forced or logdir)
attempts = []
original_open = error.open
def tracked_open(path, mode):
    attempts.append(path)
    if os.environ.get('GAMESHELF_TEST_FAIL_OPENS') == '1':
        raise OSError('synthetic denied write')
    return original_open(path, mode)
error.open = tracked_open
try:
    f, path = error.open_error_file(filename, 'w')
    f.write('synthetic traceback only');f.close()
    failure = None
except (OSError, ValueError) as exc:
    path = None
    failure = str(exc)
print(json.dumps({'bytecodeDisabled':sys.dont_write_bytecode,'logdir':logdir,
                  'traceback':os.path.realpath(path) if path else None,
                  'failure':failure,'attempts':attempts},ensure_ascii=False))
"""#
 static func fixture(_ root:URL,_ suffix:String)throws->URL {
  let app=root.appendingPathComponent(".preparing-"+suffix+".app"),base=app.appendingPathComponent("Contents/Resources/autorun")
  try write(base.appendingPathComponent("NewHorizon.py"),launcher)
  try write(base.appendingPathComponent("renpy/error.py"),errorModule)
  try write(base.appendingPathComponent("renpy/vc_version.py"),version)
  try write(base.appendingPathComponent("renpy/__init__.py"),"android = False\n")
  try write(base.appendingPathComponent("renpy/synthetic_module.py"),"VALUE = 42\n")
  try PropertyListSerialization.data(fromPropertyList:["CFBundleExecutable":"NewHorizon","CFBundleName":"Synthetic RenPy","CFBundlePackageType":"APPL","CFBundleIdentifier":"org.gameshelf.synthetic"],format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
  return app
 }
 static func snapshot(_ root:URL)throws->[String:String] {
  var result:[String:String]=[:]
  for case let url as URL in fm.enumerator(at:root,includingPropertiesForKeys:nil)! {
   if (try fm.attributesOfItem(atPath:url.path)[.type]) as? FileAttributeType == .typeRegular {
    result[String(url.path.dropFirst(root.path.count))]=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
   }
  }
  return result
 }
 static func run(_ app:URL,_ root:URL,log:String?,forced:String="",filename:String="traceback.txt",failOpens:Bool=false)throws->[String:Any] {
  let script=root.appendingPathComponent("driver.py");try write(script,driver)
  let p=Process(),done=DispatchSemaphore(value:0),out=Pipe(),err=Pipe()
  p.executableURL=URL(fileURLWithPath:"/usr/bin/env");p.arguments=["python3","-E",script.path,app.appendingPathComponent("Contents/Resources/autorun").path,forced,filename]
  var environment=ProcessInfo.processInfo.environment
  environment["HOME"]=root.appendingPathComponent("Synthetic Home").path
  environment["TMPDIR"]=app.appendingPathComponent("Contents/Resources/autorun").path
  environment["PYTHONDONTWRITEBYTECODE"]="1"
  environment["RENPY_LOG_BASE"]=log
  environment["GAMESHELF_TEST_FAIL_OPENS"]=failOpens ? "1":"0"
  p.environment=environment;p.standardOutput=out;p.standardError=err;p.terminationHandler={_ in done.signal()}
  try p.run()
  guard done.wait(timeout:.now()+10) == .success else{if p.isRunning{Darwin.kill(p.processIdentifier,SIGKILL)};throw Failure(description:"Python synthetic timeout")}
  let output=out.fileHandleForReading.readDataToEndOfFile(),error=err.fileHandleForReading.readDataToEndOfFile()
  try check(p.terminationStatus==0,"Python failed: "+String(decoding:error,as:UTF8.self))
  return try JSONSerialization.jsonObject(with:output) as! [String:Any]
 }
 static func outside(_ path:String,_ app:URL)->Bool {
  let base=app.resolvingSymlinksInPath().path
  let path=URL(fileURLWithPath:path).resolvingSymlinksInPath().path
  return path.hasPrefix("/") && path != base && !path.hasPrefix(base+"/")
 }
 static func exercise(_ app:URL,_ root:URL,log:String?,forced:String="",filename:String="traceback.txt",failOpens:Bool=false)throws->[String:Any] {
  let before=try snapshot(app),result=try run(app,root,log:log,forced:forced,filename:filename,failOpens:failOpens)
  try check(result["bytecodeDisabled"] as? Bool == true,"RED: embedded-style Python still permits __pycache__ writes")
  try check(try snapshot(app)==before,"sealed app changed after real Python import/errorfile")
  for path in result["attempts"] as? [String] ?? []{try check(outside(path,app),"relative or bundle error-file fallback attempted")}
  if let path=result["traceback"] as? String {
   try check(outside(path,app),"error file stayed in bundle")
   if path.hasPrefix("/private/tmp/gameshelf-renpy-"){try fm.removeItem(at:URL(fileURLWithPath:path).deletingLastPathComponent())}
  }
  return result
 }
 static func rejects(_ action:()throws->Void)throws {
  do{try action()}catch{return};throw Failure(description:"unsafe stage accepted")
 }
 static func integration(_ root:URL)throws {
  let source=try fixture(root,"integration-source")
  let base=source.appendingPathComponent("Contents/Resources/autorun")
  try write(base.appendingPathComponent("game/inert-payload.txt"),"Synthetic payload, never run")
  let c=root.appendingPathComponent("synthetic-engine.c");try write(c,"int main(void) { return 0; }\n")
  let exe=source.appendingPathComponent("Contents/MacOS/NewHorizon")
  try fm.createDirectory(at:exe.deletingLastPathComponent(),withIntermediateDirectories:true)
  let clang=Process(),done=DispatchSemaphore(value:0)
  clang.executableURL=URL(fileURLWithPath:"/usr/bin/clang");clang.arguments=[c.path,"-o",exe.path];clang.terminationHandler={_ in done.signal()}
  try clang.run();guard done.wait(timeout:.now()+30) == .success else{if clang.isRunning{Darwin.kill(clang.processIdentifier,SIGKILL)};throw Failure(description:"synthetic Mach-O compile timed out")}
  try check(clang.terminationStatus==0,"Mach-O fixture compile")
  let sourceBefore=try snapshot(source)
  let game=Game(title:"Synthetic only",folder:source.path,originalFolder:source.path,entry:Candidate(path:".",backend:.native,engine:"macOS"))
  let cacheRoot=root.appendingPathComponent("Integration Cache")
  let first=try NativeAppCache.prepare(game:game,root:cacheRoot,runningCheck:{_ in false})
  try check(first.cached,"integration did not use cache")
  let receipt=cacheRoot.appendingPathComponent("NativeApps/"+game.id.uuidString+".json")
  let bytes=try Data(contentsOf:receipt),values=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
  try check(values["bootstrapProfile"] as? String == NativeRenpyBootstrap.profileID,"adapter profile missing from receipt")
  let identifier="local.gameshelf.native."+game.id.uuidString.lowercased()
  try NativeAppIdentity.verify(first.app,identifier:identifier,excluding:["Contents/Resources/autorun/game"])
  let sealedBefore=try snapshot(first.app)
  _ = try exercise(first.app,root,log:root.appendingPathComponent("Integration Logs").path)
  try NativeAppIdentity.verify(first.app,identifier:identifier,excluding:["Contents/Resources/autorun/game"])
  let inode=try fm.attributesOfItem(atPath:first.app.appendingPathComponent("Contents/MacOS/NewHorizon").path)[.systemFileNumber] as! NSNumber
  let second=try NativeAppCache.prepare(game:game,root:cacheRoot,runningCheck:{_ in false})
  let secondInode=try fm.attributesOfItem(atPath:second.app.appendingPathComponent("Contents/MacOS/NewHorizon").path)[.systemFileNumber] as! NSNumber
  try check(first.app==second.app && inode==secondInode,"second prepare replaced/re-signed app")
  try check(try snapshot(second.app)==sealedBefore,"second prepare altered seal")
  try check(try Data(contentsOf:receipt)==bytes,"second prepare rewrote receipt")
  try check(try snapshot(source)==sourceBefore,"source app modified")
  print("PASS NativeCache integration: real Mach-O stub, adapted sealed Python import/errorfile, strict signature verification, identical inode/seal/receipt on second prepare, original source unchanged")
 }
 static func main()throws {
  let root=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("build/validation/renpy-bootstrap/run-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  let app=try fixture(root,"normal"),logs=root.appendingPathComponent("External 日志")
  let original=try snapshot(app)
  try check(NativeRenpyBootstrap.profile(source:app,executableName:"NewHorizon")==NativeRenpyBootstrap.profileID,"official profile not recognized")
  try check(try snapshot(app)==original,"source recognition changed files")
  try check(try NativeRenpyBootstrap.prepare(stage:app,executableName:"NewHorizon"),"known template not adapted")
  let sealed=try snapshot(app)
  try check(try !NativeRenpyBootstrap.prepare(stage:app,executableName:"NewHorizon"),"adapter not idempotent")
  try check(try snapshot(app)==sealed,"repeat adaptation changed files")
  let result=try exercise(app,root,log:logs.path)
  try check(result["traceback"] as? String == logs.appendingPathComponent("traceback.txt").path,"traceback ignored external RENPY_LOG_BASE")
  print("PASS real Python: bytecode disabled before imports; preferred traceback external; sealed stage unchanged; profile read-only; adaptation idempotent")
  for (name,log) in [("missing",Optional<String>.none),("empty",Optional("")),("relative",Optional("relative-logs")),("bundle",Optional(app.appendingPathComponent("Contents/Resources/autorun").path))] {
   let result=try exercise(app,root,log:log)
   try check(result["traceback"] is String,"fallback log missing: "+name)
  }
  let alias=root.appendingPathComponent("Log Alias");try fm.createSymbolicLink(at:alias,withDestinationURL:app)
  _ = try exercise(app,root,log:alias.path)
  let blocker=root.appendingPathComponent("not-a-directory");try write(blocker,"blocked")
  for forced in [blocker.path,app.appendingPathComponent("Contents/Resources/autorun").path] {
   let result=try exercise(app,root,log:logs.path,forced:forced)
   try check((result["traceback"] as? String)?.hasPrefix("/private/tmp/gameshelf-renpy-")==true,"error fallback was not local external temp")
  }
  let poisoned=root.appendingPathComponent("Poisoned Logs");try fm.createDirectory(at:poisoned,withIntermediateDirectories:true)
  try fm.createSymbolicLink(at:poisoned.appendingPathComponent("traceback.txt"),withDestinationURL:app.appendingPathComponent("traceback.txt"))
  _ = try exercise(app,root,log:logs.path,forced:poisoned.path)
  let denied=try exercise(app,root,log:logs.path,failOpens:true)
  try check(denied["failure"] is String && (denied["attempts"] as? [String])?.count==2,"failed external writes did not fail closed")
  let traversal=try exercise(app,root,log:logs.path,filename:"../traceback.txt")
  try check(traversal["failure"] is String && (traversal["attempts"] as? [String])?.isEmpty==true,"unsafe error filename accepted")
  print("PASS real Python fallback matrix: missing/empty/relative/bundle/symlink log paths; invalid config.logdir; poisoned TMPDIR; failed writes and traversal never attempt relative/bundle files")
  for target in ["NewHorizon.py","renpy/error.py","renpy/vc_version.py"] {
   let unknown=try fixture(root,"unknown-"+UUID().uuidString),url=unknown.appendingPathComponent("Contents/Resources/autorun/"+target)
   try write(url,try String(contentsOf:url,encoding:.utf8)+"# modified unknown template\n")
   let before=try snapshot(unknown)
   try check(NativeRenpyBootstrap.profile(source:unknown,executableName:"NewHorizon")==nil,"unknown template got a profile")
   try check(try !NativeRenpyBootstrap.prepare(stage:unknown,executableName:"NewHorizon"),"unknown template patched")
   try check(try snapshot(unknown)==before,"partial patch on unknown template")
  }
  let linked=try fixture(root,"symlink"),script=linked.appendingPathComponent("Contents/Resources/autorun/NewHorizon.py"),external=root.appendingPathComponent("external.py")
  try write(external,launcher);try fm.removeItem(at:script);try fm.createSymbolicLink(at:script,withDestinationURL:external)
  try rejects{_ = try NativeRenpyBootstrap.prepare(stage:linked,executableName:"NewHorizon")}
  try check(try String(contentsOf:external,encoding:.utf8)==launcher,"external launcher changed")
  let published=root.appendingPathComponent("Published.app");try fm.moveItem(at:app,to:published)
  try rejects{_ = try NativeRenpyBootstrap.prepare(stage:published,executableName:"NewHorizon")}
  print("PASS strict template/stage rejection: version or either complete-file change, no partial writes, symlinks and published app rejected")
  try integration(root)
  print("PASS all NativeRenpyBootstrap tests; only synthetic fixtures used")
 }
}
