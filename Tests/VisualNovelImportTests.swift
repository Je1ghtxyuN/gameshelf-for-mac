import Foundation
@main struct VisualNovelImportTests {
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("VNImport-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
  struct Failure:Error{var message:String}
  func check(_ value:Bool,_ message:String)throws{if !value{throw Failure(message:message)}}
  func put(_ path:String,_ data:Data=Data("MZ".utf8))throws{
   let file=root.appendingPathComponent(path);try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:file)
  }
  var failures=0,passed=0
  func test(_ name:String,_ body:()throws->Void){do{try body();passed+=1;print("PASS "+name)}catch{failures+=1;print("FAIL "+name+": "+String(describing:error))}}
  test("QLIE import identifies archive family and keeps original plus translated launchers"){
   try put("qlie/GameData/data.pack",Data(repeating:0,count:10)+Data("FilePackVer3.0".utf8)+Data(repeating:0,count:14))
   for name in ["Story.exe","Story_cn.exe","エンジン設定.exe","FileCheck.exe"]{try put("qlie/"+name)}
   let c=try Scan.candidates(at:root.appendingPathComponent("qlie"))
   try check(c.map{$0.path}==["Story_cn.exe","Story.exe"],"translated first and helper exclusion changed: \(c)")
   try check(c.allSatisfy{$0.engine=="QLIE" && $0.backend == .wine},"QLIE was routed to an unrelated native engine")
  }
  test("CatSystem2 import uses KIF bytes and excludes its settings helper"){
   try put("cats/scene.int",Data([0x4b,0x49,0x46,0]));for name in ["Story.exe","Story_sc.exe","cs2conf.exe"]{try put("cats/"+name)}
   let c=try Scan.candidates(at:root.appendingPathComponent("cats"))
   try check(c.map{$0.path}==["Story_sc.exe","Story.exe"] && c.allSatisfy{$0.engine=="CatSystem2"},"CatSystem2 markers or Chinese launcher missed")
  }
  test("strong Unity and RPG markers take precedence over a generic text filename"){
   try put("unity/Story.exe");try put("unity/UnityPlayer.dll",Data());try put("unity/0.txt",Data())
   try check(try Scan.candidates(at:root.appendingPathComponent("unity")).first?.engine=="Unity","text marker overrode Unity")
   try put("rpg/Story.exe");try put("rpg/www/js/rpg_core.js",Data());try put("rpg/0.txt",Data())
   try check(try Scan.candidates(at:root.appendingPathComponent("rpg")).first?.engine=="RPG Maker MV","text marker overrode RPG")
  }
  test("unrelated pack does not invent QLIE"){
   try put("other/GameData/data.pack",Data("unrelated format".utf8));try put("other/Story.exe")
   try check(try Scan.candidates(at:root.appendingPathComponent("other")).first?.engine=="Windows","extension-only detection")
  }
  test("multiple translated entries stay selectable alongside original"){
   for name in ["Story.exe","Story_cn.exe","Story_chs.exe"]{try put("ambiguous/"+name)}
   let names=try Scan.candidates(at:root.appendingPathComponent("ambiguous")).map{$0.path}
   try check(names.count==3 && names.last=="Story.exe" && Set(names)==Set(["Story.exe","Story_cn.exe","Story_chs.exe"]),"ambiguity discarded or wrong default")
  }
  test("engine re-detection reuses entry identity and preserves saved game metadata"){
   try put("existing/Story.exe");let store=try LibraryStore(root:root.appendingPathComponent("library"));let source=root.appendingPathComponent("existing")
   var game=try store.add(source:source,candidate:Candidate(path:"Story.exe",backend:.wine,engine:"Windows"));game.title="My display name";game.favorite=true;game.lastPlayed=Date(timeIntervalSince1970:100);try store.update(game)
   let refreshed=try store.add(source:source,candidate:Candidate(path:"Story.exe",backend:.wine,engine:"QLIE"))
   try check(store.games.count==1 && refreshed.id==game.id && refreshed.title==game.title && refreshed.favorite && refreshed.lastPlayed==game.lastPlayed && refreshed.entry.engine=="QLIE","engine upgrade duplicated or reset library/save identity")
   let reopened=try LibraryStore(root:store.root);try check(reopened.games.count==1 && reopened.games.first?.entry.engine=="QLIE","engine upgrade not persisted")
  }
  print("VN import: \(passed) passed; \(failures) failed");if failures>0{exit(1)}
 }
}
