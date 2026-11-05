import Foundation
@main struct RenameTests {
 static func main()throws {
  let fm=FileManager.default,r=fm.temporaryDirectory.appendingPathComponent("RenameTests-"+UUID().uuidString)
  defer{try? fm.removeItem(at:r)}
  let s=try LibraryStore(root:r),folder=r.appendingPathComponent("upstream-version-folder")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true);try Data("MZfixture".utf8).write(to:folder.appendingPathComponent("Game.exe"))
  let g=try s.add(source:folder,candidate:Candidate(path:"Game.exe",backend:.wine,engine:"Windows"));let c=try s.createCollection(name:"SLG");try s.setCollections(for:g.id,ids:[c.id])
  try s.renameGame(g.id,name:"  游戏新名称  ")
  try s.recordPlayed(g.id,date:Date(timeIntervalSince1970:123))
  let loaded=try LibraryStore(root:r),new=loaded.games[0]
  guard new.title=="游戏新名称",new.titleIsCustom==true,new.lastPlayed==Date(timeIntervalSince1970:123),new.id==g.id,new.folder==g.folder,new.entry==g.entry,loaded.collectionIDs(for:g.id)==[c.id],fm.fileExists(atPath:folder.appendingPathComponent("Game.exe").path) else{fatalError("rename altered game identity/source/membership")}
  for name in ["", " \n",String(repeating:"a",count:161),"bad\nname","bad\u{0}name"]{
   do{try s.renameGame(g.id,name:name);fatalError("invalid accepted")}catch{}
  }
  do{try s.renameGame(UUID(),name:"missing");fatalError("unknown accepted")}catch{}
  try fm.removeItem(at:r.appendingPathComponent("library.json"));try fm.createDirectory(at:r.appendingPathComponent("library.json"),withIntermediateDirectories:false);try Data("keep".utf8).write(to:r.appendingPathComponent("library.json/keep"))
  do{try s.renameGame(g.id,name:"Should rollback");fatalError("failed write accepted")}catch{}
  guard s.games[0].title=="游戏新名称" else{fatalError("failed save changed in-memory name")}
  print("PASS display rename persists without changing source, identity, membership; invalid values and failed saves rejected")
 }
}
