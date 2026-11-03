import Foundation
import CryptoKit
import Darwin

// Local inert fixtures only. Compile with Core.swift and UnityCursorAdapter.swift.
@main struct UnityCursorAdapterTests {
 static var fm: FileManager { .default }
 static let original = Data([0x4d, 0x5a, 7, 0x18, 0x28, 6, 5, 4])
 static let patched = Data([0x4d, 0x5a, 7, 0x16, 0x28, 6, 5, 4])
 static let profile = "cyanbrain-cursor-unconfined-v1"
 static let assembly = "CYANBRAIN_Data/Managed/Assembly-CSharp.dll"
 static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
 static var spec: UnityCursorAdapter.PatchSpec {
  .init(sourceSHA256: hash(original), length: 8, offset: 3)
 }
 static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw LibraryError("FAIL: " + message) }
 }
 static func rejects(_ body: () throws -> Void) throws {
  do { try body() } catch { return }
  throw LibraryError("FAIL: unsafe preparation accepted")
 }
 static func write(_ url: URL, _ bytes: Data) throws {
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try bytes.write(to: url)
 }
 struct Fixture {
  let base: URL, source: URL, root: URL
  var game: Game
  var config: URL { root.appendingPathComponent("Compatibility/\(game.id.uuidString).json") }
  var destination: URL { root.appendingPathComponent("Adapters/\(game.id.uuidString)/current") }
  init() throws {
   base = URL(fileURLWithPath: "/private/tmp/unity-cursor-test-" + UUID().uuidString)
   source = base.appendingPathComponent("Original 游戏")
   root = base.appendingPathComponent("Local")
   game = Game(title: "CYANBRAIN", folder: source.path, originalFolder: source.path,
               entry: Candidate(path: "CYANBRAIN.exe", backend: .wine, engine: "Unity"))
   try write(source.appendingPathComponent(assembly), original)
   for path in ["CYANBRAIN.exe", "UnityPlayer.dll", "CYANBRAIN_Data/body/assets", "CYANBRAIN_Data/globalgamemanagers", "CYANBRAIN_Data/Managed/UnityEngine.dll"] {
    try write(source.appendingPathComponent(path), Data("inert body".utf8))
   }
   // Nested internal links must be checked even beneath linked body directories.
   try fm.createSymbolicLink(atPath: source.appendingPathComponent("CYANBRAIN_Data/body/internal").path, withDestinationPath: "assets")
  }
  func enable(_ changes: [String: String] = [:]) throws {
   var object = ["profile": profile, "sourceFolder": source.path, "sourceSHA256": hash(original)]
   object.merge(changes) { _, new in new }
   try write(config, JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
  }
  func prepare(_ patch: UnityCursorAdapter.PatchSpec = spec,
               publication: UnityCursorAdapter.Publication = .init(),
               inspection: UnityCursorAdapter.SourceInspection = .init()) throws -> Game {
   try UnityCursorAdapter.prepareIfEnabled(game: game, dataRoot: root, spec: patch, publication: publication, inspection: inspection)
  }
 }
 static func main() throws {
  var failures = 0, count = 0
  func test(_ name: String, _ body: (Fixture) throws -> Void) {
   count += 1
   do {
    let fixture = try Fixture()
    defer { try? fm.removeItem(at: fixture.base) }
    try body(fixture)
    print("PASS \(name)")
   } catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
  }
  test("absent opt-in returns entire Game unchanged without creating dataRoot") { f in
   let output = try f.prepare()
   let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
   try check(encoder.encode(output) == encoder.encode(f.game), "Game unchanged")
   try check(!fm.fileExists(atPath: f.root.path), "no work on opt-out")
   var missing = f.game; missing.folder = "/does/not/exist"
   _ = try UnityCursorAdapter.prepareIfEnabled(game: missing, dataRoot: f.root)
  }
  test("single byte private patch, sparse links, identity, receipt and verified reuse") { f in
   try f.enable()
   let output = try f.prepare(), dest = URL(fileURLWithPath: try f.prepare().folder)
   try check(dest.path == f.destination.path, "adapter under UUID root")
   try check(output.id == f.game.id && output.originalFolder == f.game.originalFolder && output.entry == f.game.entry && output.title == f.game.title, "identity preserved")
   try check(f.game.folder == f.source.path, "input game unchanged")
   let bytes = try Data(contentsOf: dest.appendingPathComponent(assembly))
   try check(bytes == patched && zip(bytes, original).filter { $0 != $1 }.count == 1, "exact one byte")
   try check(Data(contentsOf: f.source.appendingPathComponent(assembly)) == original, "source untouched")
   for path in ["", "CYANBRAIN_Data", "CYANBRAIN_Data/Managed"] {
    try check(fm.attributesOfItem(atPath: dest.appendingPathComponent(path).path)[.type] as? FileAttributeType == .typeDirectory, "real directory")
   }
   for path in ["CYANBRAIN.exe", "UnityPlayer.dll", "CYANBRAIN_Data/body", "CYANBRAIN_Data/globalgamemanagers", "CYANBRAIN_Data/Managed/UnityEngine.dll"] {
    try check(fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent(path).path) == f.source.appendingPathComponent(path).path, "body linked, never copied")
   }
   let receipt = try Data(contentsOf: dest.appendingPathComponent(".unity-cursor-adapter.json"))
   let object = try JSONSerialization.jsonObject(with: receipt) as! [String: Any]
   try check(object["profile"] as? String == profile && object["id"] as? String == f.game.id.uuidString, "receipt ownership")
   try check(object["source"] as? String == f.source.path && object["sourceSHA256"] as? String == hash(original) && object["patchedSHA256"] as? String == hash(patched), "receipt hashes")
   try check((object["links"] as? [String: String])?.count == 5, "receipt intended links")
   let inode = try fm.attributesOfItem(atPath: dest.path)[.systemFileNumber] as! NSNumber
   _ = try f.prepare()
   try check(fm.attributesOfItem(atPath: dest.path)[.systemFileNumber] as? NSNumber == inode, "verified reuse")
   try fm.removeItem(at: f.config)
   try check(f.prepare().folder == f.game.folder, "removing opt-in reverses selection")
  }
  for (key, value) in [("profile", "unknown-v2"), ("sourceSHA256", "bad"), ("sourceFolder", "/private/tmp/other")] {
   test("reject configuration \(key)") { f in
    try f.enable([key: value]); try rejects { _ = try f.prepare() }
    try check(!fm.fileExists(atPath: f.destination.path), "nothing published")
   }
  }
  test("corrupt config and symlink config fail closed") { f in
   try write(f.config, Data("{".utf8)); try rejects { _ = try f.prepare() }
   try fm.removeItem(at: f.config)
   try fm.createSymbolicLink(atPath: f.config.path, withDestinationPath: f.base.appendingPathComponent("missing").path)
   try rejects { _ = try f.prepare() }
  }
  test("symlink Compatibility directory rejected") { f in
   try f.enable(); let moved = f.base.appendingPathComponent("config")
   try fm.moveItem(at: f.config.deletingLastPathComponent(), to: moved)
   try fm.createSymbolicLink(at: f.config.deletingLastPathComponent(), withDestinationURL: moved)
   try rejects { _ = try f.prepare() }
  }
  for kind in ["backend", "engine", "entry", "originalFolder", "folder"] {
   test("reject game mismatch \(kind)") { fixture in
    var f = fixture; try f.enable()
    switch kind {
    case "backend": f.game.entry.backend = .native
    case "engine": f.game.entry.engine = "Other"
    case "entry": f.game.entry.path = "../CYANBRAIN.exe"
    case "originalFolder": f.game.originalFolder = f.base.path
    default: f.game.folder = f.base.path
    }
    try rejects { _ = try f.prepare() }
   }
  }
  test("changed source version never reuses old adapter") { f in
   try f.enable(); _ = try f.prepare()
   try write(f.source.appendingPathComponent(assembly), Data(repeating: 0, count: 8))
   do { _ = try f.prepare(); throw LibraryError("FAIL: obsolete patch reused") }
   catch { try check(error.localizedDescription.contains("source-version"), "explicit source version error") }
   try check(Data(contentsOf: f.destination.appendingPathComponent(assembly)) == patched, "old adapter preserved")
  }
  test("production spec rejects synthetic DLL even with matching config hash") { f in
   try f.enable()
   try rejects { _ = try UnityCursorAdapter.prepareIfEnabled(game: f.game, dataRoot: f.root) }
  }
  test("wrong expected opcode and out-of-range offset rejected") { f in
   try f.enable()
   try rejects { _ = try f.prepare(.init(sourceSHA256: hash(original), length: 8, offset: 99)) }
   try rejects { _ = try f.prepare(.init(sourceSHA256: hash(original), length: 8, offset: 2)) }
   try rejects { _ = try f.prepare(.init(sourceSHA256: hash(original), length: 9, offset: 3)) }
  }
  for path in ["escape", "CYANBRAIN_Data/body/escape", assembly, "CYANBRAIN_Data/Managed"] {
   test("external source link rejected at \(path)") { f in
    try f.enable()
    let item = f.source.appendingPathComponent(path)
    if fm.fileExists(atPath: item.path) { try fm.removeItem(at: item) }
    try fm.createSymbolicLink(at: item, withDestinationURL: f.base)
    try rejects { _ = try f.prepare() }
    try check(!fm.fileExists(atPath: f.destination.path), "no unsafe mirror published")
   }
  }
  test("dangling and cyclic source links rejected") { f in
   try f.enable(); let link = f.source.appendingPathComponent("bad")
   try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
   try rejects { _ = try f.prepare() }
   try fm.removeItem(at: link)
   try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "bad")
   try rejects { _ = try f.prepare() }
  }
  test("dataRoot/source overlap rejected in both directions") { f in
   for root in [f.source.appendingPathComponent("Local"), f.base] {
    let config = root.appendingPathComponent("Compatibility/\(f.game.id.uuidString).json")
    try write(config, JSONSerialization.data(withJSONObject: ["profile": profile, "sourceFolder": f.source.path, "sourceSHA256": hash(original)]))
    try rejects { _ = try UnityCursorAdapter.prepareIfEnabled(game: f.game, dataRoot: root, spec: spec) }
    try check(!fm.fileExists(atPath: root.appendingPathComponent("Adapters").path), "no overlap output")
   }
  }
  for level in ["root", "Adapters", "id", "current"] {
   test("symlink output destination \(level) rejected") { f in
    try f.enable()
    let other = f.base.appendingPathComponent("Other"); try fm.createDirectory(at: other, withIntermediateDirectories: false)
    let target: URL
    switch level {
    case "root":
     try fm.moveItem(at: f.root, to: other.appendingPathComponent("Local"))
     target = f.root
     try fm.createSymbolicLink(at: target, withDestinationURL: other.appendingPathComponent("Local"))
    case "Adapters": target = f.root.appendingPathComponent("Adapters")
    case "id": target = f.destination.deletingLastPathComponent()
    default: target = f.destination
    }
    if level != "root" {
     try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
     try fm.createSymbolicLink(at: target, withDestinationURL: other)
    }
    try rejects { _ = try f.prepare() }
   }
  }
  test("unowned destination preserved") { f in
   try f.enable(); let sentinel = f.destination.appendingPathComponent("mine")
   try write(sentinel, Data([9])); try rejects { _ = try f.prepare() }
   try check(Data(contentsOf: sentinel) == Data([9]), "unowned data preserved")
  }
  test("refresh is staged and keeps recognized previous directory") { f in
   try f.enable(); _ = try f.prepare()
   let inode = try fm.attributesOfItem(atPath: f.destination.path)[.systemFileNumber] as! NSNumber
   try write(f.source.appendingPathComponent("added.dll"), Data([8]))
   _ = try f.prepare()
   _ = try fm.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent("added.dll").path)
   let siblings = try fm.contentsOfDirectory(at: f.destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
   let previous = siblings.filter { $0.lastPathComponent.hasPrefix(".previous-") }
   try check(previous.count == 1, "previous preserved")
   try check(fm.attributesOfItem(atPath: previous[0].path)[.systemFileNumber] as? NSNumber == inode, "previous inode preserved")
   try check(!siblings.contains { $0.lastPathComponent.hasPrefix(".staging-") }, "no staging debris")
  }
  test("failed refresh preserves recognized adapter") { f in
   try f.enable(); _ = try f.prepare()
   let before = try Data(contentsOf: f.destination.appendingPathComponent(".unity-cursor-adapter.json"))
   try fm.createSymbolicLink(at: f.source.appendingPathComponent("unsafe"), withDestinationURL: f.base)
   try rejects { _ = try f.prepare() }
   try check(Data(contentsOf: f.destination.appendingPathComponent(".unity-cursor-adapter.json")) == before, "previous receipt untouched")
   try check(Data(contentsOf: f.destination.appendingPathComponent(assembly)) == patched, "previous patch untouched")
  }
  test("tampered adapter links, receipt, and unowned children refused") { f in
   try f.enable(); _ = try f.prepare()
   let link = f.destination.appendingPathComponent("CYANBRAIN.exe")
   try fm.removeItem(at: link); try fm.createSymbolicLink(at: link, withDestinationURL: f.base)
   try rejects { _ = try f.prepare() }
   try fm.removeItem(at: link); try fm.createSymbolicLink(at: link, withDestinationURL: f.source.appendingPathComponent("CYANBRAIN.exe"))
   try write(f.destination.appendingPathComponent("unowned"), Data([1]))
   try rejects { _ = try f.prepare() }
   try fm.removeItem(at: f.destination.appendingPathComponent("unowned"))
   let receipt = f.destination.appendingPathComponent(".unity-cursor-adapter.json")
   try fm.removeItem(at: receipt); try fm.createSymbolicLink(at: receipt, withDestinationURL: f.config)
   try rejects { _ = try f.prepare() }
  }
  test("entry must resolve to a regular executable file, not a directory") { f in
   try f.enable()
   let exe = f.source.appendingPathComponent("CYANBRAIN.exe")
   try fm.removeItem(at: exe); try fm.createDirectory(at: exe, withIntermediateDirectories: false)
   try rejects { _ = try f.prepare() }
  }
  test("safe internal directory links and canonical game folder aliases accepted") { fixture in
   var f = fixture; try f.enable()
   let alias = f.base.appendingPathComponent("SourceAlias")
   try fm.createSymbolicLink(at: alias, withDestinationURL: f.source)
   f.game.folder = alias.path; f.game.originalFolder = alias.path
   try fm.createSymbolicLink(atPath: f.source.appendingPathComponent("body-alias").path, withDestinationPath: "CYANBRAIN_Data/body")
   let output = try f.prepare()
   try check(output.originalFolder == alias.path, "preserve originalFolder string verbatim")
   try check(fm.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent("body-alias").path) == f.source.appendingPathComponent("CYANBRAIN_Data/body").path, "canonical contained link")
  }
  test("damaged private DLL is refreshed without changing source and old copy is preserved") { f in
   try f.enable(); _ = try f.prepare()
   let file = f.destination.appendingPathComponent(assembly)
   try write(file, Data(repeating: 3, count: 8))
   _ = try f.prepare()
   try check(Data(contentsOf: file) == patched, "private patch repaired")
   try check(Data(contentsOf: f.source.appendingPathComponent(assembly)) == original, "source remains original")
   let previous = try fm.contentsOfDirectory(at: f.destination.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".previous-") }
   try check(previous.count == 1 && Data(contentsOf: previous[0].appendingPathComponent(assembly)) == Data(repeating: 3, count: 8), "damaged prior adapter retained")
  }
  test("removed source child refreshes link inventory") { f in
   try f.enable(); _ = try f.prepare()
   try fm.removeItem(at: f.source.appendingPathComponent("UnityPlayer.dll"))
   _ = try f.prepare()
   try check((try? fm.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent("UnityPlayer.dll").path)) == nil, "stale link removed")
  }
  test("unowned UUID container and symlinked private DLL are refused") { f in
   try f.enable()
   let mine = f.destination.deletingLastPathComponent().appendingPathComponent("mine")
   try write(mine, Data([9])); try rejects { _ = try f.prepare() }
   try check(Data(contentsOf: mine) == Data([9]), "container preserved")
   try fm.removeItem(at: mine); _ = try f.prepare()
   let dll = f.destination.appendingPathComponent(assembly)
   try fm.removeItem(at: dll)
   try fm.createSymbolicLink(at: dll, withDestinationURL: f.source.appendingPathComponent(assembly))
   try rejects { _ = try f.prepare() }
   try check(Data(contentsOf: f.source.appendingPathComponent(assembly)) == original, "linked source never patched")
  }
  test("source receipt collision fails before replacing previous adapter") { f in
   try f.enable(); _ = try f.prepare()
   let before = try fm.attributesOfItem(atPath: f.destination.path)[.systemFileNumber] as! NSNumber
   try write(f.source.appendingPathComponent(".unity-cursor-adapter.json"), Data([1]))
   try rejects { _ = try f.prepare() }
   try check(fm.attributesOfItem(atPath: f.destination.path)[.systemFileNumber] as? NSNumber == before, "failed refresh keeps current inode")
  }
  for unsupported in [ENOTSUP, EOPNOTSUPP] {
   test("portable initial publication on errno \(unsupported)") { f in
    try f.enable()
    let output = try f.prepare(publication: .init(rename: { _, _, _ in unsupported }))
    try check(output.folder == f.destination.path, "portable launch folder")
    try check(Data(contentsOf: f.destination.appendingPathComponent(assembly)) == patched, "portable private patch")
    try check(Data(contentsOf: f.source.appendingPathComponent(assembly)) == original, "source unchanged")
    _ = try f.prepare()
    try check(childrenOfOwner(f).count == 1, "reusable adapter and no staging debris")
   }
   test("portable refresh on errno \(unsupported) preserves recognized backup") { f in
    try f.enable(); _ = try f.prepare()
    let before = try inode(f.destination)
    try write(f.source.appendingPathComponent("added.dll"), Data([8]))
    _ = try f.prepare(publication: .init(rename: { _, _, _ in unsupported }))
    try check(fm.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent("added.dll").path) == f.source.appendingPathComponent("added.dll").path, "updated mirror published")
    let previous = try backups(f)
    try check(previous.count == 1 && inode(previous[0]) == before, "old directory retained")
    try check(Data(contentsOf: previous[0].appendingPathComponent(assembly)) == patched, "old bytes retained")
    try check(!childrenOfOwner(f).contains { $0.lastPathComponent.hasPrefix(".staging-") }, "no staging debris")
   }
  }
  test("portable refresh publish failure restores recognized previous adapter") { f in
   try f.enable(); _ = try f.prepare()
   let before = try inode(f.destination)
   try write(f.source.appendingPathComponent("added.dll"), Data([8]))
   var moves = 0
   let publication = UnityCursorAdapter.Publication(rename: { _, _, _ in ENOTSUP }, move: { from, to in
    moves += 1
    if moves == 2 { throw POSIXError(.EIO) }
    try fm.moveItem(at: from, to: to)
   })
   try rejects { _ = try f.prepare(publication: publication) }
   try check(inode(f.destination) == before, "prior adapter restored")
   try check(Data(contentsOf: f.destination.appendingPathComponent(assembly)) == patched, "prior bytes restored")
   try check(childrenOfOwner(f).count == 1, "failed stage cleaned and backup restored")
  }
  test("portable refresh failure never overwrites a new unowned destination") { f in
   try f.enable(); _ = try f.prepare()
   let before = try inode(f.destination)
   try write(f.source.appendingPathComponent("added.dll"), Data([8]))
   var moves = 0
   let publication = UnityCursorAdapter.Publication(rename: { _, _, _ in ENOTSUP }, move: { from, to in
    moves += 1
    if moves == 2 {
     try write(f.destination.appendingPathComponent("mine"), Data([9]))
     throw POSIXError(.EIO)
    }
    try fm.moveItem(at: from, to: to)
   })
   try rejects { _ = try f.prepare(publication: publication) }
   try check(Data(contentsOf: f.destination.appendingPathComponent("mine")) == Data([9]), "unowned contents preserved")
   let previous = try backups(f)
   try check(previous.count == 1 && inode(previous[0]) == before, "recognized backup preserved")
   try check(Data(contentsOf: previous[0].appendingPathComponent(assembly)) == patched, "backup bytes preserved")
  }
  for obstruction in ["dangling-link", "restore-error"] {
   test("portable refresh keeps backup when rollback encounters \(obstruction)") { f in
    try f.enable(); _ = try f.prepare()
    let before = try inode(f.destination)
    try write(f.source.appendingPathComponent("added.dll"), Data([8]))
    var moves = 0
    let publication = UnityCursorAdapter.Publication(rename: { _, _, _ in ENOTSUP }, move: { from, to in
     moves += 1
     if moves == 2 {
      if obstruction == "dangling-link" {
       try fm.createSymbolicLink(at: f.destination, withDestinationURL: f.base.appendingPathComponent("missing"))
      }
      throw POSIXError(.EIO)
     }
     if moves == 3 { throw POSIXError(.ENOSPC) }
     try fm.moveItem(at: from, to: to)
    })
    try rejects { _ = try f.prepare(publication: publication) }
    if obstruction == "dangling-link" {
     try check(fm.destinationOfSymbolicLink(atPath: f.destination.path) == f.base.appendingPathComponent("missing").path, "dangling destination never replaced")
    } else { try check(!fm.fileExists(atPath: f.destination.path), "failed restore leaves destination absent") }
    let previous = try backups(f)
    try check(previous.count == 1 && inode(previous[0]) == before, "prior directory retained after failed rollback")
    try check(Data(contentsOf: previous[0].appendingPathComponent(assembly)) == patched, "backup data retained")
   }
  }
  for symlink in [false, true] {
   test("unsupported initial rename revalidates newly \(symlink ? "symlinked" : "unowned") destination") { f in
    try f.enable()
    let publication = UnityCursorAdapter.Publication(rename: { _, _, _ in
     if symlink { try! fm.createSymbolicLink(at: f.destination, withDestinationURL: f.base.appendingPathComponent("missing")) }
     else { try! write(f.destination.appendingPathComponent("mine"), Data([9])) }
     return ENOTSUP
    })
    try rejects { _ = try f.prepare(publication: publication) }
    if symlink {
     try check(fm.destinationOfSymbolicLink(atPath: f.destination.path) == f.base.appendingPathComponent("missing").path, "dangling destination untouched")
    } else { try check(Data(contentsOf: f.destination.appendingPathComponent("mine")) == Data([9]), "unowned directory untouched") }
   }
  }
  test("unsupported swap revalidates current ownership before moving anything") { f in
   try f.enable(); _ = try f.prepare()
   let before = try inode(f.destination)
   try write(f.source.appendingPathComponent("added.dll"), Data([8]))
   let publication = UnityCursorAdapter.Publication(rename: { _, _, _ in
    try! write(f.destination.appendingPathComponent("mine"), Data([9]))
    return ENOTSUP
   })
   try rejects { _ = try f.prepare(publication: publication) }
   try check(inode(f.destination) == before && Data(contentsOf: f.destination.appendingPathComponent("mine")) == Data([9]), "unowned addition untouched")
   try check(backups(f).isEmpty, "no unowned current moved to backup")
  }
  test("permission error does not fall back to portable publication") { f in
   try f.enable()
   try rejects { _ = try f.prepare(publication: .init(rename: { _, _, _ in EACCES })) }
   try check(!fm.fileExists(atPath: f.destination.path), "other errors stay fatal")
   try check(childrenOfOwner(f).isEmpty, "failed stage cleaned")
  }
  test("source resolution budget stays constant with 248 more ordinary files on reuse") { f in
   try f.enable()
   let live = UnityCursorAdapter.SourceInspection()
   var resolutions = [String]()
   let inspection = UnityCursorAdapter.SourceInspection(resolve: { item in
    resolutions.append(item.path)
    return try live.resolve(item)
   })
   _ = try f.prepare(inspection: inspection)
   let expected = Set([f.source.path, f.source.appendingPathComponent("CYANBRAIN_Data/body/internal").path])
   try check(resolutions.count == 2 && Set(resolutions) == expected, "resolve only canonical root and actual symlink")
   for index in 0..<248 {
    try write(f.source.appendingPathComponent("CYANBRAIN_Data/body/ordinary/\(index).bin"), Data([7]))
   }
   resolutions.removeAll()
   let before = try inode(f.destination)
   _ = try f.prepare(inspection: inspection)
   try check(resolutions.count == 2 && Set(resolutions) == expected, "ordinary files and directories never call realpath")
   try check(inode(f.destination) == before, "verified adapter reused")
   try check(Data(contentsOf: f.source.appendingPathComponent(assembly)) == original, "source remains unchanged")
  }
  test("directory symlink to active ancestor is rejected") { f in
   try f.enable()
   try fm.createSymbolicLink(atPath: f.source.appendingPathComponent("CYANBRAIN_Data/body/back").path, withDestinationPath: "../..")
   try rejects { _ = try f.prepare() }
  }
  test("cross-directory symlink cycle is rejected") { f in
   try f.enable()
   let body = f.source.appendingPathComponent("CYANBRAIN_Data/body")
   for dir in ["a", "b"] { try fm.createDirectory(at: body.appendingPathComponent(dir), withIntermediateDirectories: false) }
   try fm.createSymbolicLink(atPath: body.appendingPathComponent("a/to-b").path, withDestinationPath: "../b")
   try fm.createSymbolicLink(atPath: body.appendingPathComponent("b/to-a").path, withDestinationPath: "../a")
   try rejects { _ = try f.prepare() }
  }
  test("case-colliding siblings are rejected even when reached through a directory alias") { f in
   try f.enable()
   let body = f.source.appendingPathComponent("CYANBRAIN_Data/body")
   try fm.createSymbolicLink(atPath: f.source.appendingPathComponent("000-alias").path, withDestinationPath: "CYANBRAIN_Data/body")
   let live = UnityCursorAdapter.SourceInspection()
   let inspection = UnityCursorAdapter.SourceInspection(entries: { dir in
    var entries = try live.entries(dir)
    // Represent a case-sensitive share on a case-insensitive test filesystem.
    if dir.path == body.path { entries.append(dir.appendingPathComponent("ASSETS")) }
    return entries
   })
   try rejects { _ = try f.prepare(inspection: inspection) }
   try check(!fm.fileExists(atPath: f.destination.path), "colliding inventory never published")
  }
  test("non-regular source nodes still fail closed") { f in
   try f.enable()
   let fifo = f.source.appendingPathComponent("CYANBRAIN_Data/body/pipe")
   guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
   try rejects { _ = try f.prepare() }
  }
  test("same filenames in different parents and repeated directory aliases are safe") { f in
   try f.enable()
   for name in ["a", "b"] {
    try write(f.source.appendingPathComponent("CYANBRAIN_Data/body/\(name)/same.bin"), Data([8]))
   }
   for alias in ["000-first", "001-second"] {
    try fm.createSymbolicLink(atPath: f.source.appendingPathComponent(alias).path, withDestinationPath: "CYANBRAIN_Data/body")
   }
   _ = try f.prepare()
   for alias in ["000-first", "001-second"] {
    try check(fm.destinationOfSymbolicLink(atPath: f.destination.appendingPathComponent(alias).path) == f.source.appendingPathComponent("CYANBRAIN_Data/body").path, "safe aliases retain canonical targets")
   }
  }
  test("an unreadable nested directory fails preparation and preserves current adapter") { f in
   try f.enable(); _ = try f.prepare()
   let before = try inode(f.destination)
   let body = f.source.appendingPathComponent("CYANBRAIN_Data/body")
   let live = UnityCursorAdapter.SourceInspection()
   let inspection = UnityCursorAdapter.SourceInspection(entries: { directory in
    if directory.path == body.path { throw POSIXError(.EACCES) }
    return try live.entries(directory)
   })
   try rejects { _ = try f.prepare(inspection: inspection) }
   try check(inode(f.destination) == before && Data(contentsOf: f.destination.appendingPathComponent(assembly)) == patched, "enumeration failures never publish partial inventory")
  }
  print("UnityCursorAdapter: \(count - failures)/\(count) passed")
  if failures != 0 { exit(1) }
 }
 static func inode(_ directory: URL) throws -> NSNumber {
  try fm.attributesOfItem(atPath: directory.path)[.systemFileNumber] as! NSNumber
 }
 static func childrenOfOwner(_ fixture: Fixture) throws -> [URL] {
  try fm.contentsOfDirectory(at: fixture.destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
 }
 static func backups(_ fixture: Fixture) throws -> [URL] {
  try childrenOfOwner(fixture).filter { $0.lastPathComponent.hasPrefix(".previous-") }
 }
}
