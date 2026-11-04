import Foundation
import CryptoKit
import Darwin
import AppKit

/// Ad-hoc identity for copied runtimes only. Never signs an existing published
/// cache, follows a resource link, or executes any copied program.
enum NativeAppIdentity {
 static let signingProfile = "local-adhoc-inside-out-v1"
 static let networkPurpose = "读取您选择的网络游戏库资源。"

 /// Read-only LaunchServices/OS inventory, including apps launched before this
 /// GameShelf process existed. Never activates, terminates or signs an app.
 static func runningApplication(at app: URL) -> NSRunningApplication? {
  guard app.isFileURL, let root = try? canonicalPath(app) else { return nil }
  return NSWorkspace.shared.runningApplications.first { candidate in
   guard !candidate.isTerminated else { return false }
   if let bundle = candidate.bundleURL, (try? canonicalPath(bundle)) == root { return true }
   if let executable = candidate.executableURL, let path = try? canonicalPath(executable) {
    return path.hasPrefix(root + "/")
   }
   return false
  }
 }
 static func isRunning(at app: URL) -> Bool { runningApplication(at: app) != nil }

 static func isMachO(_ file: URL) throws -> Bool {
  let handle = try FileHandle(forReadingFrom: file)
  defer { try? handle.close() }
  let bytes = Array(try handle.read(upToCount: 4) ?? Data())
  return [[0xfe,0xed,0xfa,0xce], [0xce,0xfa,0xed,0xfe],
          [0xfe,0xed,0xfa,0xcf], [0xcf,0xfa,0xed,0xfe],
          [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca],
          [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(bytes)
 }

 /// The cache builder invokes this only on its unpublished, newly copied stage.
 static func signStaged(_ app: URL, identifier: String, excluding: Set<String>) throws {
  guard app.lastPathComponent.hasPrefix(".preparing-"), app.pathExtension == "app" else {
   throw failure("只能签署新创建的临时缓存。")
  }
  let plan = try inventory(app, excluding: excluding)
  // Signing a bundle's main Mach-O by filename can still make codesign treat it
  // as its enclosing bundle. Leave each main executable for its bundle's turn,
  // after dylibs/helpers and all nested bundles are already sealed.
  let mains = try Set(([app] + plan.bundles).compactMap { try mainExecutable($0) })
  for file in plan.files where !mains.contains(file.path) {
   // Each leaf has a stable identifier, independent of the random stage name.
   let relative = String(file.path.dropFirst(plan.base.count))
   let suffix = SHA256.hash(data: Data(relative.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
   try codesign(["--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements",
                 "--identifier", identifier + ".code." + suffix, file.path])
  }
  for bundle in plan.bundles {
   let relative = String(bundle.path.dropFirst(plan.base.count))
   let suffix = SHA256.hash(data: Data(relative.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
   try codesign(["--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements",
                 "--identifier", identifier + ".bundle." + suffix, bundle.path])
  }
  try codesign(["--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements",
                "--identifier", identifier, app.path])
  try verify(app, identifier: identifier, excluding: excluding)
 }

 /// Read-only validation of every copied code object and the complete root seal.
 static func verify(_ app: URL, identifier: String, excluding: Set<String>) throws {
  let plan = try inventory(app, excluding: excluding)
  for code in plan.files + plan.bundles {
   try codesign(["--verify", "--all-architectures", "--strict=sideband", code.path])
  }
  // Full resource/code validation, but deliberately not strict=symlinks: known
  // payload symlinks point outside the bundle by design. inventory validates
  // all other links; NativeAppCache separately checks each payload destination.
  try codesign(["--verify", "--all-architectures", "--strict=sideband",
                "-R=identifier \"" + identifier + "\"", app.path])
 }

 private struct Plan { let base: String; let files: [URL]; let bundles: [URL] }
 private static func failure(_ text: String) -> LibraryError { LibraryError("本地原生缓存签名：" + text) }
 private static func canonicalPath(_ url: URL) throws -> String {
  guard let resolved = realpath(url.path, nil) else { throw failure("无法解析复制的运行库路径。") }
  defer { free(resolved) }
  return String(cString: resolved)
 }
 private static func mainExecutable(_ bundle: URL) throws -> String? {
  let fm = FileManager.default
  let plist = ["Contents/Info.plist", "Resources/Info.plist", "Info.plist"]
   .map { bundle.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
  guard let plist,
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
        let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
        name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { return nil }
  let executable = bundle.appendingPathComponent(bundle.pathExtension.lowercased() == "framework" ? name : "Contents/MacOS/" + name)
  return try canonicalPath(executable)
 }
 private static func inventory(_ app: URL, excluding: Set<String>) throws -> Plan {
  let fm = FileManager.default
  var filesystem: statfs = .init(), root = stat()
  guard lstat(app.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR,
        statfs(app.path, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
   throw failure("签名对象必须是本地普通目录。")
  }
  let canonical = try canonicalPath(app)
  var files: [URL] = [], bundles: [URL] = [], traversalError: Error?
  guard let walk = fm.enumerator(at: URL(fileURLWithPath: canonical).appendingPathComponent("Contents"), includingPropertiesForKeys: nil,
   errorHandler: { _, error in traversalError = error; return false }) else { throw failure("无法枚举复制的运行库。") }
  for case let file as URL in walk {
   guard file.path.hasPrefix(canonical + "/") else { throw failure("运行库枚举路径不安全。") }
   let relative = String(file.path.dropFirst(canonical.count + 1))
   var info = stat()
   guard lstat(file.path, &info) == 0 else { throw failure("无法检查复制的运行库。") }
   if excluding.contains(relative) {
    guard info.st_mode & S_IFMT == S_IFLNK else { throw failure("资源必须保留为链接。") }
    continue
   }
   switch info.st_mode & S_IFMT {
   case S_IFLNK:
    let resolved = try canonicalPath(file)
    guard resolved.hasPrefix(canonical + "/") else { throw failure("非资源链接超出了缓存。") }
   case S_IFREG:
    if try isMachO(file) {
     guard info.st_nlink == 1 else { throw failure("不能签署具有硬链接的代码。") }
     files.append(file)
    }
   case S_IFDIR:
    if ["app", "framework", "xpc", "appex", "bundle", "plugin"].contains(file.pathExtension.lowercased()) {
     bundles.append(file)
    }
   default: throw failure("运行库包含特殊文件。")
   }
   guard files.count + bundles.count <= 4096 else { throw failure("运行库代码对象过多。") }
  }
  if let traversalError { throw traversalError }
  // Nested bundles must be sealed only after their own contained code/bundles.
  let deepest: (URL, URL) -> Bool = { left, right in
   left.pathComponents.count == right.pathComponents.count ? left.path < right.path : left.pathComponents.count > right.pathComponents.count
  }
  return Plan(base: canonical, files: files.sorted(by: deepest), bundles: bundles.sorted(by: deepest))
 }

 private final class Output: @unchecked Sendable { var bytes = Data() }
 private static func codesign(_ arguments: [String]) throws {
  let process = Process(), pipe = Pipe(), output = Output()
  let drained = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
  process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = arguments
  process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
  process.terminationHandler = { _ in exited.signal() }
  DispatchQueue.global(qos: .utility).async {
   defer { try? pipe.fileHandleForReading.close(); drained.signal() }
   while let bytes = try? pipe.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty {
    if output.bytes.count < 4096 { output.bytes.append(bytes.prefix(4096 - output.bytes.count)) }
   }
  }
  defer { PreparationTasks.shared.finish(process) }
  do { try PreparationTasks.shared.run(process) }
  catch { try? pipe.fileHandleForWriting.close(); drained.wait(); throw error }
  try? pipe.fileHandleForWriting.close()
  guard exited.wait(timeout: .now() + 30) == .success else {
   if process.isRunning { process.terminate() }
   if exited.wait(timeout: .now() + 2) != .success, process.isRunning {
    Darwin.kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2)
   }
   throw failure("签名或校验超时，未发布缓存。")
  }
  drained.wait()
  guard process.terminationReason == .exit, process.terminationStatus == 0 else {
   throw failure("签名或完整性校验失败：" + String(decoding: output.bytes, as: UTF8.self))
  }
 }
}
