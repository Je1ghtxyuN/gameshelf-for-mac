import Foundation
@main struct StorageTests {
 static func main() throws {
  let fm=FileManager.default, base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at:base,withIntermediateDirectories:true)
  defer {try? fm.removeItem(at:base)}
  let source=base.appendingPathComponent("NAS 游戏")
  try fm.createDirectory(at:source,withIntermediateDirectories:true)
  try "MZ".write(to:source.appendingPathComponent("Game.exe"),atomically:true,encoding:.utf8)
  let store=try LibraryStore(root:base.appendingPathComponent("local"))
  let candidate=Candidate(path:"Game.exe",backend:.wine,engine:"Windows")
  let g=try store.add(source:source,candidate:candidate)
  guard g.windowSize=="1280x720" else{fatalError("New Windows imports must default to a bounded window area")}
  _ = try store.add(source:source,candidate:candidate)
  guard store.games.count == 1, g.folder == source.path else {fatalError("Import must deduplicate and reference source")}
  guard !fm.fileExists(atPath:store.root.appendingPathComponent("Games").path) else {fatalError("Import unexpectedly copied content")}
  let reopened=try LibraryStore(root:store.root)
  guard reopened.games.count == 1 else {fatalError("Persistent library missing")}
  let copied=try store.download(g)
  guard copied.folder != source.path, fm.fileExists(atPath:source.appendingPathComponent("Game.exe").path), fm.fileExists(atPath:URL(fileURLWithPath:copied.folder).appendingPathComponent("Game.exe").path) else {fatalError("Download must preserve original and create local copy")}
  try store.remove(g.id)
  guard fm.fileExists(atPath:source.path),fm.fileExists(atPath:copied.folder) else {fatalError("Remove from library deleted game files")}
  do {_ = try store.add(source:source,candidate:Candidate(path:"../escape.exe",backend:.wine,engine:"Windows"));fatalError("Escaping entry accepted")} catch {}
  try "bad json".write(to:store.root.appendingPathComponent("library.json"),atomically:true,encoding:.utf8)
  do {_ = try LibraryStore(root:store.root);fatalError("Corrupt library silently overwritten")} catch {}
  print("PASS: reference import, deduplication, persistence, copy, non-destructive removal, containment, corruption checks")
 }
}
