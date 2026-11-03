import Foundation
@main struct RuntimeTests {
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? fm.removeItem(at:root)}
  let source=root.appendingPathComponent("Source.app"),prefix=source.appendingPathComponent("Contents/SharedSupport/prefix")
  try fm.createDirectory(at:prefix.appendingPathComponent("drive_c"),withIntermediateDirectories:true)
  try fm.createDirectory(at:prefix.appendingPathComponent("dosdevices"),withIntermediateDirectories:true)
  try fm.createDirectory(at:source.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
  try "stub".write(to:source.appendingPathComponent("Contents/MacOS/wineskinlauncher"),atomically:true,encoding:.utf8)
  let original:[String:Any] = ["Program Name and Path":"/Touhou/TH08/th08.exe","CFBundleIdentifier":"old","Fullscreen":true]
  let data=try PropertyListSerialization.data(fromPropertyList:original,format:.xml,options:0)
  try data.write(to:source.appendingPathComponent("Contents/Info.plist"))
  let gameFolder=root.appendingPathComponent("NAS 物語")
  try fm.createDirectory(at:gameFolder,withIntermediateDirectories:true)
  try "MZ".write(to:gameFolder.appendingPathComponent("物語.exe"),atomically:true,encoding:.utf8)
  let game=Game(title:"物語",folder:gameFolder.path,originalFolder:gameFolder.path,entry:Candidate(path:"物語.exe",backend:.wine,engine:"KiriKiri"))
  let dest=root.appendingPathComponent("Run.app")
  let result=try Wrapper.prepare(game:game,source:source,destination:dest)
  guard result==dest else{fatalError("Runtime must be isolated from source")}
  guard try Data(contentsOf:source.appendingPathComponent("Contents/Info.plist"))==data else{fatalError("Original wrapper mutated")}
  let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:dest.appendingPathComponent("Contents/Info.plist")),format:nil) as! [String:Any]
  guard plist["Program Name and Path"] as? String == "/windows/system32/cmd.exe" else{fatalError("Non-ASCII entry not mapped")}
  guard plist["Fullscreen"] as? Bool == false else{fatalError("Fullscreen default enabled")}
  let mapping=dest.appendingPathComponent("Contents/SharedSupport/prefix/dosdevices/g:")
  guard try fm.destinationOfSymbolicLink(atPath:mapping.path)==gameFolder.path else{fatalError("Original game not mapped")}
  let launch=try Wrapper.launchSpec(game:game,runtime:dest)
  guard launch.arguments == [gameFolder.appendingPathComponent("物語.exe").path], launch.directory.path==gameFolder.path else{fatalError("Unicode argv or game working directory lost")}
  guard launch.environment["WINEPREFIX"]==dest.appendingPathComponent("Contents/SharedSupport/prefix").path else{fatalError("Wrong prefix")}
  try fm.createDirectory(at:source.appendingPathComponent("Contents/SharedSupport/wine"),withIntermediateDirectories:true)
  try fm.createDirectory(at:source.appendingPathComponent("Contents/Frameworks"),withIntermediateDirectories:true)
  let shared=root.appendingPathComponent("Shared.app")
  _ = try Wrapper.prepare(game:game,source:source,destination:shared,shareEngine:true)
  guard try fm.destinationOfSymbolicLink(atPath:shared.appendingPathComponent("Contents/SharedSupport/wine").path)==source.appendingPathComponent("Contents/SharedSupport/wine").path else{fatalError("Shared engine was copied instead of referenced")}
  guard !((try? fm.destinationOfSymbolicLink(atPath:shared.appendingPathComponent("Contents/SharedSupport/prefix").path)) != nil) else{fatalError("Mutable prefix must not point to original")}
  var measured=game;measured.showPerformanceHUD=true
  let measuredSpec=try Wrapper.launchSpec(game:measured,runtime:dest)
  guard measuredSpec.environment["DXVK_HUD"]=="fps,frametimes,gpuload,compiler" else{fatalError("Per-game performance overlay not enabled")}
  guard !Wrapper.msyncEnabled(inode:8_000_000_000_000_000_000),Wrapper.msyncEnabled(inode:12345678) else{fatalError("NAS 64-bit inode must not create an oversized Darwin shared-memory name")}
  let nasSync=Wrapper.syncSettings(inode:8_000_000_000_000_000_000)
  guard nasSync["WINEMSYNC"]=="0",nasSync["WINEESYNC"]=="0" else{print("FAIL: unsupported NAS synchronization must use Wine classic waits, not spinning ESync");exit(1)}
  guard Wrapper.syncSettings(inode:nil)==["WINEMSYNC":"0","WINEESYNC":"0"] else{fatalError("Unknown inode must use conservative synchronization")}
  guard Wrapper.syncSettings(inode:12345678)==["WINEMSYNC":"1","WINEESYNC":"1"] else{fatalError("Supported local synchronization changed")}
  let replacement=root.appendingPathComponent("Replacement.app")
  try fm.copyItem(at:source,to:replacement)
  let save=shared.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/save.dat")
  try "keep-progress".write(to:save,atomically:true,encoding:.utf8)
  _ = try Wrapper.prepare(game:game,source:replacement,destination:shared,shareEngine:true)
  var failures:[String]=[]
  for path in ["Contents/SharedSupport/wine","Contents/Frameworks"] {
   if try fm.destinationOfSymbolicLink(atPath:shared.appendingPathComponent(path).path) != replacement.appendingPathComponent(path).path {failures.append("engine link still targets old source: "+path)}
  }
  guard try String(contentsOf:save,encoding:.utf8)=="keep-progress" else{fatalError("Engine change replaced game saves")}
  if !failures.isEmpty {for failure in failures{print("FAIL: "+failure)};exit(1)}
  // A missing replacement component must not leave a half-switched runtime.
  let incomplete=root.appendingPathComponent("Incomplete.app")
  try fm.copyItem(at:replacement,to:incomplete)
  try fm.removeItem(at:incomplete.appendingPathComponent("Contents/Frameworks"))
  do{_ = try Wrapper.prepare(game:game,source:incomplete,destination:shared,shareEngine:true);fatalError("Incomplete replacement accepted")}catch{}
  for path in ["Contents/SharedSupport/wine","Contents/Frameworks"] {
   guard try fm.destinationOfSymbolicLink(atPath:shared.appendingPathComponent(path).path)==replacement.appendingPathComponent(path).path else{fatalError("Failed engine switch changed existing links")}
  }
  // Build the waiter while the launch environment is known; run it only AFTER
  // wine64 exits, because the game's child processes may still own the prefix.
  let waiter=try Wrapper.waitSpec(game:game,runtime:shared)
  guard waiter.executable.path==shared.appendingPathComponent("Contents/SharedSupport/wine/bin/wineserver").path,
        waiter.arguments==["-w"],
        waiter.environment["WINEPREFIX"]==shared.appendingPathComponent("Contents/SharedSupport/prefix").path,
        waiter.directory.path==shared.appendingPathComponent("Contents/SharedSupport/prefix").path else{fatalError("Waiter must wait for the same Wine prefix, not depend on NAS game cwd")}
  let stopper=try Wrapper.stopSpec(game:game,runtime:shared)
  guard stopper.arguments==["-k"],stopper.environment==waiter.environment,stopper.directory==waiter.directory,stopper.executable==waiter.executable else{fatalError("Stop must reuse exact private prefix and DYLD environment")}
  let secondWaiter=try Wrapper.waitSpec(game:game,runtime:dest)
  guard secondWaiter.environment["WINEPREFIX"] != waiter.environment["WINEPREFIX"] else{fatalError("Distinct game prefixes share a wait target")}
  let sharedLaunch=try Wrapper.launchSpec(game:game,runtime:shared)
  guard waiter.environment==sharedLaunch.environment else{fatalError("Waiter and launcher disagree on Wine environment/MSync policy")}
  // Source changes must audit against the previous source before refreshing links.
  let stale=shared.appendingPathComponent("Contents/SharedSupport/prefix/drive_c/stale-save")
  try fm.createSymbolicLink(at:stale,withDestinationURL:replacement.appendingPathComponent("Contents/SharedSupport/prefix/drive_c"))
  do{_ = try Wrapper.prepare(game:game,source:source,destination:shared,shareEngine:true);fatalError("Link into previous source prefix survived engine switch")}catch{}
  try fm.removeItem(at:stale)
  for path in ["Contents/SharedSupport/wine","Contents/Frameworks"] {
   guard try fm.destinationOfSymbolicLink(atPath:shared.appendingPathComponent(path).path)==replacement.appendingPathComponent(path).path else{fatalError("Rejected prefix was partially switched")}
  }
  // The new shared-link refresh must not break or overwrite older full clones.
  let independent=root.appendingPathComponent("Independent.app")
  _ = try Wrapper.prepare(game:game,source:source,destination:independent)
  do{_ = try Wrapper.prepare(game:game,source:replacement,destination:independent,shareEngine:true)}catch{print("FAIL: existing independent clone rejected: \(error)");exit(1)}
  for path in ["Contents/SharedSupport/wine","Contents/Frameworks"] {
   guard (try? fm.destinationOfSymbolicLink(atPath:independent.appendingPathComponent(path).path))==nil else{fatalError("Independent engine replaced with a shared link")}
  }
  var windowed=game;windowed.windowSize="1280x720"
  let fixed=try Wrapper.launchSpec(game:windowed,runtime:dest)
  guard fixed.arguments==["explorer","/desktop=GameShelf"+game.id.uuidString+",1280x720",gameFolder.appendingPathComponent(game.entry.path).path] else{fatalError("Fixed window area must use an isolated desktop and preserve Unicode game argv")}
  var adapted=windowed;adapted.entry.engine="RPG Maker VX Ace"
  for name in ["GameShelfAdapter.rb","GameShelfBootstrap.rvdata2"] {
   try Data("owned synthetic fixture".utf8).write(to:gameFolder.appendingPathComponent(name))
  }
  let nativeWindow=try Wrapper.launchSpec(game:adapted,runtime:dest)
  guard nativeWindow.arguments==[gameFolder.appendingPathComponent(game.entry.path).path],nativeWindow.environment["GAMESHELF_WINDOW_BOUNDS"]=="1280x720" else{fatalError("Prepared RGSS adapter must use its bounded game window, without virtual desktop")}
  adapted.windowSize=nil
  let follow=try Wrapper.launchSpec(game:adapted,runtime:dest)
  guard follow.environment["GAMESHELF_WINDOW_BOUNDS"]==nil else{fatalError("Follow-game must not force adapter geometry")}
  print("PASS: isolated wrapper, original unchanged, window default, NAS mapping, Unicode launch")
 }
}
