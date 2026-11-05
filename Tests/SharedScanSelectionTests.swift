import Foundation
@main struct SharedScanSelectionTests {
 static func main()throws {
  precondition(tryValue("/Volumes/Share/Game/Novel/macOS","/Volumes/Share/Game")=="Novel/macOS")
  precondition(tryValue("/Volumes/Share/Game","/Volumes/Share/Game")==".")
  let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("SharedScanMapping-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:temporary.appendingPathComponent("Library/Game"),withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:temporary)}
  try FileManager.default.createSymbolicLink(at:temporary.appendingPathComponent("Alias"),withDestinationURL:temporary.appendingPathComponent("Library"))
  precondition(tryValue(temporary.appendingPathComponent("Library/Game").path,temporary.appendingPathComponent("Alias").path)=="Game")
  for (folder,root) in [("/Volumes/Other/Game/Novel","/Volumes/Share/Game"),("/Volumes/Share/GameEvil/Novel","/Volumes/Share/Game"),("/Volumes/Share/Game/../Secret","/Volumes/Share/Game"),("/games/a","/")]{do{_ = try SharedScanSelection.relative(folder:folder,localRoot:root);fatalError("escaped mapping accepted")}catch{}}
  precondition(SharedScanSelection.suggestedRoot(source:"/Volumes/Share/Game/galgame",title:"Game")=="/Volumes/Share/Game")
  precondition(SharedScanSelection.suggestedRoot(source:"/Volumes/Share/Other",title:"Game")==nil)
  for tool in ["custom_c.exe","custom_CN.exe","replayview_CN.exe","thprac.exe","settings_ja.exe","th14_update100b.exe"]{precondition(!SharedScanSelection.launchable(Candidate(path:tool,backend:.wine,engine:"Windows")),tool)}
  for game in ["CustomAdventure.exe","ReplayStory.exe","th13.exe","th13_CN.exe"]{precondition(SharedScanSelection.launchable(Candidate(path:game,backend:.wine,engine:"Windows")),game)}
  print("PASS selected scan reuse: explicit confined directory mapping, stale helper exclusion and real launcher preservation")
 }
 static func tryValue(_ folder:String,_ root:String)->String{try! SharedScanSelection.relative(folder:folder,localRoot:root)}
}
