import Foundation
import CryptoKit
import Darwin

enum RPGDictionary {
 private static let fm=FileManager.default
 private static let magic=Data([82,71,83,83,65,68,0,3])
 private static let artifactNames=["Game.exe","Game.ini","GameShelfAdapter.rb","GameShelfBootstrap.rvdata2","GameShelfTranslations.rvdata2"]
 private struct Stamp:Codable,Equatable {
  let size:Int64,seconds:Int64,nanos:Int64
  init(_ value:stat){size=value.st_size;seconds=Int64(value.st_mtimespec.tv_sec);nanos=Int64(value.st_mtimespec.tv_nsec)}
 }
 private struct CacheInput:Codable {
  let version:Int,source:String,archive:Stamp,bootstrap:String,dictionary:String,appendTool:String
 }
 private struct Receipt:Codable {let version:Int,key:String,cache:Stamp}
 private struct Seed:Codable {let version:Int;let gameID:UUID}

 /// Returns a transient launch copy. The library's Game and source tree are never written.
 /// Call off the UI thread, with no live game using this Play directory.
 static func prepareIfNeeded(game:Game,dataRoot:URL,tools:URL) throws -> Game {
  guard game.entry.backend == .wine,game.entry.engine=="RPG Maker VX Ace" else{return game}
  let source=physicalSystemPath(URL(fileURLWithPath:game.folder).standardizedFileURL.resolvingSymlinksInPath())
  let originalArchive=source.appendingPathComponent("Game.rgss3a"),json=source.appendingPathComponent("翻译文件.json")
  guard fm.fileExists(atPath:json.path),fm.fileExists(atPath:originalArchive.path),try isV3(originalArchive) else{return game}
  try EntryPolicy.validate(game.entry)
  guard game.entry.path=="Game.exe" else{throw LibraryError("VX Ace 词典适配需要根目录 Game.exe。")}
  let requestedRoot=dataRoot.standardizedFileURL
  try privatePath(requestedRoot,directory:true)
  // Resolve only after checking user-controlled ancestors. Python's no-follow
  // output traversal also rejects the OS /var and /tmp convenience aliases.
  let root=physicalSystemPath(requestedRoot.resolvingSymlinksInPath())
  let resolvedRoot=physicalSystemPath(root.resolvingSymlinksInPath().standardizedFileURL).path
  let sourcePath=source.path
  guard !within(sourcePath,resolvedRoot),!within(resolvedRoot,sourcePath) else{throw LibraryError("词典数据目录不能与原游戏目录重叠。")}
  try privatePath(root,directory:true)
  try validateStorage(sourceIsLocal:volumeIsLocal(source),dataIsLocal:volumeIsLocal(root))
  // The generator links resources before writing its own scripts. Reject names
  // that would otherwise make those writes follow a link back to the source.
  let ownedNames=Set(artifactNames.dropFirst(2).map{$0.lowercased()})
  guard try !children(source).contains(where:{ownedNames.contains($0.lastPathComponent.lowercased())}) else {
   throw LibraryError("原目录已有同名 GameShelf 自有脚本，请选择未适配的原游戏目录。")
  }
  for path in [originalArchive,json,source.appendingPathComponent("Game.exe"),source.appendingPathComponent("Game.ini")] {
   guard !within(physicalSystemPath(path.resolvingSymlinksInPath().standardizedFileURL).path,resolvedRoot) else{throw LibraryError("原游戏文件指向私有数据目录，已停止。")}
  }
  let generator=tools.appendingPathComponent("prepare_rgss_dictionary.rb"),append=tools.appendingPathComponent("append_rgss3a.py")
  try privatePath(generator,directory:false);try privatePath(append,directory:false)
  guard fm.fileExists(atPath:generator.path),fm.fileExists(atPath:append.path) else{throw LibraryError("缺少随应用提供的 RPG 词典工具。")}
  let home=root.appendingPathComponent("Adapters/"+game.id.uuidString)
  try makeDirectory(home)
  let lock=home.appendingPathComponent("Prepare.lock")
  try privatePath(lock,directory:true)
  guard Darwin.mkdir(lock.path,0o700)==0 else {
   throw LibraryError("此游戏的词典正在准备，或上次中断留下了锁。确认没有准备进程后才可移除："+lock.path)
  }
  let lockInfo=try info(lock)!
  defer {
   if let current=try? info(lock),current.st_ino==lockInfo.st_ino,current.st_dev==lockInfo.st_dev { _ = Darwin.rmdir(lock.path) }
  }
  let play=home.appendingPathComponent("Play"),assets=home.appendingPathComponent("Assets")
  try makeDirectory(assets)
  try privatePath(play,directory:true)
  let links=try resourceLinks(source:source)
  try migrateLegacySystem(play:play,source:source)
  if fm.fileExists(atPath:play.path){try auditPlay(play,play:play,assets:assets,links:links)}
  let seedURL=home.appendingPathComponent("SaveSeed.json")
  try privatePath(seedURL,directory:false)

  let archiveStamp=Stamp(try requiredInfo(originalArchive,follow:true))
  let jsonHash=hash(try readSmall(json))
  let work=home.appendingPathComponent(".work-"+UUID().uuidString)
  try makeDirectory(work)
  // Generator-created resource symlinks are never used for writing or launching.
  defer{try? fm.removeItem(at:work)}
  try runTool(executable:URL(fileURLWithPath:"/usr/bin/ruby"),arguments:[generator.path,source.path,work.path],directory:work,timeout:120)
  var generated:[String:Data]=[:]
  for name in artifactNames {
   let file=work.appendingPathComponent(name)
   try privatePath(file,directory:false)
   generated[name]=try readSmall(file)
  }
  guard String(data:generated["GameShelfAdapter.rb"]!,encoding:.utf8) != nil else{throw LibraryError("自有词典适配脚本不是 UTF-8。")}
  let input=CacheInput(version:1,source:originalArchive.standardizedFileURL.path,archive:archiveStamp,bootstrap:hash(generated["GameShelfBootstrap.rvdata2"]!),dictionary:hash(generated["GameShelfTranslations.rvdata2"]!),appendTool:hash(try readSmall(append)))
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  let key=hash(try encoder.encode(input))
  let cache=assets.appendingPathComponent(key+".rgss3a"),receipt=assets.appendingPathComponent(key+".receipt.json")
  try privatePath(cache,directory:false);try privatePath(receipt,directory:false)
  let minimumSize=archiveStamp.size+Int64(generated["GameShelfBootstrap.rvdata2"]!.count+generated["GameShelfTranslations.rvdata2"]!.count)
  var ready=false
  if let record=try? JSONDecoder().decode(Receipt.self,from:readSmall(receipt)),let current=try info(cache) {
   ready=record.version==1 && record.key==key && record.cache==Stamp(current) && current.st_size>=minimumSize
   if ready {ready=try isV3(cache)}
  }
  guard Stamp(try requiredInfo(originalArchive,follow:true))==archiveStamp,hash(try readSmall(json))==jsonHash else{throw LibraryError("原归档或词典在准备期间发生变化，请重试。")}
  if !ready {
   // An existing file without a matching completed receipt is not a usable cache.
   try removePrivateFile(receipt);try removePrivateFile(cache)
   do {
    try runTool(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[append.path,originalArchive.path,cache.path,"--bootstrap",work.appendingPathComponent("GameShelfBootstrap.rvdata2").path,"--dictionary",work.appendingPathComponent("GameShelfTranslations.rvdata2").path,"--publish-mode","exclusive-copy"],directory:work,timeout:1800)
    try privatePath(cache,directory:false)
    let current=try requiredInfo(cache)
    guard current.st_size>=minimumSize,try isV3(cache),Stamp(try requiredInfo(originalArchive,follow:true))==archiveStamp,hash(try readSmall(json))==jsonHash else{throw LibraryError("词典归档缓存不完整或原文件已变化，未发布。")}
    try writePrivate(encoder.encode(Receipt(version:1,key:key,cache:Stamp(current))),to:receipt)
   } catch {
    try? removePrivateFile(receipt);try? removePrivateFile(cache)
    throw error
   }
  }

  // Only completed caches reach stable Play. Existing local saves are never reset.
  try makeDirectory(play);try makeDirectory(play.appendingPathComponent("Fonts"))
  try makeDirectory(play.appendingPathComponent("System"))
  try auditPlay(play,play:play,assets:assets,links:links)
  try seedSystemWindow(source:source,play:play,home:home,gameID:game.id)
  if (try? JSONDecoder().decode(Seed.self,from:readSmall(seedURL)))?.gameID != game.id {
   var budget=256*1024*1024
   for item in try children(source) where isSave(item) {
    try seedSave(item,to:play.appendingPathComponent(item.lastPathComponent),budget:&budget)
   }
   try writePrivate(encoder.encode(Seed(version:1,gameID:game.id)),to:seedURL)
  }
  for (name,target) in links.sorted(by:{$0.key<$1.key}) {
   let link=play.appendingPathComponent(name)
   try makeDirectory(link.deletingLastPathComponent())
   try resourceLink(link,to:target)
  }
  for name in artifactNames {
   let destination=play.appendingPathComponent(name)
   if name=="Game.ini" {
    try privatePath(destination,directory:false)
    let ini=try info(destination)==nil ? generated[name]!:readSmall(destination)
    try writePrivate(bootstrapINI(ini),to:destination)
   } else {try writePrivate(generated[name]!,to:destination)}
  }
  let archiveLink=play.appendingPathComponent("Game.rgss3a")
  try checkArchiveLink(archiveLink,assets:assets)
  if (try? fm.destinationOfSymbolicLink(atPath:archiveLink.path)) != cache.path {
   if (try? info(archiveLink)) != nil {try fm.removeItem(at:archiveLink)}
   try fm.createSymbolicLink(atPath:archiveLink.path,withDestinationPath:cache.path)
  }
  var runGame=game
  runGame.folder=play.path
  return runGame
 }

 private static func within(_ path:String,_ root:String)->Bool {path==root || path.hasPrefix(root+"/")}
 /// INI keys are ASCII; preserve all other bytes, including legacy Japanese
 /// encodings, comments, other sections, and the user's volume/settings values.
 private static func bootstrapINI(_ data:Data)throws -> Data {
  guard !data.contains(0),!data.starts(with:[0xff,0xfe]),!data.starts(with:[0xfe,0xff]) else {
   throw LibraryError("Game.ini 编码不支持安全校正，已保留原设置。")
  }
  let newline:[UInt8]=data.range(of:Data([13,10])) == nil ? [10]:[13,10]
  let setting=Array("Scripts=GameShelfBootstrap.rvdata2".utf8)
  var result=Data(),inGame=false,hasScript=false,sawGame=false
  func appendLine(_ bytes:[UInt8]) {
   if !result.isEmpty,result.last != 10 {result.append(contentsOf:newline)}
   result.append(contentsOf:bytes);result.append(contentsOf:newline)
  }
  func finishSection() {if inGame && !hasScript {appendLine(setting)}}
  let lines=Array(data).split(separator:10,omittingEmptySubsequences:false)
  for (index,part) in lines.enumerated() {
   if index==lines.count-1 && part.isEmpty {continue}
   let raw=Array(part),hasLF=index<lines.count-1
   var body=raw
   if body.last==13 {body.removeLast()}
   if index==0,body.starts(with:[0xef,0xbb,0xbf]) {body.removeFirst(3)}
   let text=String(decoding:body,as:UTF8.self).trimmingCharacters(in:.whitespaces)
   if text.hasPrefix("["),text.hasSuffix("]") {
    finishSection()
    inGame=text.dropFirst().dropLast().trimmingCharacters(in:.whitespaces).lowercased()=="game"
    sawGame = sawGame || inGame;hasScript=false
   }
   let key=text.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
   if inGame,key.count==2,key[0].trimmingCharacters(in:.whitespaces).lowercased()=="scripts" {
    result.append(contentsOf:setting)
    if raw.last==13 {result.append(13)}
    hasScript=true
   } else {result.append(contentsOf:raw)}
   if hasLF {result.append(10)}
  }
  finishSection()
  if !sawGame {appendLine(Array("[Game]".utf8));appendLine(setting)}
  return result
 }
 private static func physicalSystemPath(_ url:URL)->URL {
  let path=url.path
  // Foundation abbreviates /private/var back to /var even after resolving it.
  if path=="/var" || path.hasPrefix("/var/") || path=="/tmp" || path.hasPrefix("/tmp/") {
   return URL(fileURLWithPath:"/private"+path)
  }
  return url
 }
 /// Unknown volume attributes fail closed, including when the data root is new.
 static func validateStorage(sourceIsLocal:Bool?,dataIsLocal:Bool?)throws {
  guard let sourceIsLocal=sourceIsLocal,let dataIsLocal=dataIsLocal else {
   throw LibraryError("无法判定原游戏或运行数据目录所在卷，已停止归档复制。请确认挂载和运行数据位置后重试。")
  }
  guard sourceIsLocal || !dataIsLocal else {
   throw LibraryError("原游戏位于 NAS/远端卷，请先把运行数据位置选到 NAS；不会在 Mac 本地复制游戏归档。")
  }
 }
 private static func volumeIsLocal(_ url:URL)throws -> Bool? {
  var existing=url
  while try info(existing)==nil {
   let parent=existing.deletingLastPathComponent()
   guard parent.path != existing.path else{return nil}
   existing=parent
  }
  return (try? existing.resourceValues(forKeys:[.volumeIsLocalKey]))?.volumeIsLocal
 }
 private static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
 private static func info(_ url:URL,follow:Bool=false)throws -> stat? {
  var value=stat()
  let path=follow ? url.resolvingSymlinksInPath().path:url.path
  let result=Darwin.lstat(path,&value)
  if result==0 {return value}
  if errno==ENOENT {return nil}
  throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
 }
 private static func requiredInfo(_ url:URL,follow:Bool=false)throws -> stat {
  guard let value=try info(url,follow:follow),(value.st_mode & S_IFMT)==S_IFREG else{throw LibraryError("所需文件不是普通文件："+url.lastPathComponent)}
  return value
 }
 private static func privatePath(_ url:URL,directory:Bool) throws {
  var current=URL(fileURLWithPath:"/")
  let components=url.standardizedFileURL.pathComponents.dropFirst()
  for (index,component) in components.enumerated() {
   current=current.appendingPathComponent(component)
   guard let value=try info(current) else{continue}
   let type=value.st_mode & S_IFMT
   if type==S_IFLNK {
    // System aliases are unavoidable for macOS temporary directories; arbitrary
    // user-controlled aliases, including the private root itself, are rejected.
    let target=try fm.destinationOfSymbolicLink(atPath:current.path)
    if (current.path=="/var" && target=="private/var") || (current.path=="/tmp" && target=="private/tmp") {continue}
    throw LibraryError("私有可写路径不能是符号链接："+current.path)
   }
   let wantsDirectory=index<components.count-1 || directory
   guard wantsDirectory ? type==S_IFDIR : (type==S_IFREG && value.st_nlink==1) else{throw LibraryError("私有路径类型不安全或文件有外部硬链接："+current.path)}
  }
 }
 private static func makeDirectory(_ url:URL)throws {
  try privatePath(url,directory:true)
  try fm.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  try privatePath(url,directory:true)
 }
 private static func readSmall(_ url:URL,limit:Int=32*1024*1024)throws -> Data {
  let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
  var data=Data()
  while let chunk=try handle.read(upToCount:min(65536,limit+1-data.count)),!chunk.isEmpty {
   data.append(chunk)
   guard data.count<=limit else{throw LibraryError("文件超过小文件处理上限："+url.lastPathComponent)}
  }
  return data
 }
 private static func isV3(_ url:URL)throws -> Bool {
  let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
  return try handle.read(upToCount:8)==magic
 }
 private static func writePrivate(_ data:Data,to url:URL)throws {
  try privatePath(url,directory:false)
  if fm.fileExists(atPath:url.path),(try? readSmall(url))==data {return}
  try data.write(to:url,options:.atomic)
 }
 private static func removePrivateFile(_ url:URL)throws {
  try privatePath(url,directory:false)
  if try info(url) != nil {try fm.removeItem(at:url)}
 }
 private static func children(_ url:URL)throws -> [URL] {
  let values=try fm.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).sorted{$0.lastPathComponent<$1.lastPathComponent}
  guard Set(values.map{$0.lastPathComponent.lowercased()}).count==values.count else{throw LibraryError("目录含大小写冲突的文件名。")}
  return values
 }
 private static func isSave(_ url:URL)->Bool {
  let name=url.lastPathComponent.lowercased()
  return name=="save" || name=="saves" || ["rvdata2","rvdata","rxdata","sav","save"].contains(url.pathExtension.lowercased())
 }
 private static func seedSave(_ source:URL,to destination:URL,budget:inout Int)throws {
  guard let value=try info(source) else{throw LibraryError("存档复制时原文件不可用。")}
  if (value.st_mode & S_IFMT)==S_IFDIR {
   try makeDirectory(destination)
   for item in try children(source){try seedSave(item,to:destination.appendingPathComponent(item.lastPathComponent),budget:&budget)}
  } else {
   guard (value.st_mode & S_IFMT)==S_IFREG else{throw LibraryError("存档含链接或特殊文件，不能安全独立复制。")}
   try privatePath(destination,directory:false)
   if try info(destination) != nil{return}
   guard value.st_size<=32*1024*1024,value.st_size<=budget else{throw LibraryError("首次存档复制超过小量迁移上限，未覆盖既有存档。")}
   let bytes=try readSmall(source);budget-=bytes.count
   try writePrivate(bytes,to:destination)
  }
 }
 private static func resourceLinks(source:URL)throws -> [String:URL] {
  var links:[String:URL]=[:]
  let reserved=Set((artifactNames+["Game.rgss3a","翻译文件.json","Fonts","Tool","System"]).map{$0.lowercased()})
  for item in try children(source) {
   if reserved.contains(item.lastPathComponent.lowercased()) || isSave(item) || item.pathExtension.lowercased()=="log" {continue}
   links[item.lastPathComponent]=item
  }
  let system=source.appendingPathComponent("System")
  if let value=try info(system) {
   guard (value.st_mode & S_IFMT)==S_IFDIR else{throw LibraryError("原 System 必须是独立目录，不能是链接。")}
   for item in try children(system) {
    if item.lastPathComponent.lowercased()=="window" {
     guard item.lastPathComponent=="window" else{throw LibraryError("System/window 设置文件大小写不明确。")}
     _ = try windowSettingInfo(item)
    } else {links["System/"+item.lastPathComponent]=item}
   }
  }
  let fonts=source.appendingPathComponent("Fonts")
  var visited=Set<String>()
  func addFonts(_ folder:URL,_ relative:String)throws {
   guard visited.insert(folder.resolvingSymlinksInPath().path).inserted else{throw LibraryError("字体目录含循环链接。")}
   for item in try children(folder) {
    if let value=try info(item,follow:true),(value.st_mode & S_IFMT)==S_IFDIR {try addFonts(item,relative+item.lastPathComponent+"/")}
    else if ["ttf","otf","ttc"].contains(item.pathExtension.lowercased()) {links[relative+item.lastPathComponent]=item}
   }
  }
  if fm.fileExists(atPath:fonts.path){try addFonts(fonts,"Fonts/")}
  let included=source.appendingPathComponent("Tool/loaders/unifont-all.ttf")
  if fm.fileExists(atPath:included.path){links["Fonts/unifont-all.ttf"]=included}
  return links
 }
 private static func migrateLegacySystem(play:URL,source:URL)throws {
  let system=play.appendingPathComponent("System")
  guard let value=try info(system),(value.st_mode & S_IFMT)==S_IFLNK else {
   try privatePath(system,directory:true);return
  }
  let expected=source.appendingPathComponent("System")
  guard value.st_nlink==1,try fm.destinationOfSymbolicLink(atPath:system.path)==expected.path,
        let original=try info(expected),(original.st_mode & S_IFMT)==S_IFDIR else {
   throw LibraryError("System 链接不是已知的原目录引用，未迁移。")
  }
  // Only unlink this exact legacy link. Never remove/traverse its source target.
  guard Darwin.unlink(system.path)==0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
  try privatePath(system,directory:true)
 }
 private static func windowSettingInfo(_ path:URL)throws -> stat? {
  guard let value=try info(path) else{return nil}
  guard (value.st_mode & S_IFMT)==S_IFREG,value.st_nlink==1,value.st_size<=1024*1024 else {
   throw LibraryError("System/window 必须是小型普通文件，不能是符号链接或硬链接。")
  }
  return value
 }
 private static func seedSystemWindow(source:URL,play:URL,home:URL,gameID:UUID)throws {
  let marker=home.appendingPathComponent("SystemWindowSeed.json")
  let local=play.appendingPathComponent("System/window")
  try privatePath(marker,directory:false);try privatePath(local,directory:false)
  if try info(marker) != nil {
   let seed=try JSONDecoder().decode(Seed.self,from:readSmall(marker))
   guard seed.version==1,seed.gameID==gameID else{throw LibraryError("System/window 初始化记录不匹配。")}
   return
  }
  let original=source.appendingPathComponent("System/window")
  if try info(local)==nil,let expected=try windowSettingInfo(original) {
   let fd=Darwin.open(original.path,O_RDONLY|O_NOFOLLOW)
   guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
   let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? handle.close()}
   var current=stat()
   guard Darwin.fstat(fd,&current)==0,current.st_dev==expected.st_dev,current.st_ino==expected.st_ino,
         (current.st_mode & S_IFMT)==S_IFREG,current.st_nlink==1 else{throw LibraryError("System/window 在复制前发生变化。")}
   var bytes=Data()
   while let chunk=try handle.read(upToCount:min(65536,1024*1024+1-bytes.count)),!chunk.isEmpty {
    bytes.append(chunk)
    guard bytes.count<=1024*1024 else{throw LibraryError("System/window 超过小文件上限。")}
   }
   // Opaque copy only: no Marshal decoding or interpretation of the setting.
   try writePrivate(bytes,to:local)
  }
  // Also record initial absence/deletion, so subsequent launches never reseed.
  try writePrivate(JSONEncoder().encode(Seed(version:1,gameID:gameID)),to:marker)
 }
 private static func checkArchiveLink(_ link:URL,assets:URL)throws {
  guard let value=try info(link) else{return}
  guard (value.st_mode & S_IFMT)==S_IFLNK else{throw LibraryError("Play 归档引用不是本应用的缓存链接。")}
  let raw=try fm.destinationOfSymbolicLink(atPath:link.path)
  let target=URL(fileURLWithPath:raw,relativeTo:link.deletingLastPathComponent()).standardizedFileURL
  guard target.deletingLastPathComponent().path==assets.standardizedFileURL.path,target.pathExtension=="rgss3a" else{throw LibraryError("Play 归档指向私有 Assets 以外，已停止。")}
  try privatePath(target,directory:false)
 }
 private static func auditPlay(_ directory:URL,play:URL,assets:URL,links:[String:URL])throws {
  try privatePath(directory,directory:true)
  for item in try children(directory) {
   let value=try info(item)!,type=value.st_mode & S_IFMT
   if type==S_IFLNK {
    if item.path==play.appendingPathComponent("Game.rgss3a").path {try checkArchiveLink(item,assets:assets);continue}
    let relative=String(item.path.dropFirst(play.path.count+1))
    guard let expected=links[relative],try fm.destinationOfSymbolicLink(atPath:item.path)==expected.path else{throw LibraryError("Play 含非原资源的外部可写链接："+relative)}
   } else if type==S_IFDIR {try auditPlay(item,play:play,assets:assets,links:links)}
   else {try privatePath(item,directory:false)}
  }
 }
 private static func resourceLink(_ link:URL,to target:URL)throws {
  if let current=try info(link) {
   guard (current.st_mode & S_IFMT)==S_IFLNK,try fm.destinationOfSymbolicLink(atPath:link.path)==target.path else{throw LibraryError("资源目标已有非预期文件，未覆盖："+link.lastPathComponent)}
   return
  }
  try fm.createSymbolicLink(atPath:link.path,withDestinationPath:target.path)
 }

 /// Bounded subprocess runner, also independently testable without invoking a game.
 static func runTool(executable:URL,arguments:[String],directory:URL,timeout:TimeInterval)throws {
  guard ["/usr/bin/ruby","/usr/bin/python3"].contains(executable.path) else{throw LibraryError("不支持的词典工具解释器。")}
  try privatePath(directory,directory:true)
  let log=directory.appendingPathComponent(".tool-"+UUID().uuidString+".log")
  let fd=Darwin.open(log.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
  guard fd>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
  let output=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
  defer{try? output.close();try? fm.removeItem(at:log)}
  let process=Process();process.executableURL=executable;process.arguments=arguments;process.currentDirectoryURL=directory
  var environment=ProcessInfo.processInfo.environment
  for key in ["RUBYOPT","RUBYLIB","PYTHONPATH","PYTHONHOME","PYTHONSTARTUP"] {environment.removeValue(forKey:key)}
  environment["PYTHONDONTWRITEBYTECODE"]="1"
  process.environment=environment;process.standardOutput=output;process.standardError=output
  let done=DispatchSemaphore(value:0)
  process.terminationHandler={_ in done.signal()}
  try PreparationTasks.shared.run(process)
  defer{PreparationTasks.shared.finish(process)}
  if done.wait(timeout:.now()+timeout) != .success {
   process.terminate()
   if done.wait(timeout:.now()+2) != .success {Darwin.kill(process.processIdentifier,SIGKILL);_ = done.wait(timeout:.now()+2)}
   throw LibraryError("词典工具执行超时："+executable.lastPathComponent)
  }
  guard process.terminationReason == .exit,process.terminationStatus==0 else{throw LibraryError("词典工具失败，退出码 \(process.terminationStatus)："+(arguments.first.map{URL(fileURLWithPath:$0).lastPathComponent} ?? executable.lastPathComponent))}
 }
}
