import Foundation

/// Explicit, per-launch opt-in. Never changes saved game preferences or a prefix.
enum WineWindowPolicy {
 static func centered(_ launch:LaunchSpec,helper:URL)throws->LaunchSpec {
  // An explicit virtual desktop retains its existing behavior.
  if launch.arguments.first=="explorer" {return launch}
  guard helper.isFileURL,FileManager.default.fileExists(atPath:helper.path),!launch.arguments.isEmpty else{throw LibraryError("缺少 Wine 窗口启动组件。")}
  var result=launch
  result.arguments=[helper.path]+launch.arguments
  return result
 }
}
extension Wrapper {
 /// Main supplies its bundled, locally built helper. nativeWindow opts THIS launch
 /// out of the saved virtual-desktop size; it does not persist a preference change.
 static func centeredLaunchSpec(game:Game,runtime:URL,helper:URL,nativeWindow:Bool=false)throws->LaunchSpec {
  var launchGame=game
  if nativeWindow{launchGame.windowSize=nil}
  return try WineWindowPolicy.centered(launchSpec(game:launchGame,runtime:runtime),helper:helper)
 }
}
