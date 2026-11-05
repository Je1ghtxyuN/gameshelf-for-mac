import Foundation
import Darwin
import NetFS

private func check(_ value: Bool, _ message: String) throws {
 if !value { throw NSError(domain: "NetworkLibraryMountTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func rejects(_ body: () throws -> Void) throws {
 do { try body() } catch { return }
 throw NSError(domain: "NetworkLibraryMountTests", code: 2,
               userInfo: [NSLocalizedDescriptionKey: "Expected rejection"])
}
private let fixtureShare = SharedSMBShare(host: "gateway.example", port: 445,
 name: "gs_123-abc", username: "private-user", password: "secret:@/?#% password")

private final class MountFixture {
 let target = URL(fileURLWithPath: "/Volumes/GameShelf-test")
 var state = NetworkLibraryMount.TargetState.directory(device: 1, inode: 2, owner: geteuid(), empty: true)
 var mountCalls = 0, unmountCalls = 0
 var resultPaths: [String] = ["/Volumes/GameShelf-test"]
 var status: Int32 = 0, unmountStatus: Int32 = 0
 var after: NetworkLibraryMount.MountIdentity?
 var capturedURL: URL?
 var capturedUser = "", capturedPassword = ""
 var openOptions: [String: Any] = [:], mountOptions: [String: Any] = [:]
 init() {
  after = identity()
 }
 func identity(source: String = "//private-user@gateway.example:445/gs_123-abc",
               type: String = "smbfs", target: String = "/Volumes/GameShelf-test",
               serial: Int32 = 11) -> NetworkLibraryMount.MountIdentity {
  .init(target: target, fileSystem: type, source: source, fsid0: serial, fsid1: 12)
 }
 var operations: NetworkLibraryMount.Operations {
  .init(inspect: { _ in self.state }, mount: { url, _, user, password, open, options in
   self.mountCalls += 1; self.capturedURL = url
   self.capturedUser = user; self.capturedPassword = password
   self.openOptions = open; self.mountOptions = options
   if let after = self.after { self.state = .mounted(after) }
   return .init(status: self.status, paths: self.resultPaths)
  }, unmount: { _, flags in
   try check(flags == 0, "Unmount must never force busy volumes")
   self.unmountCalls += 1
   return self.unmountStatus
  })
 }
}

@main struct NetworkLibraryMountTests {
 static func main() throws {
  if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--recover-receipt" {
   let f = MountFixture(); f.state = .mounted(f.identity())
   guard let recovered = try NetworkLibraryMount.recoverReceipt(at: URL(fileURLWithPath: CommandLine.arguments[2]),
     target: f.target, identityKey: "server/account/game", operations: f.operations) else {
    throw NSError(domain: "NetworkLibraryMountTests", code: 8)
   }
   try NetworkLibraryMount.unmount(recovered, operations: f.operations)
   try check(f.unmountCalls == 1, "Fresh process must recover exact mount ownership")
   return
  }
  for (name, run) in [("validation", validation), ("mounting", mounting),
                       ("identity", refusalAndIdentity), ("target inspection", realTargetInspection),
                       ("persisted recovery", persistedRecovery)] {
   do { try run() } catch {
    throw NSError(domain: "NetworkLibraryMountTests", code: 5,
     userInfo: [NSLocalizedDescriptionKey: name + ": " + error.localizedDescription])
   }
  }
  print("PASS NetworkLibraryMount: validation, secret separation, mount identity/ownership, safe targets/unmount, persisted recovery across processes (no network mounts)")
 }
 static func validation() throws {
  let url = try fixtureShare.mountURL()
  try check(url.absoluteString == "smb://gateway.example:445/gs_123-abc", "SMB URL must contain only endpoint and generated share")
  try check(url.user == nil && url.password == nil, "Credentials must stay outside URL")
  try check(!String(describing: fixtureShare).contains(fixtureShare.password) &&
            !String(reflecting: fixtureShare).contains(fixtureShare.password), "Descriptions must redact password")
  let decoded = try JSONDecoder().decode(SharedSMBShare.self, from: JSONEncoder().encode(fixtureShare))
  try check(decoded == fixtureShare, "Server share model must round trip")
  for host in ["", "smb://host", "host/path", "user@host", "host:445", "host?x", "host#x", "host\\path", "host%2fpath", "%31%32%37.0.0.1", "host\n", " host", ".host", "host..example", "-host", "host-", "host."] {
   var share = fixtureShare; share.host = host
   try rejects { _ = try share.mountURL() }
  }
  for name in ["", ".", "..", "a/b", "a\\b", "a%2fb", "a?b", "a#b", "a b", "a\n", "a\u{0}", String(repeating: "a", count: 129)] {
   var share = fixtureShare; share.name = name
   try rejects { _ = try share.mountURL() }
  }
  for port in [0, -1, 65536] {
   var share = fixtureShare; share.port = port
   try rejects { _ = try share.mountURL() }
  }
  for host in ["127.0.0.1", "nas", "nas-1.example", "::1", "[2001:db8::1]"] {
   var share = fixtureShare; share.host = host
   try check(try share.mountURL().host != nil, "Valid host must form URL")
  }
  var share = fixtureShare; share.username = ""
  try rejects { _ = try share.mountURL() }
  share.username = "user\n"
  try rejects { _ = try share.mountURL() }
 }
 static func mounting() throws {
  let f = MountFixture()
  let mounted = try NetworkLibraryMount.mount(share: fixtureShare, at: f.target, operations: f.operations)
  try check(mounted.owned && mounted.url == f.target, "Verified new mount must be owned")
  try check(f.capturedUser == "private-user" && f.capturedPassword == fixtureShare.password, "NetFS must receive separate credentials")
  try check(f.capturedURL?.user == nil && f.capturedURL?.password == nil, "NetFS URL has no credentials")
  try check(f.openOptions[kNetFSForceNewSessionKey] as? Bool == true, "Do not reuse another account's authenticated session")
  try check(f.openOptions[kNAUIOptionKey] as? String == kNAUIOptionNoUI, "No unexpected authentication UI")
  try check(f.mountOptions[kNetFSMountAtMountDirKey] as? Bool == true, "Require the exact requested target")
  let flags = (f.mountOptions[kNetFSMountFlagsKey] as? NSNumber)?.uint32Value ?? 0
  try check(flags & UInt32(MNT_DONTBROWSE | MNT_NOSUID | MNT_NODEV) == UInt32(MNT_DONTBROWSE | MNT_NOSUID | MNT_NODEV), "Mount must be hidden, nosuid and nodev")
  try check(flags & UInt32(MNT_NOEXEC) == 0, "Game execution must remain possible")
  f.unmountStatus = EBUSY
  try rejects { try NetworkLibraryMount.unmount(mounted, operations: f.operations) }
  try check(f.unmountCalls == 1, "Busy unmount must fail without retrying forcibly")
  f.unmountStatus = 0
  try NetworkLibraryMount.unmount(mounted, operations: f.operations)
  try check(f.unmountCalls == 2, "A busy mount retains ownership for a later normal unmount")
  try rejects { try NetworkLibraryMount.unmount(mounted, operations: f.operations) }
  try check(f.unmountCalls == 2, "A consumed handle must not unmount a later volume even if its filesystem ID is recycled")
 }
 static func refusalAndIdentity() throws {
  for state: NetworkLibraryMount.TargetState in [
   .missing,
   .directory(device: 1, inode: 2, owner: geteuid(), empty: false),
   .directory(device: 1, inode: 2, owner: geteuid() &+ 1, empty: true),
   .mounted(MountFixture().identity())
  ] {
   let f = MountFixture(); f.state = state
   try rejects { _ = try NetworkLibraryMount.mount(share: fixtureShare, at: f.target, operations: f.operations) }
   try check(f.mountCalls == 0, "Never mount over occupied, foreign-owned or already mounted target")
  }
  for identity in [
   MountFixture().identity(type: "apfs"),
   MountFixture().identity(target: "/Volumes/GameShelf-test-other"),
   MountFixture().identity(source: "//other@gateway.example:445/gs_123-abc"),
   MountFixture().identity(source: "//private-user@evil.example:445/gs_123-abc"),
   MountFixture().identity(source: "//private-user@gateway.example:444/gs_123-abc"),
   MountFixture().identity(source: "//private-user@gateway.example:445/other"),
   MountFixture().identity(source: "//private-user:secret@gateway.example/gs_123-abc")
  ] {
   let f = MountFixture(); f.after = identity
   try rejects { _ = try NetworkLibraryMount.mount(share: fixtureShare, at: f.target, operations: f.operations) }
   try check(f.unmountCalls == 0, "Never clean up an unverified mount")
  }
  for paths in [[], ["/Volumes/GameShelf-test-other"], ["/Volumes/GameShelf-test", "/Volumes/extra"], ["/Volumes/GameShelf-test/../GameShelf-test"]] {
   let f = MountFixture(); f.resultPaths = paths
   try rejects { _ = try NetworkLibraryMount.mount(share: fixtureShare, at: f.target, operations: f.operations) }
  }
  let spoof = MountFixture(); spoof.after = nil
  try rejects { _ = try NetworkLibraryMount.mount(share: fixtureShare, at: spoof.target, operations: spoof.operations) }
  let failed = MountFixture(); failed.status = EACCES
  try rejects { _ = try NetworkLibraryMount.mount(share: fixtureShare, at: failed.target, operations: failed.operations) }
  let changed = MountFixture()
  var operations = changed.operations, inspections = 0
  operations.inspect = { _ in
   inspections += 1
   return .directory(device: 1, inode: inspections == 1 ? 2 : 3, owner: geteuid(), empty: true)
  }
  try rejects { _ = try NetworkLibraryMount.mount(share: fixtureShare, at: changed.target, operations: operations) }
  try check(changed.mountCalls == 0, "A replaced directory must fail before NetFS runs")
  let f = MountFixture()
  let mounted = try NetworkLibraryMount.mount(share: fixtureShare, at: f.target, operations: f.operations)
  f.state = .mounted(f.identity(serial: 99))
  try rejects { try NetworkLibraryMount.unmount(mounted, operations: f.operations) }
  f.state = .directory(device: 1, inode: 2, owner: geteuid(), empty: true)
  try rejects { try NetworkLibraryMount.unmount(mounted, operations: f.operations) }
  try NetworkLibraryMount.unmount(MountedLibraryShare(url: f.target, owned: false), operations: f.operations)
  try rejects { try NetworkLibraryMount.unmount(MountedLibraryShare(url: f.target, owned: true), operations: f.operations) }
  try check(f.unmountCalls == 0, "Unowned, forged, replaced and spoof-directory handles cannot unmount")
 }
 static func realTargetInspection() throws {
  let fm = FileManager.default
  // appendingPathComponent can fold /private/tmp back to the /tmp symlink.
  let root = URL(fileURLWithPath: "/private/tmp/NetworkLibraryMount-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? fm.removeItem(at: root) }
  let target = URL(fileURLWithPath: root.path + "/empty")
  try fm.createDirectory(at: target, withIntermediateDirectories: false)
  guard case .directory(_, _, let owner, let empty) = try NetworkLibraryMount.Operations.live.inspect(target) else {
   throw NSError(domain: "NetworkLibraryMountTests", code: 3)
  }
  try check(owner == geteuid() && empty, "Real empty target inspection")
  let file = URL(fileURLWithPath: target.path + "/occupied")
  try Data([1]).write(to: file)
  guard case .directory(_, _, _, let nowEmpty) = try NetworkLibraryMount.Operations.live.inspect(target) else {
   throw NSError(domain: "NetworkLibraryMountTests", code: 4)
  }
  try check(!nowEmpty, "Nonempty target must be identified")
  let link = URL(fileURLWithPath: root.path + "/link")
  try fm.createSymbolicLink(at: link, withDestinationURL: target)
  try rejects { _ = try NetworkLibraryMount.Operations.live.inspect(link) }
  try rejects { _ = try NetworkLibraryMount.Operations.live.inspect(URL(fileURLWithPath: link.path + "/nested")) }
  try rejects { _ = try NetworkLibraryMount.Operations.live.inspect(file) }
  try check(try NetworkLibraryMount.Operations.live.inspect(URL(fileURLWithPath: root.path + "/missing")) == .missing, "Missing final directory must be distinguished from unsafe traversal")
  for url in [URL(string: "https://example.com/target")!, URL(fileURLWithPath: "/"), URL(string: "file://otherhost/tmp/target")!] {
   try rejects { _ = try NetworkLibraryMount.mount(share: fixtureShare, at: url, operations: MountFixture().operations) }
  }
 }
 static func persistedRecovery() throws {
  let fm = FileManager.default
  let root = URL(fileURLWithPath: "/private/tmp/NetworkReceipt-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? fm.removeItem(at: root) }
  let file = URL(fileURLWithPath: root.path + "/owned.json"), key = "server/account/game"
  let f = MountFixture()
  let mounted = try NetworkLibraryMount.mount(share: fixtureShare, at: f.target, operations: f.operations)
  try rejects { try NetworkLibraryMount.persistReceipt(mounted: .init(url: f.target, owned: true), identityKey: key, to: file, operations: f.operations) }
  try check(!fm.fileExists(atPath: file.path), "Forged ownership must not create a recovery receipt")
  try NetworkLibraryMount.persistReceipt(mounted: mounted, identityKey: key, to: file, operations: f.operations)
  try NetworkLibraryMount.persistReceipt(mounted: mounted, identityKey: key, to: file, operations: f.operations)
  let original = try Data(contentsOf: file)
  try rejects { try NetworkLibraryMount.persistReceipt(mounted: mounted, identityKey: "other/account/game", to: file, operations: f.operations) }
  try check(original.count <= 8192 && !String(decoding: original, as: UTF8.self).contains(fixtureShare.password), "Receipt must be small and contain no password")
  try check((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Receipt must be mode 0600")
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  child.arguments = ["--recover-receipt", file.path]
  try child.run(); child.waitUntilExit()
  try check(child.terminationStatus == 0, "Receipt recovery must work in a genuinely fresh process")
  try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: "other/account/game", operations: f.operations) }
  try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: URL(fileURLWithPath: "/Volumes/other"), identityKey: key, operations: f.operations) }
  for identity in [f.identity(serial: 99), f.identity(type: "apfs"),
                   f.identity(source: "//other@gateway.example/gs_123-abc"),
                   f.identity(target: "/Volumes/other")] {
   f.state = .mounted(identity)
   try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) }
   try check(try Data(contentsOf: file) == original && f.unmountCalls == 0, "Identity mismatch must preserve receipt and never unmount")
  }
  f.state = .mounted(f.identity())
  for mode in [0o644, 0o400, 0o1600] {
   try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
   try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) }
  }
  try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  let alias = URL(fileURLWithPath: root.path + "/alias.json")
  try fm.createSymbolicLink(at: alias, withDestinationURL: file)
  try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: alias, target: f.target, identityKey: key, operations: f.operations) }
  let parentAlias = URL(fileURLWithPath: root.path + "-link")
  try fm.createSymbolicLink(at: parentAlias, withDestinationURL: root)
  defer { try? fm.removeItem(at: parentAlias) }
  try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: URL(fileURLWithPath: parentAlias.path + "/owned.json"), target: f.target, identityKey: key, operations: f.operations) }
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
  try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) }
  try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  let linked = URL(fileURLWithPath: root.path + "/hardlink.json")
  try fm.linkItem(at: file, to: linked)
  try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) }
  try fm.removeItem(at: linked)
  for invalid in [Data(repeating: 32, count: 8193), Data("{}".utf8)] {
   try invalid.write(to: file)
   try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) }
  }
  for field in ["version", "identityKey", "target", "fsid0", "source"] {
   var record = try JSONSerialization.jsonObject(with: original) as! [String: Any]
   if field == "version" { record[field] = 99 }
   else if field == "identityKey" { record[field] = "other/account/game" }
   else {
    var mount = record["mount"] as! [String: Any]
    mount[field] = field == "fsid0" ? 99 : (field == "target" ? "/Volumes/other" : "//other@gateway.example/gs_123-abc")
    record["mount"] = mount
   }
   try JSONSerialization.data(withJSONObject: record).write(to: file)
   try rejects { _ = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) }
  }
  try original.write(to: file)
  guard let recovered = try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) else {
   throw NSError(domain: "NetworkLibraryMountTests", code: 9)
  }
  try rejects { try NetworkLibraryMount.unmount(mounted, operations: f.operations) }
  f.unmountStatus = EBUSY
  try rejects { try NetworkLibraryMount.unmount(recovered, operations: f.operations) }
  try check(f.unmountCalls == 1 && fm.fileExists(atPath: file.path), "Busy recovered mount must preserve receipt without forced retry")
  f.unmountStatus = 0
  try NetworkLibraryMount.unmount(recovered, operations: f.operations)
  f.state = .directory(device: 1, inode: 2, owner: geteuid(), empty: true)
  try check(try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) == nil, "Unmounted target needs no adoption")
  try check(!fm.fileExists(atPath: file.path), "Stale receipt may be cleared only after the expected mount is absent")
  try check(try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) == nil, "Missing receipt means no recovery authority")
  // A newly verified mount can replace its own namespace's old receipt after
  // recovery + normal unmount, without granting authority over an existing mount.
  try original.write(to: file, options: .atomic)
  try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  f.after = f.identity(serial: 77)
  let fresh = try NetworkLibraryMount.mount(share: fixtureShare, at: f.target, operations: f.operations)
  try NetworkLibraryMount.persistReceipt(mounted: fresh, identityKey: key, to: file, operations: f.operations)
  try check(try Data(contentsOf: file) != original, "New owned mount must replace its namespace's stale receipt")
  f.state = .missing
  try check(try NetworkLibraryMount.recoverReceipt(at: file, target: f.target, identityKey: key, operations: f.operations) == nil, "Removed mountpoint is no longer mounted")
  try check(!fm.fileExists(atPath: file.path), "Missing target may clear its checked receipt")
 }
}
