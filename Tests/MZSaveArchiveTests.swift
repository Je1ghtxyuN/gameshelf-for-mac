import Foundation
@main struct MZSaveArchiveTests {
 static func main()throws {
  let fm=FileManager.default,base=fm.temporaryDirectory.appendingPathComponent("MZSaveArchive-"+UUID().uuidString)
  defer{try? fm.removeItem(at:base)}
  let source=base.appendingPathComponent("游戏"),data=base.appendingPathComponent("Managed"),id=UUID()
  try fm.createDirectory(at:source.appendingPathComponent("data"),withIntermediateDirectories:true)
  try Data(#"{"advanced":{"gameId":83816141}}"#.utf8).write(to:source.appendingPathComponent("data/System.json"))
  let folder=source.appendingPathComponent("Save");try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let slot="x\u{1}真实压缩字节";try Data(slot.utf8).write(to:folder.appendingPathComponent("file1.rmmzsave"));try Data("x\u{1}global".utf8).write(to:folder.appendingPathComponent("global.rmmzsave"));try Data("keep config".utf8).write(to:folder.appendingPathComponent("config.rmmzsave"))
  let before=try Data(contentsOf:folder.appendingPathComponent("file1.rmmzsave"))
  let plan=try MZSaveArchive.prepare(folder:source,storageID:id,root:data,webKitDirectory:nil)!
  guard plan.gameId==83816141,plan.files["file1"]==slot,plan.files["config"]==nil,plan.files.count==2 else{fatalError("uppercase Save and selective import")}
  guard try Data(contentsOf:plan.backup.appendingPathComponent("WindowsSave/file1.rmmzsave"))==before else{fatalError("backup bytes")}
  try plan.markCompleted(imported:1)
  guard try MZSaveArchive.prepare(folder:source,storageID:id,root:data,webKitDirectory:nil)==nil else{fatalError("successful receipt not reused")}
  try Data((slot+"new").utf8).write(to:folder.appendingPathComponent("file1.rmmzsave"))
  let changed=try MZSaveArchive.prepare(folder:source,storageID:id,root:data,webKitDirectory:nil)!
  guard changed.fingerprint != plan.fingerprint else{fatalError("changed source must get new recovery plan")}
  try fm.removeItem(at:folder.appendingPathComponent("global.rmmzsave"))
  do{_ = try MZSaveArchive.prepare(folder:source,storageID:id,root:data,webKitDirectory:nil);fatalError("missing global accepted")}catch{}
  let empty=base.appendingPathComponent("NoSaves");try fm.createDirectory(at:empty,withIntermediateDirectories:true)
  guard try MZSaveArchive.prepare(folder:empty,storageID:id,root:data,webKitDirectory:nil)==nil else{fatalError("game without saves should launch normally")}
  let bindings=try WebSaveBindings(root:data)
  let stable=try bindings.resolve(source:source.path,initial:id)
  guard stable==id,try WebSaveBindings(root:data).resolve(source:source.path,initial:UUID())==id else{fatalError("reimport must retain data-store identity")}
  let file=data.appendingPathComponent("WebSaveBindings.json");let old=try Data(contentsOf:file);try Data("broken".utf8).write(to:file)
  do{_ = try WebSaveBindings(root:data);fatalError("corrupt binding accepted")}catch{}
  guard try Data(contentsOf:file)==Data("broken".utf8) else{fatalError("corrupt binding overwritten")};try old.write(to:file)
  print("PASS MZ save source backup, receipt, changed source, missing index, no-save handling, stable identity, corruption preservation")
 }
}
