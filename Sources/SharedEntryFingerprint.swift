import Foundation
import CryptoKit

enum SharedEntryFingerprint {
 static func hash(folder:URL,entry:Candidate)throws->String {
  try EntryPolicy.validate(entry)
  let root=folder.standardizedFileURL.resolvingSymlinksInPath()
  var file=entry.path=="." ? root:root.appendingPathComponent(entry.path).standardizedFileURL
  if entry.backend == .native && file.pathExtension.lowercased()=="app"{file=file.appendingPathComponent("Contents/Info.plist")}
  guard file.path.hasPrefix(root.path+"/") else{throw LibraryError("游戏入口超出目录。")}
  var current=root
  for part in file.path.dropFirst(root.path.count+1).split(separator:"/") {
   current.appendPathComponent(String(part))
   let info=try FileManager.default.attributesOfItem(atPath:current.path)
   guard info[.type] as? FileAttributeType != .typeSymbolicLink else{throw LibraryError("共享入口不能使用符号链接。")}
  }
  let info=try FileManager.default.attributesOfItem(atPath:file.path)
  let limit:Int64=(entry.backend == .native && file.lastPathComponent=="Info.plist") ? 1024*1024:128*1024*1024
  guard info[.type] as? FileAttributeType == .typeRegular,let size=info[.size] as? NSNumber,size.int64Value<=limit else{throw LibraryError("无法核对共享游戏入口。")}
  let input=try FileHandle(forReadingFrom:file);defer{try? input.close()}
  var hash=SHA256(),total:Int64=0
  while let bytes=try input.read(upToCount:1024*1024),!bytes.isEmpty {
   total+=Int64(bytes.count);guard total<=limit else{throw LibraryError("游戏入口超过核对大小限制。")};hash.update(data:bytes)
  }
  guard total==size.int64Value else{throw LibraryError("游戏入口正在变化，请稍后重试。")}
  return hash.finalize().map{String(format:"%02x",$0)}.joined()
 }
}
