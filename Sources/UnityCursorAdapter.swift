import Foundation
import CryptoKit
import Darwin

/// Explicit local launch overlay; never writes to a game's source, prefix, or saves.
enum UnityCursorAdapter {
 struct PatchSpec: Sendable {
  let sourceSHA256: String
  let length: Int
  let offset: Int
  static var cyanbrain: PatchSpec {
   .init(sourceSHA256: "98a6fcbe592f09c2ece50a35c7ec3cd3900cc56ddb00354140dd072722ae5901", length: 388608, offset: 36679)
  }
 }
 /// Returns zero on success or the captured errno, independently of later IO.
 /// Injectable filesystem operations allow local unsupported-filesystem fixtures.
 struct Publication {
  var rename: (URL, URL, UInt32) -> Int32 = { from, to, flags in
   renameatx_np(AT_FDCWD, from.path, AT_FDCWD, to.path, flags) == 0 ? 0 : errno
  }
  var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
 }
 struct SourceInspection {
  var resolve: (URL) throws -> URL = { try canonical($0) }
  var entries: (URL) throws -> [URL] = { try sourceEntries($0) }
 }
 private static let profile = "cyanbrain-cursor-unconfined-v1"
 private static let assembly = "CYANBRAIN_Data/Managed/Assembly-CSharp.dll"
 private static let marker = ".unity-cursor-adapter.json"
 private static var fm: FileManager { .default }
 private struct Configuration: Decodable {
  let profile: String
  let sourceFolder: String
  let sourceSHA256: String
 }
 private struct Receipt: Codable, Equatable {
  let profile: String
  let id: UUID
  let source: String
  let sourceSHA256: String
  let patchedSHA256: String
  let links: [String: String]
 }

 static func prepareIfEnabled(game: Game, dataRoot: URL) throws -> Game {
  try prepareIfEnabled(game: game, dataRoot: dataRoot, spec: .cyanbrain)
 }

 /// Internal injectable spec for inert fixture tests; production uses the fixed
 /// shipped fingerprint, length and CIL offset through the two-argument API.
 static func prepareIfEnabled(game: Game, dataRoot: URL, spec: PatchSpec, publication: Publication = .init(), inspection: SourceInspection = .init()) throws -> Game {
  guard dataRoot.isFileURL else { throw failure("dataRoot must be a local file URL") }
  // standardizedFileURL rewrites /private/tmp to the symlink /tmp on macOS.
  // Inspect the supplied physical components first, without introducing aliases.
  let root = dataRoot
  // lstat each component before looking up config: a dangling symlink is not opt-out.
  try realAncestors(root)
  let compatibility = root.appendingPathComponent("Compatibility")
  try realAncestors(compatibility)
  let configFile = compatibility.appendingPathComponent(game.id.uuidString + ".json")
  guard let configType = try type(configFile) else { return game }
  guard configType == .typeRegular else { throw failure("configuration must be a regular file") }
  let config: Configuration
  do {
   let bytes = try read(configFile, limit: 16384)
   guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
         Set(fields.keys) == Set(["profile", "sourceFolder", "sourceSHA256"]) else {
    throw failure("invalid configuration fields")
   }
   config = try JSONDecoder().decode(Configuration.self, from: bytes)
  } catch { throw failure("invalid configuration: \(error.localizedDescription)") }
  guard config.profile == profile, config.sourceSHA256 == spec.sourceSHA256 else {
   throw failure("unsupported profile or source-version in configuration")
  }
  guard game.entry.backend == .wine, game.entry.engine == "Unity", game.entry.path == "CYANBRAIN.exe" else {
   throw failure("profile requires the CYANBRAIN.exe Wine Unity entry")
  }
  guard game.folder.hasPrefix("/"), game.originalFolder.hasPrefix("/"), config.sourceFolder.hasPrefix("/") else {
   throw failure("source folders must be absolute")
  }
  let source = try inspection.resolve(URL(fileURLWithPath: config.sourceFolder))
  guard source.path == config.sourceFolder else {
   throw failure("configured canonical source differs from current/original folder")
  }
  // The usual paths already match the canonical root. Only aliases need another
  // resolution, and the same alias in folder/originalFolder is resolved once.
  for folder in Set([game.folder, game.originalFolder]) where folder != source.path {
   guard try inspection.resolve(URL(fileURLWithPath: folder)).path == source.path else {
    throw failure("configured canonical source differs from current/original folder")
   }
  }
  guard !contains(root, source), !contains(source, root) else { throw failure("source/output overlap") }
  for dir in [source, source.appendingPathComponent("CYANBRAIN_Data"), source.appendingPathComponent("CYANBRAIN_Data/Managed")] {
   guard try type(dir) == .typeDirectory else { throw failure("source directory missing or symlinked: \(dir.path)") }
  }
  let dll = source.appendingPathComponent(assembly)
  guard try type(dll) == .typeRegular else { throw failure("source-version: assembly is not a regular file") }
  // Bound reads by the known version, never mmap or copy the rest of the game.
  let original: Data
  do { original = try read(dll, limit: spec.length) }
  catch { throw failure("source-version: \(error.localizedDescription)") }
  guard original.count == spec.length, digest(original) == spec.sourceSHA256,
        spec.offset >= 0, spec.offset < original.count, original[spec.offset] == 0x18 else {
   throw failure("source-version: Assembly-CSharp.dll checksum, length or opcode changed")
  }
  var patched = original
  // Engine.Awake 060001f8 IL_0047: ldc.i4.2 -> ldc.i4.0 before Cursor.set_lockState.
  patched[spec.offset] = 0x16

  let snapshot = try inspectSource(source, inspection: inspection)
  guard snapshot.entryIsRegular else {
   throw failure("game entry must resolve to a regular file")
  }
  let links = snapshot.links
  let receipt = Receipt(profile: profile, id: game.id, source: source.path,
                        sourceSHA256: spec.sourceSHA256, patchedSHA256: digest(patched), links: links)
  let adapters = root.appendingPathComponent("Adapters")
  let owner = adapters.appendingPathComponent(game.id.uuidString)
  let destination = owner.appendingPathComponent("current")
  try realAncestors(destination)
  var previous: Receipt?
  if try type(destination) != nil {
   previous = try ownedReceipt(destination, expected: receipt)
   if previous == receipt, try read(destination.appendingPathComponent(assembly), limit: spec.length) == patched {
    return launch(game, at: destination)
   }
  } else if try type(owner) != nil {
   // An empty UUID container left by a failed preparation is harmless; never
   // claim a populated container whose current adapter has no ownership receipt.
   guard try children(owner).isEmpty else { throw failure("unowned adapter container") }
  }
  try makeDirectories(owner)
  // On refresh the staging slot becomes the old adapter's backup in the same
  // atomic exchange, leaving no fallible filesystem step after publication.
  let stage = owner.appendingPathComponent((previous == nil ? ".staging-" : ".previous-") + UUID().uuidString)
  // Exclusive mkdir; no removal or reuse of any existing staging destination.
  try fm.createDirectory(at: stage, withIntermediateDirectories: false)
  var cleanStage = true
  defer { if cleanStage { try? fm.removeItem(at: stage) } }
  try fm.createDirectory(at: stage.appendingPathComponent("CYANBRAIN_Data"), withIntermediateDirectories: false)
  try fm.createDirectory(at: stage.appendingPathComponent("CYANBRAIN_Data/Managed"), withIntermediateDirectories: false)
  for (relative, target) in links {
   try fm.createSymbolicLink(atPath: stage.appendingPathComponent(relative).path, withDestinationPath: target)
  }
  try patched.write(to: stage.appendingPathComponent(assembly), options: [.withoutOverwriting])
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  try encoder.encode(receipt).write(to: stage.appendingPathComponent(marker), options: [.withoutOverwriting])
  _ = try ownedReceipt(stage, expected: receipt)
  guard try read(stage.appendingPathComponent(assembly), limit: spec.length) == patched else { throw failure("staged patch verification failed") }
  // Recheck before publish; a changed source must never silently launch stale CIL.
  guard try read(dll, limit: spec.length) == original else { throw failure("source-version: source changed during preparation") }
  try realAncestors(destination)
  if let previous {
   guard try ownedReceipt(destination, expected: receipt) == previous else { throw failure("adapter changed during preparation") }
   // Atomic exchange keeps current available throughout refresh and leaves the
   // old recognized tree in the unique backup slot, never deleted.
   let error = publication.rename(stage, destination, UInt32(RENAME_SWAP))
   if error == ENOTSUP || error == EOPNOTSUPP {
    try portablePublish(stage, to: destination, previous: previous, expected: receipt, publication: publication)
   } else if error != 0 {
    throw failure("atomic adapter exchange failed: \(error)")
   }
   cleanStage = false
  } else {
   // RENAME_EXCL prevents a concurrent unowned destination from being replaced.
   let error = publication.rename(stage, destination, UInt32(RENAME_EXCL))
   if error == ENOTSUP || error == EOPNOTSUPP {
    try portablePublish(stage, to: destination, previous: nil, expected: receipt, publication: publication)
   } else if error != 0 {
    throw failure("exclusive adapter publication failed: \(error)")
   }
   cleanStage = false
  }
  return launch(game, at: destination)
 }

 /// Filesystems without rename flags use non-overwriting moves. Refresh has a
 /// brief gap at current; a failed move restores only a verified owned backup
 /// into an absent destination, never deleting a newly arrived file or link.
 private static func portablePublish(_ stage: URL, to destination: URL, previous: Receipt?,
                                     expected: Receipt, publication: Publication) throws {
  try realAncestors(stage)
  guard try ownedReceipt(stage, expected: expected) == expected else { throw failure("staging adapter changed") }
  try realAncestors(destination)
  guard let previous else {
   guard try type(destination) == nil else { throw failure("unowned destination appeared before portable publication") }
   try publication.move(stage, destination)
   return
  }
  let backup = destination.deletingLastPathComponent().appendingPathComponent(".previous-" + UUID().uuidString)
  guard try type(backup) == nil else { throw failure("portable backup destination already exists") }
  guard try ownedReceipt(destination, expected: expected) == previous else { throw failure("adapter changed before portable refresh") }
  do {
   try publication.move(destination, backup)
   try realAncestors(destination)
   guard try type(destination) == nil else { throw failure("unowned destination appeared during portable refresh") }
   try publication.move(stage, destination)
  } catch let publicationError {
   do {
    try realAncestors(destination)
    if try type(destination) == nil, try type(backup) == .typeDirectory,
       try ownedReceipt(backup, expected: expected) == previous {
     try publication.move(backup, destination)
    }
   } catch {
    throw failure("portable publication failed: \(publicationError.localizedDescription); restore failed: \(error.localizedDescription); previous adapter retained at \(backup.path)")
   }
   throw publicationError
  }
 }

 private static func launch(_ game: Game, at root: URL) -> Game {
  var result = game; result.folder = root.path; return result
 }
 private static func failure(_ detail: String) -> LibraryError { LibraryError("Unity cursor adapter: " + detail) }
 private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
 private static func contains(_ parent: URL, _ child: URL) -> Bool {
  parent.path == child.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
 }
 private static func canonical(_ url: URL) throws -> URL {
  // POSIX realpath avoids Foundation's /private/tmp display-alias rewriting.
  guard let path = realpath(url.path, nil) else { throw failure("cannot resolve source path: \(url.path) (\(errno))") }
  defer { free(path) }
  return URL(fileURLWithPath: String(cString: path))
 }
 /// FileManager attributes use lstat, so dangling links are visible.
 private static func type(_ url: URL) throws -> FileAttributeType? {
  do { return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
  catch let error as NSError {
   if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
   if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
   throw error
  }
 }
 private static func realAncestors(_ directory: URL) throws {
  var current = URL(fileURLWithPath: "/", isDirectory: true)
  for part in directory.pathComponents.dropFirst() {
   guard part != ".", part != ".." else { throw failure("directory traversal component") }
   current.appendPathComponent(part)
   if let kind = try type(current), kind != .typeDirectory { throw failure("unsafe directory component: \(current.path)") }
  }
 }
 private static func makeDirectories(_ directory: URL) throws {
  try realAncestors(directory)
  if try type(directory) == nil {
   try makeDirectories(directory.deletingLastPathComponent())
   try fm.createDirectory(at: directory, withIntermediateDirectories: false)
  }
 }
 private static func read(_ file: URL, limit: Int) throws -> Data {
  guard limit >= 0, limit < Int.max else { throw failure("invalid read bound") }
  guard try type(file) == .typeRegular else { throw failure("unsafe regular file: \(file.path)") }
  let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
  let data = try handle.read(upToCount: limit + 1) ?? Data()
  guard data.count <= limit else { throw failure("file exceeds known size: \(file.lastPathComponent)") }
  return data
 }
 private static func safeName(_ name: String) -> Bool {
  !name.isEmpty && name != "." && name != ".." &&
  !name.contains(where: { "/\\:".contains($0) }) && !name.hasSuffix(".") && !name.hasSuffix(" ") &&
  !name.unicodeScalars.contains(where: { $0.value < 32 })
 }
 private static func children(_ directory: URL) throws -> [URL] {
  try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
 }
 private static var sourceKeys: Set<URLResourceKey> { [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey] }
 /// Enumerate one level with bulk-prefetched metadata. Recursion stays explicit
 /// so aliases participate in active/visited cycle checks instead of being skipped.
 private static func sourceEntries(_ directory: URL) throws -> [URL] {
  var enumerationError: Error?
  guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: Array(sourceKeys),
                                      options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in
   enumerationError = error; return false
  }) else { throw failure("cannot enumerate source directory: \(directory.path)") }
  var entries = [URL]()
  for item in enumerator {
   guard let child = item as? URL else { throw failure("invalid source enumeration entry") }
   entries.append(child)
  }
  if let enumerationError { throw enumerationError }
  return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
 }
 private struct SourceSnapshot {
  var links = [String: String]()
  var entryIsRegular = false
 }
 /// Root and symlink targets are canonical. Ordinary descendants inherit their
 /// physical parent's lexical containment, using the enumerator's cached types.
 /// This avoids per-file realpath/stat round trips on SMB without omitting nodes.
 private static func inspectSource(_ source: URL, inspection: SourceInspection) throws -> SourceSnapshot {
  var snapshot = SourceSnapshot()
  var visited = Set<String>(), active = Set<String>()
  var namesByParent = [String: Set<String>]()
  let mirrorParents = Set([source.path, source.appendingPathComponent("CYANBRAIN_Data").path,
                           source.appendingPathComponent("CYANBRAIN_Data/Managed").path])
  func walk(_ directory: URL) throws {
   guard contains(source, directory), !active.contains(directory.path) else { throw failure("cyclic or external source directory link") }
   if visited.contains(directory.path) { return }
   active.insert(directory.path); defer { active.remove(directory.path) }
   for child in try inspection.entries(directory) {
    guard child.isFileURL, child.deletingLastPathComponent().path == directory.path,
          contains(source, child), safeName(child.lastPathComponent),
          namesByParent[directory.path, default: []].insert(child.lastPathComponent.lowercased()).inserted else {
     throw failure("unsafe, external or case-colliding source name")
    }
    var values = try child.resourceValues(forKeys: sourceKeys)
    var target = child
    if values.isSymbolicLink == true {
     target = try inspection.resolve(child)
     guard contains(source, target) else { throw failure("external source link: \(child.path)") }
     values = try target.resourceValues(forKeys: sourceKeys)
    }
    guard values.isSymbolicLink == false, values.isRegularFile == true || values.isDirectory == true else {
     throw failure("unsafe, dangling or non-regular source target: \(child.path)")
    }
    let relative = String(child.path.dropFirst(source.path.count + 1))
    if relative == "CYANBRAIN.exe" { snapshot.entryIsRegular = values.isRegularFile == true }
    if mirrorParents.contains(directory.path), relative != "CYANBRAIN_Data",
       relative != "CYANBRAIN_Data/Managed", relative != assembly {
     guard relative != marker else { throw failure("source collides with adapter receipt") }
     snapshot.links[relative] = target.path
    }
    if values.isDirectory == true { try walk(target) }
   }
   visited.insert(directory.path)
  }
  try walk(source)
  return snapshot
 }
 /// A receipt is ownership evidence only when the complete sparse layout matches
 /// it. Unknown files, redirected links, or symlinked structural directories fail.
 private static func ownedReceipt(_ directory: URL, expected: Receipt) throws -> Receipt {
  let receipt: Receipt
  do { receipt = try JSONDecoder().decode(Receipt.self, from: read(directory.appendingPathComponent(marker), limit: 2 * 1024 * 1024)) }
  catch { throw failure("unowned or corrupt adapter receipt: \(error.localizedDescription)") }
  guard receipt.profile == expected.profile, receipt.id == expected.id, receipt.source == expected.source,
        receipt.sourceSHA256 == expected.sourceSHA256, receipt.patchedSHA256 == expected.patchedSHA256 else {
   throw failure("unrecognized adapter ownership/version")
  }
  var wanted: [String: Set<String>] = ["": [marker, "CYANBRAIN_Data"], "CYANBRAIN_Data": ["Managed"], "CYANBRAIN_Data/Managed": ["Assembly-CSharp.dll"]]
  for (relative, target) in receipt.links {
   let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
   guard parts.allSatisfy(safeName), !relative.hasPrefix("/"), let name = parts.last else { throw failure("unsafe receipt link path") }
   let parent = parts.dropLast().joined(separator: "/")
   guard wanted[parent] != nil, !wanted[parent]!.contains(name),
         target.hasPrefix(receipt.source + "/"),
         !URL(fileURLWithPath: target).pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
    throw failure("unsafe receipt link target")
   }
   wanted[parent]!.insert(name)
   let link = directory.appendingPathComponent(relative)
   guard try type(link) == .typeSymbolicLink, try fm.destinationOfSymbolicLink(atPath: link.path) == target else {
    throw failure("adapter link differs from receipt")
   }
  }
  for (relative, names) in wanted {
   let dir = directory.appendingPathComponent(relative)
   guard try type(dir) == .typeDirectory, Set(try children(dir).map(\.lastPathComponent)) == names else {
    throw failure("unowned or unsafe adapter contents")
   }
  }
  guard try type(directory.appendingPathComponent(assembly)) == .typeRegular else { throw failure("unsafe adapter assembly") }
  return receipt
 }
}
