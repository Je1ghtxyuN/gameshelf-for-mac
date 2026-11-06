import Foundation
import Darwin

/// Explicit opt-in integration test. Inputs must be synthetic binaries and a
/// verified official managed source; all writable state stays in build/validation.
@main struct ManagedWineSmokeTests {
 static func main() throws {
  let fm=FileManager.default,args=CommandLine.arguments
  guard args.count==3 else{throw LibraryError("Usage: ManagedWineSmokeTests SOURCE VALIDATION_ROOT")}
  let source=URL(fileURLWithPath:args[1]),root=URL(fileURLWithPath:args[2]).standardizedFileURL
  let allowed=URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("build/validation").standardizedFileURL.path
  guard root.path.hasPrefix(allowed+"/"),!fm.fileExists(atPath:root.path) else{throw LibraryError("Requires a new build/validation directory")}
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  let folder=root.appendingPathComponent("合成 fixtures with spaces")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  for bits in [32,64] {try fm.copyItem(at:URL(fileURLWithPath:allowed).appendingPathComponent("synthetic\(bits).exe"),to:folder.appendingPathComponent("合成 \(bits).exe"))}
  var game=Game(title:"Synthetic only",folder:folder.path,originalFolder:folder.path,entry:Candidate(path:"合成 64.exe",backend:.wine,engine:"Windows"))
  let runtime=root.appendingPathComponent("Runtime with spaces.app")
  _ = try Wrapper.prepare(game:game,source:source,destination:runtime,shareEngine:true)
  let prefix=runtime.appendingPathComponent("Contents/SharedSupport/prefix")
  guard !fm.fileExists(atPath:prefix.appendingPathComponent("user.reg").path) else{throw LibraryError("Not a clean prefix")}
  func run(_ spec:LaunchSpec,_ label:String,_ timeout:Double)throws {
   let log=root.appendingPathComponent(label+".log");fm.createFile(atPath:log.path,contents:nil)
   let handle=try FileHandle(forWritingTo:log);defer{try? handle.close()}
   let p=Process(),done=DispatchSemaphore(value:0)
   p.executableURL=spec.executable;p.arguments=spec.arguments;p.environment=spec.environment;p.currentDirectoryURL=spec.directory
   p.standardOutput=handle;p.standardError=handle;p.terminationHandler={_ in done.signal()}
   let start=Date();try p.run()
   guard done.wait(timeout:.now()+timeout) == .success else {
    if p.isRunning{p.terminate()}
    if done.wait(timeout:.now()+2) != .success,p.isRunning{Darwin.kill(p.processIdentifier,SIGKILL);_ = done.wait(timeout:.now()+2)}
    throw LibraryError(label+" timed out; see "+log.path)
   }
   print("\(label): exit=\(p.terminationStatus), seconds=\(Date().timeIntervalSince(start)), executable=\(spec.executable.path), arguments=\(spec.arguments)")
   guard p.terminationStatus==0 else{throw LibraryError(label+" failed; see "+log.path)}
  }
  let stop=try Wrapper.stopSpec(game:game,runtime:runtime),wait=try Wrapper.waitSpec(game:game,runtime:runtime)
  defer {
   // Both commands receive this test's exact WINEPREFIX, never a global kill.
   try? run(stop,"cleanup-stop",10);try? run(wait,"cleanup-wait",10)
  }
  var boot=try Wrapper.launchSpec(game:game,runtime:runtime)
  boot.arguments=["wineboot","--init"];boot.directory=prefix
  boot.environment["WINEDLLOVERRIDES"]="winemenubuilder.exe=d;mscoree,mshtml=d"
  try run(boot,"clean-wineboot",90)
  // Match SharedWineBootstrap: stop/wait flushes the server registry before
  // checking initialization. wineboot can exit before user.reg is persisted.
  try run(stop,"bootstrap-stop",10);try run(wait,"bootstrap-wait",10)
  for path in ["user.reg","system.reg","drive_c/windows/system32/kernel32.dll","drive_c/windows/system32/wow64.dll","drive_c/windows/syswow64/kernel32.dll"] {
   guard fm.fileExists(atPath:prefix.appendingPathComponent(path).path) else{throw LibraryError("Missing initialized prefix file: "+path)}
  }
  for bits in [64,32] {
   game.entry.path="合成 \(bits).exe"
   var spec=try Wrapper.launchSpec(game:game,runtime:runtime)
   spec.arguments += ["日本語 spaced argument","quote\"slash\\"]
   try run(spec,"synthetic-\(bits)",30)
   let receipt=try String(contentsOf:prefix.appendingPathComponent("drive_c/smoke\(bits).txt"),encoding:.utf8)
   guard receipt=="PASS synthetic Windows \(bits)\n" else{throw LibraryError("Wrong architecture or receipt")}
  }
  print("PASS official Wine clean prefix + synthetic PE32/PE32+, Unicode/spaced executable and quoted argv; no game or owner prefix used")
 }
}
