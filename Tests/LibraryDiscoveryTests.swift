import Foundation

@main struct LibraryDiscoveryTests {
 struct Failure: Error { let message: String }
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("LibraryDiscoveryTests-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  var passed = 0, failed = 0
  func check(_ value: Bool, _ label: String) throws { if !value { throw Failure(message: label) } }
  func reject(_ label: String, _ action: () throws -> Void) throws {
   do { try action() } catch { return }
   throw Failure(message: label)
  }
  func put(_ folder: URL, _ path: String, _ value: String = "MZfixture") throws {
   let file = folder.appendingPathComponent(path)
   try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
   try Data(value.utf8).write(to: file)
  }
  func source(_ folder: URL, id: UUID = UUID()) -> LibrarySource {
   LibrarySource(id: id, title: "Fixture library", path: folder.path)
  }
  func test(_ name: String, _ body: (URL) throws -> Void) {
   do {
    let folder = root.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try body(folder)
    passed += 1; print("PASS \(name)")
   } catch { failed += 1; print("FAIL \(name): \(error)") }
  }

  test("one complete directory groups translated executables and native alternatives") { folder in
   for name in ["Novel.exe", "Novel_CN.exe", "Novel_CHS.exe", "設定.exe", "cs2conf.exe", "FileCheck.exe", "unins000.exe", "エンジン設定.exe"] { try put(folder, "Edition/" + name) }
   try put(folder, "Edition/Novel.app/Contents/MacOS/Novel", "native fixture")
   let result = LibraryDiscovery.scan(source: source(folder))
   try check(result.completed && !result.cancelled && result.issues.isEmpty, "successful scan not complete")
   try check(result.games.count == 1, "one row per EXE or app instead of directory")
   let game = result.games[0]
   try check(game.relativePath == "Edition" && game.title == "Edition", "wrong relative directory/title")
   try check(game.entries.count == 4, "tools retained or valid ambiguous executable discarded")
   try check(game.entries.contains { $0.path == "Novel.app" && $0.backend == .native }, "native entry hidden by EXEs")
   try check(Set(game.entries.prefix(2).map(\.path)) == Set(["Novel_CN.exe", "Novel_CHS.exe"]), "translated launchers not prioritized")
  }
  test("resource trees are pruned while direct platform and version siblings survive") { folder in
   try put(folder, "Release/Game.exe")
   try put(folder, "Release/Graphics/nested/decoy.exe")
   try put(folder, "Release/Game_Data/Plugins/decoy.exe")
   try put(folder, "Release/renpy/deeper/decoy.exe")
   try put(folder, "Release/www/tools/decoy.exe")
   try put(folder, "Release/Windows/Game.exe")
   try put(folder, "Release/Mac/Novel.app/Contents/Resources/game/decoy.exe")
   try put(folder, "Versions/v1/Game.exe")
   try put(folder, "Versions/v2/Game.exe")
   let result = LibraryDiscovery.scan(source: source(folder))
   try check(result.completed, "resource pruning made scan incomplete")
   try check(Set(result.games.map(\.relativePath)) == Set(["Release", "Release/Windows", "Release/Mac/Novel.app", "Versions/v1", "Versions/v2"]), "resource or platform boundary was wrong")
  }
  test("resource-like library category names and separate native apps are not merged") { folder in
   try put(folder, "Data/Real/Game.exe")
   try put(folder, "Native/One.app/Contents/MacOS/One", "fixture")
   try put(folder, "Native/Two.app/Contents/MacOS/Two", "fixture")
   try put(folder, ".hidden/Game.exe")
   let result = LibraryDiscovery.scan(source: source(folder))
   try check(Set(result.games.map(\.relativePath)) == Set(["Data/Real", "Native/One.app", "Native/Two.app"]), "folder-name merge or global resource exclusion")
  }
  test("identity survives rescans and mount relocation but not source or version changes") { folder in
   try put(folder, "v1/Game.exe")
   try put(folder, "v2/Game.exe")
   let first = source(folder), a = LibraryDiscovery.scan(source: first)
   let relocated = folder.appendingPathComponent("relocated")
   try put(relocated, "v1/Game.exe")
   let b = LibraryDiscovery.scan(source: source(relocated, id: first.id))
   let c = LibraryDiscovery.scan(source: source(relocated))
   try check(a.games.count == 2 && a.games[0].id != a.games[1].id, "versions merged")
   try check(a.games.first { $0.relativePath == "v1" }?.id == b.games.first?.id, "absolute mount path affected identity")
   try check(b.games.first?.id != c.games.first?.id, "source UUID omitted from identity")
  }
  test("symlink roots directories entries and marker paths are never followed") { folder in
   let external = root.appendingPathComponent(UUID().uuidString)
   try put(external, "Game.exe")
   try put(external, "index.html", "<html>fixture</html>")
   try fm.createSymbolicLink(at: folder.appendingPathComponent("LinkedGame"), withDestinationURL: external)
   try fm.createSymbolicLink(at: folder.appendingPathComponent("Game.exe"), withDestinationURL: external.appendingPathComponent("Game.exe"))
   try fm.createSymbolicLink(at: folder.appendingPathComponent("index.html"), withDestinationURL: external.appendingPathComponent("index.html"))
   try check(LibraryDiscovery.scan(source: source(folder)).games.isEmpty, "external link produced a candidate")
   let alias = root.appendingPathComponent(UUID().uuidString)
   try fm.createSymbolicLink(at: alias, withDestinationURL: external)
   let denied = LibraryDiscovery.scan(source: source(alias))
   try check(!denied.completed && !denied.issues.isEmpty && denied.games.isEmpty, "selected symlink root traversed")
  }
  test("only executable headers qualify and known helpers do not suppress valid names") { folder in
   try put(folder, "Helpers/setup.exe")
   try put(folder, "Helpers/FileCheck.exe")
   try put(folder, "TextOnly/Novel.exe", "not a PE header")
   try put(folder, "Legitimate/ConfigurationStory.exe")
   try put(folder, "Legitimate/CustomAdventure.exe")
   let result = LibraryDiscovery.scan(source: source(folder))
   try check(result.games.count == 1 && result.games[0].relativePath == "Legitimate", "helper-only or invalid header accepted")
   try check(result.games[0].entries.count == 2, "legacy broad prefix exclusion leaked into discovery")
  }
  test("cancellation and limits return explicitly incomplete partial results") { folder in
   for name in ["a", "b", "c"] { try put(folder, name + "/Game.exe") }
   var visited = 0
   let result = LibraryDiscovery.scan(source: source(folder), cancelled: { visited >= 2 }, progress: { visited = $0.visitedDirectories })
   try check(result.cancelled && !result.completed && visited == 2, "cancel did not stop between directories")
   let limited = LibraryDiscovery.scan(source: source(folder), limits: DiscoveryLimits(maxDirectories: 2))
   try check(!limited.completed && !limited.cancelled && !limited.issues.isEmpty && limited.games.count <= 1, "directory budget ignored")
   let depth = LibraryDiscovery.scan(source: source(folder), limits: DiscoveryLimits(maxDepth: 0))
   try check(!depth.completed && depth.games.isEmpty, "depth budget ignored")
   let headers = LibraryDiscovery.scan(source: source(folder), limits: DiscoveryLimits(maxHeaderReads: 0))
   try check(!headers.completed && headers.games.isEmpty, "header budget ignored")
   let entries = LibraryDiscovery.scan(source: source(folder), limits: DiscoveryLimits(maxEntriesPerDirectory: 2))
   try check(!entries.completed && !entries.issues.isEmpty, "directory entry budget ignored")
  }
  test("direct selected game or app root uses dot relative path") { folder in
   try put(folder, "Game.exe")
   let game = LibraryDiscovery.scan(source: source(folder))
   try check(game.games.count == 1 && game.games[0].relativePath == ".", "root game path must be dot")
   let app = folder.appendingPathComponent("Single.app")
   try put(app, "Contents/MacOS/Single", "fixture")
   let result = LibraryDiscovery.scan(source: source(app))
   try check(result.games.first?.entries == [Candidate(path: ".", backend: .native, engine: "macOS")], "selected app root did not remain a leaf")
  }
  test("root registration choices ignored and added statuses persist incrementally") { folder in
   let library = folder.appendingPathComponent("library"), state = folder.appendingPathComponent("state")
   try put(library, "One/Game.exe")
   try put(library, "One/Game_CN.exe")
   try put(library, "Two/Game.exe")
   let store = try DiscoveryStore(root: state)
   let registered = try store.register(path: library, title: "Fixture")
   let again = try store.register(path: library, title: "Renamed")
   try check(registered.id == again.id && store.sources.count == 1, "duplicate registration changed source identity")
   let result = LibraryDiscovery.scan(source: again)
   try store.apply(result, sourceID: registered.id)
   let one = result.games.first { $0.relativePath == "One" }!, two = result.games.first { $0.relativePath == "Two" }!
   let selected = one.entries.first { $0.path == "Game_CN.exe" }!, gameID = UUID()
   try store.select(one.id, entry: selected)
   try store.ignore(two.id)
   try store.markAdded(one.id, entry: selected, gameID: gameID)
   try put(library, "Three/Game.exe")
   try store.apply(LibraryDiscovery.scan(source: again), sourceID: registered.id)
   let loaded = try DiscoveryStore(root: state)
   try check(loaded.records.count == 3 && loaded.sources[0].title == "Renamed", "incremental state not persisted")
   let kept = loaded.records.first { $0.game.id == one.id }!
   try check(kept.status == .added && kept.addedGameID == gameID && kept.selectedEntry == selected, "rescan reset selected added identity")
   try check(loaded.records.first { $0.game.id == two.id }?.status == .ignored, "rescan reset ignored decision")
   try check(loaded.records.first { $0.game.relativePath == "Three" }?.status == .pending, "new sibling auto-added")
   try reject("foreign entry selected") { try loaded.select(one.id, entry: Candidate(path: "../outside.exe", backend: .wine, engine: "Windows")) }
  }
  test("offline and partial rescans preserve decisions while complete missing results mark unavailable") { folder in
   let library = folder.appendingPathComponent("library"), state = folder.appendingPathComponent("state")
   try put(library, "One/Game.exe")
   try put(library, "One/Game_CN.exe")
   let store = try DiscoveryStore(root: state), registered = try store.register(path: library, title: "Fixture")
   let initial = LibraryDiscovery.scan(source: registered)
   try store.apply(initial, sourceID: registered.id)
   try check(initial.games.count == 1, "initial game missing")
   let game = initial.games[0], entry = game.entries.first { $0.path == "Game_CN.exe" }!
   try store.select(game.id, entry: entry)
   try store.ignore(game.id)
   try store.apply(LibraryDiscovery.scan(source: registered, cancelled: { true }), sourceID: registered.id)
   try check(store.records[0].available, "cancel marked unseen game unavailable")
   try fm.moveItem(at: library, to: folder.appendingPathComponent("disconnected"))
   let offline = LibraryDiscovery.scan(source: registered)
   try check(!offline.completed && !offline.issues.isEmpty, "offline scan claimed complete")
   try store.apply(offline, sourceID: registered.id)
   try check(store.records.count == 1 && !store.records[0].available && store.records[0].status == .ignored && store.records[0].selectedEntry == entry, "offline deleted or reset state")
   try fm.moveItem(at: folder.appendingPathComponent("disconnected"), to: library)
   try fm.removeItem(at: library.appendingPathComponent("One/Game_CN.exe"))
   try store.apply(LibraryDiscovery.scan(source: registered), sourceID: registered.id)
   try check(store.records[0].available && store.records[0].selectedEntry == entry, "missing chosen entry was silently replaced")
   try fm.removeItem(at: library.appendingPathComponent("One"))
   try store.apply(LibraryDiscovery.scan(source: registered), sourceID: registered.id)
   try check(store.records.count == 1 && !store.records[0].available, "complete missing scan deleted candidate history")
  }
  test("discovery snapshot write failure rolls back registration and decisions") { folder in
   let library = folder.appendingPathComponent("library"), state = folder.appendingPathComponent("state")
   try put(library, "Game.exe")
   let store = try DiscoveryStore(root: state), registered = try store.register(path: library, title: "Fixture")
   let result = LibraryDiscovery.scan(source: registered)
   try store.apply(result, sourceID: registered.id)
   let file = state.appendingPathComponent("discovery.json"), bytes = try Data(contentsOf: file)
   try fm.removeItem(at: file);try fm.createDirectory(at: file, withIntermediateDirectories: false)
   try put(file, "sentinel", "preserve")
   try reject("failed registration accepted") { _ = try store.register(path: folder.appendingPathComponent("other"), title: "Other") }
   try reject("failed ignore accepted") { try store.ignore(result.games[0].id) }
   try reject("failed selection accepted") { try store.select(result.games[0].id, entry: result.games[0].entries[0]) }
   try reject("failed added decision accepted") { try store.markAdded(result.games[0].id, entry: result.games[0].entries[0], gameID: UUID()) }
   try check(store.sources.count == 1 && store.records[0].status == .pending && store.records[0].selectedEntry == nil, "failed write changed in-memory state")
   try check(try String(contentsOf: file.appendingPathComponent("sentinel"), encoding: .utf8) == "preserve", "failed write damaged target")
   try fm.removeItem(at: file);try bytes.write(to: file)
   try check(try DiscoveryStore(root: state).records.count == 1, "last durable snapshot lost")
  }
  test("corrupt discovery snapshot is rejected without replacement") { folder in
   let file = folder.appendingPathComponent("discovery.json"), bytes = Data("{broken".utf8)
   try bytes.write(to: file)
   try reject("malformed state accepted") { _ = try DiscoveryStore(root: folder) }
   try check(try Data(contentsOf: file) == bytes, "malformed state overwritten")
  }
  test("a resource-named category without a complete game remains traversable") { folder in
   try put(folder, "renpy/Actual/Game.exe")
   try put(folder, "Example_Data/Other/Game.exe")
   let result = LibraryDiscovery.scan(source: source(folder))
   try check(result.completed && Set(result.games.map(\.relativePath)) == Set(["renpy/Actual", "Example_Data/Other"]), "weak folder names pruned real sibling games")
  }
  test("semantic snapshot corruption and forged scan paths are rejected transactionally") { folder in
   let library = folder.appendingPathComponent("library"), state = folder.appendingPathComponent("state")
   try put(library, "Game.exe")
   let store = try DiscoveryStore(root: state), registered = try store.register(path: library)
   let result = LibraryDiscovery.scan(source: registered)
   try store.apply(result, sourceID: registered.id)
   let file = state.appendingPathComponent("discovery.json"), good = try Data(contentsOf: file)
   let object = try JSONSerialization.jsonObject(with: good) as! [String: Any]
   let originalRecords = object["records"] as! [[String: Any]]
   var traversal = object, changed = originalRecords[0], game = changed["game"] as! [String: Any]
   game["relativePath"] = "../escape"; changed["game"] = game; traversal["records"] = [changed]
   var duplicate = object; duplicate["records"] = originalRecords + originalRecords
   var future = object; future["version"] = 99
   for corrupt in [traversal, duplicate, future] {
    let bad = try JSONSerialization.data(withJSONObject: corrupt)
    try bad.write(to: file)
    try reject("invalid semantic snapshot accepted") { _ = try DiscoveryStore(root: state) }
    try check(try Data(contentsOf: file) == bad, "semantic corruption overwritten")
   }
   try good.write(to: file)
   var forged = result.games[0]; forged.relativePath = "../outside"
   try reject("forged scan path accepted") {
    try store.apply(DiscoveryResult(games: [forged], issues: [], completed: true, cancelled: false), sourceID: registered.id)
   }
   try check(try Data(contentsOf: file) == good && store.records[0].game == result.games[0], "invalid scan mutated durable or in-memory records")
  }
  test("unsupported Windows filenames cannot poison persistence for valid siblings") { folder in
   let library = folder.appendingPathComponent("library"), state = folder.appendingPathComponent("state")
   try put(library, "Valid/Game.exe")
   try put(library, "Mixed/Bad\"Entry.exe")
   try put(library, "Mixed/Game.exe")
   let store = try DiscoveryStore(root: state), registered = try store.register(path: library)
   let result = LibraryDiscovery.scan(source: registered)
   try check(!result.completed && !result.issues.isEmpty, "unsupported entry not reported")
   try check(result.games.count == 2 && result.games.allSatisfy { $0.entries.allSatisfy { $0.path == "Game.exe" } }, "invalid Windows entry leaked into selection")
   try store.apply(result, sourceID: registered.id)
   try check(store.records.count == 2, "invalid sibling prevented valid discovery persistence")
  }
  test("restore persists ignored to pending and preserves choices without resetting added games") { folder in
   let library = folder.appendingPathComponent("library"), state = folder.appendingPathComponent("state")
   try put(library, "Game.exe")
   try put(library, "Game_CN.exe")
   let store = try DiscoveryStore(root: state), registered = try store.register(path: library)
   let result = LibraryDiscovery.scan(source: registered)
   try store.apply(result, sourceID: registered.id)
   let candidate = result.games[0], chosen = candidate.entries.first { $0.path == "Game_CN.exe" }!, gameID = UUID()
   try store.select(candidate.id, entry: chosen)
   try store.ignore(candidate.id)
   try store.restore(candidate.id)
   let restored = try DiscoveryStore(root: state).records[0]
   try check(restored.status == .pending && restored.selectedEntry == chosen && restored.available, "restoring ignore lost selection or was not durable")
   try store.markAdded(candidate.id, entry: chosen, gameID: gameID)
   let file = state.appendingPathComponent("discovery.json"), before = try Data(contentsOf: file)
   try store.restore(candidate.id)
   try check(store.records[0].status == .added && store.records[0].addedGameID == gameID && store.records[0].selectedEntry == chosen, "restore corrupted an added record")
   try check(try Data(contentsOf: file) == before, "restore rewrote a non-ignored record")
   try store.ignore(candidate.id)
   try store.restore(candidate.id)
   let retained = try DiscoveryStore(root: state).records[0]
   try check(retained.status == .pending && retained.addedGameID == gameID && retained.selectedEntry == chosen, "restore discarded prior library identity")
   try reject("unknown restore accepted") { try store.restore("missing-candidate") }
  }
  test("restore write failure preserves ignored in-memory and durable state") { folder in
   let library = folder.appendingPathComponent("library"), state = folder.appendingPathComponent("state")
   try put(library, "Game.exe")
   let store = try DiscoveryStore(root: state), registered = try store.register(path: library)
   let result = LibraryDiscovery.scan(source: registered)
   try store.apply(result, sourceID: registered.id)
   let id = result.games[0].id
   try store.ignore(id)
   let file = state.appendingPathComponent("discovery.json"), backup = try Data(contentsOf: file)
   try fm.removeItem(at: file); try fm.createDirectory(at: file, withIntermediateDirectories: false)
   try put(file, "sentinel", "preserve")
   try reject("failed restore accepted") { try store.restore(id) }
   try check(store.records[0].status == .ignored, "failed restore changed in-memory state")
   try check(try String(contentsOf: file.appendingPathComponent("sentinel"), encoding: .utf8) == "preserve", "failed restore damaged target")
   try fm.removeItem(at: file); try backup.write(to: file)
   try check(try DiscoveryStore(root: state).records[0].status == .ignored, "failed restore lost durable ignored state")
   try store.restore(id)
   try check(try DiscoveryStore(root: state).records[0].status == .pending, "restore could not retry after storage recovery")
  }
  test("custom and localized settings helpers never become game entries") { folder in
   try put(folder, "Game/th08.exe")
   let helpers = ["custom.exe", "設定.exe", "设置.exe", "環境設定.exe", "环境设置.exe", "游戏设置.exe", "エンジン設定.exe", "config_jp.exe", "config64.exe", "config-tool.exe", "uninstall_game.exe", "uninstaller.exe"]
   for helper in helpers {
    try put(folder, "Game/" + helper)
    try put(folder, "Helpers/" + helper)
   }
   let result = LibraryDiscovery.scan(source: source(folder))
   try check(result.completed && result.games.count == 1 && result.games[0].relativePath == "Game", "helper-only directory became a game")
   try check(result.games[0].entries.map(\.path) == ["th08.exe"], "custom/settings tool offered beside main launcher")
  }
  test("generic platform titles use edition parents without merging identities") { folder in
   try put(folder, "Example v1.0/Windows/Game.exe")
   try put(folder, "Example v2.0/Windows/Game.exe")
   try put(folder, "Specific Edition/Game.exe")
   let registered = source(folder), result = LibraryDiscovery.scan(source: registered)
   try check(result.completed && result.games.count == 3, "platform editions were merged or omitted")
   let first = result.games.first { $0.relativePath == "Example v1.0/Windows" }!
   let second = result.games.first { $0.relativePath == "Example v2.0/Windows" }!
   try check(first.title == "Example v1.0" && second.title == "Example v2.0", "generic platform label hid edition title")
   try check(first.id != second.id && first.entries == second.entries, "display fallback changed edition grouping")
   let repeated = LibraryDiscovery.scan(source: registered)
   try check(repeated.games.map(\.id) == result.games.map(\.id), "title fallback destabilized discovery IDs")
   try check(result.games.first { $0.relativePath == "Specific Edition" }?.title == "Specific Edition", "ordinary title was replaced")
  }
  test("direct platform roots use actual parent and all platform aliases are recognized") { folder in
   let parent = folder.appendingPathComponent("Example v1.0")
   for name in ["Windows", "win", "win32", "win64", "pc", "Mac", "macOS", "osx"] {
    let platform = parent.appendingPathComponent(name)
    try put(platform, "Game.exe")
    let registered = source(platform), result = LibraryDiscovery.scan(source: registered)
    try check(result.completed && result.games.count == 1, "platform root did not scan")
    let game = result.games[0]
    try check(game.relativePath == "." && game.title == "Example v1.0", "selected root platform title did not use source URL parent")
    try check(LibraryDiscovery.scan(source: registered).games[0].id == game.id, "direct root title changed identity")
   }
  }
  print("LibraryDiscovery: \(passed) passed; \(failed) failed")
  if failed != 0 { exit(1) }
 }
}
