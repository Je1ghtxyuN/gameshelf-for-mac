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
  print("PASS WineWindowPolicy: explicit per-launch wrapper, unchanged env/argv/desktop, native opt-in does not mutate preferences")
 }
}
