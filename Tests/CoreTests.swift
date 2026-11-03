import Foundation
import CryptoKit
@main struct Tests {
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("GameLibrary-tests-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  func put(_ path: String, _ value: String = "") throws {
   let u = root.appendingPathComponent(path)
   try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
   try value.write(to: u, atomically: true, encoding: .utf8)
  }
  try put("visual/物語.exe", "MZ"); try put("visual/data.xp3"); try put("visual/unins000.exe", "MZ")
  let vn = try Scan.candidates(at: root.appendingPathComponent("visual"))
  guard vn == [Candidate(path: "物語.exe", backend: .wine, engine: "KiriKiri")] else { fatalError("KiriKiri should bind Unicode game executable and exclude uninstallers: \(vn)") }
  try put("unity/Adventure.exe", "MZ"); try put("unity/UnityCrashHandler64.exe", "MZ"); try put("unity/Adventure_Data/globalgamemanagers")
  let unity = try Scan.candidates(at: root.appendingPathComponent("unity"))
  guard unity.count == 1, unity.first?.engine == "Unity" else { fatalError("Unity helper was mistaken for game") }
  try put("mv/Game.exe", "MZ"); try put("mv/www/index.html", "<html></html>"); try put("mv/www/js/rpg_core.js")
  let mv = try Scan.candidates(at: root.appendingPathComponent("mv"))
  guard mv.count == 1, mv.first?.backend == .wine, mv.first?.engine == "RPG Maker MV" else { fatalError("Desktop MV must not silently bypass Node plugins by using browser backend") }
  try put("unknown-mz/Game.exe","MZ");try put("unknown-mz/index.html","<html></html>");try put("unknown-mz/js/rmmz_core.js");try put("unknown-mz/package.json","{}")
  guard try Scan.candidates(at:root.appendingPathComponent("unknown-mz")).first?.backend == .wine else{fatalError("Untested desktop MZ must retain Wine")}
  try put("web/index.html", "<html></html>"); try put("web/js/rmmz_core.js")
  let web = try Scan.candidates(at: root.appendingPathComponent("web"))
  guard web == [Candidate(path:"index.html",backend:.web,engine:"RPG Maker MZ · Web")] else { fatalError("Browser export not recognized") }
  try put("renpy/Novel.exe","MZ"); try put("renpy/renpy/__init__.py"); try put("renpy/game/script.rpy")
  guard try Scan.candidates(at: root.appendingPathComponent("renpy")).first?.engine == "Ren’Py", try Scan.candidates(at: root.appendingPathComponent("renpy")).first?.backend == .renpy else { fatalError("RenPy detection failed") }
  try put("ambiguous/main.exe","MZ"); try put("ambiguous/main_cn.exe","MZ")
  guard try Scan.candidates(at: root.appendingPathComponent("ambiguous")).count == 2 else { fatalError("Must preserve ambiguous entrypoint choice") }
  try put("empty/notes.txt")
  guard try Scan.candidates(at: root.appendingPathComponent("empty")).isEmpty else { fatalError("Non game accepted") }
  do { _ = try Scan.candidates(at: root.appendingPathComponent("offline")); fatalError("Missing source not rejected") } catch {}
  let profileFiles=["package.json":"synthetic package","js/main.js":"synthetic bootstrap","js/plugins.js":"synthetic plugins"]
  for (path,bytes) in profileFiles {try put("profile/"+path,bytes)}
  let hashes=profileFiles.mapValues{SHA256.hash(data:Data($0.utf8)).map{String(format:"%02x",$0)}.joined()}
  let profileRoot=root.appendingPathComponent("profile")
  guard MZWebProfile.matches(at:profileRoot,fingerprints:hashes) else{fatalError("Matching inert profile rejected")}
  try put("profile/js/plugins.js","modified plugin configuration")
  guard !MZWebProfile.matches(at:profileRoot,fingerprints:hashes) else{fatalError("Changed desktop plugins must not inherit verified web profile")}
  try fm.removeItem(at:profileRoot.appendingPathComponent("js/plugins.js"))
  try put("external-plugin","synthetic plugins")
  try fm.createSymbolicLink(at:profileRoot.appendingPathComponent("js/plugins.js"),withDestinationURL:root.appendingPathComponent("external-plugin"))
  guard !MZWebProfile.matches(at:profileRoot,fingerprints:hashes) else{fatalError("Profile must not read a file outside the selected game")}
  print("PASS: engine/entrypoint/offline checks and verified MZ profile mutation/containment")
 }
}
