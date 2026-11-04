import Foundation
import Darwin
import NetFS
import Security

/// Transient gateway credentials. Do not persist this response in library/defaults state.
struct SharedSMBShare: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
 var host: String
 var port: Int
 var name: String
 var username: String
 var password: String

 var description: String { "SharedSMBShare(credentials: redacted)" }
 var debugDescription: String { description }

 /// No credentials are ever placed in the URL, including its user-info component.
 func mountURL() throws -> URL {
  let endpoint = try Self.validatedHost(host)
  let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
  guard (1...65535).contains(port), (1...128).contains(name.utf8.count),
        name.first?.isASCII == true, name.first?.isLetter == true || name.first?.isNumber == true,
        name.allSatisfy({ allowed.contains($0) }),
        !username.isEmpty, !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
   throw NetworkLibraryMount.Failure.invalidShare
  }
  var components = URLComponents()
  components.scheme = "smb"; components.host = endpoint; components.port = port
  components.path = "/" + name
  guard let url = components.url, components.user == nil, components.password == nil else {
   throw NetworkLibraryMount.Failure.invalidShare
  }
  return url
 }

 fileprivate static func validatedHost(_ host: String) throws -> String {
  guard !host.isEmpty, host.utf8.count <= 253, host.utf8.allSatisfy({ $0 < 128 }),
        !host.contains("%") else { throw NetworkLibraryMount.Failure.invalidShare }
  var address = in6_addr()
  let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
  if inet_pton(AF_INET6, bare, &address) == 1 { return "[" + bare.lowercased() + "]" }
  let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
  let labels = host.split(separator: ".", omittingEmptySubsequences: false)
  guard labels.allSatisfy({ label in
   !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
   label.allSatisfy({ allowed.contains($0) })
  }) else { throw NetworkLibraryMount.Failure.invalidShare }
  return host.lowercased()
 }
}

struct MountedLibraryShare {
 let url: URL
 let owned: Bool
 fileprivate let identity: NetworkLibraryMount.MountIdentity?
 fileprivate let receipt: UUID?
 // A caller-created handle never confers permission to unmount an existing volume.
 init(url: URL, owned: Bool) { self.url = url; self.owned = owned; identity = nil; receipt = nil }
 fileprivate init(url: URL, identity: NetworkLibraryMount.MountIdentity, receipt: UUID) {
  self.url = url; owned = true; self.identity = identity; self.receipt = receipt
 }
}

enum NetworkLibraryMount {
 enum Failure: Error, LocalizedError {
  case invalidShare, unsafeTarget, unexpectedMount, notOwned, invalidReceipt
  case mountFailed(Int32), unmountFailed(Int32), credentialFailed(OSStatus), invalidToken
  var errorDescription: String? {
   switch self {
   case .invalidShare: return "Invalid shared-library endpoint or credentials."
   case .unsafeTarget: return "The mount target must be an existing, private, empty directory without symbolic links."
   case .unexpectedMount: return "The mounted volume does not match the requested SMB share and target."
   case .notOwned: return "This SMB mount is no longer owned by this handle."
   case .invalidReceipt: return "The private recovery receipt is unsafe or does not match this account and mount."
   case .mountFailed(let code): return "Shared-library mount failed (\(code))."
   case .unmountFailed(let code): return "Shared-library unmount failed (\(code)); the volume may still be busy."
   case .credentialFailed(let code): return "Shared-library Keychain operation failed (\(code))."
   case .invalidToken: return "Invalid shared-library token."
   }
  }
 }

 struct MountIdentity: Codable, Equatable {
  let target: String
  let fileSystem: String
  let source: String
  let fsid0: Int32
  let fsid1: Int32

  fileprivate func matches(_ share: SharedSMBShare, at target: URL) -> Bool {
   guard self.target == target.path, fileSystem == "smbfs", source.hasPrefix("//"),
         let endpoint = URLComponents(string: "smb:" + source),
         let host = endpoint.host, let expectedHost = try? SharedSMBShare.validatedHost(share.host),
         let actualHost = try? SharedSMBShare.validatedHost(host),
         actualHost == expectedHost, (endpoint.port ?? 445) == share.port,
         endpoint.user == share.username, endpoint.password == nil,
         endpoint.percentEncodedPath == "/" + share.name,
         endpoint.query == nil, endpoint.fragment == nil else { return false }
   return true
  }
 }
 enum TargetState: Equatable {
  case missing
  case directory(device: UInt64, inode: UInt64, owner: uid_t, empty: Bool)
  case mounted(MountIdentity)
 }
 struct MountResult {
  let status: Int32
  let paths: [String]
 }
 /// Injection is limited to OS boundaries; validation and ownership decisions stay here.
 struct Operations {
  var inspect: (URL) throws -> TargetState
  var mount: (URL, URL, String, String, [String: Any], [String: Any]) throws -> MountResult
  var unmount: (URL, Int32) throws -> Int32
  static var live: Operations {
   .init(inspect: inspectTarget, mount: { url, target, user, password, open, options in
    var paths: Unmanaged<CFArray>?
    let status = NetFSMountURLSync(url as CFURL, target as CFURL, user as CFString, password as CFString,
     NSMutableDictionary(dictionary: open), NSMutableDictionary(dictionary: options), &paths)
    let returned = paths?.takeRetainedValue() as? [String] ?? []
    return MountResult(status: Int32(status), paths: returned)
   }, unmount: { url, flags in
    Darwin.unmount(url.path, flags) == 0 ? 0 : errno
   })
  }
 }

 // Serializes mounts/unmounts performed by this helper, including target checks.
 private static let lock = NSLock()
 private static var ownedMounts: [UUID: MountIdentity] = [:]

 /// Blocking API: callers must use a worker queue. Existing mounts are never adopted.
 /// The gateway must require SMB3 encryption; an smb URL alone cannot enforce that policy.
 static func mount(share: SharedSMBShare, at target: URL, operations: Operations = .live) throws -> MountedLibraryShare {
  let url = try share.mountURL()
  try validateTargetURL(target)
  lock.lock(); defer { lock.unlock() }
  let before = try operations.inspect(target)
  guard case .directory(_, _, let owner, true) = before, owner == geteuid() else { throw Failure.unsafeTarget }
  // Refuse a directory replaced or populated during preparation.
  guard try operations.inspect(target) == before else { throw Failure.unsafeTarget }
  let open: [String: Any] = [kNetFSForceNewSessionKey: true, kNAUIOptionKey: kNAUIOptionNoUI]
  let options: [String: Any] = [kNetFSMountAtMountDirKey: true,
   kNetFSMountFlagsKey: NSNumber(value: UInt32(MNT_DONTBROWSE | MNT_NOSUID | MNT_NODEV))]
  let result = try operations.mount(url, target, share.username, share.password, open, options)
  guard result.status == 0 else { throw Failure.mountFailed(result.status) }
  guard result.paths == [target.path],
        case .mounted(let identity) = try operations.inspect(target), identity.matches(share, at: target) else {
   // Never unmount some other volume while trying to clean up an unverified result.
   throw Failure.unexpectedMount
  }
  let receipt = UUID()
  ownedMounts[receipt] = identity
  return MountedLibraryShare(url: target, identity: identity, receipt: receipt)
 }

 /// No force flag, retries, directory removal, or unmounting of an inherited mount.
 static func unmount(_ mounted: MountedLibraryShare, operations: Operations = .live) throws {
  guard mounted.owned else { return }
  try validateTargetURL(mounted.url)
  lock.lock(); defer { lock.unlock() }
  guard let receipt = mounted.receipt, let expected = mounted.identity, ownedMounts[receipt] == expected,
        expected.target == mounted.url.path, expected.fileSystem == "smbfs" else { throw Failure.notOwned }
  guard case .mounted(let actual) = try operations.inspect(mounted.url), actual == expected else {
   ownedMounts.removeValue(forKey: receipt)
   throw Failure.notOwned
  }
  let status = try operations.unmount(mounted.url, 0)
  guard status == 0 else { throw Failure.unmountFailed(status) }
  ownedMounts.removeValue(forKey: receipt)
 }

 private struct RecoveryRecord: Codable, Equatable {
  let version: Int
  let identityKey: String
  let mount: MountIdentity
 }
 private struct ReceiptFile {
  let record: RecoveryRecord
  let info: stat
 }

 /// Store in a caller-created local 0700 directory outside the mount. No passwords.
 /// Only a live, genuinely owned handle can mint a receipt. A previous receipt
 /// may be replaced only within the same exact namespace and target.
 static func persistReceipt(mounted: MountedLibraryShare, identityKey: String, to receiptURL: URL,
                            operations: Operations = .live) throws {
  try validateReceiptLocation(receiptURL, target: mounted.url, identityKey: identityKey)
  lock.lock(); defer { lock.unlock() }
  guard mounted.owned, let nonce = mounted.receipt, let identity = mounted.identity,
        ownedMounts[nonce] == identity,
        case .mounted(let actual) = try operations.inspect(mounted.url), actual == identity else { throw Failure.notOwned }
  let record = RecoveryRecord(version: 1, identityKey: identityKey, mount: identity)
  try validateRecord(record, target: mounted.url, identityKey: identityKey)
  let (directory, name) = try receiptDirectory(receiptURL)
  defer { Darwin.close(directory) }
  let previous = try readReceipt(directory: directory, name: name)
  if let existing = previous {
   try validateRecord(existing.record, target: mounted.url, identityKey: identityKey)
   if existing.record == record { return }
  }
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  let bytes = try encoder.encode(record)
  guard bytes.count <= 8192 else { throw Failure.invalidReceipt }
  let temporary = ".gameshelf-receipt-" + UUID().uuidString
  let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
  guard fd >= 0 else { throw Failure.invalidReceipt }
  defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
  guard fchmod(fd, 0o600) == 0 else { throw Failure.invalidReceipt }
  try bytes.withUnsafeBytes { buffer in
   var offset = 0
   while offset < buffer.count {
    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
    if count < 0 && errno == EINTR { continue }
    guard count > 0 else { throw Failure.invalidReceipt }
    offset += count
   }
  }
  if let previous {
   var current = stat()
   guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
         current.st_dev == previous.info.st_dev, current.st_ino == previous.info.st_ino,
         privateReceiptFile(current), current.st_size == previous.info.st_size else { throw Failure.invalidReceipt }
  }
  guard fsync(fd) == 0,
        renameatx_np(directory, temporary, directory, name, previous == nil ? UInt32(RENAME_EXCL) : 0) == 0,
        fsync(directory) == 0 else { throw Failure.invalidReceipt }
 }

 /// Call ONLY after a fresh valid server lease confirms the old writer is gone.
 /// This verifies local ownership, not server revocation. It never unmounts anything.
 /// An exact surviving mount receives a new process-local nonce; an absent mount
 /// clears only the checked receipt. Different actual mounts fail closed.
 static func recoverReceipt(at receiptURL: URL, target: URL, identityKey: String,
                            operations: Operations = .live) throws -> MountedLibraryShare? {
  try validateReceiptLocation(receiptURL, target: target, identityKey: identityKey)
  lock.lock(); defer { lock.unlock() }
  let (directory, name) = try receiptDirectory(receiptURL)
  defer { Darwin.close(directory) }
  guard let stored = try readReceipt(directory: directory, name: name) else { return nil }
  try validateRecord(stored.record, target: target, identityKey: identityKey)
  switch try operations.inspect(target) {
  case .mounted(let actual):
   guard actual == stored.record.mount else { throw Failure.unexpectedMount }
   invalidateReceipts(for: target)
   let nonce = UUID()
   ownedMounts[nonce] = actual
   return MountedLibraryShare(url: target, identity: actual, receipt: nonce)
  case .directory, .missing:
   var current = stat()
   guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
         current.st_dev == stored.info.st_dev, current.st_ino == stored.info.st_ino,
         privateReceiptFile(current), current.st_size == stored.info.st_size,
         unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else { throw Failure.invalidReceipt }
   invalidateReceipts(for: target)
   return nil
  }
 }

 private static func invalidateReceipts(for target: URL) {
  ownedMounts = ownedMounts.filter { $0.value.target != target.path }
 }
 private static func validateReceiptLocation(_ url: URL, target: URL, identityKey: String) throws {
  try validateTargetURL(url); try validateTargetURL(target)
  guard !identityKey.isEmpty, identityKey.utf8.count <= 1024,
        !identityKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        url.path != target.path, !url.path.hasPrefix(target.path + "/") else { throw Failure.invalidReceipt }
 }
 private static func validateRecord(_ record: RecoveryRecord, target: URL, identityKey: String) throws {
  guard record.version == 1, record.identityKey == identityKey, record.mount.target == target.path,
        let source = URLComponents(string: "smb:" + record.mount.source), let host = source.host,
        let username = source.user else { throw Failure.invalidReceipt }
  let share = SharedSMBShare(host: host, port: source.port ?? 445,
   name: String(source.path.dropFirst()), username: username, password: "")
  guard (try? share.mountURL()) != nil, record.mount.matches(share, at: target) else { throw Failure.invalidReceipt }
 }

 /// Open each parent relative to a pinned descriptor. A private local directory
 /// is the trust boundary: same-uid malicious edits are deliberately not authenticated.
 private static func receiptDirectory(_ url: URL) throws -> (Int32, String) {
  let components = url.path.split(separator: "/").map(String.init)
  guard components.count >= 2, let name = components.last else { throw Failure.invalidReceipt }
  var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard fd >= 0 else { throw Failure.invalidReceipt }
  do {
   for component in components.dropLast() {
    let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard next >= 0 else { throw Failure.invalidReceipt }
    Darwin.close(fd); fd = next
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == 0 || info.st_uid == geteuid(),
          info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { throw Failure.invalidReceipt }
   }
   var info = stat(), filesystem: statfs = .init()
   guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
         fstatfs(fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw Failure.invalidReceipt }
   return (fd, name)
  } catch { Darwin.close(fd); throw error }
 }
 private static func privateReceiptFile(_ info: stat) -> Bool {
  (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() &&
   info.st_mode & 0o7777 == 0o600 && info.st_nlink == 1 && (1...8192).contains(info.st_size)
 }
 private static func readReceipt(directory: Int32, name: String) throws -> ReceiptFile? {
  let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
  if fd < 0 && errno == ENOENT { return nil }
  guard fd >= 0 else { throw Failure.invalidReceipt }
  defer { Darwin.close(fd) }
  var info = stat()
  guard fstat(fd, &info) == 0, privateReceiptFile(info) else { throw Failure.invalidReceipt }
  var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
  while true {
   let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
   if count < 0 && errno == EINTR { continue }
   guard count >= 0 else { throw Failure.invalidReceipt }
   if count == 0 { break }
   guard bytes.count + count <= 8192 else { throw Failure.invalidReceipt }
   bytes.append(contentsOf: buffer.prefix(count))
  }
  guard bytes.count == info.st_size, let record = try? JSONDecoder().decode(RecoveryRecord.self, from: bytes) else {
   throw Failure.invalidReceipt
  }
  return ReceiptFile(record: record, info: info)
 }

 private static func validateTargetURL(_ target: URL) throws {
  guard target.isFileURL, target.host == nil || target.host == "" || target.host == "localhost",
        target.user == nil, target.password == nil, target.query == nil, target.fragment == nil,
        target.path.hasPrefix("/"), target.path != "/",
        !target.path.contains("//"),
        !target.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
        !target.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
   throw Failure.unsafeTarget
  }
 }

 private static func inspectTarget(_ target: URL) throws -> TargetState {
  try validateTargetURL(target)
  // Reject ancestor links; O_NOFOLLOW below checks an unmounted final component.
  // Root and the current user may own ancestors; shared writable ancestors require the sticky bit.
  var current = ""
  for component in target.path.split(separator: "/").dropLast() {
   current += "/" + component
   var info = stat()
   guard lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
         info.st_uid == 0 || info.st_uid == geteuid(),
         info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { throw Failure.unsafeTarget }
  }
  // MNT_NOWAIT reads the kernel mount inventory without requesting server stats.
  let count = getfsstat(nil, 0, MNT_NOWAIT)
  guard count >= 0, count < 100_000 else { throw Failure.unsafeTarget }
  var mounts: [statfs] = .init(repeating: .init(), count: Int(count) + 16)
  let found = mounts.withUnsafeMutableBufferPointer { buffer in
   getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
  }
  guard found >= 0, Int(found) < mounts.count else { throw Failure.unsafeTarget }
  for var entry in mounts.prefix(Int(found)) {
   let path = tupleString(&entry.f_mntonname)
   if path == target.path {
    return .mounted(MountIdentity(target: path, fileSystem: tupleString(&entry.f_fstypename),
     source: tupleString(&entry.f_mntfromname), fsid0: entry.f_fsid.val.0, fsid1: entry.f_fsid.val.1))
   }
  }
  let fd = Darwin.open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  if fd < 0 && errno == ENOENT { return .missing }
  guard fd >= 0 else { throw Failure.unsafeTarget }
  defer { Darwin.close(fd) }
  var info = stat()
  guard fstat(fd, &info) == 0, info.st_mode & 0o022 == 0 else { throw Failure.unsafeTarget }
  let duplicate = dup(fd)
  guard duplicate >= 0 else { throw Failure.unsafeTarget }
  guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.unsafeTarget }
  defer { closedir(directory) }
  var empty = true
  errno = 0
  while let entry = readdir(directory) {
   let name = tupleString(&entry.pointee.d_name)
   if name != "." && name != ".." { empty = false; break }
  }
  guard errno == 0 else { throw Failure.unsafeTarget }
  return .directory(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), owner: info.st_uid, empty: empty)
 }

 private static func tupleString<T>(_ tuple: inout T) -> String {
  withUnsafePointer(to: &tuple) { pointer in
   pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
  }
 }
}

/// Stores only an API token keyed by connection UUID, never a serialized share response.
struct SharedCredentialStore {
 static func save(_ token: String, connectionID: UUID) throws {
  try save(token: token, connectionID: connectionID)
 }
 static func save(token: String, connectionID: UUID) throws {
  try Self().save(token: token, for: connectionID)
 }
 static func read(connectionID: UUID) throws -> String? {
  try Self().read(for: connectionID)
 }
 static func delete(connectionID: UUID) throws {
  try Self().delete(for: connectionID)
 }
 struct Operations {
  var add: ([String: Any]) -> OSStatus
  var update: ([String: Any], [String: Any]) -> OSStatus
  var copy: ([String: Any]) -> (OSStatus, CFTypeRef?)
  var delete: ([String: Any]) -> OSStatus
  static var live: Operations {
   .init(add: { SecItemAdd($0 as CFDictionary, nil) },
    update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
    copy: { query in
     var value: CFTypeRef?
     let status = SecItemCopyMatching(query as CFDictionary, &value)
     return (status, value)
    }, delete: { SecItemDelete($0 as CFDictionary) })
  }
 }
 private let operations: Operations
 init(operations: Operations = .live) { self.operations = operations }
 private func query(_ connection: UUID) -> [String: Any] {
  [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.gameshelf.shared",
   kSecAttrAccount as String: connection.uuidString, kSecAttrSynchronizable as String: false]
 }
 func save(token: String, for connection: UUID) throws {
  guard !token.isEmpty else { throw NetworkLibraryMount.Failure.invalidToken }
  let key = query(connection)
  let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
  var status = operations.update(key, attributes)
  if status == errSecItemNotFound {
   status = operations.add(key.merging(attributes) { _, new in new })
   if status == errSecDuplicateItem { status = operations.update(key, attributes) }
  }
  guard status == errSecSuccess else { throw NetworkLibraryMount.Failure.credentialFailed(status) }
 }
 func read(for connection: UUID) throws -> String? {
  var key = query(connection)
  key[kSecReturnData as String] = true; key[kSecMatchLimit as String] = kSecMatchLimitOne
  let (status, value) = operations.copy(key)
  if status == errSecItemNotFound { return nil }
  guard status == errSecSuccess else { throw NetworkLibraryMount.Failure.credentialFailed(status) }
  guard let data = value as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
   throw NetworkLibraryMount.Failure.invalidToken
  }
  return token
 }
 func delete(for connection: UUID) throws {
  let status = operations.delete(query(connection))
  guard status == errSecSuccess || status == errSecItemNotFound else { throw NetworkLibraryMount.Failure.credentialFailed(status) }
 }
}
