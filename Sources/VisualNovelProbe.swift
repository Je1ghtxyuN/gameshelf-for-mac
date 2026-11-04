import Foundation
import Darwin

/// Read-only hints, never compatibility certification. Lists the root once and
/// GameData at most once, without recursion. QLIE, CatSystem2, then KiriKiri take
/// precedence over NScripter markers. Each archive family examines at most eight
/// names in byte order: at most 232 bytes of archive content in total.
enum VisualNovelProbe {
 static func engine(at folder: URL) -> String? {
  guard folder.isFileURL else { return nil }
  let root = folder.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
  guard root >= 0 else { return nil }
  defer { Darwin.close(root) }
  guard let names = names(in: root) else { return nil }

  // Only this named direct child directory is inspected. openat anchors both
  // directory and leaf lookups to already-open parents, rejecting symlink swaps.
  if let gameData = names.filter({ $0.lowercased() == "gamedata" }).sorted(by: byteOrder).first {
   let directory = gameData.withCString { Darwin.openat(root, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
   if directory >= 0 {
    defer { Darwin.close(directory) }
    if let contents = self.names(in: directory) {
     for name in candidates(contents, extension: "pack") {
      if let signature = bytes(in: directory, name: name, count: 14, fromFooter: true), isQLIE(signature) {
       return "QLIE"
      }
     }
    }
   }
  }
  for name in candidates(names, extension: "int") {
   if bytes(in: root, name: name, count: 4) == [0x4b, 0x49, 0x46, 0] { return "CatSystem2" }
  }
  let xp3: [UInt8] = [0x58, 0x50, 0x33, 0x0d, 0x0a, 0x20, 0x0a, 0x1a, 0x8b, 0x67, 0x01]
  for name in candidates(names, extension: "xp3") {
   if bytes(in: root, name: name, count: 11) == xp3 { return "KiriKiri" }
  }
  for name in names where ["nscript.dat", "0.txt", "00.txt"].contains(name.lowercased()) {
   var info = stat()
   let result = name.withCString { Darwin.fstatat(root, $0, &info, AT_SYMLINK_NOFOLLOW) }
   if result == 0, isRegular(info) { return "NScripter / ONScripter" }
  }
  return nil
 }

 static func isAuxiliaryExecutable(_ name: String) -> Bool {
  let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
  guard normalized.hasSuffix(".exe") else { return false }
  let stem = String(normalized.dropLast(4))
  let exact: Set<String> = [
   "エンジン設定", "cs2conf", "filecheck", "config", "setup", "setup32", "setup64",
   "install", "installer", "unins", "uninstall", "dxsetup", "vcredist",
   "vcredist_x86", "vcredist_x64", "vc_redist.x86", "vc_redist.x64",
   "dotnet", "dotnetfx", "unitycrashhandler", "unitycrashhandler32",
   "unitycrashhandler64", "crashreport", "crashreporter"
  ]
  return exact.contains(stem) || stem.range(of: #"^(?:unins|uninstall)[0-9]+$"#, options: .regularExpression) != nil
 }

 /// Retains every candidate, including duplicate/ambiguous names. Equal natural
 /// sort keys retain caller order; generic embedded "cn" or "sc" is not a tag.
 static func orderedExecutables(_ names: [String]) -> [String] {
  let ranked = names.enumerated().map { (index: $0.offset, name: $0.element, chinese: chineseSuffix($0.element)) }
  return ranked.sorted {
   if $0.chinese != $1.chinese { return $0.chinese }
   let order = $0.name.localizedStandardCompare($1.name)
   return order == .orderedSame ? $0.index < $1.index : order == .orderedAscending
  }.map { $0.name }
 }

 private static func chineseSuffix(_ name: String) -> Bool {
  let normalized = name.precomposedStringWithCanonicalMapping.lowercased()
  let stem = normalized.hasSuffix(".exe") ? String(normalized.dropLast(4)) : normalized
  let english = #"(?:^|[_\- .\[\(【（])(?:cn|chs|sc|zh[_-]cn)[\]\)】）]*$"#
  let chinese = #"(?:中文版|汉化(?:版)?|漢化(?:版)?|简体中文(?:版)?|簡體中文(?:版)?)[\]\)】）]*$"#
  return stem.range(of: english, options: .regularExpression) != nil || stem.range(of: chinese, options: .regularExpression) != nil
 }

 private static func candidates(_ names: [String], extension suffix: String) -> ArraySlice<String> {
  names.filter { ($0 as NSString).pathExtension.lowercased() == suffix }.sorted(by: byteOrder).prefix(8)
 }

 private static func byteOrder(_ lhs: String, _ rhs: String) -> Bool {
  lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
 }

 private static func isRegular(_ info: stat) -> Bool {
  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
 }

 private static func isQLIE(_ bytes: [UInt8]) -> Bool {
  bytes.count == 14 && Array(bytes.prefix(11)) == Array("FilePackVer".utf8)
   && (48...57).contains(bytes[11]) && bytes[12] == 46 && (48...57).contains(bytes[13])
 }

 /// Uses pread rather than loading an archive, even for multi-gigabyte packs.
 /// The QLIE version signature starts exactly 28 bytes before EOF.
 private static func bytes(in parent: Int32, name: String, count: Int, fromFooter: Bool = false) -> [UInt8]? {
  guard (1...14).contains(count) else { return nil }
  let descriptor = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
  guard descriptor >= 0 else { return nil }
  defer { Darwin.close(descriptor) }
  var info = stat()
  guard Darwin.fstat(descriptor, &info) == 0, isRegular(info), info.st_size >= (fromFooter ? 28 : off_t(count)) else { return nil }
  let offset: off_t = fromFooter ? info.st_size - 28 : 0
  var result = [UInt8](repeating: 0, count: count)
  let length = result.withUnsafeMutableBytes { Darwin.pread(descriptor, $0.baseAddress, count, offset) }
  return length == count ? result : nil
 }

 /// Descriptor-relative traversal never reopens a child by an untrusted absolute
 /// path. dup shares only the enumeration offset; openat does not use that offset.
 private static func names(in descriptor: Int32) -> [String]? {
  let copy = Darwin.dup(descriptor)
  guard copy >= 0 else { return nil }
  guard let directory = Darwin.fdopendir(copy) else { Darwin.close(copy); return nil }
  defer { Darwin.closedir(directory) }
  var result: [String] = []
  while true {
   errno = 0
   guard let entry = Darwin.readdir(directory) else { return errno == 0 ? result : nil }
   let name = withUnsafePointer(to: &entry.pointee.d_name) {
    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
   }
   if let name, name != ".", name != ".." { result.append(name) }
  }
 }
}
