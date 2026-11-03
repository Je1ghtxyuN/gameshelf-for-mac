import Foundation

private func check(_ value:Bool,_ message:String)throws {
 if !value {throw NSError(domain:"CollectionTests",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
private func reject(_ message:String,_ action:()throws->Void)throws {
 do{try action()}catch{return}
 throw NSError(domain:"CollectionTests",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected rejection: "+message])
}
private final class Fixture {
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("CollectionTests-"+UUID().uuidString)
 let store:LibraryStore
 let first:Game,second:Game
 init()throws {
  store=try LibraryStore(root:root)
  let source=root.appendingPathComponent("synthetic-source")
  try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
  try Data("inert executable fixture".utf8).write(to:source.appendingPathComponent("Game.exe"))
  try Data("save sentinel".utf8).write(to:source.appendingPathComponent("Save01.dat"))
  first=Game(title:"One",folder:source.path,originalFolder:source.path,entry:Candidate(path:"Game.exe",backend:.wine,engine:"Synthetic"))
  second=Game(title:"Two",folder:source.path,originalFolder:source.path,entry:first.entry)
  store.games=[first,second];try store.save()
 }
 deinit{try? FileManager.default.removeItem(at:root)}
 var metadata:URL{root.appendingPathComponent("collections.json")}
}
@main struct CollectionTests {
 static func main()throws {
  try backwardCompatibilityAndCRUD()
  try membershipAndNonDestructiveRemoval()
  try validationAndCorruption()
  try failedWritesRollback()
  print("PASS: 4 collection suites: legacy/CRUD/persistence, multi-membership/non-destructive removal, validation/corrupt preservation, failed-write rollback")
 }
 static func backwardCompatibilityAndCRUD()throws {
  let f=try Fixture(),before=try Data(contentsOf:f.root.appendingPathComponent("library.json"))
  let loaded=try LibraryStore(root:f.root)
  try check(loaded.collections.isEmpty && loaded.games.map(\.id)==[f.first.id,f.second.id],"missing collections must preserve legacy library")
  try check(!FileManager.default.fileExists(atPath:f.metadata.path),"load must not auto-seed/write collections")
  let c=try loaded.createCollection(name:"  视觉小说 \n")
  try check(c.name=="视觉小说" && c.gameIDs.isEmpty && loaded.collections.count==1,"create/trim")
  try loaded.renameCollection(c.id,name:"  RPG  ")
  try check(loaded.collections[0].id==c.id && loaded.collections[0].name=="RPG","rename changes identity")
  let again=try LibraryStore(root:f.root)
  try check(again.collections.count==1 && again.collections[0].name=="RPG","collection persistence")
  try check(try Data(contentsOf:f.root.appendingPathComponent("library.json"))==before,"collection CRUD rewrote Game schema/library")
  try loaded.removeCollection(c.id)
  try check(try LibraryStore(root:f.root).collections.isEmpty,"removal not persisted")
 }
 static func membershipAndNonDestructiveRemoval()throws {
  let f=try Fixture(),s=f.store
  let a=try s.createCollection(name:"RPG"),b=try s.createCollection(name:"SLG")
  try s.setCollections(for:f.first.id,ids:[a.id,b.id])
  try s.setCollections(for:f.second.id,ids:[b.id])
  try s.setCollections(for:f.first.id,ids:[a.id,b.id])
  try check(s.collectionIDs(for:f.first.id)==[a.id,b.id],"multi-membership")
  try check(s.games(inCollection:b.id).map(\.id)==[f.first.id,f.second.id],"membership must preserve library order and avoid duplicates")
  try check(s.uncategorizedGames.isEmpty,"categorized game reported uncategorized")
  let loaded=try LibraryStore(root:f.root)
  try check(loaded.collectionIDs(for:f.first.id)==[a.id,b.id],"membership not persisted")
  try s.setCollections(for:f.first.id,ids:[])
  try check(s.uncategorizedGames.map(\.id)==[f.first.id],"clear memberships")
  let before=try Data(contentsOf:f.root.appendingPathComponent("library.json"))
  try s.removeCollection(b.id)
  try check(s.uncategorizedGames.count==2 && s.games.count==2,"collection removal removed games")
  try check(try Data(contentsOf:f.root.appendingPathComponent("library.json"))==before,"collection removal rewrote library")
  try check(try String(contentsOf:URL(fileURLWithPath:f.first.folder).appendingPathComponent("Save01.dat"),encoding:.utf8)=="save sentinel","collection removal modified game data")
  try s.setCollections(for:f.first.id,ids:[a.id])
  try s.remove(f.first.id)
  let stale=try LibraryStore(root:f.root)
  try check(stale.collections[0].gameIDs.contains(f.first.id) && stale.games(inCollection:a.id).isEmpty,"stale IDs should be retained but never returned as games")
  try check(stale.games(inCollection:UUID()).isEmpty && stale.collectionIDs(for:UUID()).isEmpty,"invalid query IDs")
  // Names are display strings, never path components.
  let pathName=try s.createCollection(name:"../outside")
  try check(pathName.name=="../outside" && !FileManager.default.fileExists(atPath:f.root.appendingPathComponent("outside").path),"name interpreted as path")
 }
 static func validationAndCorruption()throws {
  let f=try Fixture(),s=f.store,a=try s.createCollection(name:"RPG"),b=try s.createCollection(name:"SLG")
  for name in ["", " \n\t",String(repeating:"字",count:81)," RPG ","rpg"] {
   try reject("invalid/duplicate name"){_ = try s.createCollection(name:name)}
  }
  _ = try s.createCollection(name:String(repeating:"字",count:80))
  try reject("rename duplicate"){try s.renameCollection(b.id,name:" RPG ")}
  try reject("rename empty"){try s.renameCollection(a.id,name:" ")}
  try reject("unknown rename"){try s.renameCollection(UUID(),name:"New")}
  try reject("unknown remove"){try s.removeCollection(UUID())}
  try reject("unknown game"){try s.setCollections(for:UUID(),ids:[a.id])}
  let original=try Data(contentsOf:f.metadata)
  try reject("mixed valid/invalid collections"){try s.setCollections(for:f.first.id,ids:[a.id,UUID()])}
  try check(s.collectionIDs(for:f.first.id).isEmpty && (try Data(contentsOf:f.metadata))==original,"validation partially mutated memberships")
  let invalid: [[GameCollection]] = [
   [GameCollection(id:a.id,name:" ",gameIDs:[])],
   [GameCollection(id:a.id,name:"A",gameIDs:[]),GameCollection(id:a.id,name:"B",gameIDs:[])],
   [GameCollection(id:UUID(),name:"A",gameIDs:[]),GameCollection(id:UUID(),name:" a ",gameIDs:[])],
   [GameCollection(id:a.id,name:"A",gameIDs:[f.first.id,f.first.id])]
  ]
  var payloads=try invalid.map{try JSONEncoder().encode($0)}
  payloads.append(Data("{broken".utf8))
  for payload in payloads {
   try payload.write(to:f.metadata)
   try reject("corrupt collections"){_ = try LibraryStore(root:f.root)}
   try check(try Data(contentsOf:f.metadata)==payload,"corrupt metadata overwritten")
  }
 }
 static func failedWritesRollback()throws {
  let f=try Fixture(),s=f.store,a=try s.createCollection(name:"A"),b=try s.createCollection(name:"B")
  try s.setCollections(for:f.first.id,ids:[a.id])
  let original=try Data(contentsOf:f.metadata)
  // A nonempty directory at the destination deterministically fails an atomic file write,
  // even when tests run with elevated permissions. All paths are private fixtures.
  try FileManager.default.removeItem(at:f.metadata)
  try FileManager.default.createDirectory(at:f.metadata,withIntermediateDirectories:false)
  let sentinel=f.metadata.appendingPathComponent("sentinel")
  try Data("keep".utf8).write(to:sentinel)
  try reject("create persistence failure"){_ = try s.createCollection(name:"C")}
  try reject("rename persistence failure"){try s.renameCollection(a.id,name:"Changed")}
  try reject("remove persistence failure"){try s.removeCollection(a.id)}
  try reject("membership persistence failure"){try s.setCollections(for:f.first.id,ids:[b.id])}
  try check(s.collections.map(\.name)==["A","B"] && s.collectionIDs(for:f.first.id)==[a.id],"failed save changed in-memory collections")
  try check(try Data(contentsOf:sentinel)==Data("keep".utf8),"failed save destroyed existing destination")
  try FileManager.default.removeItem(at:f.metadata);try original.write(to:f.metadata)
  try check(try LibraryStore(root:f.root).collectionIDs(for:f.first.id)==[a.id],"rollback persistence mismatch")
 }
}
