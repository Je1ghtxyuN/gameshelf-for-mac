import Foundation
import Darwin

@main struct WineRenderCachePolicyTests {
 struct Failure:Error {let message:String}
 static func main() throws {
  let fm=FileManager.default
  let base=fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WineCache-"+UUID().uuidString)
  try fm.createDirectory(at:base,withIntermediateDirectories:true)
  defer {try? fm.removeItem(at:base)}
  func check(_ value:Bool,_ message:String)throws {if !value {throw Failure(message:message)}}
  func put(_ url:URL,_ data:Data)throws {try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try data.write(to:url)}
  func rejects(_ label:String,_ body:()throws->Void)throws {do {try body()} catch {return};throw Failure(message:"accepted "+label)}
  let root=base.appendingPathComponent("LocalSupport/GameShelf"),runtime=base.appendingPathComponent("NAS/Run.app")
  let legacy=runtime.appendingPathComponent("Contents/SharedSupport/Cache")
  let game=Game(id:UUID(uuidString:"12345678-1234-1234-1234-123456789abc")!,title:"Story",folder:base.appendingPathComponent("NAS/Game").path,originalFolder:"shared",entry:Candidate(path:"物語.exe",backend:.wine,engine:"Windows"))
  // Catches the old runtime-relative path before adding the policy.
  let spec=try Wrapper.launchSpec(game:game,runtime:runtime)
  try check(spec.environment["DXVK_STATE_CACHE_PATH"]?.hasPrefix(runtime.path) == false,"cache still follows NAS runtime")
  let payload=Data([68,88,86,75,8,0,0,0,0,0,0,0,1,2,3,4])
  try put(legacy.appendingPathComponent("物語.dxvk-cache"),payload)
  try put(legacy.appendingPathComponent("save.sav"),Data("save".utf8))
  let first=try WineRenderCachePolicy.prepare(game:game,runtime:runtime,root:root)
  let state=URL(fileURLWithPath:first["DXVK_STATE_CACHE_PATH"]!)
  try check(state.path.hasPrefix(root.path+"/WineRenderCache/"),"wrong local namespace")
  try check(try Data(contentsOf:state.appendingPathComponent("物語.dxvk-cache")) == payload,"legacy cache not copied")
  try check(!fm.fileExists(atPath:state.appendingPathComponent("save.sav").path),"save imported")
  try put(state.appendingPathComponent("物語.dxvk-cache"),Data("good local".utf8))
  _ = try WineRenderCachePolicy.prepare(game:game,runtime:runtime,root:root)
  let again=try WineRenderCachePolicy.prepare(game:game,runtime:base.appendingPathComponent("OfflineNAS/Run.app"),root:root)
  try check(first==again,"offline NAS or relocated runtime changed local cache")
  try check(try String(contentsOf:state.appendingPathComponent("物語.dxvk-cache"),encoding:.utf8) == "good local","local cache overwritten")
  try check(try Data(contentsOf:legacy.appendingPathComponent("物語.dxvk-cache")) == payload,"old cache changed")
  for name in ["DXVK_SHADER_CACHE_PATH","XDG_CACHE_HOME"] {try check(first[name]?.hasPrefix(root.path+"/") == true,"cache environment missing "+name)}
  let offlineSpec=try Wrapper.launchSpec(game:game,runtime:base.appendingPathComponent("OfflineNAS/Run.app"))
  try check(offlineSpec.environment["DXVK_STATE_CACHE_PATH"]==spec.environment["DXVK_STATE_CACHE_PATH"],"launcher cache changed offline")
  try check(offlineSpec.directory.path==game.folder && offlineSpec.arguments==[URL(fileURLWithPath:game.folder).appendingPathComponent("物語.exe").path],"game cwd/entry changed")
  try check(first["HOME"] == nil && first["DXVK_ASYNC"] == nil && first["DXVK_CONFIG"] == nil,"unrelated behavior changed")
  var other=game;other.id=UUID()
  try check(try WineRenderCachePolicy.prepare(game:other,runtime:runtime,root:root) != first,"games share cache")
  let ref=SharedGameReference(connectionID:UUID(),serverID:"server",accountID:"alice-secret",gameID:"story")
  var shared=game;shared.shared=ref
  let alice=try WineRenderCachePolicy.prepare(game:shared,runtime:runtime,root:root)
  let sharedSpec=try Wrapper.launchSpec(game:shared,runtime:runtime)
  try check(sharedSpec.environment["HOME"]==URL(fileURLWithPath:game.folder).appendingPathComponent(".gameshelf-profile/UnixHome").path,"shared profile home relocated")
  try check(sharedSpec.environment["DXVK_SHADER_CACHE_PATH"]?.contains("WineRenderCache/shared-")==true,"new DXVK cache follows network profile")
  shared.id=UUID();shared.shared?.connectionID=UUID()
  try check(try WineRenderCachePolicy.prepare(game:shared,runtime:runtime,root:root)==alice,"reconnection changed account cache")
  shared.shared?.accountID="bob-secret"
  try check(try WineRenderCachePolicy.prepare(game:shared,runtime:runtime,root:root) != alice,"accounts share cache")
  try check(!alice.values.contains(where:{$0.contains("alice-secret") || $0.contains("server")}),"identity exposed in paths")
  try rejects("root inside game") {_ = try WineRenderCachePolicy.prepare(game:game,runtime:runtime,root:URL(fileURLWithPath:game.folder))}
  try rejects("root inside runtime") {_ = try WineRenderCachePolicy.prepare(game:game,runtime:runtime,root:runtime)}
  let linked=base.appendingPathComponent("linked")
  try fm.createSymbolicLink(at:linked,withDestinationURL:root)
  try rejects("symlink cache ancestor") {_ = try WineRenderCachePolicy.prepare(game:game,runtime:runtime,root:linked.appendingPathComponent("child"))}
  let blocked=base.appendingPathComponent("blocked")
  try put(blocked,Data())
  try rejects("regular file cache root") {_ = try WineRenderCachePolicy.prepare(game:game,runtime:runtime,root:blocked)}

  // Waiting/stopping must not seed or retry a NAS import a second time.
  var waitGame=game;waitGame.id=UUID()
  let waiting=try Wrapper.waitSpec(game:waitGame,runtime:runtime)
  let waitCache=URL(fileURLWithPath:waiting.environment["DXVK_STATE_CACHE_PATH"]!)
  try check(!fm.fileExists(atPath:waitCache.appendingPathComponent("物語.dxvk-cache").path),"waitSpec imported legacy cache")
  _ = try Wrapper.launchSpec(game:waitGame,runtime:runtime)
  try check(try Data(contentsOf:waitCache.appendingPathComponent("物語.dxvk-cache"))==payload,"launch skipped initial migration")
  try put(legacy.appendingPathComponent("later.dxvk-cache"),payload)
  _ = try Wrapper.launchSpec(game:waitGame,runtime:runtime)
  _ = try Wrapper.waitSpec(game:waitGame,runtime:runtime)
  try check(!fm.fileExists(atPath:waitCache.appendingPathComponent("later.dxvk-cache").path),"completed migration rescanned NAS")

  // The default AppSupport root also owns local runtime siblings.
  let siblingRuntime=root.appendingPathComponent("Runtime/Local.app")
  try check(try WineRenderCachePolicy.prepare(game:game,runtime:siblingRuntime,root:root)==first,"AppSupport sibling runtime rejected")
  try check(!fm.fileExists(atPath:game.folder),"cache preparation created game resources")

  // A fresh game exercises migration rather than a previous successful receipt.
  var unsafe=game;unsafe.id=UUID()
  let badRuntime=base.appendingPathComponent("Bad.app"),bad=badRuntime.appendingPathComponent("Contents/SharedSupport/Cache")
  try fm.createDirectory(at:bad,withIntermediateDirectories:true)
  try fm.createSymbolicLink(at:bad.appendingPathComponent("link.dxvk-cache"),withDestinationURL:legacy.appendingPathComponent("物語.dxvk-cache"))
  try fm.createDirectory(at:bad.appendingPathComponent("dir.dxvk-cache"),withIntermediateDirectories:true)
  try check(mkfifo(bad.appendingPathComponent("pipe.dxvk-cache").path,0o600)==0,"fixture fifo")
  try put(bad.appendingPathComponent("empty.dxvk-cache"),Data())
  try put(bad.appendingPathComponent("corrupt.dxvk-cache"),Data("invalid cache".utf8))
  let huge=bad.appendingPathComponent("huge.dxvk-cache")
  try put(huge,payload)
  let handle=try FileHandle(forWritingTo:huge);try handle.truncate(atOffset:65*1024*1024);try handle.close()
  try put(bad.appendingPathComponent("valid.dxvk-cache"),payload)
  try fm.linkItem(at:bad.appendingPathComponent("valid.dxvk-cache"),to:bad.appendingPathComponent("hardlink.dxvk-cache"))
  try put(bad.appendingPathComponent("standalone.dxvk-cache"),payload)
  let migrated=try WineRenderCachePolicy.prepare(game:unsafe,runtime:badRuntime,root:root)
  let names=try fm.contentsOfDirectory(atPath:migrated["DXVK_STATE_CACHE_PATH"]!)
  try check(names.filter{$0.hasSuffix(".dxvk-cache")}.sorted()==["standalone.dxvk-cache"],"unsafe legacy file migrated")
  unsafe.id=UUID()
  let linkedRuntime=base.appendingPathComponent("Linked.app")
  try fm.createSymbolicLink(at:linkedRuntime,withDestinationURL:badRuntime)
  let skipped=try WineRenderCachePolicy.prepare(game:unsafe,runtime:linkedRuntime,root:root)
  try check(!(try fm.contentsOfDirectory(atPath:skipped["DXVK_STATE_CACHE_PATH"]!)).contains("standalone.dxvk-cache"),"legacy parent symlink followed")
  // Pre-existing files/links win even during the FIRST import, without a receipt.
  var collision=game;collision.id=UUID()
  let seed=try WineRenderCachePolicy.prepare(game:collision,runtime:base.appendingPathComponent("NotMounted.app"),root:root)
  let seedDir=URL(fileURLWithPath:seed["DXVK_STATE_CACHE_PATH"]!)
  try fm.createSymbolicLink(at:seedDir.appendingPathComponent("物語.dxvk-cache"),withDestinationURL:base.appendingPathComponent("must-not-create"))
  _ = try WineRenderCachePolicy.prepare(game:collision,runtime:runtime,root:root)
  try check((try? fm.destinationOfSymbolicLink(atPath:seedDir.appendingPathComponent("物語.dxvk-cache").path)) != nil,"destination symlink replaced")
  try check(!fm.fileExists(atPath:base.appendingPathComponent("must-not-create").path),"destination symlink followed")
  try check(try Data(contentsOf:legacy.appendingPathComponent("物語.dxvk-cache"))==payload,"collision modified source")
  try fm.removeItem(at:seedDir.appendingPathComponent(".legacy-imported"))
  try fm.removeItem(at:seedDir.appendingPathComponent("物語.dxvk-cache"))
  try put(seedDir.appendingPathComponent("物語.dxvk-cache"),Data("preexisting good".utf8))
  _ = try WineRenderCachePolicy.prepare(game:collision,runtime:runtime,root:root)
  try check(try String(contentsOf:seedDir.appendingPathComponent("物語.dxvk-cache"),encoding:.utf8)=="preexisting good","first import overwrote good cache")
  // Reject leaf symlinks as well as ancestor symlinks before any cache writes.
  try fm.removeItem(at:seedDir)
  try fm.createSymbolicLink(at:seedDir,withDestinationURL:legacy)
  try rejects("cache subdirectory symlink") {_ = try WineRenderCachePolicy.prepare(game:collision,runtime:runtime,root:root)}
  print("PASS WineRenderCachePolicy: local persistence, environment, game/account isolation, offline NAS, copy-only migration, symlink/FIFO/directory/size/corruption guards")
 }
}
