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
  let adapted=Candidate(path:"Game.exe",backend:.rpgmz,engine:"RPG Maker MZ")
  var mzGame=game;mzGame.entry=adapted
  let mzSelection=try SharedPublishSelection(game:mzGame)
  precondition(mzSelection.entry==Candidate(path:"index.html",backend:.rpgmz,engine:"RPG Maker MZ"))
  precondition(mzGame.entry==adapted && mzSelection.folder==game.originalFolder && mzSelection.gameID==game.id)
  var mzRecord=record;mzRecord.game.entries=[adapted];mzRecord.selectedEntry=adapted
  let mzScanned=try SharedPublishSelection(record:mzRecord,source:source)
  precondition(mzScanned.entry==mzSelection.entry)
  mzGame.entry=mzSelection.entry
  let alreadyWeb=try SharedPublishSelection(game:mzGame)
  precondition(alreadyWeb.entry==mzSelection.entry)
  var invalid=record;invalid.available=false
  do{_ = try SharedPublishSelection(record:invalid,source:source);fatalError("unavailable selection accepted")}catch{}
  invalid=record;invalid.game.entries=[Candidate(path:"custom_CN.exe",backend:.wine,engine:"Windows")];invalid.selectedEntry=nil
  do{_ = try SharedPublishSelection(record:invalid,source:source);fatalError("helper-only selection accepted")}catch{}
  print("PASS shared publication: library and scanner preserve exact origin, selected entry and metadata identity")
 }
}
