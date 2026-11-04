import Foundation
import Darwin

/// Managed MZ string storage inside an already-mounted private account profile.
/// The caller serializes ALL instances for this profile on its I/O queue. Every
/// operation reopens persistent state; there is no in-memory/local fallback.
final class SharedWebSaveStore {
 enum Failure: Error, LocalizedError {
  case unsafePath, invalidIdentity, corruptState, limitExceeded, io(Int32)
  var errorDescription: String? {
   switch self {
   case .unsafePath: return "共享网页存档路径不安全或不可访问。"
   case .invalidIdentity: return "共享网页存档身份不匹配。"
   case .corruptState: return "共享网页存档损坏或不完整，原数据已保留。"
   case .limitExceeded: return "共享网页存档超过大小或条目限制。"
   case .io(let code): return "共享网页存档写入或持久化确认失败（\(code)），请检查连接并重试。"
   }
  }
 }
 private static let valueLimit = 4 * 1024 * 1024
 private static let totalLimit = 32 * 1024 * 1024 // Combined UTF-8 key and value bytes.
 private static let keyLimit = 1024, countLimit = 512
 // Base64 avoids JSON escaping amplification and preserves byte-distinct Unicode
 // keys. 32 MiB values + 512 KiB keys + metadata fit comfortably within 48 MiB.
 private static let fileLimit = 48 * 1024 * 1024
 private let profilePath: String
 private let identity: String
 private struct Marker: Codable {
  enum Phase: String, Codable { case creating, ready }
  let version: Int
  let identity: String
  // Legacy markers without phase already represent established stores.
  let phase: Phase?
 }
 private struct Entry: Codable { let key: Data; let value: Data }
 private struct Snapshot: Codable {
  let version: Int
  let identity: String
  let entries: [Entry]
  init(identity: String, entries: [Entry]) { version = 1; self.identity = identity; self.entries = entries }
  private enum CodingKeys: String, CodingKey { case version, identity, entries }
  init(from decoder: Decoder) throws {
   let object = try decoder.container(keyedBy: CodingKeys.self)
   version = try object.decode(Int.self, forKey: .version)
   identity = try object.decode(String.self, forKey: .identity)
   guard identity.utf8.count <= 1024 else { throw Failure.corruptState }
   var list = try object.nestedUnkeyedContainer(forKey: .entries), decoded: [Entry] = []
   while !list.isAtEnd {
    guard decoded.count < SharedWebSaveStore.countLimit else { throw Failure.corruptState }
    decoded.append(try list.decode(Entry.self))
   }
   entries = decoded
  }
 }
 private struct FileBytes { let data: Data; let info: stat }

 init(profileRoot: URL, identity: String) throws {
  guard !identity.isEmpty, identity.utf8.count <= 1024 else { throw Failure.invalidIdentity }
  guard profileRoot.isFileURL, profileRoot.host == nil || profileRoot.host == "" || profileRoot.host == "localhost",
        profileRoot.user == nil, profileRoot.password == nil, profileRoot.query == nil, profileRoot.fragment == nil,
        profileRoot.path.hasPrefix("/"), profileRoot.path != "/", profileRoot.path.utf8.count < 4096,
        !profileRoot.path.contains("//"), !profileRoot.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
        !profileRoot.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.unsafePath }
  self.profilePath = profileRoot.path; self.identity = identity
  try withDirectory(create: true) { directory in
   var markerFile = try read("identity.json", in: directory, limit: 8192)
   let store = try read("store.json", in: directory, limit: Self.fileLimit)
   if markerFile == nil && store == nil {
    guard try emptyDirectory(directory) else { throw Failure.corruptState }
    try publish(encode(Marker(version: 1, identity: identity, phase: .creating)), name: "identity.json", in: directory, replacing: nil)
    markerFile = try read("identity.json", in: directory, limit: 8192)
   }
   guard let markerFile else { throw Failure.corruptState }
   let marker = try checkedMarker(markerFile)
   if marker.phase == .creating {
    // No initializer has returned, so gameplay could not have acknowledged a
    // save in this phase. Resume only this explicitly uncommitted creation.
    if store == nil {
     try publish(encode(Snapshot(identity: identity, entries: [])), name: "store.json", in: directory, replacing: nil)
    }
    // Validate an existing snapshot completely and retain even nonempty data.
    // Never reinterpret corrupt/foreign state as an interrupted empty create.
    _ = try load(in: directory, allowCreating: true)
    try publish(encode(Marker(version: 1, identity: identity, phase: .ready)), name: "identity.json", in: directory, replacing: markerFile.info)
   } else { _ = try load(in: directory) }
  }
 }

 func get(_ key: String) throws -> String? {
  let key = try checkedKey(key)
  return try withDirectory { directory in
   let (values, _) = try load(in: directory)
   return values[key].flatMap { String(data: $0, encoding: .utf8) }
  }
 }
 func set(_ key: String, value: String) throws {
  let key = try checkedKey(key), value = Data(value.utf8)
  guard value.count <= Self.valueLimit else { throw Failure.limitExceeded }
  try mutate { values in values[key] = value }
 }
 func remove(_ key: String) throws {
  let key = try checkedKey(key)
  try mutate { values in values.removeValue(forKey: key) }
 }
 func keys() throws -> [String] {
  try withDirectory { directory in
   let (values, _) = try load(in: directory)
   return values.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { String(data: $0, encoding: .utf8)! }
  }
 }
 func clear() throws { try mutate { $0.removeAll() } }

 private func checkedKey(_ key: String) throws -> Data {
  let bytes = Data(key.utf8)
  guard bytes.count <= Self.keyLimit else { throw Failure.limitExceeded }
  return bytes
 }
 private func mutate(_ change: (inout [Data: Data]) -> Void) throws {
  try withDirectory { directory in
   var (values, original) = try load(in: directory)
   change(&values)
   try validate(values, corrupt: false)
   let entries = values.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { Entry(key: $0, value: values[$0]!) }
   let bytes = try encode(Snapshot(identity: identity, entries: entries))
   guard bytes.count <= Self.fileLimit else { throw Failure.limitExceeded }
   try publish(bytes, name: "store.json", in: directory, replacing: original.info)
  }
 }
 private func encode<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
 }
 private func checkedMarker(_ file: FileBytes) throws -> Marker {
  guard let marker = try? JSONDecoder().decode(Marker.self, from: file.data), marker.version == 1 else { throw Failure.corruptState }
  guard marker.identity.utf8.elementsEqual(identity.utf8) else { throw Failure.invalidIdentity }
  return marker
 }
 private func load(in directory: Int32, allowCreating: Bool = false) throws -> ([Data: Data], FileBytes) {
  guard let markerFile = try read("identity.json", in: directory, limit: 8192) else { throw Failure.corruptState }
  let marker = try checkedMarker(markerFile)
  guard allowCreating || marker.phase != .creating else { throw Failure.corruptState }
  guard let store = try read("store.json", in: directory, limit: Self.fileLimit),
        let snapshot = try? JSONDecoder().decode(Snapshot.self, from: store.data), snapshot.version == 1 else { throw Failure.corruptState }
  guard snapshot.identity.utf8.elementsEqual(identity.utf8) else { throw Failure.invalidIdentity }
  var values: [Data: Data] = [:]
  for entry in snapshot.entries {
   guard values.updateValue(entry.value, forKey: entry.key) == nil else { throw Failure.corruptState }
  }
  try validate(values, corrupt: true)
  return (values, store)
 }
 private func validate(_ values: [Data: Data], corrupt: Bool) throws {
  let failure: Failure = corrupt ? .corruptState : .limitExceeded
  guard values.count <= Self.countLimit else { throw failure }
  var total = 0
  for (key, value) in values {
   guard key.count <= Self.keyLimit, value.count <= Self.valueLimit,
         key.count + value.count <= Self.totalLimit - total,
         String(data: key, encoding: .utf8) != nil, String(data: value, encoding: .utf8) != nil else { throw failure }
   total += key.count + value.count
  }
 }

 private func withDirectory<T>(create: Bool = false, _ body: (Int32) throws -> T) throws -> T {
  var root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard root >= 0 else { throw Failure.unsafePath }
  defer { Darwin.close(root) }
  for component in profilePath.split(separator: "/") {
   let next = openat(root, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
   guard next >= 0 else { throw Failure.unsafePath }
   Darwin.close(root); root = next
  }
  if create, mkdirat(root, "WebKitMZ", 0o700) != 0 && errno != EEXIST { throw Failure.io(errno) }
  let directory = openat(root, "WebKitMZ", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard directory >= 0 else { throw Failure.unsafePath }
  defer { Darwin.close(directory) }
  return try body(directory)
 }
 private func emptyDirectory(_ directory: Int32) throws -> Bool {
  let duplicate = dup(directory)
  guard duplicate >= 0 else { throw Failure.io(errno) }
  guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.io(errno) }
  defer { closedir(stream) }
  errno = 0
  while let entry = readdir(stream) {
   let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
   if name != "." && name != ".." { return false }
  }
  guard errno == 0 else { throw Failure.io(errno) }
  return true
 }
 private func safeFile(_ info: stat, limit: Int) -> Bool {
  info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_size > 0 && info.st_size <= limit
 }
 private func read(_ name: String, in directory: Int32, limit: Int) throws -> FileBytes? {
  let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
  if fd < 0 && errno == ENOENT { return nil }
  guard fd >= 0 else { throw Failure.unsafePath }
  defer { Darwin.close(fd) }
  var info = stat()
  guard fstat(fd, &info) == 0, safeFile(info, limit: limit) else { throw Failure.corruptState }
  var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
  while true {
   let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
   if count < 0 && errno == EINTR { continue }
   guard count >= 0 else { throw Failure.io(errno) }
   if count == 0 { break }
   guard count <= limit - data.count else { throw Failure.corruptState }
   data.append(contentsOf: buffer.prefix(count))
  }
  var after = stat()
  guard fstat(fd, &after) == 0, data.count == info.st_size, after.st_size == info.st_size,
        after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw Failure.corruptState }
  return FileBytes(data: data, info: info)
 }
 private func publish(_ bytes: Data, name: String, in directory: Int32, replacing previous: stat?) throws {
  let temporary = ".writing-" + UUID().uuidString + ".tmp"
  let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
  guard fd >= 0 else { throw Failure.io(errno) }
  defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
  try bytes.withUnsafeBytes { buffer in
   var offset = 0
   while offset < buffer.count {
    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { throw Failure.io(errno) }
    offset += count
   }
  }
  guard fsync(fd) == 0 else { throw Failure.io(errno) }
  if let previous {
   var current = stat()
   guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
         safeFile(current, limit: Self.fileLimit), current.st_dev == previous.st_dev,
         current.st_ino == previous.st_ino, current.st_size == previous.st_size,
         current.st_mtimespec.tv_sec == previous.st_mtimespec.tv_sec,
         current.st_mtimespec.tv_nsec == previous.st_mtimespec.tv_nsec else { throw Failure.corruptState }
  }
  var renamed=renameatx_np(directory,temporary,directory,name,previous == nil ? UInt32(RENAME_EXCL):0)
  if renamed != 0,previous == nil,errno == ENOTSUP || errno == EOPNOTSUPP {
   // macOS SMB may implement atomic rename but not the RENAME_EXCL flag.
   // This private profile has one server write lease and one serialized caller.
   // Preserve unexpected data, just as the replacement CAS above does, before
   // using the portable atomic rename. Never weaken either fsync requirement.
   var occupied=stat()
   guard fstatat(directory,name,&occupied,AT_SYMLINK_NOFOLLOW) != 0 else{throw Failure.corruptState}
   guard errno == ENOENT else{throw Failure.io(errno)}
   renamed=renameat(directory,temporary,directory,name)
  }
  guard renamed == 0 else { throw Failure.io(errno) }
  // Do not ACK unsupported/failed durability. A failure after rename may mean
  // the new complete snapshot exists; retry must reread it, never reset it.
  guard fsync(directory) == 0 else { throw Failure.io(errno) }
 }
}
