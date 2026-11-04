import Foundation
@main struct SharedWineRuntimeTests {
 static func main()throws {
  struct Failure:Error{let message:String}
  func check(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(message:message)}}
  let fm=FileManager.default,root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("SharedWine-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
  let source=root.appendingPathComponent("Source.app"),destination=root.appendingPathComponent("Private.app"),folder=root.appendingPathComponent("Game")
  func put(_ url:URL,_ text:String)throws{try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url)}
  try put(source.appendingPathComponent("Contents/MacOS/wineskinlauncher"),"")
  try put(source.appendingPathComponent("Contents/SharedSupport/wine/bin/wine64"),"")
  try fm.createDirectory(at:source.appendingPathComponent("Contents/Frameworks"),withIntermediateDirectories:true)
  let seed=source.appendingPathComponent("Contents/SharedSupport/prefix")
  try put(seed.appendingPathComponent("drive_c/ProgramData/Owner/progress.sav"),"owner progress")
  try put(seed.appendingPathComponent("user.reg"),"owner registry")
  try PropertyListSerialization.data(fromPropertyList:["CFBundleName":"Fixture"],format:.xml,options:0).write(to:source.appendingPathComponent("Contents/Info.plist"))
  try put(folder.appendingPathComponent("Game.exe"),"MZ fixture")
  let ref=SharedGameReference(connectionID:UUID(),serverID:"server",accountID:"alice",gameID:"story")
  let game=Game(title:"Story",folder:folder.path,originalFolder:"shared",entry:Candidate(path:"Game.exe",backend:.wine,engine:"Windows"),shared:ref)
  _ = try Wrapper.prepare(game:game,source:source,destination:destination,shareEngine:true,freshPrefix:true)
  let prefix=destination.appendingPathComponent("Contents/SharedSupport/prefix")
  try check(!fm.fileExists(atPath:prefix.appendingPathComponent("drive_c/ProgramData/Owner/progress.sav").path),"template ProgramData was copied into a shared account")
  try check(!fm.fileExists(atPath:prefix.appendingPathComponent("user.reg").path),"template registry copied")
  try check(fm.fileExists(atPath:prefix.appendingPathComponent("drive_c").path),"fresh C drive missing")
  try check(try fm.destinationOfSymbolicLink(atPath:prefix.appendingPathComponent("dosdevices/c:").path)=="../drive_c","fresh C mapping missing")
  try check(try fm.destinationOfSymbolicLink(atPath:prefix.appendingPathComponent("dosdevices/z:").path)=="/","fresh host-path mapping missing")
  var calls=0
  try SharedWineBootstrap.prepare(game:game,runtime:destination){spec,_ in
   calls+=1
   try check(spec.environment["WINEPREFIX"]==prefix.path,"wrong prefix")
   if spec.arguments.first=="wineboot" {
    try put(prefix.appendingPathComponent("user.reg"),"fresh registry")
    try fm.createDirectory(at:prefix.appendingPathComponent("drive_c/users/engine-user/Documents"),withIntermediateDirectories:true)
   }
  }
  try check(calls>0,"first launch skipped fresh Wine initialization")
  try check(try String(contentsOf:prefix.appendingPathComponent("user.reg"),encoding:.utf8)=="fresh registry","fresh registry was erased and would trigger reinitialization")
  let link=try fm.destinationOfSymbolicLink(atPath:prefix.appendingPathComponent("drive_c/users/engine-user").path)
  try check(link.hasSuffix("/WindowsUsers/Player"),"engine-generated user was not isolated")
  calls=0
  try SharedWineBootstrap.prepare(game:game,runtime:destination){_,_ in calls+=1}
  try check(calls==0,"repeated launch recreated account prefix")
  try check(try String(contentsOf:seed.appendingPathComponent("drive_c/ProgramData/Owner/progress.sav"),encoding:.utf8)=="owner progress","source progress changed")
  print("PASS SharedWineRuntime: engine-only fresh prefix, no ProgramData/user-registry inheritance, initialized profile mapping and repeat launch")
 }
}
