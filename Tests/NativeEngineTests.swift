import Foundation
@main struct NativeTests {
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer{try? fm.removeItem(at:root)}
  let source=root.appendingPathComponent("NAS 物語"),engine=root.appendingPathComponent("Engines/renpy-8.1.3-sdk"),engines=root.appendingPathComponent("Engines")
  try fm.createDirectory(at:source.appendingPathComponent("renpy"),withIntermediateDirectories:true)
  try "version = '8.1.3.23091805'".write(to:source.appendingPathComponent("renpy/vc_version.py"),atomically:true,encoding:.utf8)
  try fm.createDirectory(at:engine.appendingPathComponent("lib/py3-mac-universal"),withIntermediateDirectories:true)
  try "stub".write(to:engine.appendingPathComponent("lib/py3-mac-universal/renpy"),atomically:true,encoding:.utf8)
  guard NativeEngines.renpyVersion(source)=="8.1.3" else{fatalError("Exact shipped RenPy version must be selected")}
  guard NativeEngines.availableRenpyRoot(folder:source,roots:[engines])==nil else{fatalError("Incomplete SDK must fall back to Windows")}
  try fm.createDirectory(at:engine.appendingPathComponent("renpy.app/Contents/MacOS"),withIntermediateDirectories:true)
  try "stub".write(to:engine.appendingPathComponent("renpy.app/Contents/MacOS/renpy"),atomically:true,encoding:.utf8)
  guard NativeEngines.availableRenpyRoot(folder:source,roots:[engines])==engines else{fatalError("Complete exact SDK must be preferred")}
  let game=Game(title:"物語",folder:source.path,originalFolder:source.path,entry:Candidate(path:"Game.exe",backend:.wine,engine:"Ren’Py"))
  try fm.createDirectory(at:source.appendingPathComponent("game/tl/schinese"),withIntermediateDirectories:true)
  let plan=try NativeEngines.renpySpec(game:game,engines:engines,data:root.appendingPathComponent("Data"))
  guard plan.arguments==[source.path],plan.executable.path==engine.appendingPathComponent("renpy.app/Contents/MacOS/renpy").path,plan.directory.path==source.path else{fatalError("Bundled native executable must receive original NAS folder and working directory")}
  guard plan.environment["RENPY_PATH_TO_SAVES"] != nil,plan.environment["RENPY_LOG_BASE"] != nil else{fatalError("Managed saves/logs must be explicit")}
  guard plan.environment["RENPY_LANGUAGE"]=="schinese" else{fatalError("Existing Simplified Chinese translations must be selected")}
  print("PASS: native RenPy exact-version fallback, bundled launch, source reference, managed saves/logs")
 }
}
