import Foundation

@main struct SharedWebSaveStoreTests {
 static let fm = FileManager.default
 static func child(_ root: URL, _ name: String) -> URL { URL(fileURLWithPath: root.path + "/" + name) }
 static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
  if try !value() { throw NSError(domain: "SharedWebSaveStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
 }
 static func rejects(_ body: () throws -> Void) throws {
  var failed = false
  do { try body() } catch { failed = true }
  try check(failed, "Unsafe or over-limit operation was accepted")
 }
 static func initializationRecovery(in root: URL) throws {
  let identity = "initialization/account/game"
  func fixture(_ name: String, phase: String?, store: Data? = nil, markerIdentity: String? = nil) throws -> URL {
   let profile = child(root, name), directory = child(profile, "WebKitMZ")
   try fm.createDirectory(at: directory, withIntermediateDirectories: true)
   var marker: [String: Any] = ["version": 1, "identity": markerIdentity ?? identity]
   if let phase { marker["phase"] = phase }
   try JSONSerialization.data(withJSONObject: marker).write(to: child(directory, "identity.json"))
   if let store { try store.write(to: child(directory, "store.json")) }
   return profile
  }
  func phase(_ profile: URL) throws -> String? {
   let bytes = try Data(contentsOf: child(profile, "WebKitMZ/identity.json"))
   return (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["phase"] as? String
  }
  // Crash after publishing the creating marker, before publishing any store.
  let missing = try fixture("creating-missing", phase: "creating")
  let recovered = try SharedWebSaveStore(profileRoot: missing, identity: identity)
  try check(try recovered.keys().isEmpty && phase(missing) == "ready", "Only uncommitted initialization may create an empty store")
  let emptySnapshot = try Data(contentsOf: child(missing, "WebKitMZ/store.json"))
  let emptyExisting = try fixture("creating-empty-existing", phase: "creating", store: emptySnapshot)
  try check(try SharedWebSaveStore(profileRoot: emptyExisting, identity: identity).keys().isEmpty && phase(emptyExisting) == "ready", "Already-published empty snapshot must finish initialization")
  try check(try Data(contentsOf: child(emptyExisting, "WebKitMZ/store.json")) == emptySnapshot, "Empty snapshot promotion must preserve bytes")
  try recovered.set("file1", value: "acknowledged after recovery")
  try check(try SharedWebSaveStore(profileRoot: missing, identity: identity).get("file1") == "acknowledged after recovery", "Recovered initialization must support normal persistence")
  let sourceFile = child(missing, "WebKitMZ/store.json"), snapshot = try Data(contentsOf: sourceFile)
  // Crash after a valid store was published, before the ready marker. Even a
  // nonempty valid snapshot must be preserved byte-for-byte and never replaced.
  let existing = try fixture("creating-existing", phase: "creating", store: snapshot)
  let existingFile = child(existing, "WebKitMZ/store.json")
  let inode = try fm.attributesOfItem(atPath: existingFile.path)[.systemFileNumber] as? NSNumber
  let promoted = try SharedWebSaveStore(profileRoot: existing, identity: identity)
  try check(try promoted.get("file1") == "acknowledged after recovery" && phase(existing) == "ready", "Creating with a valid snapshot must retain progress then mark ready")
  try check(try Data(contentsOf: existingFile) == snapshot && fm.attributesOfItem(atPath: existingFile.path)[.systemFileNumber] as? NSNumber == inode, "Promotion must not rewrite the snapshot or replace its inode")
  let readyMarker = try Data(contentsOf: child(existing, "WebKitMZ/identity.json"))
  _ = try SharedWebSaveStore(profileRoot: existing, identity: identity)
  try check(try Data(contentsOf: child(existing, "WebKitMZ/identity.json")) == readyMarker, "Ready reopen must not rewrite the marker")
  // A live handle must not serve a store whose marker is still creating.
  var creatingMarker: [String: Any] = ["version": 1, "identity": identity, "phase": "creating"]
  let creatingBytes = try JSONSerialization.data(withJSONObject: creatingMarker)
  try creatingBytes.write(to: child(existing, "WebKitMZ/identity.json"))
  try rejects { try promoted.set("file1", value: "not ready") }
  try rejects { _ = try promoted.get("file1") }
  try rejects { try promoted.clear() }
  try check(try Data(contentsOf: existingFile) == snapshot, "Uncommitted state must never allow normal writes")
  let corrupt = Data("{truncated".utf8)
  for (index, markerPhase) in [Optional("creating"), Optional("ready"), nil].enumerated() {
   let bad = try fixture("corrupt-init-\(index)", phase: markerPhase, store: corrupt)
   let marker = child(bad, "WebKitMZ/identity.json"), before = try Data(contentsOf: marker)
   try rejects { _ = try SharedWebSaveStore(profileRoot: bad, identity: identity) }
   try check(try Data(contentsOf: child(bad, "WebKitMZ/store.json")) == corrupt && Data(contentsOf: marker) == before, "Corrupt snapshots must survive init unchanged in every phase")
  }
  for (index, markerPhase) in [Optional("ready"), nil, Optional("unknown")].enumerated() {
   let established = try fixture("missing-established-\(index)", phase: markerPhase)
   let marker = child(established, "WebKitMZ/identity.json"), before = try Data(contentsOf: marker)
   try rejects { _ = try SharedWebSaveStore(profileRoot: established, identity: identity) }
   try check(!fm.fileExists(atPath: child(established, "WebKitMZ/store.json").path), "Ready/legacy/invalid markers must never recreate missing progress")
   try check(try Data(contentsOf: marker) == before, "Rejected initialization must preserve marker bytes")
  }
  for (index, saved) in [Optional<Data>.none, Optional(snapshot)].enumerated() {
   let wrong = try fixture("wrong-marker-\(index)", phase: "creating", store: saved, markerIdentity: "other-account")
   try rejects { _ = try SharedWebSaveStore(profileRoot: wrong, identity: identity) }
   try check(try phase(wrong) == "creating", "Wrong identity must never promote")
   if let saved { try check(try Data(contentsOf: child(wrong, "WebKitMZ/store.json")) == saved, "Wrong identity must retain snapshot") }
   else { try check(!fm.fileExists(atPath: child(wrong, "WebKitMZ/store.json").path), "Wrong identity must not create a snapshot") }
  }
  var foreignObject = try JSONSerialization.jsonObject(with: snapshot) as! [String: Any]
  foreignObject["identity"] = "other-account"
  let foreignSnapshot = try JSONSerialization.data(withJSONObject: foreignObject)
  let wrongSnapshot = try fixture("wrong-snapshot", phase: "creating", store: foreignSnapshot)
  try rejects { _ = try SharedWebSaveStore(profileRoot: wrongSnapshot, identity: identity) }
  try check(try phase(wrongSnapshot) == "creating" && Data(contentsOf: child(wrongSnapshot, "WebKitMZ/store.json")) == foreignSnapshot, "Correct marker with foreign snapshot must not reset or promote")
  let legacy = try fixture("legacy-valid", phase: nil, store: snapshot)
  let legacyMarker = try Data(contentsOf: child(legacy, "WebKitMZ/identity.json"))
  try check(try SharedWebSaveStore(profileRoot: legacy, identity: identity).get("file1") == "acknowledged after recovery", "Legacy nil phase must remain ready")
  try check(try Data(contentsOf: child(legacy, "WebKitMZ/identity.json")) == legacyMarker, "Valid legacy marker need not be migrated")
  let fresh = child(root, "fresh-ready"); try fm.createDirectory(at: fresh, withIntermediateDirectories: false)
  _ = try SharedWebSaveStore(profileRoot: fresh, identity: identity)
  try check(try phase(fresh) == "ready", "Fresh initialization must finish ready before returning")
  // Unknown phase is corrupt even with a valid snapshot (not legacy-ready).
  creatingMarker["phase"] = "unknown"
  try JSONSerialization.data(withJSONObject: creatingMarker).write(to: child(existing, "WebKitMZ/identity.json"))
  try rejects { _ = try SharedWebSaveStore(profileRoot: existing, identity: identity) }
  print("PASS initialization recovery: creating missing/existing, promotion preserves bytes/inode; ready/legacy missing/corrupt, unknown phase and wrong identity refuse reset")
 }
 static func main() throws {
  let root = URL(fileURLWithPath: "/private/tmp/SharedWebStoreTests-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  try initializationRecovery(in: root)
  func profile(_ name: String) throws -> URL {
   let path = child(root, name)
   try fm.createDirectory(at: path, withIntermediateDirectories: false)
   return path
  }
  let aRoot = try profile("alice"), bRoot = try profile("bob")
  let a = try SharedWebSaveStore(profileRoot: aRoot, identity: "server/alice/same-game")
  let b = try SharedWebSaveStore(profileRoot: bRoot, identity: "server/bob/same-game")
  let value = "\u{0}中文😀e\u{301}\u{ff}"
  try a.set("file1", value: value); try b.set("file1", value: "bob")
  try check(try a.get("file1").map { Data($0.utf8) } == Data(value.utf8), "String round trip must be lossless")
  try check(try b.get("file1") == "bob", "Accounts must be independent")
  let reopened = try SharedWebSaveStore(profileRoot: aRoot, identity: "server/alice/same-game")
  try check(try reopened.get("file1") == value, "Reopen must retain acknowledged saves")
  try a.set("é", value: "composed"); try a.set("e\u{301}", value: "decomposed")
  try check(try a.get("é") == "composed" && a.get("e\u{301}") == "decomposed", "Distinct UTF-8 keys must not collapse under Swift canonical equality")
  try a.set("../../outside/secret", value: "literal")
  try check(try a.get("../../outside/secret") == "literal" && !fm.fileExists(atPath: child(root, "outside").path), "Keys are data, never paths")
  try a.set("", value: "empty key")
  try check(try a.get("") == "empty key", "Empty logical key is valid")
  try a.remove("absent"); try a.remove("file1")
  try check(try a.get("file1") == nil, "Remove must persist")
  try rejects { _ = try SharedWebSaveStore(profileRoot: aRoot, identity: "server/bob/same-game") }
  let file = child(aRoot, "WebKitMZ/store.json")
  let stable = try Data(contentsOf: file)
  for action: () throws -> Void in [
   { try a.set(String(repeating: "k", count: 1025), value: "x") },
   { try a.set("too-big", value: String(repeating: "x", count: 4 * 1024 * 1024 + 1)) }
  ] {
   try rejects(action)
   try check(try Data(contentsOf: file) == stable, "Limit rejection must not change store bytes")
  }
  try Data("{broken".utf8).write(to: file)
  try rejects { _ = try a.get("anything") }
  try rejects { try a.clear() }
  try rejects { try a.set("new", value: "no reset") }
  try rejects { _ = try SharedWebSaveStore(profileRoot: aRoot, identity: "server/alice/same-game") }
  try check(try Data(contentsOf: file) == Data("{broken".utf8), "Corrupt state must be retained")
  try stable.write(to: file)
  try fm.removeItem(at: file)
  try rejects { _ = try SharedWebSaveStore(profileRoot: aRoot, identity: "server/alice/same-game") }
  try check(!fm.fileExists(atPath: file.path), "Missing store with existing identity must not reset")
  try stable.write(to: file)
  // A syntactically valid but invalid snapshot must also remain untouched.
  let duplicate = try JSONSerialization.data(withJSONObject: ["version": 1, "identity": "server/alice/same-game", "entries": [
   ["key": Data("dup".utf8).base64EncodedString(), "value": Data("a".utf8).base64EncodedString()],
   ["key": Data("dup".utf8).base64EncodedString(), "value": Data("b".utf8).base64EncodedString()]
  ]])
  try duplicate.write(to: file)
  try rejects { try a.remove("dup") }
  try check(try Data(contentsOf: file) == duplicate, "Duplicate keys must not be silently collapsed/reset")
  try stable.write(to: file)
  let marker = child(aRoot, "WebKitMZ/identity.json"), markerBytes = try Data(contentsOf: marker)
  let markerTarget = child(root, "marker-copy.json"); try markerBytes.write(to: markerTarget)
  try fm.removeItem(at: marker); try fm.createSymbolicLink(at: marker, withDestinationURL: markerTarget)
  try rejects { try a.clear() }
  try check(try Data(contentsOf: file) == stable, "Identity symlink refusal must preserve store")
  try fm.removeItem(at: marker); try markerBytes.write(to: marker)
  let hardLink = child(root, "hard-link.json")
  try fm.linkItem(at: file, to: hardLink)
  try rejects { try a.set("hard-link", value: "no") }
  try check(try Data(contentsOf: hardLink) == stable, "Hard-linked state must not be overwritten")
  try fm.removeItem(at: hardLink)
  let outside = child(root, "outside.json"); try Data("keep".utf8).write(to: outside)
  try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: outside)
  try rejects { try a.set("escape", value: "no") }
  try check(try Data(contentsOf: outside) == Data("keep".utf8), "Store link must never be followed")
  let link = child(root, "linked-profile")
  try fm.createSymbolicLink(at: link, withDestinationURL: bRoot)
  try rejects { _ = try SharedWebSaveStore(profileRoot: link, identity: "server/bob/same-game") }
  let linkedChild = try profile("linked-child")
  try fm.createSymbolicLink(at: child(linkedChild, "WebKitMZ"), withDestinationURL: child(bRoot, "WebKitMZ"))
  try rejects { _ = try SharedWebSaveStore(profileRoot: linkedChild, identity: "server/bob/same-game") }
  let countRoot = try profile("key-limit"), counts = try SharedWebSaveStore(profileRoot: countRoot, identity: "counts")
  for index in 0..<512 { try counts.set("key-\(index)", value: "x") }
  let countFile = child(countRoot, "WebKitMZ/store.json"), countBytes = try Data(contentsOf: countFile)
  try rejects { try counts.set("key-513", value: "x") }
  try check(try Data(contentsOf: countFile) == countBytes && counts.keys().count == 512, "Key count limit must be atomic")
  try counts.set("key-0", value: "replacement")
  let totalRoot = try profile("total-limit"), total = try SharedWebSaveStore(profileRoot: totalRoot, identity: "total")
  let chunk = String(repeating: "x", count: 4 * 1024 * 1024)
  // Total includes both key and value UTF-8 bytes, not just values.
  for index in 0..<7 { try total.set("chunk-\(index)", value: chunk) }
  try total.set("chunk-7", value: String(chunk.dropLast(8 * "chunk-0".utf8.count)))
  let totalFile = child(totalRoot, "WebKitMZ/store.json"), totalBytes = try Data(contentsOf: totalFile)
  try rejects { try total.set("overflow", value: "x") }
  try check(try Data(contentsOf: totalFile) == totalBytes, "Total size limit must not partially write")
  let handle = try FileHandle(forWritingTo: totalFile); try handle.truncate(atOffset: 64 * 1024 * 1024); try handle.close()
  try rejects { _ = try total.keys() }
  try b.clear()
  try check(try b.keys().isEmpty, "Clear must persist")
  try check(try SharedWebSaveStore(profileRoot: bRoot, identity: "server/bob/same-game").keys().isEmpty, "Clear must survive reopen")
  let vanished = child(bRoot, "WebKitMZ"), moved = child(root, "disconnected-store")
  try fm.moveItem(at: vanished, to: moved)
  try rejects { _ = try b.get("file1") }; try rejects { try b.set("file1", value: "never local") }
  try check(!fm.fileExists(atPath: vanished.path), "Unavailable profile must never get recreated by an operation")
  print("PASS SharedWebSaveStore: account partition/reopen, lossless strings, identity/corruption/link refusal, literal keys, all limits, atomic rejection and durable clear")
 }
}
