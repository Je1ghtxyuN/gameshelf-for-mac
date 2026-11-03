import Foundation
@main struct NativeGameSavesTests {
 static func main()throws {
  let fm=FileManager.default,base=fm.temporaryDirectory.appendingPathComponent("NativeSaves-"+UUID().uuidString)
  defer{try? fm.removeItem(at:base)}
  let home=base.appendingPathComponent("Home"),managed=base.appendingPathComponent("NAS"),local=base.appendingPathComponent("Library")
  try fm.createDirectory(at:managed,withIntermediateDirectories:true)
  let game=Game(title:"Phoenixes",folder:"/fake/Phoenixes.app",originalFolder:"/fake/Phoenixes.app",entry:Candidate(path:".",backend:.native,engine:"macOS"))
  let old=home.appendingPathComponent("Library/Application Support/Godot/app_userdata/Phoenixes")
  try fm.createDirectory(at:old.appendingPathComponent("Saves"),withIntermediateDirectories:true);try Data("old progress".utf8).write(to:old.appendingPathComponent("Saves/Saves1.phxsav"))
  try NativeGameSaves.preparePhoenixes(game:game,managedRoot:managed,localRoot:local,home:home)
  let target=managed.appendingPathComponent("Saves/NativeApps/"+game.id.uuidString)
  guard try fm.destinationOfSymbolicLink(atPath:old.path)==target.path,try String(contentsOf:target.appendingPathComponent("Saves/Saves1.phxsav"),encoding:.utf8)=="old progress" else{fatalError("save link migration")}
  try NativeGameSaves.preparePhoenixes(game:game,managedRoot:managed,localRoot:local,home:home)
  let backupRoot=local.appendingPathComponent("Saves/Backups/"+game.id.uuidString)
  guard (try fm.contentsOfDirectory(at:backupRoot,includingPropertiesForKeys:nil)).count==1 else{fatalError("reuse duplicates backup")}
  var reimport=game;reimport.id=UUID();try NativeGameSaves.preparePhoenixes(game:reimport,managedRoot:managed,localRoot:local,home:home)
  guard try fm.destinationOfSymbolicLink(atPath:old.path)==target.path else{fatalError("reimport changed existing save association")}
  var different=game;different.id=UUID();different.originalFolder="/fake/AnotherPhoenixes.app"
  let otherHome=base.appendingPathComponent("ConflictHome"),current=otherHome.appendingPathComponent("Library/Application Support/Godot/app_userdata/Phoenixes")
  try fm.createDirectory(at:current,withIntermediateDirectories:true);try Data("new".utf8).write(to:current.appendingPathComponent("Persistent"))
  let otherTarget=managed.appendingPathComponent("Saves/NativeApps/"+different.id.uuidString);try fm.createDirectory(at:otherTarget,withIntermediateDirectories:true);try Data("prior".utf8).write(to:otherTarget.appendingPathComponent("Persistent"))
  do{try NativeGameSaves.preparePhoenixes(game:different,managedRoot:managed,localRoot:local,home:otherHome);fatalError("conflict overwritten")}catch{}
  guard try String(contentsOf:current.appendingPathComponent("Persistent"),encoding:.utf8)=="new",try String(contentsOf:otherTarget.appendingPathComponent("Persistent"),encoding:.utf8)=="prior" else{fatalError("conflict changed data")}
  let missing=base.appendingPathComponent("UnconnectedNAS")
  do{try NativeGameSaves.preparePhoenixes(game:game,managedRoot:missing,localRoot:local,home:home);fatalError("unconnected NAS faked")}catch{}
  print("PASS Phoenixes save redirection, source backup, reuse, conflict preservation, missing NAS guard")
 }
}
