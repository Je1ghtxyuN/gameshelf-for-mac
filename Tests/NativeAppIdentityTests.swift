import Foundation
import CryptoKit

@main struct NativeAppIdentityTests {
 static let fm = FileManager.default
 static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw LibraryError("FAIL native identity: " + message) }
 }
 @discardableResult static func command(_ executable: String, _ arguments: [String], succeeds: Bool = true) throws -> String {
  let process = Process(), pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
  process.standardOutput = pipe; process.standardError = pipe
  try process.run()
  let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  process.waitUntilExit()
  if succeeds && process.terminationStatus != 0 { throw LibraryError("Fixture command failed: " + output) }
  return output
 }
 static func write(_ url: URL, _ data: Data) throws {
  try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url)
 }
 static func fingerprint(_ url: URL) throws -> String {
  SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
 }
 static func main() throws {
  let base = URL(fileURLWithPath: "/private/tmp/NativeIdentityTests-" + UUID().uuidString)
  try fm.createDirectory(at: base, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: base) }
  let source = base.appendingPathComponent("Fixture.app"), root = base.appendingPathComponent("Local")
  let main = source.appendingPathComponent("Contents/MacOS/engine")
  let dylib = source.appendingPathComponent("Contents/MacOS/libfixture.dylib")
  let nested = source.appendingPathComponent("Contents/PlugIns/Helper.bundle")
  let nestedMain = nested.appendingPathComponent("Contents/MacOS/helper")
  let code = base.appendingPathComponent("fixture.c")
  try write(code, Data("int main(void) { return 0; }".utf8))
  for output in [main, nestedMain] {
   try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
   let architectures = output == main ? ["-arch", "arm64", "-arch", "x86_64"] : []
   try command("/usr/bin/clang", architectures + [code.path, "-o", output.path])
  }
  try command("/usr/bin/lipo", [main.path, "-verify_arch", "arm64", "x86_64"])
  try command("/usr/bin/clang", ["-dynamiclib", code.path, "-o", dylib.path])
  for (app, executable, id, kind) in [(source, "engine", "fixture.original", "APPL"), (nested, "helper", "fixture.helper", "BNDL")] {
   let plist = ["CFBundleExecutable": executable, "CFBundleIdentifier": id, "CFBundleName": executable, "CFBundlePackageType": kind]
   try write(app.appendingPathComponent("Contents/Info.plist"), PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
  }
  let payload = source.appendingPathComponent("Contents/Resources/autorun/game")
  try write(source.appendingPathComponent("Contents/Resources/autorun/renpy/vc_version.py"), Data("version = '8.3'".utf8))
  // A Mach-O in the excluded payload must never be signed, even as nested code.
  try fm.createDirectory(at: payload, withIntermediateDirectories: true)
  let payloadCode = payload.appendingPathComponent("unsigned-payload")
  try fm.copyItem(at: main, to: payloadCode)
  let nestedResource = nested.appendingPathComponent("Contents/Resources/note.txt")
  try write(nestedResource, Data("nested sealed resource".utf8))
  let originals = try [main, dylib, nestedMain, payloadCode, source.appendingPathComponent("Contents/Info.plist")].map { ($0, try fingerprint($0)) }
  let game = Game(title: "Synthetic identity", folder: source.path, originalFolder: source.path, entry: Candidate(path: ".", backend: .native, engine: "macOS"))
  // Finder/resource-fork metadata on copied runtimes must not block signing.
  // The payload is deliberately linked outside the stage and must remain untouched.
  let dirtyStage = base.appendingPathComponent(".preparing-metadata.app")
  try fm.copyItem(at: source, to: dirtyStage)
  let stagedPayload = dirtyStage.appendingPathComponent("Contents/Resources/autorun/game")
  try fm.removeItem(at: stagedPayload)
  try fm.createSymbolicLink(atPath: stagedPayload.path, withDestinationPath: payload.path)
  let dirtyMain = dirtyStage.appendingPathComponent("Contents/MacOS/engine")
  try command("/usr/bin/xattr", ["-w", "com.apple.ResourceFork", "copied metadata", dirtyMain.path])
  try command("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", "5445585454455354000000000000000000000000000000000000000000000000", dirtyStage.path])
  try command("/usr/bin/xattr", ["-w", "com.apple.ResourceFork", "source payload metadata", payloadCode.path])
  try command("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", "5445585454455354000000000000000000000000000000000000000000000000", payload.path])
  let payloadDirectoryMetadata = try command("/usr/bin/xattr", ["-px", "com.apple.FinderInfo", payload.path])
  let payloadMetadata = try command("/usr/bin/xattr", ["-px", "com.apple.ResourceFork", payloadCode.path])
  try NativeAppIdentity.signStaged(dirtyStage, identifier: "fixture.original", excluding: ["Contents/Resources/autorun/game"])
  try check(!(try command("/usr/bin/xattr", [dirtyMain.path])).contains("com.apple.ResourceFork"), "copied code resource fork must be removed")
  try check(!(try command("/usr/bin/xattr", [dirtyStage.path])).contains("com.apple.FinderInfo"), "copied bundle FinderInfo must be removed")
  try check(try command("/usr/bin/xattr", ["-px", "com.apple.ResourceFork", payloadCode.path]) == payloadMetadata, "metadata cleanup must not traverse payload links")
  try check(try command("/usr/bin/xattr", ["-px", "com.apple.FinderInfo", payload.path]) == payloadDirectoryMetadata, "strict verification must not clean the linked payload directory")
  let first = try NativeAppCache.prepare(game: game, root: root)
  let identifier = "local.gameshelf.native." + game.id.uuidString.lowercased()
  try command("/usr/bin/codesign", ["--verify", "--all-architectures", "-R=identifier \"" + identifier + "\"", first.app.path])
  let detail = try command("/usr/bin/codesign", ["-d", "--verbose=4", first.app.path])
  try check(detail.contains("Identifier=" + identifier) && !detail.contains("Info.plist=not bound") && !detail.contains("Sealed Resources=none"), "root must bind identifier, plist and resources")
  for relative in ["Contents/MacOS/libfixture.dylib", "Contents/PlugIns/Helper.bundle", "Contents/PlugIns/Helper.bundle/Contents/MacOS/helper"] {
   try command("/usr/bin/codesign", ["--verify", "--all-architectures", first.app.appendingPathComponent(relative).path])
  }
  let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: first.app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
  try check(!(info["NSNetworkVolumesUsageDescription"] as? String ?? "").isEmpty, "network volume access needs an honest purpose string")
  let receipt = root.appendingPathComponent("NativeApps/" + game.id.uuidString + ".json")
  let record = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
  try check(!(record["cachedSignedFingerprint"] as? String ?? "").isEmpty && !(record["signingProfile"] as? String ?? "").isEmpty, "receipt must distinguish source and signed cache")
  let cachedMain = first.app.appendingPathComponent("Contents/MacOS/engine")
  // Separating sideband inspection must retain full root AND nested resource
  // seals, and verification must reject dirty copied nodes without cleaning.
  let copiedResource = first.app.appendingPathComponent("Contents/Resources/autorun/renpy/vc_version.py")
  let copiedResourceModified = try fm.attributesOfItem(atPath: copiedResource.path)[.modificationDate] as! Date
  try command("/usr/bin/xattr", ["-w", "com.apple.ResourceFork", "invalid copied resource metadata", copiedResource.path])
  var metadataRejected = false
  do { try NativeAppIdentity.verify(first.app, identifier: identifier, excluding: ["Contents/Resources/autorun/game"]) }
  catch { metadataRejected = true }
  try check(metadataRejected, "verification must reject copied resource sideband data")
  try check(try command("/usr/bin/xattr", [copiedResource.path]).contains("com.apple.ResourceFork"), "verification must not clean existing cache metadata")
  try command("/usr/bin/xattr", ["-d", "com.apple.ResourceFork", copiedResource.path])
  try fm.setAttributes([.modificationDate: copiedResourceModified], ofItemAtPath: copiedResource.path)
  for resource in [copiedResource, first.app.appendingPathComponent("Contents/PlugIns/Helper.bundle/Contents/Resources/note.txt")] {
   let bytes = try Data(contentsOf: resource)
   let modified = try fm.attributesOfItem(atPath: resource.path)[.modificationDate] as! Date
   try Data("tampered sealed resource".utf8).write(to: resource)
   var resourceRejected = false
   do { try NativeAppIdentity.verify(first.app, identifier: identifier, excluding: ["Contents/Resources/autorun/game"]) }
   catch { resourceRejected = true }
   try check(resourceRejected, "full resource verification must reject root/nested resource tampering")
   try bytes.write(to: resource)
   try fm.setAttributes([.modificationDate: modified], ofItemAtPath: resource.path)
  }
  try NativeAppIdentity.verify(first.app, identifier: identifier, excluding: ["Contents/Resources/autorun/game"])
  let attributes = try fm.attributesOfItem(atPath: cachedMain.path)
  let receiptBytes = try Data(contentsOf: receipt)
  var reuseChecks = 0
  let second = try NativeAppCache.prepare(game: game, root: root, runningCheck: { _ in reuseChecks += 1; return true })
  try check(reuseChecks == 0, "valid reuse must not enter the rebuild/running guard")
  try check(second.app == first.app, "reuse stable cache path")
  try check(try fm.attributesOfItem(atPath: cachedMain.path)[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber, "reuse must preserve executable inode")
  try check(try fm.attributesOfItem(atPath: cachedMain.path)[.modificationDate] as? Date == attributes[.modificationDate] as? Date, "reuse must not re-sign")
  try check(try command("/usr/bin/codesign", ["-d", "--verbose=4", second.app.path]) == detail, "reuse must preserve CDHash and signing metadata")
  try check(try Data(contentsOf: receipt) == receiptBytes, "reuse must not rewrite receipt")
  // A receipt from before the signing upgrade also requests a rebuild even
  // with an unchanged source. It must not move a still-running legacy cache.
  var legacy = record
  legacy.removeValue(forKey: "cachedSignedFingerprint"); legacy.removeValue(forKey: "signingProfile")
  let legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
  try legacyBytes.write(to: receipt, options: .atomic)
  let upgradeChildren = Set(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("NativeApps").path))
  var upgradeRejected = false, upgradeChecks = 0
  do { _ = try NativeAppCache.prepare(game: game, root: root, runningCheck: { _ in upgradeChecks += 1; return true }) }
  catch { upgradeRejected = true }
  try check(upgradeRejected && upgradeChecks == 1, "running cache must block signing-receipt upgrade before staging")
  try check(try Data(contentsOf: receipt) == legacyBytes, "blocked upgrade must preserve legacy receipt bytes")
  try check(try fm.attributesOfItem(atPath: cachedMain.path)[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber, "blocked upgrade must preserve executable inode")
  try check(try command("/usr/bin/codesign", ["-d", "--verbose=4", first.app.path]) == detail, "blocked upgrade must preserve signature")
  try check(try Set(fm.contentsOfDirectory(atPath: root.appendingPathComponent("NativeApps").path)) == upgradeChildren, "blocked upgrade must not leave backups or staging")
  try receiptBytes.write(to: receipt, options: .atomic)
  for (url, hash) in originals { try check(try fingerprint(url) == hash, "signing changed source or linked payload") }
  let linkTarget = URL(fileURLWithPath: try fm.destinationOfSymbolicLink(atPath: first.app.appendingPathComponent("Contents/Resources/autorun/game").path))
  try check(linkTarget.resolvingSymlinksInPath() == payload.resolvingSymlinksInPath(), "payload stays a source link")
  for protected in [source, first.app] {
   var rejected = false
   do { try NativeAppIdentity.signStaged(protected, identifier: identifier, excluding: ["Contents/Resources/autorun/game"]) }
   catch { rejected = true }
   try check(rejected, "signer must refuse source and published cache paths")
  }
  try write(payload.appendingPathComponent("changed-resource.txt"), Data("payload remains remote".utf8))
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try fm.attributesOfItem(atPath: cachedMain.path)[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber, "payload-only change must not rebuild signed runtime")
  try check(try command("/usr/bin/codesign", ["-d", "--verbose=4", first.app.path]) == detail, "payload-only change must not alter CDHash")
  // Info.plist is excluded from the runtime snapshot but must still be protected
  // by the root signature. A cached plist edit must fail reuse verification.
  let cachedPlist = first.app.appendingPathComponent("Contents/Info.plist")
  var tampered = info; tampered["NSNetworkVolumesUsageDescription"] = "tampered"
  try PropertyListSerialization.data(fromPropertyList: tampered, format: .xml, options: 0).write(to: cachedPlist, options: .atomic)
  _ = try NativeAppCache.prepare(game: game, root: root)
  try check(try fm.attributesOfItem(atPath: cachedMain.path)[.systemFileNumber] as? NSNumber != attributes[.systemFileNumber] as? NSNumber, "signature validation must reject a changed cached plist")
  try command("/usr/bin/codesign", ["--verify", "--all-architectures", first.app.path])
  try check(try command("/usr/bin/xattr", ["-px", "com.apple.FinderInfo", payload.path]) == payloadDirectoryMetadata, "all rebuilds must preserve linked payload directory metadata")
  let beforeSourceChange = try fm.attributesOfItem(atPath: cachedMain.path)[.systemFileNumber] as? NSNumber
  try write(source.appendingPathComponent("Contents/Resources/autorun/renpy/new.py"), Data("source change".utf8))
  let beforeRebuild = try Data(contentsOf: receipt)
  let beforeCode = try fingerprint(cachedMain)
  let cacheRoot = root.appendingPathComponent("NativeApps")
  let beforeChildren = Set(try fm.contentsOfDirectory(atPath: cacheRoot.path))
  func assertPreserved(_ label: String) throws {
   try check(try Data(contentsOf: receipt) == beforeRebuild, label + ": receipt changed")
   try check(try fingerprint(cachedMain) == beforeCode, label + ": executable changed")
   try check(try fm.attributesOfItem(atPath: cachedMain.path)[.systemFileNumber] as? NSNumber == beforeSourceChange, label + ": executable inode changed")
   try check(try Set(fm.contentsOfDirectory(atPath: cacheRoot.path)) == beforeChildren, label + ": backup/staging debris created")
  }
  var rejected = false, checks = 0
  do {
   _ = try NativeAppCache.prepare(game: game, root: root, runningCheck: { target in
    checks += 1
    try! check(target.standardizedFileURL == first.app.standardizedFileURL, "guard must inspect the exact existing cache")
    return true
   })
  } catch { rejected = true }
  try check(rejected && checks == 1, "running old cache must fail before staging")
  try assertPreserved("running before staging")
  rejected = false; checks = 0
  do {
   _ = try NativeAppCache.prepare(game: game, root: root, runningCheck: { _ in checks += 1; return checks == 2 })
  } catch { rejected = true }
  try check(rejected && checks == 2, "app starting during preparation must fail before publication")
  try assertPreserved("running before publication")
  checks = 0
  _ = try NativeAppCache.prepare(game: game, root: root, runningCheck: { _ in checks += 1; return false })
  try check(checks == 2, "stopped old cache must pass both OS checks")
  try check(try fm.attributesOfItem(atPath: cachedMain.path)[.systemFileNumber] as? NSNumber != beforeSourceChange, "source runtime change rebuilds rather than re-signing the old cache")
  try command("/usr/bin/codesign", ["--verify", "--all-architectures", first.app.path])
  print("PASS NativeAppIdentity: real signatures; stable reuse; source/payload protection; running-cache refusal before staging/publication; stopped-cache refresh")
 }
}
