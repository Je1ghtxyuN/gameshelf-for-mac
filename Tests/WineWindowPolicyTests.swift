import Foundation
@main struct WineWindowPolicyTests {
 static func main()throws {
  let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("WineWindowPolicy-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let helper=root.appendingPathComponent("helper.exe");try Data("fixture".utf8).write(to:helper)
  let spec=LaunchSpec(executable:root.appendingPathComponent("wine64"),arguments:["/games/日本語 game.exe"],directory:root,environment:["WINEPREFIX":root.path])
  let wrapped=try WineWindowPolicy.centered(spec,helper:helper)
  precondition(wrapped.arguments==[helper.path]+spec.arguments && wrapped.environment==spec.environment && wrapped.directory==spec.directory && wrapped.executable==spec.executable)
  var desktop=spec;desktop.arguments=["explorer","/desktop=GameShelf,1280x720"]+spec.arguments
  let unchanged=try WineWindowPolicy.centered(desktop,helper:root.appendingPathComponent("missing"));precondition(unchanged.arguments==desktop.arguments)
  do{_ = try WineWindowPolicy.centered(spec,helper:root.appendingPathComponent("missing"));fatalError("missing helper accepted")}catch{}
  let game=Game(title:"fixture",folder:root.path,originalFolder:root.path,entry:Candidate(path:"Game.exe",backend:.wine,engine:"Windows"),windowSize:"1280x720")
  let standard=try Wrapper.centeredLaunchSpec(game:game,runtime:root,helper:helper)
  precondition(standard.arguments.first=="explorer")
  let native=try Wrapper.centeredLaunchSpec(game:game,runtime:root,helper:helper,nativeWindow:true)
  precondition(native.arguments==[helper.path,root.appendingPathComponent("Game.exe").path] && game.windowSize=="1280x720")
  precondition(native.environment["WINEPREFIX"]==root.appendingPathComponent("Contents/SharedSupport/prefix").path)
  // Old virtual-desktop preferences must not reintroduce coordinate layers.
  for engine in ["Windows","Unity","RPG Maker VX Ace"] {
   var candidate=game;candidate.entry.engine=engine
   let direct=try Wrapper.gameWindowLaunchSpec(game:candidate,runtime:root)
   precondition(direct.arguments==[root.appendingPathComponent("Game.exe").path])
   precondition(direct.environment==native.environment && direct.directory==native.directory && direct.executable==native.executable)
   precondition(candidate.windowSize=="1280x720")
  }
  let expedition=Game(title:"My Expedition",folder:root.path,originalFolder:root.path,entry:Candidate(path:"My Expedition.exe",backend:.wine,engine:"Windows"),windowSize:"1280x720")
  let expeditionSpec=try Wrapper.gameWindowLaunchSpec(game:expedition,runtime:root)
  precondition(expeditionSpec.arguments==[root.appendingPathComponent("My Expedition.exe").path],"virtual desktop and post-launch window move must not offset the game cursor")
  let onyx=Game(title:"PURE ONYX",folder:root.path,originalFolder:root.path,entry:Candidate(path:"pure-onyx.exe",backend:.wine,engine:"Unity"),windowSize:"1280x720")
  let direct=try Wrapper.gameWindowLaunchSpec(game:onyx,runtime:root)
  precondition(direct.arguments==[root.appendingPathComponent("pure-onyx.exe").path,"-screen-fullscreen","0","-screen-width","1280","-screen-height","720"],"PURE ONYX needs a direct regular-window launch, never virtual desktop/helper")
  var fullscreen=onyx;fullscreen.wineFullscreen=true
  let fullSpec=try Wrapper.gameWindowLaunchSpec(game:fullscreen,runtime:root)
  precondition(fullSpec.arguments[2]=="1","fullscreen must remain selectable")
  precondition(onyx.windowSize=="1280x720","launch policy must not change saved game metadata")
  print("PASS WineWindowPolicy: all engines bypass desktop/mover, preserve environment and metadata; fullscreen selectable")
 }
}
