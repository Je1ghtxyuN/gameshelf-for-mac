import Foundation
import CryptoKit

enum Backend: String, Codable { case wine, web, native, renpy, rpgmz }
struct Candidate: Codable, Equatable { var path: String; var backend: Backend; var engine: String }
struct LibraryError: LocalizedError {
 let message: String
 init(_ message:String){self.message=message}
 var errorDescription:String?{message}
}
enum MZWebProfile {
 // A tested desktop package may opt into WebKit; unknown NW.js packages retain
 // Wine because Node plugins and native modules cannot be assumed portable.
 static let sakura:[String:String]=[
  "package.json":"7a5f59321b3d8f6c6a657b3018d2f78cc7b542722b1673a0c4fcbb0a32d35fb7",
  "js/main.js":"122d02193c3e89c81e21cb5e7bee698f1f473ea55af31b91c3e29e28c04f871f",
  "js/plugins.js":"827678222c355214b53f8ce300aff11bef3321a6e732232975d23f2eb099402b",
  "js/rmmz_core.js":"03c5a7454c2f9303ccced4589304c341c12bbed6c24c6132e1a4e627347d6569",
  "js/rmmz_managers.js":"d1575c2ee01d1ecc3aa7dc88e1a04f5028717f7e807f4662d47daf94d79b7f7d"
 ]
 static func matches(at root:URL,fingerprints:[String:String]=sakura)->Bool {
  let base=root.standardizedFileURL.resolvingSymlinksInPath()
  guard !fingerprints.isEmpty else{return false}
  for (path,expected) in fingerprints {
   let file=base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
   guard file.path.hasPrefix(base.path+"/"),let handle=try? FileHandle(forReadingFrom:file) else{return false}
   defer{try? handle.close()}
   guard let bytes=try? handle.read(upToCount:2*1024*1024+1),bytes.count<=2*1024*1024 else{return false}
   let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
   guard digest==expected else{return false}
  }
  return true
 }
}
enum Scan {
 static func candidates(at root:URL) throws -> [Candidate] {
  let fm=FileManager.default
  var dir:ObjCBool=false
  guard fm.fileExists(atPath:root.path,isDirectory:&dir),dir.boolValue else {throw LibraryError("游戏目录无法访问，请检查 NAS 是否连接，或重新定位游戏。")}
  if root.pathExtension.lowercased()=="app" {return [Candidate(path:".",backend:.native,engine:"macOS")]}
  let children=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])
  let names=children.map{$0.lastPathComponent.lowercased()}
  func has(_ p:String)->Bool{fm.fileExists(atPath:root.appendingPathComponent(p).path)}
  var engine="Windows"
  if names.contains("renpy") {engine="Ren’Py"}
  else if names.contains(where:{$0.hasSuffix(".xp3")}){engine="KiriKiri"}
  else if has("www/js/rpg_core.js") || has("js/rpg_core.js") {engine="RPG Maker MV"}
  else if has("js/rmmz_core.js") || has("www/js/rmmz_core.js") {engine="RPG Maker MZ"}
  else if names.contains("game.rgss3a"){engine="RPG Maker VX Ace"}
  else if names.contains("game.rgss2a"){engine="RPG Maker VX"}
  else if names.contains("game.rgssad"){engine="RPG Maker XP"}
  else if names.contains("rpg_rt.ldb"){engine="RPG Maker 2000/2003"}
  else if names.contains("unityplayer.dll") || names.contains(where:{$0.hasSuffix("_data")}){engine="Unity"}
  else if names.contains("nscript.dat") || names.contains("0.txt"){engine="NScripter / ONScripter"}
  let excluded=["unins","uninstall","unitycrashhandler","crashreport","dxsetup","vcredist","vc_redist","dotnet","setup","installer","config","custom"]
  let exe=children.filter { u in
   let n=u.lastPathComponent.lowercased()
   guard n.hasSuffix(".exe"),!excluded.contains(where:{n.hasPrefix($0)}) else{return false}
   guard let handle=try? FileHandle(forReadingFrom:u) else{return false}
   defer{try? handle.close()}
   return (try? handle.read(upToCount:2)) == Data([0x4d,0x5a])
  }.sorted{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}
  if engine=="RPG Maker MZ",has("index.html"),exe.contains(where:{$0.lastPathComponent=="Game.exe"}),MZWebProfile.matches(at:root) {
   return [Candidate(path:"Game.exe",backend:.rpgmz,engine:engine)]
  }
  if !exe.isEmpty{return exe.map{Candidate(path:$0.lastPathComponent,backend:engine=="Ren’Py" ? .renpy:.wine,engine:engine)}}
  let apps=children.filter{$0.pathExtension.lowercased()=="app"}
  if !apps.isEmpty{return apps.map{Candidate(path:$0.lastPathComponent,backend:.native,engine:"macOS")}}
  // Desktop NW.js packages may depend on Node: never silently execute them as a browser export.
  if has("package.json") || has("nw.dll"){return []}
  if has("index.html") {return [Candidate(path:"index.html",backend:.web,engine:engine=="Windows" ? "HTML 游戏" : engine+" · Web")]}
  return []
 }
}

enum EntryPolicy {
 static func validate(_ entry:Candidate) throws {
  let parts=entry.path.split(separator:"/",omittingEmptySubsequences:false)
  guard !entry.path.hasPrefix("/"),!parts.contains(".."),!entry.path.isEmpty else {throw LibraryError("游戏入口路径无效。")}
  if entry.backend == .wine || entry.backend == .rpgmz {
   guard !entry.path.contains("\\"),!entry.path.contains(":"),!entry.path.contains("\""),!entry.path.unicodeScalars.contains(where:{$0.value<32}),!parts.contains(where:{$0.hasSuffix(" ") || $0.hasSuffix(".")}) else {throw LibraryError("游戏文件名无法安全映射到 Windows 路径，请先整理文件名。")}
  }
 }
}
struct CopyReceipt:Codable {var id:UUID;var source:String;var entry:Candidate}
struct Game: Codable, Identifiable {
 var id:UUID=UUID()
 var title:String
 var folder:String
 var originalFolder:String
 var entry:Candidate
 var favorite:Bool=false
 var lastPlayed:Date?=nil
 var cover:String?=nil
 var showPerformanceHUD:Bool?=nil
 var windowSize:String?=nil
 var nativeLanguage:String?=nil
}
struct GameCollection:Codable,Identifiable {
 var id:UUID=UUID()
 var name:String
 var gameIDs:[UUID]
}
final class LibraryStore {
 let root:URL
 var games:[Game]=[]
 private(set) var collections:[GameCollection]=[]
 private let fm=FileManager.default
 init(root:URL) throws {
  self.root=root
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  let file=root.appendingPathComponent("library.json")
  if fm.fileExists(atPath:file.path) {
   do { games=try JSONDecoder().decode([Game].self,from:Data(contentsOf:file)) }
   catch {throw LibraryError("游戏库文件无法读取，已保留原文件：\(file.path)。请先备份后修复，应用不会覆盖它。")}
  }
  let collectionFile=root.appendingPathComponent("collections.json")
  if fm.fileExists(atPath:collectionFile.path) {
   do {
    let loaded=try JSONDecoder().decode([GameCollection].self,from:Data(contentsOf:collectionFile))
    try Self.validateCollections(loaded)
    collections=loaded
   }catch{throw LibraryError("分类文件无法读取，已保留原文件：\(collectionFile.path)。请先备份后修复，应用不会覆盖它。")}
  }
 }
 private static func collectionName(_ name:String)throws->String {
  let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !trimmed.isEmpty,trimmed.count<=80 else{throw LibraryError("分类名称须为 1–80 个字符。")}
  return trimmed
 }
 private static func collectionNameKey(_ name:String)->String {
  name.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
 }
 private static func validateCollections(_ values:[GameCollection])throws {
  var ids=Set<UUID>(),names=Set<String>()
  for value in values {
   let name=try collectionName(value.name)
   guard name==value.name,ids.insert(value.id).inserted,names.insert(collectionNameKey(name)).inserted,
         Set(value.gameIDs).count==value.gameIDs.count else{throw LibraryError("分类包含重复名称、重复标识或无效数据。")}
   // Memberships may outlive removed library entries; queries filter against current games.
  }
 }
 private func commitCollections(_ next:[GameCollection])throws {
  try Self.validateCollections(next)
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(next).write(to:root.appendingPathComponent("collections.json"),options:.atomic)
  // Publish in memory only after the atomic write succeeds; failures leave prior state intact.
  collections=next
 }
 func createCollection(name:String)throws->GameCollection {
  let value=GameCollection(name:try Self.collectionName(name),gameIDs:[])
  try commitCollections(collections+[value])
  return value
 }
 func renameCollection(_ id:UUID,name:String)throws {
  guard let index=collections.firstIndex(where:{$0.id==id}) else{throw LibraryError("分类不存在。")}
  var next=collections;next[index].name=try Self.collectionName(name)
  try commitCollections(next)
 }
 func removeCollection(_ id:UUID)throws {
  guard collections.contains(where:{$0.id==id}) else{throw LibraryError("分类不存在。")}
  try commitCollections(collections.filter{$0.id != id})
 }
 func setCollections(for gameID:UUID,ids:Set<UUID>)throws {
  guard games.contains(where:{$0.id==gameID}) else{throw LibraryError("游戏已从库中移除。")}
  guard ids.isSubset(of:Set(collections.map(\.id))) else{throw LibraryError("所选分类不存在。")}
  var next=collections
  for index in next.indices {
   if ids.contains(next[index].id) {
    if !next[index].gameIDs.contains(gameID){next[index].gameIDs.append(gameID)}
   }else{next[index].gameIDs.removeAll{$0==gameID}}
  }
  try commitCollections(next)
 }
 func collectionIDs(for gameID:UUID)->Set<UUID> {
  guard games.contains(where:{$0.id==gameID}) else{return []}
  return Set(collections.filter{$0.gameIDs.contains(gameID)}.map(\.id))
 }
 func games(inCollection id:UUID)->[Game] {
  guard let value=collections.first(where:{$0.id==id}) else{return []}
  let members=Set(value.gameIDs)
  return games.filter{members.contains($0.id)}
 }
 var uncategorizedGames:[Game] {
  let members=Set(collections.flatMap(\.gameIDs))
  return games.filter{!members.contains($0.id)}
 }
 func save() throws {
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(games).write(to:root.appendingPathComponent("library.json"),options:.atomic)
 }
 func add(source:URL,candidate:Candidate) throws -> Game {
  try EntryPolicy.validate(candidate)
  let folder=source.standardizedFileURL.resolvingSymlinksInPath()
  let entry=folder.appendingPathComponent(candidate.path).standardizedFileURL
  guard entry.path==folder.path || entry.path.hasPrefix(folder.path+"/") else {throw LibraryError("游戏入口超出所选目录。")}
  guard fm.fileExists(atPath:entry.path) else {throw LibraryError("找不到游戏入口，NAS 可能已断开。")}
  if let g=games.first(where:{$0.originalFolder==folder.path && $0.entry==candidate}) {return g}
  let g=Game(title:folder.pathExtension.lowercased()=="app" ? folder.deletingPathExtension().lastPathComponent : folder.lastPathComponent,folder:folder.path,originalFolder:folder.path,entry:candidate,windowSize:candidate.backend == .wine ? "1280x720":nil)
  games.append(g)
  do {try save()} catch {games.removeLast();throw error}
  return g
 }
 func update(_ game:Game) throws {
  guard let index=games.firstIndex(where:{$0.id==game.id}) else {throw LibraryError("游戏已从库中移除。")}
  let previous=games[index];games[index]=game
  do {try save()} catch {games[index]=previous;throw error}
 }
 func recordPlayed(_ id:UUID,date:Date=Date())throws {
  guard var game=games.first(where:{$0.id==id}) else{throw LibraryError("游戏已从库中移除。")}
  game.lastPlayed=date;try update(game)
 }
 func renameGame(_ id:UUID,name:String)throws {
  let title=name.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !title.isEmpty,title.count<=160,!title.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw LibraryError("游戏名称须为 1–160 个字符，不能包含换行或控制字符。")}
  guard var game=games.first(where:{$0.id==id}) else{throw LibraryError("游戏已从库中移除。")}
  game.title=title;try update(game)
 }
 func remove(_ id:UUID) throws {
  let previous=games;games.removeAll{$0.id==id}
  do {try save()} catch {games=previous;throw error}
 }
 // Copy never writes into the original game. Caller runs this away from the UI thread.
 func download(_ game:Game) throws -> Game {
  let source=URL(fileURLWithPath:game.folder).standardizedFileURL.resolvingSymlinksInPath()
  let parent=root.appendingPathComponent("Games")
  let destination=parent.appendingPathComponent(game.id.uuidString)
  var result=game;result.folder=destination.path
  if source==destination{return game}
  let receipts=root.appendingPathComponent("CopyReceipts")
  let receiptURL=receipts.appendingPathComponent(game.id.uuidString+".json")
  if fm.fileExists(atPath:destination.path) {
   if let data=try? Data(contentsOf:receiptURL),let receipt=try? JSONDecoder().decode(CopyReceipt.self,from:data),receipt.id==game.id,receipt.source==source.path,receipt.entry==game.entry,fm.fileExists(atPath:destination.appendingPathComponent(game.entry.path).path){return result}
   throw LibraryError("本地目录已存在但无法验证归属，未覆盖。请在 Finder 中检查。")
  }
  guard fm.fileExists(atPath:source.path) else {throw LibraryError("原游戏目录不可用，请连接 NAS 后再下载。")}
  guard !destination.resolvingSymlinksInPath().path.hasPrefix(source.path+"/") else {throw LibraryError("不能把游戏复制到它自己的子目录。")}
  // Preserve internal links as relative links; external dependencies cannot be called an offline copy.
  var links:[(String,String)]=[]
  var traversalError:Error?
  if let walker=fm.enumerator(at:source,includingPropertiesForKeys:[.isSymbolicLinkKey],options:[],errorHandler:{_,error in traversalError=error;return false}) {
   for case let raw as URL in walker {
    let item=raw.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(raw.lastPathComponent)
    if (try? fm.destinationOfSymbolicLink(atPath:item.path)) != nil {
     walker.skipDescendants()
     let target=item.resolvingSymlinksInPath()
     guard target.path==source.path || target.path.hasPrefix(source.path+"/") else {throw LibraryError("游戏包含指向目录外部的链接，无法保证离线可用，未创建本地副本：\(item.lastPathComponent)")}
     let from=item.deletingLastPathComponent().pathComponents,to=target.pathComponents
     var common=0;while common<min(from.count,to.count),from[common]==to[common]{common+=1}
     let relative=(Array(repeating:"..",count:from.count-common)+Array(to.dropFirst(common))).joined(separator:"/")
     links.append((String(item.path.dropFirst(source.path.count+1)),relative.isEmpty ? ".":relative))
    }
   }
  }
  if let traversalError {throw traversalError}
  try fm.createDirectory(at:parent,withIntermediateDirectories:true)
  let staging=parent.appendingPathComponent(".partial-"+UUID().uuidString)
  defer{try? fm.removeItem(at:staging)}
  try fm.copyItem(at:source,to:staging)
  for (path,target) in links {
   let link=staging.appendingPathComponent(path)
   try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:target)
  }
  try fm.createDirectory(at:receipts,withIntermediateDirectories:true)
  let receipt=CopyReceipt(id:game.id,source:source.path,entry:game.entry)
  try JSONEncoder().encode(receipt).write(to:receiptURL,options:.atomic)
  try fm.moveItem(at:staging,to:destination)
  return result
 }
}

/// Only short-lived environment preparation helpers; never register game processes.
final class PreparationTaskGroup {
 private let lock=NSLock()
 private var cancelled=false
 private var processes:[ObjectIdentifier:Process]=[:]
 func run(_ process:Process,launcher:(Process)throws->Void={try $0.run()})throws {
  lock.lock();let stopped=cancelled;lock.unlock()
  guard !stopped else{throw LibraryError("准备任务已取消。")}
  // Spawn can block on a remote working directory. Never hold the state lock here.
  try launcher(process)
  lock.lock();let cancelledDuringStart=cancelled
  if !cancelledDuringStart{processes[ObjectIdentifier(process)]=process}
  lock.unlock()
  if cancelledDuringStart {
   if process.isRunning{process.terminate()}
   throw LibraryError("准备任务已取消。")
  }
 }
 func finish(_ process:Process){lock.lock();processes.removeValue(forKey:ObjectIdentifier(process));lock.unlock()}
 func cancel(){
  lock.lock();cancelled=true;let owned=Array(processes.values);lock.unlock()
  for process in owned where process.isRunning{process.terminate()}
 }
}
enum PreparationTasks {static let shared=PreparationTaskGroup()}

struct ImportProgress {
 enum Outcome{case added,existing,failed,cancelled}
 let total:Int
 private(set) var processed=0
 private(set) var added=0
 private(set) var existing=0
 private(set) var failed=0
 private(set) var cancelled=0
 func checking(_ name:String)->String{"正在导入 \(processed+1)/\(total)：识别「\(name)」…"}
 mutating func record(_ outcome:Outcome){
  processed+=1
  switch outcome{case .added:added+=1;case .existing:existing+=1;case .failed:failed+=1;case .cancelled:cancelled+=1}
 }
 var summary:String {
  var text="导入完成：已添加 \(added) 项"
  if existing>0{text+="，已在库中 \(existing) 项"}
  if failed>0{text+="，失败 \(failed) 项"}
  if cancelled>0{text+="，取消 \(cancelled) 项"}
  return text+"。"
 }
}
