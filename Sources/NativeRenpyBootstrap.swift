import Foundation
import CryptoKit
import Darwin

/// Call only AFTER source/stage consistency checks and BEFORE signing the newly
/// copied cache stage. On error discard the stage; never publish/sign it. This
/// helper does not execute Python, sign code, or access the source application.
enum NativeRenpyBootstrap {
 static let profileID = "renpy-8.3.7.25031702-sealed-bootstrap-v2"
 struct Preparation {let profile:String;let changed:Bool;let patchedPaths:[String]}
 enum Failure:Error,LocalizedError {
  case unsafeStage,unsupportedTemplate,writeFailed
  var errorDescription:String? {
   switch self {
   case .unsafeStage:return "Ren’Py 引导适配仅允许未发布、无外部链接的本地缓存准备目录。"
   case .unsupportedTemplate:return "Ren’Py 引导模板不在已核验名单中，未修改或签署未知模板。"
   case .writeFailed:return "Ren’Py 引导适配写入失败；请丢弃此准备目录。"
   }
  }
 }
 // Observed pristine upstream 8.3.7.25031702 files (MIT, Tom Rothamel).
 // The complete file, not just replaceable function text, must match.
 private static let launcherHash="5a2d8e648e3f4cbdcd32cbd2bb0ba48d10de32fe14042e201a8bb7088cefad79"
 private static let loaderHash="c1e425e2870d16b7fa1c706581d96f054b5f18e2e1c84749e450a7f7d8309815"
 private static let errorHash="dfa364e74c6bebce6612e7028b311d4f122f5b27a8c5d8542eb697192c7c8e38"
 private static let versionHash="ff16e393b9e77aa21cbf203a7c11679221775120e366c0295949139c7b4ed239"
 private static let bytecodePatch="import sys\n# GameShelf sealed bootstrap v1: prevent bytecode writes before Ren’Py imports.\nsys.dont_write_bytecode = True\n"
 private static let logFunction = #"""
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

 """#
 private static let errorFunction = #"""
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


 """#
 // Both patched modules can be imported independently during error handling.
 // Do not depend on renpy.__main__ already being set by the launcher.
 private static let helpers = #"""
 # GameShelf sealed bootstrap v1: all generated logs stay outside this bundle.
 def _gameshelf_bundle_root():
     root = os.path.realpath(__file__)
     while not root.lower().endswith('.app'):
         parent = os.path.dirname(root)
         if parent == root:
             raise RuntimeError('GameShelf bootstrap is not inside an app bundle')
         root = parent
     return root

 def _gameshelf_external_path(path):
     if not isinstance(path, str) or not path or not os.path.isabs(path):
         return None
     try:
         path = os.path.realpath(path)
         bundle = _gameshelf_bundle_root()
         if path == bundle or path.startswith(bundle + os.sep):
             return None
         return path
     except (OSError, ValueError):
         return None

 def _gameshelf_local_temp():
     import tempfile
     # Ignore TMPDIR/gettempdir: an embedded launcher can point it at the bundle.
     return tempfile.mkdtemp(prefix='gameshelf-renpy-', dir='/private/tmp')

 def _gameshelf_log_directory(preferred):
     import tempfile
     default = os.path.join(os.path.expanduser('~'), 'Library', 'Logs',
                            'GameShelf', 'RenPy', os.path.basename(_gameshelf_bundle_root()))
     for candidate in (preferred, default):
         path = _gameshelf_external_path(candidate)
         if path is None:
             continue
         try:
             os.makedirs(path, mode=0o700, exist_ok=True)
             with tempfile.TemporaryFile(dir=path):
                 pass
             return path
         except OSError:
             pass
     return _gameshelf_local_temp()

 """#
 private static var logReplacement:String {
  helpers+"\ndef path_to_logdir(basedir):\n    return _gameshelf_log_directory(os.environ.get('RENPY_LOG_BASE'))\n\n"
 }
 private static var errorReplacement:String {
  helpers + #"""

 def open_error_file(fn, mode):
     if not isinstance(fn, str) or fn in ('', '.', '..') or os.path.basename(fn) != fn or chr(92) in fn:
         raise ValueError('GameShelf error filename must be a simple basename')
     directory = _gameshelf_external_path(getattr(getattr(renpy, 'config', None), 'logdir', None))
     if directory is not None:
         new_fn = _gameshelf_external_path(os.path.join(directory, fn))
         if new_fn is not None:
             try:
                 return open(new_fn, mode), new_fn
             except Exception:
                 pass
     # Never try open(fn, mode): cwd can be the signed autorun directory.
     new_fn = os.path.join(_gameshelf_local_temp(), fn)
     return open(new_fn, mode), new_fn


 """#
 }
 private static let loaderHelper = #"""
# GameShelf sealed bootstrap v2: SMB read-only RPA close workaround.
# The app sets 1 only after checking the actual resolved game-resource volume.
class _GameShelfSMBReadOnlyRPA(object):
    def __init__(self, stream):
        self.stream = stream
        self.enabled = False

    def __enter__(self):
        stream = self.stream.__enter__()
        self.enabled = (os.environ.get("GAMESHELF_SMB_RPA_CLOSE") == "1"
                        and getattr(self.stream, "mode", None) == "rb"
                        and isinstance(getattr(self.stream, "name", None), str)
                        and self.stream.name.lower().endswith(".rpa"))
        return stream

    def __exit__(self, exc_type, exc_value, tb):
        if not self.enabled:
            return self.stream.__exit__(exc_type, exc_value, tb)
        try:
            self.stream.close()
        except Exception as close_error:
            import errno
            if isinstance(close_error, OSError) and close_error.errno == errno.EBADF:
                return False
            if exc_value is None:
                raise
            # Preserve the original body exception, traceback and any cause.
            # Retain the distinct close failure as a diagnostic, without IO
            # retries or another close which could affect a reused descriptor.
            try:
                print("GameShelf: RPA close failed while preserving body error: "
                      + repr(close_error), file=sys.stderr)
            except Exception:
                pass
        return False



"""#
 private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
 private static func replaceOnce(_ text:String,_ old:String,_ new:String)throws->String {
  guard text.components(separatedBy:old).count==2 else{throw Failure.unsupportedTemplate}
  return text.replacingOccurrences(of:old,with:new)
 }
 private static func adapted(_ bytes:Data,expected:String,changes:[(String,String)])throws->Data {
  guard let text=String(data:bytes,encoding:.utf8) else{throw Failure.unsupportedTemplate}
  if digest(bytes)==expected {
   let result=try changes.reduce(text){try replaceOnce($0,$1.0,$1.1)}
   return Data(result.utf8)
  }
  // Idempotency accepts only our exact deterministic transformation of the
  // same pinned original. A marker or matching function alone is insufficient.
  let original=try changes.reversed().reduce(text){try replaceOnce($0,$1.1,$1.0)}
  guard digest(Data(original.utf8))==expected else{throw Failure.unsupportedTemplate}
  return bytes
 }
 private static func checked(_ root:URL,_ relative:String,directory:Bool=false,mutable:Bool=true)throws->URL {
  var current=root
  for component in relative.split(separator:"/") {
   current.appendPathComponent(String(component))
   var st=stat();guard lstat(current.path,&st)==0,(!mutable || st.st_uid==getuid()),st.st_mode&S_IFMT != S_IFLNK else{throw Failure.unsafeStage}
   if current.path != root.appendingPathComponent(relative).path || directory {
    guard st.st_mode&S_IFMT==S_IFDIR else{throw Failure.unsafeStage}
   }else{guard st.st_mode&S_IFMT==S_IFREG,(!mutable || st.st_nlink==1),st.st_size<=128*1024 else{throw Failure.unsafeStage}}
  }
  return current
 }
 /// Read-only source recognition, including NAS files owned by a different uid.
 /// No marker-only/partial match and no mutation of source metadata or content.
 static func profile(source:URL,executableName:String)->String? {
  guard validName(executableName),source.isFileURL,source.pathExtension=="app" else{return nil}
  var st=stat();guard lstat(source.path,&st)==0,st.st_mode&S_IFMT==S_IFDIR else{return nil}
  do {
   let base="Contents/Resources/autorun/"
   for (path,hash) in [(base+"renpy/vc_version.py",versionHash),(base+executableName+".py",launcherHash),(base+"renpy/error.py",errorHash),(base+"renpy/loader.py",loaderHash)] {
    let url=try checked(source,path,mutable:false)
    guard digest(try Data(contentsOf:url))==hash else{return nil}
   }
   return profileID
  }catch{return nil}
 }
 private static func validName(_ name:String)->Bool {
  !name.isEmpty && name.count<=255 && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") &&
   !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)})
 }
 /// Main cache-builder API. Unknown templates are skipped unchanged. Unsafe
 /// paths or failed writes throw, so callers must discard the unpublished stage.
 @discardableResult static func prepare(stage:URL,executableName:String)throws->Bool {
  guard validName(executableName) else{return false}
  let info=try checked(stage,"Contents/Info.plist")
  guard let values=try PropertyListSerialization.propertyList(from:Data(contentsOf:info),format:nil) as? [String:Any],
        values["CFBundleExecutable"] as? String == executableName else{return false}
  do{return try prepare(stagedApp:stage).changed}
  catch Failure.unsupportedTemplate{return false}
 }
 @discardableResult static func prepare(stagedApp:URL)throws->Preparation {
  let root=stagedApp.standardizedFileURL
  var st=stat()
  guard root.isFileURL,root.pathExtension=="app",root.lastPathComponent.hasPrefix(".preparing-"),
        lstat(root.path,&st)==0,st.st_mode&S_IFMT==S_IFDIR,st.st_uid==getuid() else{throw Failure.unsafeStage}
  let info=try checked(root,"Contents/Info.plist")
  guard let values=try PropertyListSerialization.propertyList(from:Data(contentsOf:info),format:nil) as? [String:Any],
        let executable=values["CFBundleExecutable"] as? String,!executable.isEmpty,executable.count<=255,
        executable != ".",executable != "..",!executable.contains("/"),!executable.contains("\\"),
        !executable.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw Failure.unsupportedTemplate}
  let base="Contents/Resources/autorun/"
  let version=try checked(root,base+"renpy/vc_version.py")
  guard digest(try Data(contentsOf:version))==versionHash else{throw Failure.unsupportedTemplate}
  let launcherPath=base+executable+".py",errorPath=base+"renpy/error.py",loaderPath=base+"renpy/loader.py"
  let launcher=try checked(root,launcherPath),error=try checked(root,errorPath),loader=try checked(root,loaderPath)
  let originals=try [Data(contentsOf:launcher),Data(contentsOf:error),Data(contentsOf:loader)]
  // Preflight ALL three complete templates before modifying any of them.
  let replacements=try [adapted(originals[0],expected:launcherHash,changes:[("import sys\n",bytecodePatch),(logFunction,logReplacement)]),
                        adapted(originals[1],expected:errorHash,changes:[(errorFunction,errorReplacement)]),
                        adapted(originals[2],expected:loaderHash,changes:[
                         ("def index_archives():\n",loaderHelper+"def index_archives():\n"),
                         ("            with f:\n","            with _GameShelfSMBReadOnlyRPA(f):\n"),
                         ("            with open(afn, \"rb\") as f:\n","            with _GameShelfSMBReadOnlyRPA(open(afn, \"rb\")) as f:\n")])]
  let urls=[launcher,error,loader],paths=[launcherPath,errorPath,loaderPath]
  var written:[Int]=[]
  do {
   for index in urls.indices where originals[index] != replacements[index] {
    _ = try checked(root,paths[index])
    let permissions=try FileManager.default.attributesOfItem(atPath:urls[index].path)[.posixPermissions]
    try replacements[index].write(to:urls[index],options:.atomic);written.append(index)
    if let permissions {try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:urls[index].path)}
   }
  }catch {
   for index in written.reversed(){try? originals[index].write(to:urls[index],options:.atomic)}
   throw Failure.writeFailed
  }
  return Preparation(profile:profileID,changed:!written.isEmpty,patchedPaths:paths)
 }
}
