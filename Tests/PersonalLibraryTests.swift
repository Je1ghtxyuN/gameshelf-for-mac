import Foundation

@main struct PersonalLibraryTests {
 static func main() throws {
  struct Failure:Error{}
  func check(_ value:Bool)throws{if !value{throw Failure()}}
  func rejects(_ action:()throws->Void)throws{do{try action();throw Failure()}catch is Failure{throw Failure()}catch{}}
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("PersonalLibrary-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:root)}
  let library=try LibraryStore(root:root)
  let game=Game(title:"Example",folder:"/private-original/Game",originalFolder:"/private-original/Game",entry:Candidate(path:"Play_cn.exe",backend:.wine,engine:"Windows"),favorite:true)
  library.games=[game];try library.save();let group=try library.createCollection(name:"RPG");try library.setCollections(for:game.id,ids:[group.id])
  let original=try Data(contentsOf:root.appendingPathComponent("library.json"))
  let connection=SharedConnection(name:"Home",address:"https://games.example.org",serverID:"server",accountID:"alice",username:"alice",isAdministrator:true)
  let state=try PersonalLibraryBindingStore(root:root)
  try check(state.binding==nil)
  let binding=try state.bind(to:connection)
  try check(binding.accountID=="alice" && binding.revision==0)
  try check(try PersonalLibraryBindingStore(root:root).bind(to:connection).deviceID==binding.deviceID)
  var bob=connection;bob.accountID="bob";bob.id=UUID()
  try rejects{_ = try state.bind(to:bob)}
  let snapshot=try PersonalLibrarySnapshot.make(games:library.games,collections:library.collections,serverID:"server",accountID:"alice",playtime:{_ in 9720})
  try check(snapshot.games.count==1 && snapshot.games[0].title=="Example" && snapshot.games[0].favorite && snapshot.games[0].playtimeSeconds==9720)
  let encoded=try snapshot.encoded();let text=String(decoding:encoded,as:UTF8.self)
  try check(!text.contains("private-original") && !text.contains("Play_cn.exe") && !text.contains("password") && !text.contains("folder"))
  try check(snapshot.games[0].collectionIDs==[group.id])
  let foreign=Game(title:"Bob private",folder:"/other",originalFolder:"/other",entry:game.entry,shared:SharedGameReference(connectionID:UUID(),serverID:"server",accountID:"bob",gameID:"other"))
  try check(try PersonalLibrarySnapshot.make(games:[game,foreign],collections:library.collections,serverID:"server",accountID:"alice",playtime:{_ in 0}).games.count==1)
  try state.acknowledge(identity:binding,revision:1,fingerprint:snapshot.fingerprint(),coverHashes:[:])
  try check(try PersonalLibraryBindingStore(root:root).binding?.revision==1)
  try check(try Data(contentsOf:root.appendingPathComponent("library.json"))==original)
  try rejects{try PersonalLibrarySnapshot.make(games:[game],collections:[],serverID:"server",accountID:"alice",playtime:{_ in Double.infinity}).validate()}
  let bad=root.appendingPathComponent("personal-library-binding.json");try Data("broken".utf8).write(to:bad)
  try rejects{_ = try PersonalLibraryBindingStore(root:root)}
  try check(try Data(contentsOf:bad)==Data("broken".utf8))
  print("PASS PersonalLibrary: stable account binding, cross-account refusal/filtering, metadata-only snapshot, totals, acknowledgment, original library and corruption preservation")
 }
}
