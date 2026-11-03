import Foundation
import CryptoKit

/// A library entry can be removed/reimported without creating a fresh save container.
final class WebSaveBindings {
 private let file:URL
 private var bindings:[String:UUID]
 init(root:URL,fileName:String="WebSaveBindings.json")throws {
  guard fileName.range(of:"^[A-Za-z0-9_-]+\\.json$",options:.regularExpression) != nil else{throw LibraryError("无效的存档关联文件名。")}
  file=root.appendingPathComponent(fileName)
  if FileManager.default.fileExists(atPath:file.path){
   do{bindings=try JSONDecoder().decode([String:UUID].self,from:Data(contentsOf:file))}
   catch{throw LibraryError("网页存档关联文件损坏，已保留原件，未创建新的空存档位置。")}
  }else{bindings=[:]}
 }
 func resolve(source:String,initial:UUID)throws->UUID {
  let key=URL(fileURLWithPath:source).standardizedFileURL.path
  if let value=bindings[key]{return value}
  var next=bindings;next[key]=initial
  try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  try encoder.encode(next).write(to:file,options:.atomic);bindings=next;return initial
 }
}

struct MZSaveArchive {
 let gameId:Int
 let files:[String:String]
 let fingerprint:String
 let backup:URL
 private let receipt:URL
 private let storageID:UUID
 var payload:String {
  let data=try! JSONSerialization.data(withJSONObject:["gameId":gameId,"files":files],options:[.sortedKeys])
  // Base64 keeps arbitrary save bytes and Unicode out of executable script source.
  return data.base64EncodedString()
 }
 func markCompleted(imported:Int)throws {
  let data=try JSONSerialization.data(withJSONObject:["fingerprint":fingerprint,"storageID":storageID.uuidString,"imported":imported,"backup":backup.path,"completed":ISO8601DateFormatter().string(from:Date())],options:[.prettyPrinted,.sortedKeys])
  try FileManager.default.createDirectory(at:receipt.deletingLastPathComponent(),withIntermediateDirectories:true)
  try data.write(to:receipt,options:.atomic)
 }
 static func prepare(folder:URL,storageID:UUID,root:URL,webKitDirectory:URL?)throws->MZSaveArchive? {
  let fm=FileManager.default,base=folder.standardizedFileURL.resolvingSymlinksInPath()
  // Windows is case insensitive; Unix NAS shares are not.
  let save=try fm.contentsOfDirectory(at:base,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles]).first{$0.lastPathComponent.caseInsensitiveCompare("save") == .orderedSame}
  guard let save else{return nil}
  let resolved=save.resolvingSymlinksInPath()
  guard resolved.path.hasPrefix(base.path+"/") else{throw LibraryError("旧存档文件夹指向游戏目录之外，未自动迁移。")}
  let entries=try fm.contentsOfDirectory(at:resolved,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey],options:[.skipsHiddenFiles]).filter{$0.pathExtension.lowercased()=="rmmzsave"}
  guard entries.contains(where:{$0.deletingPathExtension().lastPathComponent.range(of:"^file[0-9]{1,3}$",options:.regularExpression) != nil}) else{return nil}
  guard entries.count<=110 else{throw LibraryError("旧存档文件数量异常，已停止自动迁移。")}
  var raw:[String:Data]=[:],files:[String:String]=[:],total=0
  for entry in entries.sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
   let values=try entry.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
   guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=4*1024*1024 else{throw LibraryError("旧存档含链接或文件过大，未自动迁移。")}
   let bytes=try Data(contentsOf:entry);total+=bytes.count
   guard total<=16*1024*1024 else{throw LibraryError("旧存档总量过大，未自动迁移。")}
   raw[entry.lastPathComponent]=bytes
   let name=entry.deletingPathExtension().lastPathComponent
   if name=="global" || name.range(of:"^file[0-9]{1,3}$",options:.regularExpression) != nil {
    guard let string=String(data:bytes,encoding:.utf8),!string.isEmpty else{throw LibraryError("旧存档编码无法读取，原件已保留。")}
    files[name]=string
   }
  }
  guard files["global"] != nil else{throw LibraryError("找到旧进度，但缺少 global.rmmzsave 索引，未写入空存档或覆盖现有进度。")}
  let system=try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("data/System.json"))) as? [String:Any]
  guard let advanced=system?["advanced"] as? [String:Any],let gameID=advanced["gameId"] as? Int,gameID>0 else{throw LibraryError("无法确认旧存档所属游戏。")}
  var digest=SHA256();digest.update(data:Data(String(gameID).utf8))
  for key in files.keys.sorted(){digest.update(data:Data(key.utf8));digest.update(data:Data(files[key]!.utf8))}
  let fingerprint=digest.finalize().map{String(format:"%02x",$0)}.joined()
  let receipt=root.appendingPathComponent("Saves/Migrations/"+storageID.uuidString+"-"+fingerprint+".json")
  if fm.fileExists(atPath:receipt.path){return nil}
  let backup=root.appendingPathComponent("Saves/Backups/"+storageID.uuidString+"/"+fingerprint)
  if !fm.fileExists(atPath:backup.path) {
   let stage=backup.deletingLastPathComponent().appendingPathComponent(".preparing-"+UUID().uuidString)
   try fm.createDirectory(at:stage.appendingPathComponent("WindowsSave"),withIntermediateDirectories:true)
   do {
    for (name,bytes) in raw{try bytes.write(to:stage.appendingPathComponent("WindowsSave/"+name),options:.atomic)}
    if let webKitDirectory,fm.fileExists(atPath:webKitDirectory.path){try fm.copyItem(at:webKitDirectory,to:stage.appendingPathComponent("WebKitBeforeImport"))}
    try fm.moveItem(at:stage,to:backup)
   }catch{try? fm.removeItem(at:stage);throw error}
  }
  return MZSaveArchive(gameId:gameID,files:files,fingerprint:fingerprint,backup:backup,receipt:receipt,storageID:storageID)
 }
}
