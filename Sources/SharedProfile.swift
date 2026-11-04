import Foundation

enum SharedProfile {
 private static func userFolder(_ name:String,under profile:URL)->URL {
  switch name.lowercased() {
  case "default","default user":return profile.appendingPathComponent("Default")
  case "public","all users":return profile.appendingPathComponent("Public")
  default:return profile.appendingPathComponent("Player")
  }
 }
 static func localRuntimeRoot(game:Game,root:URL)->URL {
  guard let ref=game.shared else{return root}
  return root.appendingPathComponent("SharedRuntime/"+ref.storageKey)
 }
 static func networkProfile(game:Game)throws->URL {
  guard game.shared != nil else{throw LibraryError("这个游戏不属于共享账号。")}
  let base=URL(fileURLWithPath:game.folder).standardizedFileURL
  let profile=base.appendingPathComponent(".gameshelf-profile")
  let fm=FileManager.default
  if (try? fm.destinationOfSymbolicLink(atPath:profile.path)) != nil{throw LibraryError("个人存档目录不能是外部链接。")}
  try fm.createDirectory(at:profile,withIntermediateDirectories:true)
  guard profile.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path+"/") else{throw LibraryError("个人存档目录超出了游戏共享。")}
  return profile
 }
 static func prepareWine(game:Game,runtime:URL,removeSeedRegistry:Bool=true)throws {
  guard let ref=game.shared else{return}
  let fm=FileManager.default
  let prefix=runtime.appendingPathComponent("Contents/SharedSupport/prefix")
  let marker=prefix.appendingPathComponent("gameshelf-account.json")
  let users=prefix.appendingPathComponent("drive_c/users")
  let profile=try networkProfile(game:game).appendingPathComponent("WindowsUsers")
  let identity=ref.storageKey
  if fm.fileExists(atPath:marker.path) {
   guard let record=try JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as? [String:Any],record["identity"] as? String==identity,record["schema"] as? String=="3",
         let recorded=record["users"] as? [String],!recorded.isEmpty else{throw LibraryError("运行环境属于其他账号或旧版映射，未启动游戏。")}
   // The stable mount point survives disconnects; mappings must still be exact.
   let present=Set(try fm.contentsOfDirectory(atPath:users.path))
   guard Set(recorded).isSubset(of:present),Set([NSUserName(),"Public","Default"]).isSubset(of:present) else{throw LibraryError("共享运行环境的个人目录映射缺失，未启动游戏。")}
   for name in present {
    guard let link=try? fm.destinationOfSymbolicLink(atPath:users.appendingPathComponent(name).path),link==userFolder(name,under:profile).path else{throw LibraryError("共享运行环境的个人目录映射已改变，未继续写入。")}
   }
   return
  }
  // A shared prefix is seeded from an installed engine, never from its user data.
  // Remove links themselves; do not traverse them into the owner's home folder.
  let oldNames=(try? fm.contentsOfDirectory(atPath:users.path)) ?? []
  let names=Set(oldNames+[NSUserName(),"Public","Default"])
  for name in names {
   guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\\"),!name.contains(":") else{throw LibraryError("Windows 用户目录名称无效。")}
  }
  if !removeSeedRegistry {
   let info=runtime.appendingPathComponent("Contents/Info.plist")
   guard let value=try PropertyListSerialization.propertyList(from:Data(contentsOf:info),format:nil) as? [String:Any],value["GameShelfFreshPrefix"] as? Bool==true else{throw LibraryError("仅允许全新引擎环境保留初始化后的注册表。")}
  }
  for name in removeSeedRegistry ? ["user.reg","userdef.reg"] : [] {
   let file=prefix.appendingPathComponent(name)
   if fm.fileExists(atPath:file.path) || (try? fm.destinationOfSymbolicLink(atPath:file.path)) != nil {try fm.removeItem(at:file)}
  }
  if fm.fileExists(atPath:users.path) || (try? fm.destinationOfSymbolicLink(atPath:users.path)) != nil {try fm.removeItem(at:users)}
  try fm.createDirectory(at:users,withIntermediateDirectories:true)
  for name in names.sorted() {
   // macOS login names may differ between two devices using one GameShelf
   // account. All regular Windows usernames resolve to the stable Player tree.
   let target=userFolder(name,under:profile)
   for relative in ["Desktop","Documents","Downloads","Music","Pictures","Videos","AppData/Roaming","AppData/Local","AppData/LocalLow","Temp"] {
    try fm.createDirectory(at:target.appendingPathComponent(relative),withIntermediateDirectories:true)
   }
   // SMB servers may prohibit remote symlinks. Keep legacy paths writable
   // private directories; Wine's known-folder registry supplies modern paths.
   for (alias,path) in [("Application Data","AppData/Roaming"),("Local Settings","AppData/Local"),("My Documents","Documents")] {
    let link=target.appendingPathComponent(alias)
    _ = path
    try fm.createDirectory(at:link,withIntermediateDirectories:true)
   }
   try fm.createSymbolicLink(atPath:users.appendingPathComponent(name).path,withDestinationPath:target.path)
  }
  try JSONSerialization.data(withJSONObject:["identity":identity,"schema":"3","users":names.sorted()],options:.sortedKeys).write(to:marker,options:.atomic)
 }
}
