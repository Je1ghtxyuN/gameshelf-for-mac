import Foundation
@main struct SharedProfileTests {
 static func main()throws {
  struct Failure:Error{var message:String}
  func check(_ value:Bool,_ message:String)throws{if !value{throw Failure(message:message)}}
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("SharedProfile-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
  let original=root.appendingPathComponent("owner-home");try fm.createDirectory(at:original,withIntermediateDirectories:true)
  try Data("owner progress".utf8).write(to:original.appendingPathComponent("old.sav"))
  let source=SharedGameReference(connectionID:UUID(),serverID:"server",accountID:"alice",gameID:"story")
  let mounted=root.appendingPathComponent("network");try fm.createDirectory(at:mounted,withIntermediateDirectories:true)
  let game=Game(title:"Story",folder:mounted.path,originalFolder:"remote",entry:Candidate(path:"Game.exe",backend:.wine,engine:"Windows"),shared:source)
  let runtime=root.appendingPathComponent("runtime.app"),prefix=runtime.appendingPathComponent("Contents/SharedSupport/prefix")
  try fm.createDirectory(at:prefix.appendingPathComponent("drive_c/users/owner"),withIntermediateDirectories:true)
  try fm.createSymbolicLink(at:prefix.appendingPathComponent("drive_c/users/owner/Documents"),withDestinationURL:original)
  try Data("old private registry".utf8).write(to:prefix.appendingPathComponent("user.reg"))
  try SharedProfile.prepareWine(game:game,runtime:runtime)
  try check(!fm.fileExists(atPath:prefix.appendingPathComponent("user.reg").path),"template registry leaked")
  let users=prefix.appendingPathComponent("drive_c/users")
  let user=users.appendingPathComponent(NSUserName())
  let target=try fm.destinationOfSymbolicLink(atPath:user.path)
  try check(target.hasPrefix(mounted.appendingPathComponent(".gameshelf-profile").path+"/"),"profile did not target private server view")
  try check(target.hasSuffix("/WindowsUsers/Player"),"account saves depend on the Mac login name")
  try check(try fm.destinationOfSymbolicLink(atPath:users.appendingPathComponent("owner").path)==target,"template username gets a separate progress directory")
  try Data("alice progress".utf8).write(to:user.appendingPathComponent("Documents/new.sav"))
  try check(try String(contentsOf:original.appendingPathComponent("old.sav"),encoding:.utf8)=="owner progress","owner save changed")
  try Data("new registry".utf8).write(to:prefix.appendingPathComponent("user.reg"))
  try SharedProfile.prepareWine(game:game,runtime:runtime)
  try check(try String(contentsOf:prefix.appendingPathComponent("user.reg"),encoding:.utf8)=="new registry","subsequent launch reset account registry")
  for missing in [NSUserName(),"owner"] {
   let mapping=users.appendingPathComponent(missing)
   let previous=try fm.destinationOfSymbolicLink(atPath:mapping.path)
   try fm.removeItem(at:mapping)
   var rejected=false
   do{try SharedProfile.prepareWine(game:game,runtime:runtime)}catch{rejected=true}
   try fm.createSymbolicLink(atPath:mapping.path,withDestinationPath:previous)
   try check(rejected,"missing user mapping accepted: "+missing)
  }
  var other=game;other.shared?.accountID="bob"
  do{try SharedProfile.prepareWine(game:other,runtime:runtime);throw Failure(message:"cross-account prefix reuse accepted")}catch is Failure{throw Failure(message:"cross-account prefix reuse accepted")}catch{}
  let path=SharedProfile.localRuntimeRoot(game:game,root:root)
  try check(path != SharedProfile.localRuntimeRoot(game:other,root:root),"runtime accounts collide")
  try check(fm.fileExists(atPath:original.appendingPathComponent("old.sav").path),"source removed")
  print("PASS SharedProfile: first-run scrub, private user folders, subsequent persistence, identity mismatch rejection and original save protection")
 }
}
