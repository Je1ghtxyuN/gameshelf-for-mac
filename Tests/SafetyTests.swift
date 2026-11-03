import Foundation
@main struct SafetyTests {
 static func main() throws {
  let fm=FileManager.default,base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fm.createDirectory(at:base,withIntermediateDirectories:true);defer{try? fm.removeItem(at:base)}
  let folder=base.appendingPathComponent("game")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  try "MZ".write(to:folder.appendingPathComponent("Game.exe"),atomically:true,encoding:.utf8)
  let store=try LibraryStore(root:base.appendingPathComponent("local"))
  let g=try store.add(source:folder,candidate:Candidate(path:"Game.exe",backend:.wine,engine:"Windows"))
  let outside=base.appendingPathComponent("outside");try "save-original".write(to:outside,atomically:true,encoding:.utf8)
  try fm.createSymbolicLink(atPath:folder.appendingPathComponent("save-link").path,withDestinationPath:outside.path)
  do{_ = try store.download(g);fatalError("External save symlink must not silently survive local download")}catch{}
  try fm.removeItem(at:folder.appendingPathComponent("save-link"))
  try fm.createSymbolicLink(atPath:folder.appendingPathComponent("alias.exe").path,withDestinationPath:folder.appendingPathComponent("Game.exe").path)
  let copy=try store.download(g)
  let copiedAlias=URL(fileURLWithPath:copy.folder).appendingPathComponent("alias.exe").resolvingSymlinksInPath()
  guard copiedAlias.path==URL(fileURLWithPath:copy.folder).appendingPathComponent("Game.exe").path else{fatalError("Internal absolute link still points to source")}
  // Simulate crash before the UI saved the completed copy: recover/adopt without recopying.
  let reopened=try LibraryStore(root:store.root)
  let recovered=try reopened.download(g)
  guard recovered.folder==copy.folder else{fatalError("Completed copy not recovered")}
  try "MZ".write(to:folder.appendingPathComponent("sub\\Game.exe"),atomically:true,encoding:.utf8)
  do{_ = try store.add(source:folder,candidate:Candidate(path:"sub\\Game.exe",backend:.wine,engine:"Windows"));fatalError("Literal Windows separator accepted")}catch{}
  let source=base.appendingPathComponent("Source.app"),prefix=source.appendingPathComponent("Contents/SharedSupport/prefix")
  try fm.createDirectory(at:prefix.appendingPathComponent("drive_c"),withIntermediateDirectories:true)
  try fm.createDirectory(at:source.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
  try "stub".write(to:source.appendingPathComponent("Contents/MacOS/wineskinlauncher"),atomically:true,encoding:.utf8)
  let data=try PropertyListSerialization.data(fromPropertyList:["Fullscreen":true],format:.xml,options:0)
  try data.write(to:source.appendingPathComponent("Contents/Info.plist"))
  let externalDos=base.appendingPathComponent("original-dos")
  try fm.createDirectory(at:externalDos,withIntermediateDirectories:true)
  try fm.createSymbolicLink(atPath:externalDos.appendingPathComponent("g:").path,withDestinationPath:"/original-game")
  try fm.createSymbolicLink(atPath:prefix.appendingPathComponent("dosdevices").path,withDestinationPath:externalDos.path)
  do{_ = try Wrapper.prepare(game:g,source:source,destination:base.appendingPathComponent("Clone.app"));fatalError("Nested symlink escaped clone") }catch{}
  guard try fm.destinationOfSymbolicLink(atPath:externalDos.appendingPathComponent("g:").path)=="/original-game" else{fatalError("Original mapping mutated")}
  try fm.removeItem(at:prefix.appendingPathComponent("dosdevices"))
  try fm.createDirectory(at:prefix.appendingPathComponent("dosdevices"),withIntermediateDirectories:true)
  try fm.createDirectory(at:prefix.appendingPathComponent("drive_c/users/player"),withIntermediateDirectories:true)
  try "original-registry".write(to:prefix.appendingPathComponent("registry-original"),atomically:true,encoding:.utf8)
  // Every unsafe case must fail before replacing G: or editing the original prefix.
  var failures:[String]=[]
  for (index,relative,target) in [
   (0,"dosdevices/c:",prefix.appendingPathComponent("drive_c")),
   (1,"user.reg",prefix.appendingPathComponent("registry-original")),
   (2,"drive_c/users/player/saves",prefix.appendingPathComponent("drive_c")),
   (3,"system.reg",outside),
   (4,"dosdevices/c:",externalDos)
  ] {
   let link=prefix.appendingPathComponent(relative)
   try fm.createSymbolicLink(at:link,withDestinationURL:target)
   do {
    _ = try Wrapper.prepare(game:g,source:source,destination:base.appendingPathComponent("Unsafe-\(index).app"))
    failures.append("accepted unsafe prefix link: "+relative)
   } catch {}
   try fm.removeItem(at:link)
  }
  guard try String(contentsOf:outside,encoding:.utf8)=="save-original",
        try String(contentsOf:prefix.appendingPathComponent("registry-original"),encoding:.utf8)=="original-registry" else{fatalError("Original writable data mutated")}
  // Normal Wine host integration must survive: Z:, Mac user folders and relative C:.
  let hostHome=base.appendingPathComponent("MacHome")
  try fm.createDirectory(at:hostHome,withIntermediateDirectories:true)
  try fm.createSymbolicLink(atPath:prefix.appendingPathComponent("dosdevices/c:").path,withDestinationPath:"../drive_c")
  try fm.createSymbolicLink(atPath:prefix.appendingPathComponent("dosdevices/z:").path,withDestinationPath:"/")
  try fm.createSymbolicLink(at:prefix.appendingPathComponent("drive_c/users/player/Documents"),withDestinationURL:hostHome)
  let safe=base.appendingPathComponent("Safe.app")
  _ = try Wrapper.prepare(game:g,source:source,destination:safe)
  for (relative,target) in [("dosdevices/z:","/"),("drive_c/users/player/Documents",hostHome.path)] {
   guard try fm.destinationOfSymbolicLink(atPath:safe.appendingPathComponent("Contents/SharedSupport/prefix/"+relative).path)==target else{fatalError("Normal Wine host mapping was changed")}
  }
  // An indirect link must not hide a traversal through the original prefix,
  // even when its final destination is an otherwise-allowed Mac user folder.
  let indirect=base.appendingPathComponent("indirect")
  try fm.createSymbolicLink(at:indirect,withDestinationURL:prefix.appendingPathComponent("drive_c/users/player/Documents"))
  try fm.createSymbolicLink(at:prefix.appendingPathComponent("drive_c/users/player/saves"),withDestinationURL:indirect)
  do {
   _ = try Wrapper.prepare(game:g,source:source,destination:base.appendingPathComponent("Indirect.app"))
   failures.append("indirect link through original prefix was accepted")
  } catch {}
  if !failures.isEmpty {for failure in failures{print("FAIL: "+failure)};exit(1)}
  print("PASS: copy safety, prefix writable-link rejection, normal Wine host mappings")
 }
}
