import Foundation
// Native engine probing is kept separate from the Windows launch backend.
enum NativeEngines {
 static func renpyVersion(_ folder:URL)->String? {
  guard let text=try? String(contentsOf:folder.appendingPathComponent("renpy/vc_version.py"),encoding:.utf8),let expression=try? NSRegularExpression(pattern:#"(?m)^version\s*=\s*['"]([0-9]+\.[0-9]+\.[0-9]+)(?:\.[0-9]+)?['"]"#),let match=expression.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let range=Range(match.range(at:1),in:text) else{return nil}
  return String(text[range])
 }
 static func availableRenpyRoot(folder:URL,roots:[URL])->URL? {
  guard let version=renpyVersion(folder) else{return nil}
  return roots.first { root in
   let sdk=root.appendingPathComponent("renpy-"+version+"-sdk")
   return ["lib/py3-mac-universal/renpy","renpy.app/Contents/MacOS/renpy"].allSatisfy {FileManager.default.fileExists(atPath:sdk.appendingPathComponent($0).path)}
  }
 }
 static func renpySpec(game:Game,engines:URL,data:URL) throws -> LaunchSpec {
  let folder=URL(fileURLWithPath:game.folder)
  guard let version=renpyVersion(folder) else{throw LibraryError("无法识别此游戏的 Ren’Py 版本，未尝试不匹配的引擎。")}
  let executable=engines.appendingPathComponent("renpy-"+version+"-sdk/renpy.app/Contents/MacOS/renpy")
  guard FileManager.default.fileExists(atPath:executable.path) else{throw LibraryError("需要对应版本的原生 Ren’Py 引擎："+version)}
  let saves=data.appendingPathComponent("Saves/"+game.id.uuidString),logs=data.appendingPathComponent("Logs/"+game.id.uuidString)
  try FileManager.default.createDirectory(at:saves,withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
  var environment=ProcessInfo.processInfo.environment
  environment["RENPY_PATH_TO_SAVES"]=saves.path
  environment["RENPY_LOG_BASE"]=logs.path
  for language in ["schinese","simplified_chinese","chinese"] {
   if FileManager.default.fileExists(atPath:folder.appendingPathComponent("game/tl/"+language).path) {environment["RENPY_LANGUAGE"]=language;break}
  }
  environment["PYTHONDONTWRITEBYTECODE"]="1"
  return LaunchSpec(executable:executable,arguments:[folder.path],directory:folder,environment:environment)
 }
}
