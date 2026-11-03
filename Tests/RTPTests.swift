import Foundation
@main struct RTPTests {
 static func main() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  try "[Game]\r\nRTP=RPGVXAce\r\nTitle=Test\r\n".write(to:root.appendingPathComponent("Game.ini"),atomically:true,encoding:.utf8)
  guard try RTP.requirement(root)=="RPGVXAce" else{fatalError("VX Ace RTP requirement not detected")}
  try "[Game]\nRTP=\n[Other]\nRTP=ignored\n".write(to:root.appendingPathComponent("Game.ini"),atomically:true,encoding:.utf8)
  guard try RTP.requirement(root)==nil else{fatalError("Self-contained game incorrectly blocked")}
  try "[Game]\nRTP=../../escape\n".write(to:root.appendingPathComponent("Game.ini"),atomically:true,encoding:.utf8)
  do{_ = try RTP.requirement(root);fatalError("Unsafe RTP name accepted")}catch{}
  try "[Game]\nRTP=RPGVXAce\n".write(to:root.appendingPathComponent("Game.ini"),atomically:true,encoding:.utf8)
  let deps=root.appendingPathComponent("Dependencies"),rtp=deps.appendingPathComponent("RPGVXAce")
  try FileManager.default.createDirectory(at:rtp.appendingPathComponent("Audio"),withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:rtp.appendingPathComponent("Graphics"),withIntermediateDirectories:true)
  let game=Game(title:"test",folder:root.path,originalFolder:root.path,entry:Candidate(path:"Game.exe",backend:.wine,engine:"RPG Maker VX Ace"))
  do{_ = try RTP.assets(game:game,root:deps);fatalError("Partial installation must not be accepted") }catch{}
  try "{\"name\":\"RPGVXAce\",\"installerExitCode\":0}".write(to:rtp.appendingPathComponent("GameShelf-install-complete.json"),atomically:true,encoding:.utf8)
  guard try RTP.assets(game:game,root:deps)?.name=="RPGVXAce" else{fatalError("Completed installation not recognized")}
  let prefix=root.appendingPathComponent("prefix"),installed=root.appendingPathComponent("prefix/drive_c/RPGVXAce")
  try FileManager.default.createDirectory(at:installed.appendingPathComponent("Audio"),withIntermediateDirectories:true)
  try FileManager.default.createDirectory(at:installed.appendingPathComponent("Graphics"),withIntermediateDirectories:true)
  try #"[Software\\Wow6432Node\\Enterbrain\\RGSS3\\RTP]"#.appending("\n" + #""RPGVXAce"="C:\\RPGVXAce""#).write(to:prefix.appendingPathComponent("system.reg"),atomically:true,encoding:.utf8)
  guard RTP.installedAssets(prefix:prefix,name:"RPGVXAce")?.path==installed.path else{fatalError("A working RTP already installed in the private prefix must be usable without a GameShelf receipt")}
  guard RTP.installedAssets(prefix:prefix,name:"RPGVXAce",managedRoot:prefix.appendingPathComponent("drive_c"))==nil else{fatalError("An existing registry entry must not bypass a managed RTP completion receipt")}
  print("PASS: RTP requirement, self-contained game, invalid dependency validation")
 }
}
