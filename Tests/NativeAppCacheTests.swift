import Foundation
import Darwin
import CryptoKit

// Standalone: swiftc Sources/Core.swift Sources/NativeAppCache.swift Tests/NativeAppCacheTests.swift -o /private/tmp/native-cache-tests
@main struct NativeAppCacheTests {
 static var fm: FileManager { FileManager.default }
 final class HashProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0, peak = 0, accepted = 0
  private var error: Error?
  func begin() -> Int { lock.lock(); defer { lock.unlock() }; active += 1; peak = max(peak, active); return active }
  func end() { lock.lock(); active -= 1; lock.unlock() }
  func submitted() { lock.lock(); accepted += 1; lock.unlock() }
  func failed(_ error: Error) { lock.lock(); self.error = error; lock.unlock() }
  func snapshot() -> (active: Int, peak: Int, accepted: Int, error: Error?) {
   lock.lock(); defer { lock.unlock() }; return (active, peak, accepted, error)
  }
 }
 static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw LibraryError("FAIL: " + message) }
 }
 static func rejects(_ message: String, _ body: () throws -> Void) throws {
  do { try body() } catch { return }
  throw LibraryError("FAIL: accepted " + message)
 }
 static func write(_ url: URL, _ data: Data) throws {
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url)
 }
 static func setLinkDate(_ url: URL, _ date: Date) throws {
  var times = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
               timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
  guard lutimes(url.path, &times) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
 }
 static func fixture(_ base: URL, _ name: String = "NAS 物語", renpy: Bool = true) throws -> Game {
  let app = base.appendingPathComponent(name + ".app")
  let info: [String: String] = ["CFBundleExecutable": "engine", "CFBundleName": "Original", "CFBundleIdentifier": "org.original.game"]
  try write(app.appendingPathComponent("Contents/Info.plist"), PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
  try write(app.appendingPathComponent("Contents/MacOS/engine"), Data("INERT executable fixture".utf8))
  if renpy {
   try write(app.appendingPathComponent("Contents/Resources/autorun/renpy/vc_version.py"), Data("version = '8.3'".utf8))
   try write(app.appendingPathComponent("Contents/Resources/autorun/main.py"), Data("inert".utf8))
   try write(app.appendingPathComponent("Contents/Resources/autorun/game/sentinel"), Data(repeating: 71, count: 2 * 1024 * 1024))
   try write(app.appendingPathComponent("Contents/Resources/autorun/Windows.EXE"), Data(repeating: 72, count: 4096))
  }
  return Game(title: name, folder: app.path, originalFolder: app.path, entry: Candidate(path: ".", backend: .native, engine: "macOS"))
 }
 static func serialFingerprintReference(_ base: URL) throws {
  let game = try fixture(base, "Serial fingerprint reference")
  let source = URL(fileURLWithPath: game.folder), stamp = Date(timeIntervalSince1970: 1700000000)
  for index in 0..<96 {
   try write(source.appendingPathComponent("Contents/Resources/autorun/renpy/module-\(index).py"), Data("module \(index) 中文\n".utf8))
  }
  try write(source.appendingPathComponent("Contents/Resources/autorun/renpy/empty.py"), Data())
  try write(source.appendingPathComponent("Contents/Resources/autorun/renpy/boundary.py"), Data(repeating: 90, count: 65536))
  try write(source.appendingPathComponent("Contents/MacOS/large.dylib"), Data(repeating: 65, count: 65537))
  let link = source.appendingPathComponent("Contents/MacOS/runtime-link")
  try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "large.dylib")
  try setLinkDate(link, stamp)
  let walk = fm.enumerator(at: source, includingPropertiesForKeys: nil)!
  for case let file as URL in walk {
   if (try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular {
    try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
   }
  }
  let root = base.appendingPathComponent("SerialReferenceLocal")
  _ = try NativeAppCache.prepare(game: game, root: root)
  let receipt = root.appendingPathComponent("NativeApps/" + game.id.uuidString + ".json")
  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
  let hash = object["runtimeFingerprint"] as? String ?? "missing"
  print("REFERENCE serial fingerprint: " + hash)
  // Captured from the unmodified serial implementation, with fixed file times.
  try check(hash == "9800475f707dcbe4a3c8f89c7dbf91b7711e753374ffd52037378fe234a4f5d9", "parallel snapshot must match pre-change serial fingerprint byte for byte: " + hash)
 }
 static func boundedHashTests(_ base: URL) throws {
  let pool = NativeAppCache.SmallFileHashes(), probe = HashProbe()
  let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), producer = DispatchGroup()
  let files = (0..<40).map { base.appendingPathComponent("parallel-hash/\($0).py") }
  for (index, file) in files.enumerated() { try write(file, Data("actual file \(index) 中文".utf8)) }
  producer.enter()
  DispatchQueue.global().async {
   defer { producer.leave() }
   do {
    for (index, file) in files.enumerated() {
     try pool.submit(path: String(index)) {
      if probe.begin() == 16 { ready.signal() }
      defer { probe.end() }
      release.wait() // Controlled network latency; hashes still read real files.
      return SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
     }
     probe.submitted()
    }
   } catch { probe.failed(error) }
  }
  let reachedSixteen = ready.wait(timeout: .now() + 3) == .success
  let held = probe.snapshot()
  for _ in files { release.signal() }
  producer.wait()
  let values = try pool.finish(), completed = probe.snapshot()
  try check(reachedSixteen && completed.peak == 16, "hash work must overlap with exactly 16 active tasks; observed \(completed.peak)")
  try check(held.accepted <= 16, "producer must backpressure at 16 outstanding tasks, not build an unbounded queue")
  try check(completed.active == 0 && completed.error == nil && values.count == files.count, "all accepted hashes join before returning")
  for index in files.indices {
   let expected = SHA256.hash(data: Data("actual file \(index) 中文".utf8)).map { String(format: "%02x", $0) }.joined()
   try check(values[String(index)] == expected, "parallel SHA equals serial SHA for file \(index)")
  }
  print("PASS bounded hashing: peak=\(completed.peak), accepted while held=\(held.accepted), 40 real-file SHA outputs equal serial")

  let failing = NativeAppCache.SmallFileHashes(), failureProbe = HashProbe()
  let blockerStarted = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
  try failing.submit(path: "in-flight") {
   _ = failureProbe.begin(); defer { failureProbe.end() }
   blockerStarted.signal(); unblock.wait()
   return SHA256.hash(data: try Data(contentsOf: files[0])).map { String(format: "%02x", $0) }.joined()
  }
  try check(blockerStarted.wait(timeout: .now() + 3) == .success, "error fixture has an in-flight hash")
  try failing.submit(path: "missing") {
   let handle = try FileHandle(forReadingFrom: base.appendingPathComponent("missing-hash-input.py"))
   defer { try? handle.close() }
   return "unexpected"
  }
  DispatchQueue.global().async {
   defer { finished.signal() }
   do { _ = try failing.finish() } catch { failureProbe.failed(error) }
  }
  let returnedEarly = finished.wait(timeout: .now() + 0.1) == .success
  unblock.signal()
  if !returnedEarly { finished.wait() }
  let failure = failureProbe.snapshot()
  try check(!returnedEarly && failure.active == 0 && failure.error != nil, "hash read error propagates only after in-flight work drains")
  try rejects("failed pool accepting more work") {
   try failing.submit(path: "after-error") { "unexpected" }
  }
  failing.drain()
  print("PASS hash read failure: joins in-flight IO, propagates error, rejects later work")
 }
 static func runtimeFingerprintTests(_ base: URL) throws {
  let game = try fixture(base, "Runtime fingerprint")
  let root = base.appendingPathComponent("FingerprintLocal")
  let source = URL(fileURLWithPath: game.folder)
  let script = source.appendingPathComponent("Contents/Resources/autorun/main.py")
  let stamp = Date(timeIntervalSince1970: 1700000000)
  try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: script.path)
  let executable = source.appendingPathComponent("Contents/MacOS/engine")
  let executableBytes = try Data(contentsOf: executable)
  let executableDate = try fm.attributesOfItem(atPath: executable.path)[.modificationDate] as! Date
  let plist = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
  let first = try NativeAppCache.prepare(game: game, root: root)
  let cachedScript = first.app.appendingPathComponent("Contents/Resources/autorun/main.py")
  try write(script, Data("other".utf8)) // Same size AND mtime; only the small-file SHA changes.
  try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: script.path)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try Data(contentsOf: cachedScript) == Data("other".utf8), "small runtime content change must invalidate with unchanged main/plist/size/mtime")
  try check(try Data(contentsOf: executable) == executableBytes, "main executable bytes unchanged")
  try check(try fm.attributesOfItem(atPath: executable.path)[.modificationDate] as? Date == executableDate, "main executable mtime unchanged")
  try check(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")) == plist, "source plist unchanged during runtime refresh")

  let extra = source.appendingPathComponent("Contents/Resources/autorun/renpy/extra.py")
  try write(extra, Data("new module".utf8))
  _ = try NativeAppCache.prepare(game: game, root: root)
  let cachedExtra = first.app.appendingPathComponent("Contents/Resources/autorun/renpy/extra.py")
  try check(fm.fileExists(atPath: cachedExtra.path), "added runtime file invalidates")
  try fm.removeItem(at: extra)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(!fm.fileExists(atPath: cachedExtra.path), "removed runtime file invalidates")

  let receipt = root.appendingPathComponent("NativeApps/" + game.id.uuidString + ".json")
  func legacyReceipt() throws {
   var object = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
   object.removeValue(forKey: "runtimeFingerprint")
   try JSONSerialization.data(withJSONObject: object).write(to: receipt, options: .atomic)
  }
  func inode() throws -> UInt64 {
   (try fm.attributesOfItem(atPath: cachedScript.path)[.systemFileNumber] as! NSNumber).uint64Value
  }
  func backups() throws -> Int {
   try fm.contentsOfDirectory(atPath: root.appendingPathComponent("NativeApps").path).filter { $0.hasSuffix(".app") && $0.contains(".previous-") }.count
  }
  try legacyReceipt()
  let oldInode = try inode(), oldBackups = try backups()
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try inode() == oldInode && backups() == oldBackups, "matching legacy runtime upgrades without copying or backup")
  let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
  try check(upgraded["version"] as? Int == 1 && !(upgraded["runtimeFingerprint"] as? String ?? "").isEmpty, "legacy receipt atomically gains runtime fingerprint at version 1")

  // A legacy receipt alone must never vouch for stale or damaged runtime bytes.
  try legacyReceipt()
  try write(cachedScript, Data("wrong".utf8))
  try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: cachedScript.path)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try Data(contentsOf: cachedScript) == Data("other".utf8) && backups() == oldBackups + 1, "mismatching legacy runtime backs up and recopies")
  try write(cachedScript, Data("wrong".utf8))
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try Data(contentsOf: cachedScript) == Data("other".utf8), "current receipt also verifies cached runtime")

  let beforeExcluded = try inode(), backupsBeforeExcluded = try backups()
  try write(source.appendingPathComponent("Contents/Resources/autorun/game/sentinel"), Data("changed payload".utf8))
  try write(source.appendingPathComponent("Contents/Resources/autorun/Windows.EXE"), Data("changed excluded EXE".utf8))
  try write(source.appendingPathComponent("Contents/Resources/autorun/Another.exe"), Data("new excluded EXE".utf8))
  try legacyReceipt()
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try inode() == beforeExcluded && backups() == backupsBeforeExcluded, "legacy upgrade excludes payload, all source autorun EXEs and rewritten Info.plist")

  try legacyReceipt()
  let payloadLink = first.app.appendingPathComponent("Contents/Resources/autorun/game")
  try fm.removeItem(at: payloadLink)
  try fm.createSymbolicLink(atPath: payloadLink.path, withDestinationPath: source.appendingPathComponent("Contents/Resources/autorun/renpy").path)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try fm.destinationOfSymbolicLink(atPath: payloadLink.path) == source.appendingPathComponent("Contents/Resources/autorun/game").standardizedFileURL.resolvingSymlinksInPath().path, "legacy receipt cannot bypass payload link validation")
  try legacyReceipt()
  var wrongReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
  wrongReceipt["source"] = "/wrong/source.app"
  try JSONSerialization.data(withJSONObject: wrongReceipt).write(to: receipt, options: .atomic)
  let beforeWrongSource = try backups()
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try backups() == beforeWrongSource + 1, "legacy upgrade requires matching old receipt fields")

  let boundary = source.appendingPathComponent("Contents/Resources/autorun/renpy/boundary.py")
  try write(boundary, Data(repeating: 65, count: 65536))
  try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: boundary.path)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try write(boundary, Data(repeating: 66, count: 65536))
  try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: boundary.path)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try Data(contentsOf: first.app.appendingPathComponent("Contents/Resources/autorun/renpy/boundary.py")) == Data(repeating: 66, count: 65536), "64 KiB boundary still uses content SHA")

  let dylib = source.appendingPathComponent("Contents/MacOS/large.dylib")
  try write(dylib, Data(repeating: 65, count: 65537))
  try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: dylib.path)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try write(dylib, Data(repeating: 66, count: 65537))
  try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: dylib.path)
  let beforeLargeEdit = try inode()
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try inode() == beforeLargeEdit && Data(contentsOf: first.app.appendingPathComponent("Contents/MacOS/large.dylib")) == Data(repeating: 65, count: 65537), "known limit: large same-size same-mtime edits do not trigger content reads")
  try fm.setAttributes([.modificationDate: stamp.addingTimeInterval(10)], ofItemAtPath: dylib.path)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try Data(contentsOf: first.app.appendingPathComponent("Contents/MacOS/large.dylib")) == Data(repeating: 66, count: 65537), "large runtime mtime invalidates without content hashing")

  let link = source.appendingPathComponent("Contents/MacOS/runtime-link")
  try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "engine")
  try setLinkDate(link, stamp)
  try check(try fm.attributesOfItem(atPath: link.path)[.modificationDate] as? Date == stamp, "fixture modifies the link's own mtime")
  try check(try fm.attributesOfItem(atPath: executable.path)[.modificationDate] as? Date == executableDate, "link mtime fixture leaves referent unchanged")
  _ = try NativeAppCache.prepare(game: game, root: root)
  try fm.removeItem(at: link)
  try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "large.dylib")
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try fm.destinationOfSymbolicLink(atPath: first.app.appendingPathComponent("Contents/MacOS/runtime-link").path) == "large.dylib", "runtime symlink target invalidates")
  let beforeLinkTime = try backups()
  try setLinkDate(link, stamp.addingTimeInterval(20))
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try backups() == beforeLinkTime + 1, "runtime symlink mtime invalidates")
  try fm.removeItem(at: link)
  try write(link, Data("now a regular file".utf8))
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try Data(contentsOf: first.app.appendingPathComponent("Contents/MacOS/runtime-link")) == Data("now a regular file".utf8), "runtime file type change invalidates")
  print("PASS runtime fingerprints: same-mtime source edit, additions/deletions, verified legacy upgrade, cache damage, exclusions, large mtime, symlink target")
 }
 static func main() throws {
  let base = URL(fileURLWithPath: "/private/tmp/native-cache-tests-" + UUID().uuidString)
  defer { try? fm.removeItem(at: base) }
  try serialFingerprintReference(base)
  try boundedHashTests(base)
  try runtimeFingerprintTests(base)
  let root = base.appendingPathComponent("Local"), game = try fixture(base)
  let source = URL(fileURLWithPath: game.folder).resolvingSymlinksInPath(), info = source.appendingPathComponent("Contents/Info.plist")
  let original = try Data(contentsOf: info)
  let launch = try NativeAppCache.prepare(game: game, root: root)
  try check(launch.cached, "recognized RenPy must cache")
  try check(launch.environment.isEmpty, "environment belongs to caller")
  try check(launch.cachedBytes > 0 && launch.cachedBytes < 2 * 1024 * 1024, "payload bytes must not count or copy")
  let payload = launch.app.appendingPathComponent("Contents/Resources/autorun/game")
  let target = try fm.destinationOfSymbolicLink(atPath: payload.path)
  try check(target == source.appendingPathComponent("Contents/Resources/autorun/game").path, "payload links to source")
  try check(try Data(contentsOf: payload.appendingPathComponent("sentinel")) == Data(repeating: 71, count: 2 * 1024 * 1024), "payload preserved")
  try check(!fm.fileExists(atPath: launch.app.appendingPathComponent("Contents/Resources/autorun/Windows.EXE").path), "exclude Windows executables")
  try check(try Data(contentsOf: info) == original, "source plist unchanged")
  let cachedInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: launch.app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
  try check(cachedInfo["CFBundleIdentifier"] as? String == "local.gameshelf.native." + game.id.uuidString.lowercased(), "unique bundle ID")
  try check(cachedInfo["CFBundleName"] as? String == "Original", "preserve bundle name")
  let marker = launch.app.appendingPathComponent("reuse-marker")
  try write(marker, Data([1]))
  let reused = try NativeAppCache.prepare(game: game, root: root)
  try check(reused.app == launch.app && fm.fileExists(atPath: marker.path), "reuse cache without recopy")
  try write(source.appendingPathComponent("Contents/MacOS/engine"), Data("changed executable metadata".utf8))
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(!fm.fileExists(atPath: marker.path), "executable metadata refresh")
  var backups = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("NativeApps").path).filter { $0.contains(".previous-") && $0.hasSuffix(".app") }
  try check(backups.count == 1, "stale cache preserved")
  var relocated = try fixture(base, "Second source"); relocated.id = game.id
  _ = try NativeAppCache.prepare(game: relocated, root: root)
  backups = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("NativeApps").path).filter { $0.contains(".previous-") && $0.hasSuffix(".app") }
  try check(backups.count == 2, "wrong source owned cache backed up")
  let unknown = try fixture(base, "Unknown", renpy: false)
  let direct = try NativeAppCache.prepare(game: unknown, root: root)
  try check(!direct.cached && direct.cachedBytes == 0 && direct.app.path == URL(fileURLWithPath: unknown.folder).resolvingSymlinksInPath().path, "unknown native direct")
  var invalid = game; invalid.entry.path = "../escape.app"
  try rejects("entry traversal") { _ = try NativeAppCache.prepare(game: invalid, root: root) }
  invalid = game; invalid.entry.backend = .wine
  try rejects("non-native") { _ = try NativeAppCache.prepare(game: invalid, root: root) }
  try rejects("source overlap") { _ = try NativeAppCache.prepare(game: game, root: source.appendingPathComponent("Local")) }
  let unsafe = base.appendingPathComponent("Unsafe")
  try fm.createSymbolicLink(atPath: unsafe.path, withDestinationPath: source.path)
  try rejects("symlink cache root") { _ = try NativeAppCache.prepare(game: game, root: unsafe) }
  let otherLocal = base.appendingPathComponent("OtherLocal")
  try fm.createDirectory(at: otherLocal, withIntermediateDirectories: true)
  let linkedLocal = base.appendingPathComponent("LinkedLocal")
  try fm.createSymbolicLink(atPath: linkedLocal.path, withDestinationPath: otherLocal.path)
  try rejects("symlink cache root outside source") { _ = try NativeAppCache.prepare(game: game, root: linkedLocal) }
  let linkedNative = base.appendingPathComponent("LinkedNative")
  try fm.createDirectory(at: linkedNative, withIntermediateDirectories: true)
  try fm.createSymbolicLink(atPath: linkedNative.appendingPathComponent("NativeApps").path, withDestinationPath: otherLocal.path)
  try rejects("symlink NativeApps outside source") { _ = try NativeAppCache.prepare(game: game, root: linkedNative) }
  let unownedRoot = base.appendingPathComponent("Unowned")
  let unowned = unownedRoot.appendingPathComponent("NativeApps/" + game.id.uuidString + ".app")
  try write(unowned.appendingPathComponent("sentinel"), Data([2]))
  try rejects("unowned destination") { _ = try NativeAppCache.prepare(game: game, root: unownedRoot) }
  try check(try Data(contentsOf: unowned.appendingPathComponent("sentinel")) == Data([2]), "unowned untouched")
  let symlinkRoot = base.appendingPathComponent("SymlinkDest")
  try fm.createDirectory(at: symlinkRoot.appendingPathComponent("NativeApps"), withIntermediateDirectories: true)
  try fm.createSymbolicLink(atPath: symlinkRoot.appendingPathComponent("NativeApps/" + game.id.uuidString + ".app").path, withDestinationPath: source.path)
  try rejects("symlink destination") { _ = try NativeAppCache.prepare(game: game, root: symlinkRoot) }
  let godot = try fixture(base, "Godot", renpy: false)
  try write(URL(fileURLWithPath: godot.folder).appendingPathComponent("Contents/Resources/main.pck"), Data(repeating: 8, count: 1024 * 1024))
  let godotLaunch = try NativeAppCache.prepare(game: godot, root: root)
  try check(godotLaunch.cached && godotLaunch.cachedBytes < 1024 * 1024, "explicit PCK cached without payload")
  _ = try fm.destinationOfSymbolicLink(atPath: godotLaunch.app.appendingPathComponent("Contents/Resources/main.pck").path)
  let cachedGodotExecutable = godotLaunch.app.appendingPathComponent("Contents/MacOS/engine")
  let godotInode = try fm.attributesOfItem(atPath: cachedGodotExecutable.path)[.systemFileNumber] as! NSNumber
  try write(URL(fileURLWithPath: godot.folder).appendingPathComponent("Contents/Resources/main.pck"), Data("updated NAS payload".utf8))
  _ = try NativeAppCache.prepare(game: godot, root: root)
  try check(try fm.attributesOfItem(atPath: cachedGodotExecutable.path)[.systemFileNumber] as? NSNumber == godotInode, "PCK payload changes reuse runtime cache")
  let escaped = try fixture(base, "Escaped")
  let exe = URL(fileURLWithPath: escaped.folder).appendingPathComponent("Contents/MacOS/engine")
  try fm.removeItem(at: exe); try fm.createSymbolicLink(atPath: exe.path, withDestinationPath: source.appendingPathComponent("Contents/MacOS/engine").path)
  try rejects("escaping main executable") { _ = try NativeAppCache.prepare(game: escaped, root: root) }
  let repairGame = try fixture(base, "Repair")
  let repair = try NativeAppCache.prepare(game: repairGame, root: root)
  try fm.removeItem(at: repair.app.appendingPathComponent("Contents/MacOS/engine"))
  let repaired = try NativeAppCache.prepare(game: repairGame, root: root)
  try check(fm.fileExists(atPath: repaired.app.appendingPathComponent("Contents/MacOS/engine").path), "damaged owned cache repaired")
  let changedInfo: [String: String] = ["CFBundleExecutable": "engine", "CFBundleName": "Updated", "CFBundleIdentifier": "org.original.changed"]
  try write(URL(fileURLWithPath: repairGame.folder).appendingPathComponent("Contents/Info.plist"), PropertyListSerialization.data(fromPropertyList: changedInfo, format: .xml, options: 0))
  let changed = try NativeAppCache.prepare(game: repairGame, root: root)
  let updated = try PropertyListSerialization.propertyList(from: Data(contentsOf: changed.app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
  try check(updated["CFBundleName"] as? String == "Updated", "plist SHA invalidates cache")
  var nested = game
  nested.folder = base.path; nested.entry.path = source.lastPathComponent
  _ = try NativeAppCache.prepare(game: nested, root: root)
  var escapeEntry = game
  escapeEntry.folder = base.appendingPathComponent("EntryFolder").path
  try fm.createDirectory(atPath: escapeEntry.folder, withIntermediateDirectories: true)
  try fm.createSymbolicLink(atPath: URL(fileURLWithPath: escapeEntry.folder).appendingPathComponent("Escape.app").path, withDestinationPath: source.path)
  escapeEntry.entry.path = "Escape.app"
  try rejects("entry symlink escape") { _ = try NativeAppCache.prepare(game: escapeEntry, root: root) }
  let badInfo = try fixture(base, "BadInfo")
  try write(URL(fileURLWithPath: badInfo.folder).appendingPathComponent("Contents/Info.plist"), PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "../engine"], format: .xml, options: 0))
  try rejects("executable filename slash") { _ = try NativeAppCache.prepare(game: badInfo, root: root) }
  let oversized = try fixture(base, "Oversized")
  let huge = URL(fileURLWithPath: oversized.folder).appendingPathComponent("Contents/MacOS/huge")
  try write(huge, Data())
  let handle = try FileHandle(forWritingTo: huge)
  try handle.truncate(atOffset: 512 * 1024 * 1024 + 1); try handle.close()
  try rejects("oversized engine") { _ = try NativeAppCache.prepare(game: oversized, root: root) }
  try check(!fm.fileExists(atPath: root.appendingPathComponent("NativeApps/" + oversized.id.uuidString + ".app").path), "oversized runtime never published")
  let children = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("NativeApps").path)
  try check(!children.contains(where: { $0.hasPrefix(".preparing-") }), "no staging debris")
  PreparationTasks.shared.cancel()
  let cancelled = try fixture(base, "Cancelled")
  try rejects("cancelled helper") { _ = try NativeAppCache.prepare(game: cancelled, root: root) }
  let afterCancel = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("NativeApps").path)
  try check(!afterCancel.contains(where: { $0.hasPrefix(".preparing-") }), "cancelled staging cleaned")
  print("PASS NativeAppCache: local rsync, payload links, reuse, refresh, backups, validation, direct, PCK")
 }
}
