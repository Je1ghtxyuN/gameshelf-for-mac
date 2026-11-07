import Foundation

enum PureOnyxDisplaySettings {
 static func updating(_ text:String,fullscreen:Bool)->String {
  let newline=text.contains("\r\n") ? "\r\n":"\n"
  var lines=text.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n")
  if lines.last==""{lines.removeLast()}
  let start=lines.firstIndex{$0.trimmingCharacters(in:.whitespaces)=="[Screen]"}
  let values=[("Fullscreen",fullscreen ? "True":"False"),("Resolution","1280 x 720")]
  if let start {
   let end=lines.indices.dropFirst(start+1).first{lines[$0].trimmingCharacters(in:.whitespaces).hasPrefix("[")} ?? lines.count
   var missing:[String]=[]
   for (key,value) in values {
    if let i=(start+1..<end).first(where:{lines[$0].components(separatedBy:"=").first?.trimmingCharacters(in:.whitespaces)==key}){lines[i]=key+" = "+value}
    else{missing.append(key+" = "+value)}
   }
   lines.insert(contentsOf:missing,at:end)
  }else{lines += ["[Screen]"]+values.map{$0.0+" = "+$0.1}}
  return lines.joined(separator:newline)+newline
 }
 static func apply(prefix:URL,fullscreen:Bool)throws {
  let users=prefix.appendingPathComponent("drive_c/users")
  let fm=FileManager.default
  let folders=(try? fm.contentsOfDirectory(at:users,includingPropertiesForKeys:nil)) ?? []
  var seen=Set<String>()
  for user in folders where !["public","default","default user","all users"].contains(user.lastPathComponent.lowercased()) {
   let file=user.appendingPathComponent("AppData/LocalLow/Eromancer/pure-onyx/Settings.ini").resolvingSymlinksInPath()
   guard seen.insert(file.path).inserted else{continue}
   let old=fm.fileExists(atPath:file.path) ? try String(contentsOf:file,encoding:.utf8):""
   let next=updating(old,fullscreen:fullscreen)
   guard old != next else{continue}
   try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
   if !old.isEmpty {
    let backup=file.appendingPathExtension("gameshelf-display-backup")
    if !fm.fileExists(atPath:backup.path){try Data(old.utf8).write(to:backup,options:.atomic)}
   }
   try Data(next.utf8).write(to:file,options:.atomic)
  }
 }
}
