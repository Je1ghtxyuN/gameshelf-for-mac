import Foundation

@main struct VisualNovelProbeTests {
 struct Failure: Error { let message: String }
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("VisualNovelProbeTests-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  var passed = 0, failed = 0
  func check(_ value: Bool, _ message: String) throws {
   if !value { throw Failure(message: message) }
  }
  func put(_ folder: URL, _ path: String, _ bytes: Data) throws {
   let file = folder.appendingPathComponent(path)
   try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
   try bytes.write(to: file)
  }
  func pack(_ version: String = "3.0") -> Data {
   Data(repeating: 0x5a, count: 17) + Data(("FilePackVer" + version).utf8) + Data(repeating: 0, count: 14)
  }
  let xp3 = Data([0x58, 0x50, 0x33, 0x0d, 0x0a, 0x20, 0x0a, 0x1a, 0x8b, 0x67, 0x01])
  func test(_ name: String, _ body: (URL) throws -> Void) {
   do {
    let folder = root.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try body(folder)
    passed += 1
    print("PASS \(name)")
   } catch {
    failed += 1
    print("FAIL \(name): \(error)")
   }
  }

  test("QLIE requires exact footer offset and version digits, not a pack extension") { folder in
   try put(folder, "GameData/data.pack", Data("ordinary unrelated pack".utf8))
   try check(VisualNovelProbe.engine(at: folder) == nil, "pack extension invented QLIE")
   for bytes in [pack("x.y"), pack() + Data([0]), Data("FilePackVer3.0".utf8), Data(repeating: 0, count: 28)] {
    try put(folder, "GameData/data.pack", bytes)
    try check(VisualNovelProbe.engine(at: folder) == nil, "malformed footer accepted")
   }
   try put(folder, "GameData/data.pack", pack())
   try check(VisualNovelProbe.engine(at: folder) == "QLIE", "valid QLIE footer missed")
   try put(folder, "GameData/data.pack", pack("2.1"))
   try check(VisualNovelProbe.engine(at: folder) == "QLIE", "valid alternate version missed")
  }
  test("QLIE probes only GameData directly, not arbitrary or recursive packs") { folder in
   try put(folder, "data.pack", pack())
   try put(folder, "Other/GameData/data.pack", pack())
   try put(folder, "GameData/nested/data.pack", pack())
   try check(VisualNovelProbe.engine(at: folder) == nil, "out of scope archive detected")
   try put(folder, "GameData/direct.PACK", pack())
   try check(VisualNovelProbe.engine(at: folder) == "QLIE", "case-insensitive archive extension missed")
  }
  test("CatSystem2 verifies four-byte KIF header at the start") { folder in
   try put(folder, "data.int", Data("not KIF".utf8))
   try put(folder, "nested/valid.int", Data([0x4b, 0x49, 0x46, 0]))
   try check(VisualNovelProbe.engine(at: folder) == nil, "int extension or nested archive invented engine")
   try put(folder, "data.int", Data([0x4b, 0x49, 0x46, 1]))
   try check(VisualNovelProbe.engine(at: folder) == nil, "wrong KIF terminator accepted")
   try put(folder, "data.int", Data([0x4b, 0x49, 0x46, 0]))
   try check(VisualNovelProbe.engine(at: folder) == "CatSystem2", "KIF signature missed")
  }
  test("KiriKiri verifies all eleven XP3 bytes in a direct regular file") { folder in
   try put(folder, "data.xp3", Data("XP3".utf8))
   try put(folder, "nested/good.xp3", xp3)
   try check(VisualNovelProbe.engine(at: folder) == nil, "truncated header or nested archive accepted")
   var wrong = xp3
   wrong[10] = 0
   try put(folder, "data.xp3", wrong)
   try check(VisualNovelProbe.engine(at: folder) == nil, "wrong eleventh magic byte accepted")
   try put(folder, "data.xp3", xp3)
   try check(VisualNovelProbe.engine(at: folder) == "KiriKiri", "valid XP3 header missed")
  }
  test("NScripter recognizes empty direct marker files without reading story data") { folder in
   for name in ["nscript.dat", "0.txt", "00.txt"] {
    try put(folder, name, Data())
    try check(VisualNovelProbe.engine(at: folder) == "NScripter / ONScripter", "marker \(name) missed")
    try fm.removeItem(at: folder.appendingPathComponent(name))
   }
   try put(folder, "nested/0.txt", Data())
   try fm.createDirectory(at: folder.appendingPathComponent("nscript.dat"), withIntermediateDirectories: false)
   try check(VisualNovelProbe.engine(at: folder) == nil, "directory or nested story marker accepted")
  }
  test("signature probes cap each candidate list at eight in deterministic name order") { folder in
   for kind in ["pack", "int", "xp3"] {
    let selected = folder.appendingPathComponent(kind)
    let base = kind == "pack" ? "GameData/" : ""
    // Reverse creation order: enumeration order must not choose the ninth file.
    for index in (0...8).reversed() {
     let bytes: Data = index == 8 ? (kind == "pack" ? pack() : (kind == "int" ? Data([0x4b, 0x49, 0x46, 0]) : xp3)) : Data()
     try put(selected, base + String(format: "%02d", index) + "." + kind, bytes)
    }
    try check(VisualNovelProbe.engine(at: selected) == nil, "read candidate nine for \(kind)")
    try fm.removeItem(at: selected.appendingPathComponent(base + "00." + kind))
    let expected = kind == "pack" ? "QLIE" : (kind == "int" ? "CatSystem2" : "KiriKiri")
    try check(VisualNovelProbe.engine(at: selected) == expected, "candidate eight not examined for \(kind)")
   }
  }
  test("external directory and file symlinks cannot supply signatures or markers") { folder in
   let outside = root.appendingPathComponent(UUID().uuidString)
   try put(outside, "GameData/valid.pack", pack())
   try put(outside, "valid.int", Data([0x4b, 0x49, 0x46, 0]))
   try put(outside, "valid.xp3", xp3)
   try put(outside, "0.txt", Data())
   try fm.createSymbolicLink(at: folder.appendingPathComponent("GameData"), withDestinationURL: outside.appendingPathComponent("GameData"))
   try fm.createSymbolicLink(at: folder.appendingPathComponent("data.int"), withDestinationURL: outside.appendingPathComponent("valid.int"))
   try fm.createSymbolicLink(at: folder.appendingPathComponent("data.xp3"), withDestinationURL: outside.appendingPathComponent("valid.xp3"))
   try fm.createSymbolicLink(at: folder.appendingPathComponent("0.txt"), withDestinationURL: outside.appendingPathComponent("0.txt"))
   try check(VisualNovelProbe.engine(at: folder) == nil, "external symlink detected an engine")
   try fm.removeItem(at: folder.appendingPathComponent("GameData"))
   try fm.createDirectory(at: folder.appendingPathComponent("GameData"), withIntermediateDirectories: false)
   try fm.createSymbolicLink(at: folder.appendingPathComponent("GameData/data.pack"), withDestinationURL: outside.appendingPathComponent("GameData/valid.pack"))
   try check(VisualNovelProbe.engine(at: folder) == nil, "external leaf pack symlink accepted")
   let alias = root.appendingPathComponent(UUID().uuidString)
   try fm.createSymbolicLink(at: alias, withDestinationURL: outside)
   try check(VisualNovelProbe.engine(at: alias) == nil, "selected symlink directory traversed")
  }
  test("large sparse QLIE archive uses its 64-bit footer offset") { folder in
   try put(folder, "GameData/data.pack", Data())
   let file = folder.appendingPathComponent("GameData/data.pack")
   let handle = try FileHandle(forWritingTo: file)
   defer { try? handle.close() }
   let length: UInt64 = 5 * 1024 * 1024 * 1024
   try handle.truncate(atOffset: length)
   try handle.seek(toOffset: length - 28)
   try handle.write(contentsOf: Data("FilePackVer3.0".utf8))
   try check(VisualNovelProbe.engine(at: folder) == "QLIE", "sparse archive footer missed")
  }
  test("auxiliary names are narrow and Japanese normalization is canonical") { _ in
   for name in ["エンジン設定.exe", "エンジン設定.exe".decomposedStringWithCanonicalMapping, "CS2CONF.EXE", "FileCheck.exe", "custom.exe", "設定.exe", "设置.exe", "環境設定.exe", "环境设置.exe", "config_jp.exe", "config64.exe", "config-tool.exe", "uninstall_game.exe", "uninstaller.exe", "setup.exe", "unins000.exe", "uninstall.exe", "UnityCrashHandler64.exe", "vc_redist.x64.exe"] {
    try check(VisualNovelProbe.isAuxiliaryExecutable(name), "helper retained: \(name)")
   }
   for name in ["ConfigurationStory.exe", "CustomAdventure.exe", "config_story.exe", "uninstallAdventure.exe", "设置冒险.exe", "設定物語.exe", "SetupAdventure.exe", "FileCheckerStory.exe", "エンジン設定物語.exe", "cs2conf_story.exe", "Story.exe", "FileCheck.txt"] {
    try check(!VisualNovelProbe.isAuxiliaryExecutable(name), "valid or ambiguous name filtered: \(name)")
   }
  }
  test("Chinese launch choices sort first while retaining Japanese and ambiguity") { _ in
   let input = ["日本語.exe", "Story.exe", "Novel_CHS.exe", "Novel_CN.exe", "Novel中文版.exe", "Novel汉化.exe", "Novel_sc.exe"]
   let output = VisualNovelProbe.orderedExecutables(input)
   try check(output.count == input.count && Set(output) == Set(input), "ordering discarded candidates")
   try check(Set(output.prefix(5)) == Set(input.suffix(5)), "Chinese suffixes were not prioritized")
   try check(output.contains("日本語.exe") && output.contains("Novel_CHS.exe") && output.contains("Novel_CN.exe"), "Japanese or second Chinese choice lost")
   let expected = Array(input.suffix(5)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
   try check(Array(output.prefix(5)) == expected, "same-priority names lack localized natural order")
  }
  test("language matching uses token boundaries and sorting ties preserve input order") { _ in
   let input = ["CNInside.exe", "scenery.exe", "disc.exe", "Game_sc.exe", "Game2.exe", "Game10.exe"]
   let ordered = VisualNovelProbe.orderedExecutables(input)
   try check(ordered.first == "Game_sc.exe", "suffix priority or generic substring matching is wrong")
   let ordinary = Array(input.prefix(3)) + Array(input.suffix(2))
   try check(Array(ordered.dropFirst()) == ordinary.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "generic names falsely prioritized")
   let ties = ["story.exe", "Story.exe", "story.exe"]
   let expected = ties.enumerated().sorted {
    let comparison = $0.element.localizedStandardCompare($1.element)
    return comparison == .orderedSame ? $0.offset < $1.offset : comparison == .orderedAscending
   }.map { $0.element }
   try check(VisualNovelProbe.orderedExecutables(ties) == expected, "equal sort keys or duplicate choices reordered")
  }
  print("VisualNovelProbe: \(passed) passed; \(failed) failed")
  if failed != 0 { exit(1) }
 }
}
