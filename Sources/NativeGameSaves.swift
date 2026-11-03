import Foundation
import CryptoKit

/// Explicitly verified Godot project. Other projects keep their own data paths.
enum NativeGameSaves {
 static func storageID(game:Game,localRoot:URL)throws->UUID {
  let source=URL(fileURLWithPath:game.originalFolder).appendingPathComponent(game.entry.path).standardizedFileURL.resolvingSymlinksInPath().path
  return try WebSaveBindings(root:localRoot,fileName:"NativeSaveBindings.json").resolve(source:source,initial:game.id)
 }

 static func preparePhoenixes(game:Game,managedRoot:URL,localRoot:URL,home:URL=FileManager.default.homeDirectoryForCurrentUser)throws {
  let fm=FileManager.default
  guard fm.fileExists(atPath:managedRoot.path) else{throw LibraryError("NAS 存档目录不可用，请连接 NAS 后启动。")}
  let storageID=try storageID(game:game,localRoot:localRoot)
  let target=managedRoot.appendingPathComponent("Saves/NativeApps/"+storageID.uuidString).standardizedFileURL
  let current=home.appendingPathComponent("Library/Application Support/Godot/app_userdata/Phoenixes").standardizedFileURL
  if let link=try? fm.destinationOfSymbolicLink(atPath:current.path){
   guard URL(fileURLWithPath:link,relativeTo:current.deletingLastPathComponent()).standardizedFileURL.path==target.path else{throw LibraryError("Phoenixes 用户目录已关联其他位置，已保留，未自动替换。")}
   try fm.createDirectory(at:target,withIntermediateDirectories:true);return
  }
  // Do not write through a substituted ancestor into another game's directory.
  var parent=current.deletingLastPathComponent()
  while parent.path != home.standardizedFileURL.path && parent.path != "/" {
   if (try? fm.destinationOfSymbolicLink(atPath:parent.path)) != nil{throw LibraryError("Phoenixes 存档路径包含外部目录链接，未修改。")}
   parent.deleteLastPathComponent()
  }
  var files:[(URL,String)]=[]
  if fm.fileExists(atPath:current.path){
   guard (try fm.attributesOfItem(atPath:current.path)[.type] as? FileAttributeType) == .typeDirectory else{throw LibraryError("Phoenixes 用户目录被文件占用，未修改。")}
   var walkError:Error?
   if let walk=fm.enumerator(at:current,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey],errorHandler:{_,error in walkError=error;return false}){
    for case let file as URL in walk {
     let relative=String(file.standardizedFileURL.path.dropFirst(current.standardizedFileURL.path.count+1))
     if relative=="logs" || relative=="shader_cache"{walk.skipDescendants();continue}
     let values=try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
     guard values.isSymbolicLink != true else{throw LibraryError("Phoenixes 存档中含外部链接，未移动。")}
     if values.isRegularFile==true {
      guard (values.fileSize ?? Int.max)<=20*1024*1024 else{throw LibraryError("Phoenixes 用户文件过大，未自动迁移。")}
      let destination=target.appendingPathComponent(relative)
      if fm.fileExists(atPath:destination.path){
       guard try Data(contentsOf:file)==Data(contentsOf:destination) else{throw LibraryError("Phoenixes 已有 Mac 进度与旧进度冲突，原件均保留。请先完成存档合并。")}
      }else{files.append((file,relative))}
     }
    }
   }
   if let walkError{throw walkError}
  }
  try fm.createDirectory(at:target,withIntermediateDirectories:true)
  var backup:URL?,created:[URL]=[]
  do {
   if fm.fileExists(atPath:current.path){
    let location=localRoot.appendingPathComponent("Saves/Backups/"+game.id.uuidString+"/GodotBeforeLink-"+UUID().uuidString)
    try fm.createDirectory(at:location.deletingLastPathComponent(),withIntermediateDirectories:true)
    try fm.moveItem(at:current,to:location);backup=location
    for (_,relative) in files {
     let destination=target.appendingPathComponent(relative)
     try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
     created.append(destination);try fm.copyItem(at:location.appendingPathComponent(relative),to:destination)
    }
   }
   try fm.createDirectory(at:current.deletingLastPathComponent(),withIntermediateDirectories:true)
   try fm.createSymbolicLink(atPath:current.path,withDestinationPath:target.path)
  }catch{
   for file in created.reversed(){try? fm.removeItem(at:file)}
   if let backup,!fm.fileExists(atPath:current.path){try? fm.moveItem(at:backup,to:current)}
   throw error
  }
 }
}
