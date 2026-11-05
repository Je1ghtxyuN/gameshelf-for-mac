import Foundation
@main struct SharedPublishSelectionTests {
 static func main()throws {
  let entry=Candidate(path:"Game_cn.exe",backend:.wine,engine:"Windows")
  let game=Game(title:"My display name",folder:"/LocalCopy/Game",originalFolder:"/Volumes/Share/Game/Novel",entry:entry,cover:"/covers/local.jpg")
  let selected=try SharedPublishSelection(game:game)
  precondition(selected.folder==game.originalFolder && selected.entry==entry && selected.gameID==game.id && selected.title==game.title)
  let source=LibrarySource(title:"Game",path:"/Volumes/Share/Game")
  let record=DiscoveryRecord(game:DiscoveredGame(id:"candidate",sourceID:source.id,relativePath:"Novel",title:"Folder name",entries:[Candidate(path:"Game.exe",backend:.wine,engine:"Windows"),entry]),status:.added,selectedEntry:entry,addedGameID:game.id,available:true)
  let scanned=try SharedPublishSelection(record:record,source:source)
  precondition(scanned.folder==selected.folder && scanned.entry==selected.entry && scanned.gameID==selected.gameID)
  var invalid=record;invalid.available=false
  do{_ = try SharedPublishSelection(record:invalid,source:source);fatalError("unavailable selection accepted")}catch{}
  invalid=record;invalid.game.entries=[Candidate(path:"custom_CN.exe",backend:.wine,engine:"Windows")];invalid.selectedEntry=nil
  do{_ = try SharedPublishSelection(record:invalid,source:source);fatalError("helper-only selection accepted")}catch{}
  print("PASS shared publication: library and scanner preserve exact origin, selected entry and metadata identity")
 }
}
