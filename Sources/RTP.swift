import Foundation
enum RTP {
 static func requirement(_ folder:URL) throws -> String? {
  let file=folder.appendingPathComponent("Game.ini")
  guard FileManager.default.fileExists(atPath:file.path) else{return nil}
  let data=try Data(contentsOf:file)
  guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) ?? String(data:data,encoding:.isoLatin1) else{throw LibraryError("无法读取 Game.ini。")}
  var section=""
  for raw in text.components(separatedBy:.newlines){
   let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
   if line.hasPrefix("[") && line.hasSuffix("]"){section=String(line.dropFirst().dropLast()).lowercased();continue}
   guard section=="game",let equals=line.firstIndex(of:"=") else{continue}
   let key=line[..<equals].trimmingCharacters(in:.whitespaces).lowercased()
   guard key=="rtp" || key=="rtp1" else{continue}
   let name=line[line.index(after:equals)...].trimmingCharacters(in:.whitespaces)
   if name.isEmpty{return nil}
   guard ["RPGVXAce","RPGVX","Standard"].contains(name) else{throw LibraryError("游戏声明了无法识别的 RTP："+name)}
   return name
  }
  return nil
 }
}
extension RTP {
 static func assets(game:Game,root:URL) throws -> (name:String,directory:URL)? {
  guard let name=try requirement(URL(fileURLWithPath:game.folder)) else{return nil}
  let directory=root.appendingPathComponent(name)
  let fm=FileManager.default
  guard fm.fileExists(atPath:directory.appendingPathComponent("Audio").path),fm.fileExists(atPath:directory.appendingPathComponent("Graphics").path) else {throw LibraryError("此游戏需要 "+name+" 公共运行资源。请先从 RPG Maker 官方获取并按许可安装到："+directory.path)}
  let receipt=directory.appendingPathComponent("GameShelf-install-complete.json")
  guard let data=try? Data(contentsOf:receipt),let record=try? JSONSerialization.jsonObject(with:data) as? [String:Any],record["name"] as? String==name,record["installerExitCode"] as? Int==0 else{throw LibraryError(name+" 资源尚未完成安装或验证，请等待安装结束后再启动。")}
  return (name,directory)
 }
 static func installedAssets(prefix:URL,name:String,managedRoot:URL?=nil)->URL? {
  guard let generation=["RPGVXAce":"RGSS3","RPGVX":"RGSS2","Standard":"RGSS"][name],let text=try? String(contentsOf:prefix.appendingPathComponent("system.reg"),encoding:.utf8) else{return nil}
  var matching=false
  for raw in text.components(separatedBy:.newlines) {
   let line=raw.trimmingCharacters(in:.whitespaces)
   if line.hasPrefix("[") {
    let section=line.replacingOccurrences(of:"\\\\",with:"\\").lowercased()
    matching=section.hasPrefix("[software\\wow6432node\\enterbrain\\"+generation.lowercased()+"\\rtp]") || section.hasPrefix("[software\\enterbrain\\"+generation.lowercased()+"\\rtp]")
   }else if matching,line.hasPrefix("\""+name+"\"="),let equals=line.firstIndex(of:"=") {
    let value=String(line[line.index(after:equals)...])
    guard value.hasPrefix("\""),value.hasSuffix("\"") else{continue}
    let path=String(value.dropFirst().dropLast()).replacingOccurrences(of:"\\\\",with:"\\")
    guard path.count>2,path[path.index(after:path.startIndex)]==":" else{continue}
    let drive=String(path.prefix(1)).lowercased()
    let tail=String(path.dropFirst(2)).replacingOccurrences(of:"\\",with:"/").trimmingCharacters(in:CharacterSet(charactersIn:"/"))
    let base:URL
    if drive=="c" {base=prefix.appendingPathComponent("drive_c")}
    else if drive=="z" {base=URL(fileURLWithPath:"/")}
    else {base=prefix.appendingPathComponent("dosdevices/"+drive+":").resolvingSymlinksInPath()}
    let directory=base.appendingPathComponent(tail).standardizedFileURL
    if let managedRoot,directory.resolvingSymlinksInPath().path==managedRoot.appendingPathComponent(name).resolvingSymlinksInPath().path {
     guard let data=try? Data(contentsOf:directory.appendingPathComponent("GameShelf-install-complete.json")),let record=try? JSONSerialization.jsonObject(with:data) as? [String:Any],record["name"] as? String==name,record["installerExitCode"] as? Int==0 else{return nil}
    }
    if ["Audio","Graphics"].allSatisfy({FileManager.default.fileExists(atPath:directory.appendingPathComponent($0).path)}) {return directory}
   }
  }
  return nil
 }
 static func register(game:Game,runtime:URL,root:URL) throws {
  guard let name=try requirement(URL(fileURLWithPath:game.folder)) else{return}
  if installedAssets(prefix:runtime.appendingPathComponent("Contents/SharedSupport/prefix"),name:name,managedRoot:root) != nil{return}
  guard let dependency=try assets(game:game,root:root) else{return}
  let marker=runtime.appendingPathComponent("Contents/SharedSupport/rtp-registration.txt")
  let signature=dependency.name+"\n"+dependency.directory.path
  if (try? String(contentsOf:marker,encoding:.utf8))==signature{return}
  let generation=["RPGVXAce":"RGSS3","RPGVX":"RGSS2","Standard":"RGSS"][dependency.name]!
  let spec=try Wrapper.launchSpec(game:game,runtime:runtime)
  let p=Process();p.executableURL=spec.executable;p.environment=spec.environment
  let path="Z:"+dependency.directory.path.replacingOccurrences(of:"/",with:"\\")
  p.arguments=["reg","add","HKLM\\Software\\Enterbrain\\"+generation+"\\RTP","/v",dependency.name,"/t","REG_SZ","/d",path,"/f","/reg:32"]
  p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
  let done=DispatchSemaphore(value:0);p.terminationHandler={_ in done.signal()}
  try PreparationTasks.shared.run(p)
  defer{PreparationTasks.shared.finish(p)}
  guard done.wait(timeout:.now()+60) == .success else{p.terminate();throw LibraryError("登记 RTP 超时，请检查 NAS 连接。")}
  guard p.terminationStatus==0 else{throw LibraryError("登记 RTP 失败，代码 "+String(p.terminationStatus))}
  try signature.write(to:marker,atomically:true,encoding:.utf8)
 }
}
