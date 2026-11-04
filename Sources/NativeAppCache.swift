import Foundation
import CryptoKit
import Darwin

struct NativeAppLaunch {
 let app: URL
 let environment: [String: String]
 let cachedBytes: Int64
 let cached: Bool
}

/// Copies only recognized engine layouts. Payloads remain at their canonical source.
/// Callers should serialize preparations; the lock also protects same-process refreshes.
enum NativeAppCache {
 private static let lock = NSLock()
 private static var fm: FileManager { FileManager.default }
 private static let limit: Int64 = 512 * 1024 * 1024
 private struct Receipt: Codable, Equatable {
  let version: Int
  let id: UUID
  let source: String
  let infoSHA256: String
  let executableSize: Int64
  let executableMTime: Double
  let profile: String
  let payloads: [String]
  var runtimeFingerprint: String?
  var cachedSignedFingerprint: String?
  var signingProfile: String?
 }
 private struct BundleInfo {
  let plist: [String: Any]
  let data: Data
  let executable: URL
 }
 private static func fail(_ message: String) -> LibraryError { LibraryError("本地原生缓存：" + message) }
 private static func contains(_ parent: URL, _ child: URL) -> Bool {
  let base = parent.standardizedFileURL.resolvingSymlinksInPath().path
  let path = child.standardizedFileURL.resolvingSymlinksInPath().path
  return path == base || path.hasPrefix(base + "/")
 }
 private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
  try fm.attributesOfItem(atPath: url.path)
 }
 private static func exists(_ url: URL) -> Bool { (try? attributes(url)) != nil }
 private static func isLink(_ url: URL) -> Bool {
  (try? attributes(url)[.type] as? FileAttributeType) == .typeSymbolicLink
 }
 private static func regular(_ url: URL) -> Bool {
  (try? attributes(url)[.type] as? FileAttributeType) == .typeRegular
 }
 private static func directory(_ url: URL) -> Bool {
  (try? attributes(url)[.type] as? FileAttributeType) == .typeDirectory
 }
 private static func bundle(_ app: URL) throws -> BundleInfo {
  let plistURL = app.appendingPathComponent("Contents/Info.plist")
  guard directory(app), app.pathExtension.lowercased() == "app",
        contains(app, plistURL.resolvingSymlinksInPath()), regular(plistURL),
        (try attributes(plistURL)[.size] as? NSNumber)?.int64Value ?? Int64.max <= 1024 * 1024 else {
   throw fail("无效的应用或 Info.plist。")
  }
  let data = try Data(contentsOf: plistURL)
  guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
        name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
        !name.unicodeScalars.contains(where: { $0.value < 32 }) else {
   throw fail("CFBundleExecutable 必须是简单文件名。")
  }
  let exe = app.appendingPathComponent("Contents/MacOS/" + name)
  guard contains(app, exe.resolvingSymlinksInPath()), regular(exe) else {
   throw fail("找不到应用主程序，或主程序路径不安全。")
  }
  return BundleInfo(plist: info, data: data, executable: exe)
 }
 /// Reject links in every cache ancestor, including dangling links, before creating anything.
 private static func safeCachePath(_ url: URL) throws {
  var current = url.standardizedFileURL
  while current.path != "/" {
   if isLink(current) {
    // Foundation standardization folds /private/tmp and /private/var into these system aliases.
    let target = try fm.destinationOfSymbolicLink(atPath: current.path)
    let systemAlias = (current.path == "/tmp" && ["private/tmp", "/private/tmp"].contains(target)) ||
                      (current.path == "/var" && ["private/var", "/private/var"].contains(target))
    guard systemAlias else { throw fail("缓存路径包含符号链接。") }
    current = URL(fileURLWithPath: "/private"); continue
   }
   if exists(current) && !directory(current) { throw fail("缓存目录被其他文件占用。") }
   current.deleteLastPathComponent()
  }
 }
 private static func receipt(_ source: URL, _ info: BundleInfo, _ game: Game,
                             _ profile: String, _ payloads: [String], _ runtimeFingerprint: String) throws -> Receipt {
  let attrs = try attributes(info.executable)
  guard let size = attrs[.size] as? NSNumber, let date = attrs[.modificationDate] as? Date else {
   throw fail("无法读取主程序元数据。")
  }
  return Receipt(version: 1, id: game.id, source: source.path,
                 infoSHA256: SHA256.hash(data: info.data).map { String(format: "%02x", $0) }.joined(),
                 executableSize: size.int64Value, executableMTime: date.timeIntervalSince1970,
                 profile: profile, payloads: payloads, runtimeFingerprint: runtimeFingerprint)
 }
 private struct RuntimeEntry: Encodable {
  let path: String
  let type: String
  let size: Int64?
  let mtime: Int64?
  let target: String?
  var sha256: String?
 }
 private struct RuntimeSnapshot {
  let bytes: Int64
  let fingerprint: String
 }
 /// Owns small-file hash work and its lifetime, separate from the serial walk.
 final class SmallFileHashes: @unchecked Sendable {
  // Only submit/finish/drain are called by the serial producer. Worker results
  // and the first error are protected by lock; no worker captures walk/entries.
  private let lock = NSLock()
  private let slots = DispatchSemaphore(value: 16)
  private let group = DispatchGroup()
  private var values: [String: String] = [:]
  private var error: Error?
  func submit(path: String, work: @escaping @Sendable () throws -> String) throws {
   // Acquire BEFORE enqueueing: at most 16 work closures/handles/read buffers
   // are outstanding, rather than an unbounded queue waiting on a semaphore.
   slots.wait()
   lock.lock(); let failure = error; lock.unlock()
   if let failure { slots.signal(); throw failure }
   group.enter()
   DispatchQueue.global(qos: .userInitiated).async {
    defer { self.group.leave(); self.slots.signal() }
    let result = Result { try autoreleasepool { try work() } }
    self.lock.lock()
    switch result {
    case .success(let hash): self.values[path] = hash
    case .failure(let error): if self.error == nil { self.error = error }
    }
    self.lock.unlock()
   }
  }
  func finish() throws -> [String: String] {
   group.wait()
   lock.lock(); defer { lock.unlock() }
   if let error { throw error }
   return values
  }
  func drain() { group.wait() }
 }
 /// Inspect only Contents, which is what rsync copies. Prefetch metadata in the
 /// directory walk rather than performing a separate attributes/stat per file.
 /// Never traverse payloads or symlinks, and bound bytes before copying.
 private static func runtimeSnapshot(_ app: URL, excluding: Set<String>) throws -> RuntimeSnapshot {
  var total: Int64 = 0
  var entries: [RuntimeEntry] = []
  var traversalError: Error?
  let hashes = SmallFileHashes()
  defer { hashes.drain() }
  // Canonicalize once, including /tmp -> /private/tmp aliases. Enumerating this
  // exact root makes relative paths lexical; per-entry standardizedFileURL can
  // perform extra reachability/stat requests on SMB.
  guard let resolved = realpath(app.path, nil) else { throw fail("无法解析运行库目录。") }
  let basePath = String(cString: resolved)
  free(resolved)
  let prefix = basePath + "/"
  let canonicalRoot = URL(fileURLWithPath: basePath, isDirectory: true)
  let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
  guard let walk = fm.enumerator(at: canonicalRoot.appendingPathComponent("Contents", isDirectory: true), includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
   traversalError = error; return false
  }) else { throw fail("无法枚举运行库。") }
  for case let url as URL in walk {
   let path = url.path
   guard path.hasPrefix(prefix) else { throw fail("枚举路径超出运行库目录。") }
   let relative = String(path.dropFirst(prefix.count))
   if excluding.contains(relative) {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if values.isDirectory == true && values.isSymbolicLink != true { walk.skipDescendants() }
    continue
   }
   let values = try url.resourceValues(forKeys: keys)
   if values.isSymbolicLink == true {
    // DirectoryEnumerator does not follow links. Calling skipDescendants on a
    // non-directory can instead skip the next directory on Foundation/macOS.
    let target = try fm.destinationOfSymbolicLink(atPath: url.path)
    guard !target.hasPrefix("/"), contains(app, url.resolvingSymlinksInPath()) else {
     throw fail("运行库包含指向应用外部的链接。")
    }
    // lstat is needed only for links: resource dates/sizes may describe their referent.
    let attrs = try attributes(url)
    guard let date = attrs[.modificationDate] as? Date else { throw fail("无法读取链接时间。") }
    entries.append(RuntimeEntry(path: relative, type: "link", size: Int64(target.utf8.count),
                                mtime: Int64(floor(date.timeIntervalSince1970)), target: target, sha256: nil))
   } else if values.isRegularFile == true {
    let size = values.fileSize.map { Int64($0) } ?? limit + 1
    guard size >= 0, size <= limit - total else { throw fail("运行库超过 512 MiB，已停止缓存。") }
    total += size
    // The original plist has its own SHA; the cached plist has a rewritten bundle ID.
    if relative == "Contents/Info.plist" { continue }
    guard let date = values.contentModificationDate else { throw fail("无法读取运行库时间。") }
    if size <= 64 * 1024 {
     try hashes.submit(path: relative) {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
      guard data.count == size else { throw fail("读取期间运行库发生变化，请重试。") }
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
     }
    }
    // rsync -a preserves whole-second mtimes. Normalize to that shared precision
    // so existing v1 copies can be verified without a recopy; small-file SHA also
    // detects same-size edits with an unchanged timestamp. Large files use metadata.
    entries.append(RuntimeEntry(path: relative, type: "file", size: size,
                                mtime: Int64(floor(date.timeIntervalSince1970)), target: nil, sha256: nil))
   } else if values.isDirectory == true {
    // Directory size/mtime change when excluded payload links or Info.plist are
    // installed. Only path/type describe the copied directory structure reliably.
    entries.append(RuntimeEntry(path: relative, type: "directory", size: nil, mtime: nil, target: nil, sha256: nil))
   } else { throw fail("运行库含有不支持的文件类型。") }
  }
  if let traversalError { throw traversalError }
  let completed = try hashes.finish()
  for index in entries.indices where entries[index].type == "file" && (entries[index].size ?? Int64.max) <= 64 * 1024 {
   guard let sha = completed[entries[index].path] else { throw fail("运行库指纹不完整。") }
   entries[index].sha256 = sha
  }
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(entries.sorted { $0.path < $1.path })
  return RuntimeSnapshot(bytes: total, fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
 }
 private final class Diagnostics: @unchecked Sendable {
  var bytes = Data() // Written by the drain queue, read only after its semaphore signals.
 }
 private static func copyContents(source: URL, stage: URL, exclusions: [String]) throws {
  let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0), output = Diagnostics()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
  process.arguments = ["-a"] + exclusions.map { "--exclude=/" + $0 } + [
   source.appendingPathComponent("Contents").path + "/",
   stage.appendingPathComponent("Contents").path + "/"
  ]
  process.currentDirectoryURL = stage.deletingLastPathComponent()
  process.standardOutput = pipe; process.standardError = pipe
  DispatchQueue.global(qos: .utility).async {
   defer { try? pipe.fileHandleForReading.close(); done.signal() }
   while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
    if output.bytes.count < 16384 { output.bytes.append(chunk.prefix(16384 - output.bytes.count)) }
   }
  }
  defer { PreparationTasks.shared.finish(process) }
  do { try PreparationTasks.shared.run(process) }
  catch {
   if process.isRunning { process.terminate(); process.waitUntilExit() }
   try? pipe.fileHandleForWriting.close(); done.wait()
   throw error
  }
  try? pipe.fileHandleForWriting.close()
  process.waitUntilExit(); done.wait()
  guard process.terminationReason == .exit, process.terminationStatus == 0 else {
   throw fail("rsync 失败或准备已取消（\(process.terminationStatus)）：" + String(decoding: output.bytes, as: UTF8.self))
  }
 }
 static func prepare(game: Game, root: URL,
                     runningCheck: (URL) -> Bool = NativeAppIdentity.isRunning(at:)) throws -> NativeAppLaunch {
  lock.lock(); defer { lock.unlock() }
  guard game.entry.backend == .native else { throw fail("仅支持 native 应用入口。") }
  try EntryPolicy.validate(game.entry)
  guard !game.entry.path.contains("\\"), !game.entry.path.unicodeScalars.contains(where: { $0.value < 32 }) else {
   throw fail("应用入口路径无效。")
  }
  let folder = URL(fileURLWithPath: game.folder).standardizedFileURL.resolvingSymlinksInPath()
  let source = folder.appendingPathComponent(game.entry.path).standardizedFileURL.resolvingSymlinksInPath()
  guard contains(folder, source) else { throw fail("应用入口超出游戏目录。") }
  let info = try bundle(source)
  let local = root.standardizedFileURL
  try safeCachePath(local)
  let cacheRoot = local.appendingPathComponent("NativeApps")
  try safeCachePath(cacheRoot)
  guard !contains(source, local), !contains(local, source),
        !contains(source, cacheRoot), !contains(cacheRoot, source) else {
   throw fail("缓存与源应用目录重叠。")
  }
  let resources = source.appendingPathComponent("Contents/Resources")
  var profile: String
  var payloads: [String]
  var windows: [String] = []
  let autorun = resources.appendingPathComponent("autorun")
  if directory(autorun.appendingPathComponent("game")),
     regular(autorun.appendingPathComponent("renpy/vc_version.py")) {
   profile = "renpy-autorun-v1"; payloads = ["Resources/autorun/game"]
   windows = try fm.contentsOfDirectory(at: autorun, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "exe" }.map { "Resources/autorun/" + $0.lastPathComponent }
  } else {
   // Deliberately narrow: only explicitly observed, top-level Resources/*.pck files.
   let pcks = directory(resources) ? try fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension.lowercased() == "pck" && regular($0) } : []
   guard !pcks.isEmpty else { return NativeAppLaunch(app: source, environment: [:], cachedBytes: 0, cached: false) }
   profile = "godot-resources-pck-v1"; payloads = pcks.map { "Resources/" + $0.lastPathComponent }.sorted()
  }
  // Exclusion patterns must be literal; rsync's glob metacharacters could omit unrelated runtime files.
  for path in payloads + windows {
   guard !path.contains(where: { "*?[]\\".contains($0) }),
         contains(source, source.appendingPathComponent("Contents/" + path).resolvingSymlinksInPath()) else {
    throw fail("资源路径无法安全缓存。")
   }
  }
  let excluded = Set((payloads + windows).map { "Contents/" + $0 })
  let sourceRuntime = try runtimeSnapshot(source, excluding: excluded)
  let expected = try receipt(source, info, game, profile, payloads, sourceRuntime.fingerprint)
  let requiresSigning = try NativeAppIdentity.isMachO(info.executable)
  let destination = cacheRoot.appendingPathComponent(game.id.uuidString + ".app", isDirectory: true)
  let receiptURL = cacheRoot.appendingPathComponent(game.id.uuidString + ".json")
  let bundleID = "local.gameshelf.native." + game.id.uuidString.lowercased()
  if isLink(destination) || isLink(receiptURL) { throw fail("缓存或凭据是符号链接。") }
  let saved: Receipt? = regular(receiptURL) && ((try? attributes(receiptURL)[.size] as? NSNumber)?.intValue ?? Int.max) < 1024 * 1024
   ? (try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))) : nil
  if exists(destination) {
   let cachedPlist = destination.appendingPathComponent("Contents/Info.plist")
   let ownedInfo: [String: Any]? = regular(cachedPlist) && !isLink(cachedPlist) &&
    contains(destination, cachedPlist.resolvingSymlinksInPath()) &&
    ((try? attributes(cachedPlist)[.size] as? NSNumber)?.intValue ?? Int.max) <= 1024 * 1024
    ? (try? PropertyListSerialization.propertyList(from: Data(contentsOf: cachedPlist), format: nil) as? [String: Any]) : nil
   guard directory(destination), saved?.id == game.id, saved?.version == 1,
         ownedInfo?["CFBundleIdentifier"] as? String == bundleID else {
    throw fail("现有目标不是可确认归属的缓存，已保留。")
   }
   let linksValid = payloads.allSatisfy { path in
    (try? fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Contents/" + path).path)) == source.appendingPathComponent("Contents/" + path).path
   }
   var comparable = saved
   comparable?.cachedSignedFingerprint = nil
   comparable?.signingProfile = nil
   if comparable?.runtimeFingerprint == nil { comparable?.runtimeFingerprint = expected.runtimeFingerprint }
   if comparable == expected, linksValid, (try? bundle(destination)) != nil,
      let cachedRuntime = try? runtimeSnapshot(destination, excluding: excluded),
      cachedRuntime.fingerprint == (requiresSigning ? saved?.cachedSignedFingerprint : sourceRuntime.fingerprint),
      !requiresSigning || (saved?.signingProfile == NativeAppIdentity.signingProfile &&
       (try? NativeAppIdentity.verify(destination, identifier: bundleID, excluding: Set(payloads.map { "Contents/" + $0 }))) != nil) {
    if saved?.runtimeFingerprint == nil {
     var upgraded = saved!; upgraded.runtimeFingerprint = expected.runtimeFingerprint
     try JSONEncoder().encode(upgraded).write(to: receiptURL, options: .atomic)
    }
    return NativeAppLaunch(app: destination.standardizedFileURL.resolvingSymlinksInPath(), environment: [:], cachedBytes: cachedRuntime.bytes, cached: true)
   }
  } else if exists(receiptURL) && saved == nil { throw fail("现有缓存凭据无法确认归属。") }
  // Reuse above is read-only for valid signed caches. A refresh must also
  // respect apps that survived a GameShelf restart and are absent from its UI.
  if exists(destination), runningCheck(destination) {
   throw fail("此原生游戏仍在运行，已保留当前缓存。请先在游戏内保存并退出，再更新运行库。")
  }
  try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
  let stage = cacheRoot.appendingPathComponent(".preparing-" + UUID().uuidString + ".app")
  try fm.createDirectory(at: stage.appendingPathComponent("Contents"), withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: stage) }
  try copyContents(source: source, stage: stage, exclusions: payloads + windows)
  for path in payloads {
   let link = stage.appendingPathComponent("Contents/" + path)
   guard !exists(link), directory(link.deletingLastPathComponent()),
         contains(stage, link.deletingLastPathComponent().resolvingSymlinksInPath()) else { throw fail("资源链接目标不安全。") }
   try fm.createSymbolicLink(atPath: link.path, withDestinationPath: source.appendingPathComponent("Contents/" + path).path)
  }
  // Never write through a copied plist symlink.
  guard !isLink(stage.appendingPathComponent("Contents/Info.plist")) else { throw fail("缓存 Info.plist 不可为链接。") }
  var newInfo = info.plist; newInfo["CFBundleIdentifier"] = bundleID
  newInfo["NSNetworkVolumesUsageDescription"] = NativeAppIdentity.networkPurpose
  try PropertyListSerialization.data(fromPropertyList: newInfo, format: .xml, options: 0)
   .write(to: stage.appendingPathComponent("Contents/Info.plist"), options: .atomic)
  _ = try bundle(stage)
  let stagedRuntime = try runtimeSnapshot(stage, excluding: excluded)
  var bytes = stagedRuntime.bytes
  guard stagedRuntime.fingerprint == sourceRuntime.fingerprint,
        try receipt(source, bundle(source), game, profile, payloads,
                    runtimeSnapshot(source, excluding: excluded).fingerprint) == expected else {
   throw fail("复制期间源应用发生变化，请重试。")
  }
  var publishedReceipt = expected
  if requiresSigning {
   try NativeAppIdentity.signStaged(stage, identifier: bundleID, excluding: Set(payloads.map { "Contents/" + $0 }))
   let signedRuntime = try runtimeSnapshot(stage, excluding: excluded)
   bytes = signedRuntime.bytes
   publishedReceipt.cachedSignedFingerprint = signedRuntime.fingerprint
   publishedReceipt.signingProfile = NativeAppIdentity.signingProfile
  }
  // Preserve stale app AND receipt. Roll back publication on any failure.
  var backup: URL?, backupReceipt: URL?
  do {
   if exists(destination) {
    // The game may have started while we copied/signed the separate stage.
    // Refuse before moving either the old app or its receipt.
    guard !runningCheck(destination) else {
     throw fail("此原生游戏已在准备期间启动，未替换正在使用的缓存。请退出游戏后重试。")
    }
    let token = ".previous-" + UUID().uuidString
    let old = cacheRoot.appendingPathComponent(game.id.uuidString + token + ".app")
    try fm.moveItem(at: destination, to: old); backup = old
    if exists(receiptURL) {
     let oldReceipt = cacheRoot.appendingPathComponent(game.id.uuidString + token + ".json")
     try fm.moveItem(at: receiptURL, to: oldReceipt); backupReceipt = oldReceipt
    }
   }
   try fm.moveItem(at: stage, to: destination)
   do { try JSONEncoder().encode(publishedReceipt).write(to: receiptURL, options: .atomic) }
   catch { try? fm.moveItem(at: destination, to: stage); throw error }
  } catch {
   if let backup, !exists(destination) { try? fm.moveItem(at: backup, to: destination) }
   if let backupReceipt, !exists(receiptURL) { try? fm.moveItem(at: backupReceipt, to: receiptURL) }
   throw error
  }
  return NativeAppLaunch(app: destination.standardizedFileURL.resolvingSymlinksInPath(), environment: [:], cachedBytes: bytes, cached: true)
 }
}
