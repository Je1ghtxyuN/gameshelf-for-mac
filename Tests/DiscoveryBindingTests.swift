import Foundation
@main struct DiscoveryBindingTests {
 static func main()throws {
  struct Failure:Error{let message:String}
  func check(_ value:Bool,_ message:String)throws{if !value{throw Failure(message:message)}}
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("DiscoveryBinding-"+UUID().uuidString).resolvingSymlinksInPath()
  try fm.createDirectory(at:root.appendingPathComponent("Source/Story"),withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
  let folder=root.appendingPathComponent("Source/Story")
  for name in ["Play.exe","Play_cn.exe"]{try Data("MZ fixture".utf8).write(to:folder.appendingPathComponent(name))}
  let library=try LibraryStore(root:root.appendingPathComponent("Library"))
  let entry=Candidate(path:"Play.exe",backend:.wine,engine:"Windows")
  var existing=try library.add(source:folder,candidate:entry)
  existing.title="My chosen name";existing.folder=root.appendingPathComponent("OfflineCopy").path;try library.update(existing)
  let discoveries=try DiscoveryStore(root:root.appendingPathComponent("Discoveries"))
  let source=try discoveries.register(path:root.appendingPathComponent("Source"))
  try discoveries.apply(LibraryDiscovery.scan(source:source),sourceID:source.id)
  try DiscoveryBinding.reconcile(discovery:discoveries,source:source,canonicalRoot:root.appendingPathComponent("Source"),games:library.games)
  try check(discoveries.records[0].status == .added && discoveries.records[0].addedGameID==existing.id,"legacy import was not recognized through original folder")
  try check(library.games[0].title=="My chosen name" && library.games[0].folder==existing.folder,"discovery mutated existing library")
  let fresh=try DiscoveryStore(root:root.appendingPathComponent("OtherDiscoveries")),other=try fresh.register(path:root.appendingPathComponent("Source"))
  try fresh.apply(LibraryDiscovery.scan(source:other),sourceID:other.id)
  let record=fresh.records[0],translated=record.game.entries.first(where:{$0.path=="Play_cn.exe"})!
  try fresh.select(record.game.id,entry:translated)
  try DiscoveryBinding.reconcile(discovery:fresh,source:other,canonicalRoot:root.appendingPathComponent("Source"),games:library.games)
  try check(fresh.records[0].status == .pending && fresh.records[0].selectedEntry==translated,"explicit new language choice was overwritten")
  print("PASS DiscoveryBinding: recognize existing imports and offline copies without resetting names or explicit choices")
 }
}
