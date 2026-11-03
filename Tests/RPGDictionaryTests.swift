import Foundation
import Darwin

private func check(_ value:Bool,_ message:String) throws {
 if !value {throw LibraryError("TEST: "+message)}
}
private func rejects(_ message:String,_ work:() throws -> Void) throws {
 do {try work()} catch {return}
 throw LibraryError("TEST: expected rejection: "+message)
}

private final class Fixture {
 let fm=FileManager.default
 let root:URL,source:URL,data:URL,tools:URL
 var game:Game
 let appendCode:String
 init() throws {
  let temporary=fm.temporaryDirectory.path
  root=URL(fileURLWithPath:temporary.hasPrefix("/var/") ? "/private"+temporary:temporary).appendingPathComponent("RPGDictionary-tests-"+UUID().uuidString)
  source=root.appendingPathComponent("NAS 合成 source")
  data=root.appendingPathComponent("Private data")
  tools=root.appendingPathComponent("Tools")
  game=Game(title:"synthetic",folder:source.path,originalFolder:source.path,entry:Candidate(path:"Game.exe",backend:.wine,engine:"RPG Maker VX Ace"))
  let bundledTools=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools")
  appendCode=try String(contentsOf:bundledTools.appendingPathComponent("append_rgss3a.py"),encoding:.utf8)
  try fm.createDirectory(at:tools,withIntermediateDirectories:true)
  try fm.copyItem(at:bundledTools.appendingPathComponent("prepare_rgss_dictionary.rb"),to:tools.appendingPathComponent("prepare_rgss_dictionary.rb"))
  try restoreAppend()
  try put("Game.exe",Data("MZ synthetic, never executed".utf8))
  try put("Game.ini",Data("[Game]\r\nScripts=Data\\Scripts.rvdata2\r\n".utf8))
  try put("翻译文件.json",Data("{\"SYNTHETIC\":\"TRANSLATED\"}".utf8))
  try put("Game.rgss3a",Self.archive())
  try put("Save01.rvdata2",Data("root original save".utf8))
  try put("Save/slot.dat",Data("nested original save".utf8))
  try put("Saves/deep/slot.dat",Data("other original save".utf8))
  try put("Fonts/Original.ttf",Data("synthetic font".utf8))
  try put("Tool/loaders/unifont-all.ttf",Data("synthetic unifont".utf8))
  try put("Audio/sound.ogg",Data("synthetic resource".utf8))
  try put("System/RGSS301.dll",Data("synthetic, never loaded".utf8))
  try put("System/window",Data([4,8,105,9])) // Opaque synthetic setting; never decoded.
 }
 deinit {try? fm.removeItem(at:root)}
 var home:URL {data.appendingPathComponent("Adapters/"+game.id.uuidString)}
 var play:URL {home.appendingPathComponent("Play")}
 var assets:URL {home.appendingPathComponent("Assets")}
 func put(_ name:String,_ bytes:Data) throws {
  let path=source.appendingPathComponent(name)
  try fm.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
  try bytes.write(to:path)
 }
 func restoreAppend() throws {
  let counted="from pathlib import Path\nimport sys\nsys.stderr = Path(__file__).with_name('append.error').open('w')\nwith Path(__file__).with_name('append.count').open('a') as count:\n    count.write('run\\n')\n"
  try (counted+appendCode).write(to:tools.appendingPathComponent("append_rgss3a.py"),atomically:true,encoding:.utf8)
 }
 func count() -> Int {(try? String(contentsOf:tools.appendingPathComponent("append.count"),encoding:.utf8).split(separator:"\n").count) ?? 0}
 func prepare() throws -> Game {
  do {return try RPGDictionary.prepareIfNeeded(game:game,dataRoot:data,tools:tools)}
  catch {
   if let diagnostic=try? String(contentsOf:tools.appendingPathComponent("append.error"),encoding:.utf8),!diagnostic.isEmpty {print("Synthetic append diagnostic: "+diagnostic)}
   throw error
  }
 }
 static func archive() -> Data {
  // One synthetic index entry with opaque arbitrary ciphertext, not Ruby data.
  let name=Array("Data\\Scripts.rvdata2".utf8),key:UInt32=57
  var out=Data([82,71,83,83,65,68,0,3])
  func word(_ value:UInt32){var little=value.littleEndian;withUnsafeBytes(of:&little){out.append(contentsOf:$0)}}
  word(6)
  for v in [UInt32(12+16+name.count+16),UInt32(17),UInt32(123),UInt32(name.count)] {word(v ^ key)}
  for (i,v) in name.enumerated(){out.append(v ^ UInt8((key >> (8*(i%4))) & 255))}
  for _ in 0..<4 {word(key)}
  out.append(Data(repeating:0x55,count:17))
  return out
 }
}

@main struct RPGDictionaryTests {
 static func main() throws {
  try eligibility()
  try cacheAndSaves()
  try iniSettings()
  try systemSettings()
  try systemMigrationAndProtection()
  try failedCache()
  try protections()
  try storagePolicy()
  try executionSafety()
  print("PASS: 9 RPG dictionary suites: eligibility, cache/saves, INI settings, private System/window, System migration/protection, failures, paths, volumes, timeout/concurrency")
 }
 static func eligibility() throws {
  let f=try Fixture()
  var other=f.game;other.entry.engine="KiriKiri"
  try check(try RPGDictionary.prepareIfNeeded(game:other,dataRoot:f.data,tools:f.tools).folder==other.folder,"other engine changed")
  try f.put("Game.rgss3a",Data("RGSSAD\0\u{1}".utf8))
  try check(try f.prepare().folder==f.game.folder,"non-v3 archive changed")
  try f.put("Game.rgss3a",Fixture.archive())
  try f.fm.removeItem(at:f.source.appendingPathComponent("翻译文件.json"))
  try check(try f.prepare().folder==f.game.folder,"missing dictionary changed")
  try check(!f.fm.fileExists(atPath:f.data.path),"ineligible game wrote private data")
 }
 static func cacheAndSaves() throws {
  let f=try Fixture()
  let sourceArchive=try Data(contentsOf:f.source.appendingPathComponent("Game.rgss3a"))
  let first=try f.prepare()
  try check(first.folder==f.play.path,"eligible game did not use stable Play")
  try check(first.id==f.game.id && first.entry==f.game.entry && first.originalFolder==f.game.originalFolder && f.game.folder==f.source.path,"library metadata changed")
  try check(first.windowSize==nil,"follow-game nil setting was overridden")
  let archive=f.play.appendingPathComponent("Game.rgss3a")
  let target=archive.resolvingSymlinksInPath()
  try check(target.deletingLastPathComponent().path==f.assets.resolvingSymlinksInPath().path,"archive points outside OWN Assets")
  try check(f.count()==1,"initial cache not built once")
  let cacheTime=try f.fm.attributesOfItem(atPath:target.path)[.modificationDate] as! Date
  for path in ["Save01.rvdata2","Save/slot.dat","Saves/deep/slot.dat"] {
   let local=f.play.appendingPathComponent(path)
   try check((try? f.fm.destinationOfSymbolicLink(atPath:local.path))==nil,"save is a symlink")
   try Data("LOCAL PROGRESS".utf8).write(to:local)
  }
  try check((try? f.fm.destinationOfSymbolicLink(atPath:f.play.appendingPathComponent("Fonts").path))==nil,"Fonts directory linked to source")
  try check(try f.fm.destinationOfSymbolicLink(atPath:f.play.appendingPathComponent("Fonts/unifont-all.ttf").path)==f.source.appendingPathComponent("Tool/loaders/unifont-all.ttf").path,"missing included font reference")
  let generator=f.tools.appendingPathComponent("prepare_rgss_dictionary.rb")
  var code=try String(contentsOf:generator,encoding:.utf8)
  code += "\nFile.open(File.join(target,'GameShelfAdapter.rb'),'a') {|f| f.puts('# own adapter update')}\n"
  try code.write(to:generator,atomically:true,encoding:.utf8)
  f.game.windowSize="960x540"
  try check(try f.prepare().windowSize=="960x540","explicit window size lost")
  try check(f.count()==1,"adapter-only edit rebuilt large archive")
  try f.put("Save02.rvdata2",Data("later source save".utf8))
  f.game.windowSize=nil
  try check(try f.prepare().windowSize==nil,"reset to follow-game was overridden")
  try check(!f.fm.fileExists(atPath:f.play.appendingPathComponent("Save02.rvdata2").path),"source saves were seeded again")
  try check(try f.fm.attributesOfItem(atPath:target.path)[.modificationDate] as? Date == cacheTime,"cache was rewritten")
  try check(try String(contentsOf:f.play.appendingPathComponent("GameShelfAdapter.rb"),encoding:.utf8).contains("Unifont Smooth"),"wrong font family")
  for path in ["Save01.rvdata2","Save/slot.dat","Saves/deep/slot.dat"] {
   try check(try Data(contentsOf:f.play.appendingPathComponent(path))==Data("LOCAL PROGRESS".utf8),"existing save overwritten")
  }
  try check(try Data(contentsOf:f.source.appendingPathComponent("Save01.rvdata2"))==Data("root original save".utf8),"source save modified")
  try check(try Data(contentsOf:f.source.appendingPathComponent("Game.rgss3a"))==sourceArchive,"source archive modified")
  try f.put("翻译文件.json",Data("{\"SYNTHETIC\":\"CHANGED\"}".utf8))
  _ = try f.prepare()
  try check(f.count()==2 && archive.resolvingSymlinksInPath() != target,"dictionary change reused stale cache")
  try f.fm.setAttributes([.modificationDate:Date(timeIntervalSinceNow:20)],ofItemAtPath:f.source.appendingPathComponent("Game.rgss3a").path)
  _ = try f.prepare()
  try check(f.count()==3,"archive mtime did not invalidate cache")
 }
 static func iniSettings() throws {
  let f=try Fixture();_ = try f.prepare()
  let path=f.play.appendingPathComponent("Game.ini")
  let sourceINI=try Data(contentsOf:f.source.appendingPathComponent("Game.ini"))
  for gameSection in ["[Game]\r\nScripts=Data\\Scripts.rvdata2\r\n", "[Game]\r\n", ""] {
   let prefix=Data("; user settings\r\n".utf8)
   let suffix=Data("[AudioVol]\r\nBGM=33\r\n[Other]\r\nScripts=keep-me\r\n; legacy bytes: ".utf8)+Data([0x82,0xa0,13,10])
   try (prefix+Data(gameSection.utf8)+suffix).write(to:path)
   _ = try f.prepare()
   let updated=try Data(contentsOf:path)
   try check(updated.range(of:suffix) != nil,"user AudioVol BGM=33 or other INI bytes lost")
   try check(updated.range(of:Data("Scripts=GameShelfBootstrap.rvdata2".utf8)) != nil,"bootstrap Scripts not repaired")
   let timestamp=try f.fm.attributesOfItem(atPath:path.path)[.modificationDate] as! Date
   _ = try f.prepare()
   try check(try Data(contentsOf:path)==updated,"second INI repair was not idempotent")
   try check(try f.fm.attributesOfItem(atPath:path.path)[.modificationDate] as? Date == timestamp,"unchanged INI was rewritten")
  }
  try check(try Data(contentsOf:f.source.appendingPathComponent("Game.ini"))==sourceINI,"original INI modified")
  try check(f.count()==1,"INI changes rebuilt archive")
 }
 static func systemSettings() throws {
  let f=try Fixture()
  try f.put("System/Resources/item.bin",Data("resource only".utf8))
  let original=f.source.appendingPathComponent("System/window")
  let bytes=try Data(contentsOf:original)
  _ = try f.prepare()
  let system=f.play.appendingPathComponent("System"),local=system.appendingPathComponent("window")
  try check((try? f.fm.destinationOfSymbolicLink(atPath:system.path))==nil,"System still links to original")
  try check((try? f.fm.destinationOfSymbolicLink(atPath:local.path))==nil,"window setting still links to original")
  try check(try Data(contentsOf:local)==bytes,"setting bytes changed during initial seed")
  for name in ["RGSS301.dll","Resources"] {
   try check(try f.fm.destinationOfSymbolicLink(atPath:system.appendingPathComponent(name).path)==f.source.appendingPathComponent("System/"+name).path,"System resource reference changed")
  }
  let userBytes=Data([4,8,105,12])
  try userBytes.write(to:local)
  _ = try f.prepare()
  try check(try Data(contentsOf:local)==userBytes,"user setting reset on refresh")
  try check(try Data(contentsOf:original)==bytes,"local setting write mutated original")
  try check(f.count()==1,"setting change rebuilt archive")
  try f.fm.removeItem(at:local)
  _ = try f.prepare()
  try check(!f.fm.fileExists(atPath:local.path),"deleted user setting reseeded")
  let absent=try Fixture()
  try absent.fm.removeItem(at:absent.source.appendingPathComponent("System/window"))
  _ = try absent.prepare()
  try absent.put("System/window",bytes)
  _ = try absent.prepare()
  try check(!absent.fm.fileExists(atPath:absent.play.appendingPathComponent("System/window").path),"source setting imported after initial seed")
 }
 static func systemMigrationAndProtection() throws {
  let legacy=try Fixture()
  let sourceSystem=legacy.source.appendingPathComponent("System")
  _ = try legacy.prepare()
  // Reproduce the old layout while retaining its completed archive cache.
  try legacy.fm.removeItem(at:legacy.play.appendingPathComponent("System"))
  try legacy.fm.removeItem(at:legacy.home.appendingPathComponent("SystemWindowSeed.json"))
  try legacy.fm.createSymbolicLink(at:legacy.play.appendingPathComponent("System"),withDestinationURL:sourceSystem)
  let original=try Data(contentsOf:sourceSystem.appendingPathComponent("window"))
  _ = try legacy.prepare()
  let local=legacy.play.appendingPathComponent("System/window")
  try check((try? legacy.fm.destinationOfSymbolicLink(atPath:legacy.play.appendingPathComponent("System").path))==nil,"legacy System link not migrated")
  try check(try Data(contentsOf:local)==original,"legacy setting not copied intact")
  try Data("private preference".utf8).write(to:local)
  _ = try legacy.prepare()
  try check(try Data(contentsOf:local)==Data("private preference".utf8),"migrated user setting lost")
  try check(try Data(contentsOf:sourceSystem.appendingPathComponent("window"))==original,"migration modified original target")
  try check(legacy.fm.fileExists(atPath:sourceSystem.appendingPathComponent("RGSS301.dll").path),"migration removed original resources")
  try check(legacy.count()==1,"legacy System migration rebuilt the archive")
  for attack in ["other-System","alias-to-expected","local-window-link","local-window-hardlink","source-window-link","source-window-hardlink","local-System-hardlink","source-System-link"] {
   let f=try Fixture(),source=f.source.appendingPathComponent("System/window")
   let sourceBytes=try Data(contentsOf:source)
   if attack=="local-System-hardlink" {
    _ = try f.prepare()
    let system=f.play.appendingPathComponent("System")
    try f.fm.removeItem(at:system);try f.fm.linkItem(at:source,to:system)
   } else if attack=="source-System-link" {
    let system=f.source.appendingPathComponent("System"),external=f.root.appendingPathComponent("external-System")
    try f.fm.moveItem(at:system,to:external)
    try f.fm.createSymbolicLink(at:system,withDestinationURL:external)
   } else if attack.hasPrefix("local-") {
    _ = try f.prepare()
    let local=f.play.appendingPathComponent("System/window")
    try f.fm.removeItem(at:local)
    if attack.hasSuffix("hardlink") {try f.fm.linkItem(at:source,to:local)}
    else {try f.fm.createSymbolicLink(at:local,withDestinationURL:source)}
   } else if attack.hasPrefix("source-") {
    let target=f.root.appendingPathComponent("external-setting")
    try sourceBytes.write(to:target);try f.fm.removeItem(at:source)
    if attack.hasSuffix("hardlink") {try f.fm.linkItem(at:target,to:source)}
    else {try f.fm.createSymbolicLink(at:source,withDestinationURL:target)}
   } else {
    try f.fm.createDirectory(at:f.play,withIntermediateDirectories:true)
    let target=f.root.appendingPathComponent("other-System")
    if attack=="alias-to-expected" {try f.fm.createSymbolicLink(at:target,withDestinationURL:f.source.appendingPathComponent("System"))}
    else {try f.fm.createDirectory(at:target,withIntermediateDirectories:true)}
    try f.fm.createSymbolicLink(at:f.play.appendingPathComponent("System"),withDestinationURL:target)
   }
   try rejects(attack) {_ = try f.prepare()}
   try check(try Data(contentsOf:source)==sourceBytes,"rejected System path changed original")
  }
  let oversized=try Fixture()
  try oversized.put("System/window",Data(repeating:0,count:1024*1024+1))
  try rejects("oversized System/window") {_ = try oversized.prepare()}
 }
 static func failedCache() throws {
  let f=try Fixture()
  try "import pathlib,sys\npathlib.Path(sys.argv[2]).write_bytes(b'partial')\nsys.exit(9)\n".write(to:f.tools.appendingPathComponent("append_rgss3a.py"),atomically:true,encoding:.utf8)
  try rejects("nonzero append") {_ = try f.prepare()}
  try check(!f.fm.fileExists(atPath:f.play.appendingPathComponent("Game.rgss3a").path),"failed cache published")
  try f.restoreAppend();_ = try f.prepare()
  let cache=f.play.appendingPathComponent("Game.rgss3a").resolvingSymlinksInPath()
  try Data("partial".utf8).write(to:cache)
  _ = try f.prepare()
  try check(f.count()==2,"partial cache with stale receipt accepted")
  let receipt=cache.deletingPathExtension().appendingPathExtension("receipt.json")
  try f.fm.removeItem(at:receipt)
  _ = try f.prepare()
  try check(f.count()==3,"cache without receipt accepted")
  let falseSuccess=try Fixture()
  try "import pathlib,sys\npathlib.Path(sys.argv[2]).write_bytes(b'RGSSAD\\x00\\x03')\n".write(to:falseSuccess.tools.appendingPathComponent("append_rgss3a.py"),atomically:true,encoding:.utf8)
  try rejects("zero exit but incomplete cache") {_ = try falseSuccess.prepare()}
  try check(!falseSuccess.fm.fileExists(atPath:falseSuccess.play.appendingPathComponent("Game.rgss3a").path),"incomplete successful cache published")
  try check(try falseSuccess.fm.contentsOfDirectory(atPath:falseSuccess.assets.path).isEmpty,"failed cache or receipt retained")
 }
 static func protections() throws {
  let overlap=try Fixture()
  try rejects("source contains dataRoot") {_ = try RPGDictionary.prepareIfNeeded(game:overlap.game,dataRoot:overlap.source.appendingPathComponent("private"),tools:overlap.tools)}
  try rejects("dataRoot contains source") {_ = try RPGDictionary.prepareIfNeeded(game:overlap.game,dataRoot:overlap.root,tools:overlap.tools)}
  for relative in ["", "Adapters", "Adapters/ID/Play", "Adapters/ID/Assets", "Adapters/ID/Play/Fonts", "Adapters/ID/Play/Save", "Adapters/ID/Play/GameShelfAdapter.rb", "Adapters/ID/Play/Game.rgss3a"] {
   let f=try Fixture();_ = try f.prepare()
   let name=relative.replacingOccurrences(of:"ID",with:f.game.id.uuidString)
   let path=name.isEmpty ? f.data:f.data.appendingPathComponent(name)
   try f.fm.removeItem(at:path)
   try f.fm.createSymbolicLink(at:path,withDestinationURL:f.source)
   try rejects("private symlink "+relative) {_ = try f.prepare()}
   try check(try Data(contentsOf:f.source.appendingPathComponent("Save01.rvdata2"))==Data("root original save".utf8),"source changed through private alias")
  }
  let hard=try Fixture();_ = try hard.prepare()
  let local=hard.play.appendingPathComponent("Save01.rvdata2")
  try hard.fm.removeItem(at:local)
  try hard.fm.linkItem(at:hard.source.appendingPathComponent("Save01.rvdata2"),to:local)
  try rejects("hardlinked private save") {_ = try hard.prepare()}
  let collision=try Fixture()
  let sentinel=Data("OWN SOURCE SENTINEL".utf8)
  try collision.put("GameShelfAdapter.rb",sentinel)
  try rejects("generator write-through source collision") {_ = try collision.prepare()}
  try check(try Data(contentsOf:collision.source.appendingPathComponent("GameShelfAdapter.rb"))==sentinel,"generator modified source adapter")
  let linked=try Fixture()
  try linked.fm.createSymbolicLink(at:linked.source.appendingPathComponent("Save/alias"),withDestinationURL:linked.source.appendingPathComponent("Save01.rvdata2"))
  try rejects("source save symlink") {_ = try linked.prepare()}
  let cacheAlias=try Fixture();_ = try cacheAlias.prepare()
  let cache=cacheAlias.play.appendingPathComponent("Game.rgss3a").resolvingSymlinksInPath()
  try cacheAlias.fm.removeItem(at:cache)
  try cacheAlias.fm.createSymbolicLink(at:cache,withDestinationURL:cacheAlias.source.appendingPathComponent("Game.rgss3a"))
  try rejects("cache points to original archive") {_ = try cacheAlias.prepare()}
  let parentAlias=try Fixture()
  let alias=parentAlias.root.appendingPathComponent("private-alias")
  try parentAlias.fm.createDirectory(at:parentAlias.data,withIntermediateDirectories:true)
  try parentAlias.fm.createSymbolicLink(at:alias,withDestinationURL:parentAlias.data)
  try rejects("private parent directory alias") {_ = try RPGDictionary.prepareIfNeeded(game:parentAlias.game,dataRoot:alias.appendingPathComponent("child"),tools:parentAlias.tools)}
 }
 static func storagePolicy() throws {
  try RPGDictionary.validateStorage(sourceIsLocal:true,dataIsLocal:true)
  try RPGDictionary.validateStorage(sourceIsLocal:false,dataIsLocal:false)
  try RPGDictionary.validateStorage(sourceIsLocal:true,dataIsLocal:false)
  try rejects("NAS to local") {try RPGDictionary.validateStorage(sourceIsLocal:false,dataIsLocal:true)}
  try rejects("unknown source volume") {try RPGDictionary.validateStorage(sourceIsLocal:nil,dataIsLocal:false)}
  try rejects("unknown target volume") {try RPGDictionary.validateStorage(sourceIsLocal:true,dataIsLocal:nil)}
 }
 static func executionSafety() throws {
  let f=try Fixture()
  let start=Date()
  try rejects("subprocess timeout") {
   try RPGDictionary.runTool(executable:URL(fileURLWithPath:"/usr/bin/ruby"),arguments:["-e","sleep 30"],directory:f.tools,timeout:0.1)
  }
  try check(Date().timeIntervalSince(start)<6,"timeout did not bound subprocess")
  let generator=f.tools.appendingPathComponent("prepare_rgss_dictionary.rb")
  let original=try String(contentsOf:generator,encoding:.utf8)
  try ("File.write(File.join(__dir__,'started'),'yes'); sleep 1\n"+original).write(to:generator,atomically:true,encoding:.utf8)
  final class Outcome: @unchecked Sendable {var error:Error?}
  let outcome=Outcome(),done=DispatchSemaphore(value:0)
  DispatchQueue.global().async {
   do {_ = try f.prepare()} catch {outcome.error=error}
   done.signal()
  }
  let deadline=Date().addingTimeInterval(5)
  while !f.fm.fileExists(atPath:f.tools.appendingPathComponent("started").path),Date()<deadline {Thread.sleep(forTimeInterval:0.01)}
  try check(f.fm.fileExists(atPath:f.tools.appendingPathComponent("started").path),"first preparation did not start")
  try rejects("simultaneous prepare") {_ = try f.prepare()}
  try check(done.wait(timeout:.now()+15) == .success,"first preparation did not finish")
  if let error=outcome.error {throw error}
  try check(f.count()==1,"concurrent preparation built twice")
  try check(!f.fm.fileExists(atPath:f.home.appendingPathComponent("Prepare.lock").path),"lock not released")
 }
}
