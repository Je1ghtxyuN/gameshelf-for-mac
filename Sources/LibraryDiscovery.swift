import Foundation
import CryptoKit
import Darwin

struct LibrarySource: Codable, Identifiable, Equatable {
 var id: UUID
 var title: String
 var path: String
 init(id: UUID = UUID(), title: String, path: String) { self.id = id; self.title = title; self.path = path }
}
struct DiscoveredGame: Codable, Identifiable, Equatable {
 var id: String
 var sourceID: UUID
 var relativePath: String
 var title: String
 var entries: [Candidate]
}
struct DiscoveryLimits {
 var maxDepth: Int
 var maxDirectories: Int
 var maxEntriesPerDirectory: Int
 var maxHeaderReads: Int
 var maxReadBytes: Int
 init(maxDepth: Int = 8, maxDirectories: Int = 2000, maxEntriesPerDirectory: Int = 4096,
      maxHeaderReads: Int = 4096, maxReadBytes: Int = 16 * 1024 * 1024) {
  self.maxDepth = maxDepth; self.maxDirectories = maxDirectories
  self.maxEntriesPerDirectory = maxEntriesPerDirectory; self.maxHeaderReads = maxHeaderReads; self.maxReadBytes = maxReadBytes
 }
}
struct DiscoveryProgress {
 let visitedDirectories: Int
 let foundGames: Int
 let relativePath: String
}
struct DiscoveryIssue: Equatable {
 enum Kind { case unavailable, unreadable, limit, invalidSource }
 let relativePath: String
 let message: String
 let kind: Kind
}
struct DiscoveryResult {
 let games: [DiscoveredGame]
 let issues: [DiscoveryIssue]
 let completed: Bool
 let cancelled: Bool
}
enum DiscoveryStatus: String, Codable { case pending, ignored, added }
struct DiscoveryRecord: Codable, Equatable {
 var game: DiscoveredGame
 var status: DiscoveryStatus
 var selectedEntry: Candidate?
 var addedGameID: UUID?
 var available: Bool
 var selectedEntryAvailable: Bool {
  available && selectedEntry.map { chosen in game.entries.contains { $0.path == chosen.path && $0.backend == chosen.backend } } == true
 }
}

/// Synchronous and read-only. Call off the UI thread. Cancellation is checked
/// between filesystem operations; it cannot interrupt an OS-blocked mount read.
enum LibraryDiscovery {
 static func scan(source: LibrarySource, limits: DiscoveryLimits = DiscoveryLimits(),
                  cancelled: () -> Bool = { false }, progress: (DiscoveryProgress) -> Void = { _ in }) -> DiscoveryResult {
  withoutActuallyEscaping(cancelled) { cancellation in
   withoutActuallyEscaping(progress) { notification in
    DiscoveryWalker(source: source, limits: limits, cancellation: cancellation, notification: notification).run()
   }
  }
 }
}

private enum DiscoveryIdentity {
 static func id(_ sourceID: UUID, _ path: String) -> String {
  SHA256.hash(data: Data((sourceID.uuidString + "\0" + path).utf8)).map { String(format: "%02x", $0) }.joined()
 }
 static func validPath(_ path: String, dot: Bool = true) -> Bool {
  if path == "." { return dot }
  return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
   !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } &&
   !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
 }
 static func sameEntry(_ a: Candidate, _ b: Candidate) -> Bool { a.path == b.path && a.backend == b.backend }
 static func ordered(_ a: String, _ b: String) -> Bool {
  let comparison = a.localizedStandardCompare(b)
  return comparison == .orderedSame ? a.utf8.lexicographicallyPrecedes(b.utf8) : comparison == .orderedAscending
 }
}

private final class DiscoveryWalker {
 private struct Node { let name: String; let directory: Bool; let regular: Bool }
 private let source: LibrarySource
 private let limits: DiscoveryLimits
 private let cancellation: () -> Bool
 private let notification: (DiscoveryProgress) -> Void
 private var games: [DiscoveredGame] = []
 private var issues: [DiscoveryIssue] = []
 private var visited = 0, reads = 0, readBytes = 0
 private var wasCancelled = false, exhausted = false
 private var currentPath = "."
 private let resources: Set<String> = [
  "data", "gamedata", "graphics", "audio", "image", "images", "movies", "video", "sound", "sounds",
  "save", "saves", "savedata", "fonts", "font", "www", "js", "game", "renpy", "lib", "libs",
  "runtime", "runtimes", "node_modules", "locales", "plugins", "system", "cache", "logs",
  "tools", "redist", "_commonredist", "prerequisites", "directx"
 ]
 init(source: LibrarySource, limits: DiscoveryLimits, cancellation: @escaping () -> Bool,
      notification: @escaping (DiscoveryProgress) -> Void) {
  self.source = source; self.limits = limits; self.cancellation = cancellation; self.notification = notification
 }
 func run() -> DiscoveryResult {
  if shouldStop() { return result() }
  guard source.path.hasPrefix("/"), !source.path.contains("\0") else {
   issue(".", "来源目录路径无效。", .invalidSource); return result()
  }
  guard limits.maxDepth >= 0, limits.maxDirectories > 0, limits.maxEntriesPerDirectory > 0,
        limits.maxHeaderReads >= 0, limits.maxReadBytes >= 0 else {
   issue(".", "扫描预算无效。", .limit); return result()
  }
  let descriptor = source.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
  guard descriptor >= 0 else {
   issue(".", "来源目录不可访问或是符号链接；已有选择会保留。", .unavailable); return result()
  }
  defer { Darwin.close(descriptor) }
  walk(descriptor, path: ".", depth: 0, isApp: (source.path as NSString).pathExtension.lowercased() == "app")
  return result()
 }
 private func result() -> DiscoveryResult {
  DiscoveryResult(games: games.sorted { DiscoveryIdentity.ordered($0.relativePath, $1.relativePath) },
                  issues: issues, completed: issues.isEmpty && !wasCancelled, cancelled: wasCancelled)
 }
 private func shouldStop() -> Bool {
  if cancellation() { wasCancelled = true }
  return wasCancelled || exhausted
 }
 private func issue(_ path: String, _ message: String, _ kind: DiscoveryIssue.Kind) {
  let value = DiscoveryIssue(relativePath: path, message: message, kind: kind)
  if !issues.contains(value) { issues.append(value) }
 }
 private func report(_ path: String) {
  notification(DiscoveryProgress(visitedDirectories: visited, foundGames: games.count, relativePath: path))
 }
 private func add(_ path: String, entries: [Candidate]) {
  guard DiscoveryIdentity.validPath(path) else {
   issue(path, "目录名无法安全记录为相对路径。", .unreadable); return
  }
  let checked = entries.filter { entry in
   do {
    guard DiscoveryIdentity.validPath(entry.path, dot: entry.backend == .native) else { throw LibraryError("入口路径无效。") }
    try EntryPolicy.validate(entry)
    return true
   } catch {
    issue(path, "部分入口文件名无法安全启动，已保留其他可用入口。", .unreadable)
    return false
   }
  }
  guard !checked.isEmpty else { return }
  let root = URL(fileURLWithPath: source.path, isDirectory: true)
  let folder = path == "." ? root : root.appendingPathComponent(path, isDirectory: true)
  let name = folder.lastPathComponent
  var title = (name as NSString).pathExtension.lowercased() == "app" ? (name as NSString).deletingPathExtension : name
  let platforms: Set<String> = ["windows", "win", "win32", "win64", "pc", "mac", "macos", "osx"]
  if platforms.contains(name.lowercased()) {
   let parent = folder.deletingLastPathComponent().lastPathComponent
   if !parent.isEmpty && parent != "/" { title = parent }
  }
  games.append(DiscoveredGame(id: DiscoveryIdentity.id(source.id, path), sourceID: source.id, relativePath: path,
                              title: title, entries: checked))
 }
 private func walk(_ descriptor: Int32, path: String, depth: Int, isApp: Bool) {
  guard !shouldStop() else { return }
  guard depth <= limits.maxDepth else { issue(path, "已达到扫描深度上限。", .limit); return }
  guard visited < limits.maxDirectories else {
   issue(path, "已达到扫描目录数量上限。", .limit); exhausted = true; return
  }
  visited += 1
  currentPath = path
  if isApp {
   add(path, entries: [Candidate(path: ".", backend: .native, engine: "macOS")]); report(path); return
  }
  guard let nodes = list(descriptor, path: path) else { report(path); return }
  let engine = detectEngine(descriptor, nodes: nodes)
  var entries: [Candidate] = []
  let executables = nodes.filter { $0.regular && ($0.name as NSString).pathExtension.lowercased() == "exe" && !VisualNovelProbe.isAuxiliaryExecutable($0.name) }
  for name in VisualNovelProbe.orderedExecutables(executables.map(\.name)) {
   guard !shouldStop() else { break }
   if read(descriptor, path: name, count: 2) == Data([0x4d, 0x5a]) {
    entries.append(Candidate(path: name, backend: engine == "Ren’Py" ? .renpy : .wine, engine: engine))
   }
  }
  let nativeApps = nodes.filter { $0.directory && ($0.name as NSString).pathExtension.lowercased() == "app" }
  // Preserve Core's verified MZ opt-in, but retain other language/platform entries.
  if engine == "RPG Maker MZ", entries.contains(where: { $0.path == "Game.exe" }), regular(descriptor, "index.html"), verifiedMZ(descriptor) {
   for index in entries.indices where entries[index].path == "Game.exe" { entries[index].backend = .rpgmz }
  }
  if entries.isEmpty && nativeApps.isEmpty && regular(descriptor, "index.html") &&
      !regular(descriptor, "package.json") && !regular(descriptor, "nw.dll") && !shouldStop() {
   entries.append(Candidate(path: "index.html", backend: .web, engine: engine == "Windows" ? "HTML 游戏" : engine + " · Web"))
  }
  let completeDirectory = !entries.isEmpty
  if completeDirectory {
   entries += nativeApps.map { Candidate(path: $0.name, backend: .native, engine: "macOS") }
   add(path, entries: entries)
  }
  report(path)
  // A found game prunes known resource children, not platform/version siblings.
  // Without game context, even a category named Data or Games remains traversable.
  let strongEngineEvidence = (engine != "Windows" && engine != "Ren’Py" && engine != "Unity") ||
   (engine == "Ren’Py" && regular(descriptor, "renpy/__init__.py")) ||
   (engine == "Unity" && nodes.contains { $0.regular && $0.name.lowercased() == "unityplayer.dll" })
  let resourceContext = completeDirectory || strongEngineEvidence
  for node in nodes where node.directory {
   guard !shouldStop() else { return }
   let app = (node.name as NSString).pathExtension.lowercased() == "app"
   if app && completeDirectory { continue }
   let lower = node.name.lowercased()
   if resourceContext && !app && (resources.contains(lower) || lower.hasSuffix("_data")) { continue }
   let childPath = path == "." ? node.name : path + "/" + node.name
   let child = node.name.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
   guard child >= 0 else { issue(childPath, "子目录不可读取或已发生变化。", .unreadable); continue }
   walk(child, path: childPath, depth: depth + 1, isApp: app)
   Darwin.close(child)
  }
 }
 private func list(_ descriptor: Int32, path: String) -> [Node]? {
  let copy = Darwin.dup(descriptor)
  guard copy >= 0 else { issue(path, "无法读取目录。", .unreadable); return nil }
  guard let directory = Darwin.fdopendir(copy) else { Darwin.close(copy); issue(path, "无法读取目录。", .unreadable); return nil }
  defer { Darwin.closedir(directory) }
  var nodes: [Node] = [], count = 0
  while true {
   if shouldStop() { return nil }
   errno = 0
   guard let entry = Darwin.readdir(directory) else {
    if errno != 0 { issue(path, "目录读取未完成。", .unreadable); return nil }
    return nodes.sorted { DiscoveryIdentity.ordered($0.name, $1.name) }
   }
   let name = withUnsafePointer(to: &entry.pointee.d_name) {
    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
   }
   guard let name, name != ".", name != ".." else { continue }
   count += 1
   guard count <= limits.maxEntriesPerDirectory else { issue(path, "目录项数量超过扫描上限。", .limit); return nil }
   guard !name.hasPrefix(".") else { continue }
   var info = stat()
   guard name.withCString({ Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
    issue(path, "部分目录项不可读取。", .unreadable); continue
   }
   let type = info.st_mode & mode_t(S_IFMT)
   if type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) {
    nodes.append(Node(name: name, directory: type == mode_t(S_IFDIR), regular: type == mode_t(S_IFREG)))
   }
  }
 }
 /// Every component is opened relative to an owned descriptor without following
 /// links. This also protects nested marker/profile reads from substituted dirs.
 private func withParent<T>(_ descriptor: Int32, _ path: String, _ action: (Int32, String) -> T?) -> T? {
  let pieces = path.split(separator: "/").map(String.init)
  guard DiscoveryIdentity.validPath(path, dot: false), let last = pieces.last else { return nil }
  var parent = descriptor, owned: [Int32] = []
  defer { for fd in owned.reversed() { Darwin.close(fd) } }
  for component in pieces.dropLast() {
   let child = component.withCString { Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
   guard child >= 0 else { return nil }
   owned.append(child); parent = child
  }
  return action(parent, last)
 }
 private func regular(_ descriptor: Int32, _ path: String) -> Bool {
  withParent(descriptor, path) { parent, name in
   var info = stat()
   return name.withCString { Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) } == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
  } ?? false
 }
 private func read(_ descriptor: Int32, path: String, count: Int, footer: Bool = false, whole: Bool = false) -> Data? {
  guard !shouldStop() else { return nil }
  return withParent(descriptor, path) { parent, name in
   let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
   guard fd >= 0 else { return nil }
   defer { Darwin.close(fd) }
   var info = stat()
   guard Darwin.fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0 else { return nil }
   if footer && info.st_size < 28 { return nil }
   if whole && info.st_size > off_t(count) { return nil }
   let amount = whole ? Int(info.st_size) : min(count, Int(min(info.st_size, off_t(count))))
   guard reads < limits.maxHeaderReads, amount <= limits.maxReadBytes - readBytes else {
    issue(currentPath, "已达到扫描读取预算。", .limit); exhausted = true; return nil
   }
   reads += 1; readBytes += amount
   var bytes = Data(count: amount)
   let length = bytes.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, amount, footer ? info.st_size - 28 : 0) }
   guard length == amount else { issue(currentPath, "文件读取未完成。", .unreadable); return nil }
   return bytes
  }
 }
 private func detectEngine(_ descriptor: Int32, nodes: [Node]) -> String {
  let files = Set(nodes.filter(\.regular).map { $0.name.lowercased() })
  if nodes.contains(where: { $0.directory && $0.name.lowercased() == "renpy" }) { return "Ren’Py" }
  if regular(descriptor, "www/js/rpg_core.js") || regular(descriptor, "js/rpg_core.js") { return "RPG Maker MV" }
  if regular(descriptor, "js/rmmz_core.js") || regular(descriptor, "www/js/rmmz_core.js") { return "RPG Maker MZ" }
  for (marker, engine) in [("game.rgss3a", "RPG Maker VX Ace"), ("game.rgss2a", "RPG Maker VX"), ("game.rgssad", "RPG Maker XP"), ("rpg_rt.ldb", "RPG Maker 2000/2003")] {
   if files.contains(marker) { return engine }
  }
  if files.contains("unityplayer.dll") || nodes.contains(where: { $0.directory && $0.name.lowercased().hasSuffix("_data") }) { return "Unity" }
  // Mirror the tiny VN signatures with descriptor-relative reads. Calling the
  // legacy path-based Scan here would follow EXE links and hide native siblings.
  if let gameData = nodes.first(where: { $0.directory && $0.name.lowercased() == "gamedata" }) {
   let child = gameData.name.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
   if child >= 0 {
    defer { Darwin.close(child) }
    if let packs = list(child, path: currentPath + "/" + gameData.name) {
     for node in packs.filter({ $0.regular && ($0.name as NSString).pathExtension.lowercased() == "pack" }).sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }).prefix(8) {
      if let bytes = read(child, path: node.name, count: 14, footer: true), bytes.count == 14,
         bytes.prefix(11) == Data("FilePackVer".utf8), (48...57).contains(bytes[11]), bytes[12] == 46, (48...57).contains(bytes[13]) { return "QLIE" }
     }
    }
   }
  }
  for node in nodes.filter({ $0.regular && ($0.name as NSString).pathExtension.lowercased() == "int" }).sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }).prefix(8) {
   if read(descriptor, path: node.name, count: 4) == Data([0x4b, 0x49, 0x46, 0]) { return "CatSystem2" }
  }
  for node in nodes.filter({ $0.regular && ($0.name as NSString).pathExtension.lowercased() == "xp3" }).sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }).prefix(8) {
   if read(descriptor, path: node.name, count: 11) == Data([0x58, 0x50, 0x33, 0x0d, 0x0a, 0x20, 0x0a, 0x1a, 0x8b, 0x67, 1]) { return "KiriKiri" }
  }
  if !files.isDisjoint(with: ["nscript.dat", "0.txt", "00.txt"]) { return "NScripter / ONScripter" }
  return "Windows"
 }
 private func verifiedMZ(_ descriptor: Int32) -> Bool {
  for path in MZWebProfile.sakura.keys.sorted() {
   guard let data = read(descriptor, path: path, count: 2 * 1024 * 1024, whole: true),
         SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == MZWebProfile.sakura[path] else { return false }
  }
  return true
 }
}

/// Local discovery decisions only. Does not import games or touch a source.
/// Use on one serial owner (normally the main thread), with one instance/root.
final class DiscoveryStore {
 private struct Snapshot: Codable {
  var version = 1
  var sources: [LibrarySource]
  var records: [DiscoveryRecord]
 }
 private let file: URL
 private(set) var sources: [LibrarySource] = []
 private(set) var records: [DiscoveryRecord] = []
 init(root: URL) throws {
  file = root.appendingPathComponent("discovery.json")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let data: Data
  do { data = try Data(contentsOf: file) }
  catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
  let loaded = try JSONDecoder().decode(Snapshot.self, from: data)
  try Self.validate(loaded)
  sources = loaded.sources; records = loaded.records
 }
 func register(path: URL, title: String? = nil) throws -> LibrarySource {
  guard path.isFileURL else { throw LibraryError("请选择本地或已挂载的目录。") }
  let normalized = path.standardizedFileURL.path
  let name = title ?? path.lastPathComponent
  var next = sources
  let source: LibrarySource
  if let index = next.firstIndex(where: { $0.path == normalized }) {
   next[index].title = name; source = next[index]
  } else { source = LibrarySource(title: name, path: normalized); next.append(source) }
  try save(sources: next, records: records)
  return source
 }
 func records(sourceID: UUID) -> [DiscoveryRecord] { records.filter { $0.game.sourceID == sourceID } }
 func apply(_ result: DiscoveryResult, sourceID: UUID) throws {
  guard sources.contains(where: { $0.id == sourceID }), !(result.completed && (result.cancelled || !result.issues.isEmpty)),
        result.games.allSatisfy({ $0.sourceID == sourceID }), Set(result.games.map(\.id)).count == result.games.count else { throw LibraryError("扫描结果与来源不匹配。") }
  var next = records
  let seen = Set(result.games.map(\.id))
  let unavailable = result.issues.contains { $0.relativePath == "." && $0.kind == .unavailable }
  for index in next.indices where next[index].game.sourceID == sourceID {
   if unavailable || (result.completed && !seen.contains(next[index].game.id)) { next[index].available = false }
  }
  for game in result.games {
   if let index = next.firstIndex(where: { $0.game.id == game.id }) {
    next[index].game = game; next[index].available = true
    if let chosen = next[index].selectedEntry, let updated = game.entries.first(where: { DiscoveryIdentity.sameEntry($0, chosen) }) { next[index].selectedEntry = updated }
   } else {
    next.append(DiscoveryRecord(game: game, status: .pending, selectedEntry: nil, addedGameID: nil, available: true))
   }
  }
  try save(sources: sources, records: next)
 }
 func select(_ candidateID: String, entry: Candidate) throws {
  var next = records
  let (index, actual) = try selection(candidateID, entry: entry)
  next[index].selectedEntry = actual
  try save(sources: sources, records: next)
 }
 func ignore(_ candidateID: String) throws {
  guard let index = records.firstIndex(where: { $0.game.id == candidateID }) else { throw LibraryError("未找到该发现记录。") }
  var next = records; next[index].status = .ignored
  try save(sources: sources, records: next)
 }
 /// Undo an ignore without replacing the chosen entry or an existing library ID.
 /// An added record needs an explicit library-removal workflow, not this method.
 func restore(_ candidateID: String) throws {
  guard let index = records.firstIndex(where: { $0.game.id == candidateID }) else { throw LibraryError("未找到该发现记录。") }
  guard records[index].status == .ignored else { return }
  var next = records; next[index].status = .pending
  try save(sources: sources, records: next)
 }
 func markAdded(_ candidateID: String, entry: Candidate, gameID: UUID) throws {
  let (index, actual) = try selection(candidateID, entry: entry)
  var next = records
  next[index].selectedEntry = actual; next[index].status = .added; next[index].addedGameID = gameID
  try save(sources: sources, records: next)
 }
 private func selection(_ id: String, entry: Candidate) throws -> (Int, Candidate) {
  guard let index = records.firstIndex(where: { $0.game.id == id }), records[index].available,
        let actual = records[index].game.entries.first(where: { DiscoveryIdentity.sameEntry($0, entry) }) else { throw LibraryError("所选启动入口不在当前可用记录中。") }
  return (index, actual)
 }
 private func save(sources: [LibrarySource], records: [DiscoveryRecord]) throws {
  let snapshot = Snapshot(sources: sources, records: records)
  try Self.validate(snapshot)
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  try encoder.encode(snapshot).write(to: file, options: .atomic)
  self.sources = sources; self.records = records
 }
 private static func validate(_ snapshot: Snapshot) throws {
  guard snapshot.version == 1, Set(snapshot.sources.map(\.id)).count == snapshot.sources.count,
        Set(snapshot.sources.map(\.path)).count == snapshot.sources.count,
        Set(snapshot.records.map { $0.game.id }).count == snapshot.records.count else { throw LibraryError("发现记录格式无效，已保留原文件。") }
  let sources = Set(snapshot.sources.map(\.id))
  for source in snapshot.sources {
   guard source.path.hasPrefix("/"), !source.path.contains("\0"), URL(fileURLWithPath: source.path).standardizedFileURL.path == source.path,
         !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError("来源目录记录无效，已保留原文件。") }
  }
  for record in snapshot.records {
   let game = record.game
   guard sources.contains(game.sourceID), DiscoveryIdentity.validPath(game.relativePath),
         game.id == DiscoveryIdentity.id(game.sourceID, game.relativePath), !game.entries.isEmpty, !game.title.isEmpty,
         Set(game.entries.map { $0.backend.rawValue + "\0" + $0.path }).count == game.entries.count,
         record.status != .added || (record.selectedEntry != nil && record.addedGameID != nil) else { throw LibraryError("扫描记录身份或选择无效，已保留原文件。") }
   for entry in game.entries + (record.selectedEntry.map { [$0] } ?? []) {
    guard DiscoveryIdentity.validPath(entry.path, dot: entry.backend == .native) else { throw LibraryError("发现的启动入口路径无效。") }
    try EntryPolicy.validate(entry)
   }
  }
 }
}
