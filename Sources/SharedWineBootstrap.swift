import Foundation
import Darwin

enum SharedWineBootstrap {
 typealias Runner=(LaunchSpec,TimeInterval)throws->Void
 static func prepare(game:Game,runtime:URL,runner:Runner?=nil)throws {
  guard let ref=game.shared else{return}
  let fm=FileManager.default,support=runtime.appendingPathComponent("Contents/SharedSupport")
  let ready=support.appendingPathComponent("shared-prefix-ready.json")
  if fm.fileExists(atPath:ready.path) {
   guard let record=try JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as? [String:String],record["identity"]==ref.storageKey else{throw LibraryError("共享运行环境初始化标识不匹配。")}
   try SharedProfile.prepareWine(game:game,runtime:runtime,removeSeedRegistry:false);return
  }
  let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:runtime.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any]
  guard info?["GameShelfFreshPrefix"] as? Bool==true else{throw LibraryError("共享游戏必须使用从引擎新建的运行环境。")}
  let home=try SharedProfile.networkProfile(game:game).appendingPathComponent("UnixHome")
  try fm.createDirectory(at:home,withIntermediateDirectories:true)
  try fm.createDirectory(at:support.appendingPathComponent("Cache/XDG"),withIntermediateDirectories:true)
  let logs=support.appendingPathComponent("Logs");try fm.createDirectory(at:logs,withIntermediateDirectories:true)
  let log=logs.appendingPathComponent("bootstrap.log")
  if !fm.fileExists(atPath:log.path){fm.createFile(atPath:log.path,contents:nil)}
  let run:Runner=runner ?? {spec,timeout in try runBounded(spec,timeout:timeout,log:log)}
  var spec=try Wrapper.launchSpec(game:game,runtime:runtime)
  spec.arguments=["wineboot","--init"];spec.directory=support.appendingPathComponent("prefix")
  spec.environment["WINEDLLOVERRIDES"]="winemenubuilder.exe=d;mscoree,mshtml=d"
  let stop=try Wrapper.stopSpec(game:game,runtime:runtime),wait=try Wrapper.waitSpec(game:game,runtime:runtime)
  do {
   try run(spec,120)
   // These are bootstrap-only processes. Stop this exact prefix before fixing
   // mappings, so no Wine service can recreate host-home links concurrently.
   try run(stop,15);try run(wait,15)
   guard fm.fileExists(atPath:support.appendingPathComponent("prefix/user.reg").path) else{throw LibraryError("Wine 尚未完成全新环境初始化，请查看 bootstrap.log。")}
   try SharedProfile.prepareWine(game:game,runtime:runtime,removeSeedRegistry:false)
   try JSONSerialization.data(withJSONObject:["identity":ref.storageKey,"schema":"1"],options:.sortedKeys).write(to:ready,options:.atomic)
  }catch {
   try? run(stop,10);try? run(wait,10)
   throw error
  }
 }
 private static func runBounded(_ spec:LaunchSpec,timeout:TimeInterval,log:URL)throws {
  let handle=try FileHandle(forWritingTo:log);try handle.seekToEnd();defer{try? handle.close()}
  let process=Process();process.executableURL=spec.executable;process.arguments=spec.arguments;process.environment=spec.environment;process.currentDirectoryURL=spec.directory;process.standardOutput=handle;process.standardError=handle
  let done=DispatchSemaphore(value:0);process.terminationHandler={_ in done.signal()}
  try PreparationTasks.shared.run(process);defer{PreparationTasks.shared.finish(process)}
  guard done.wait(timeout:.now()+timeout) == .success else {
   if process.isRunning{process.terminate()}
   if done.wait(timeout:.now()+3) != .success,process.isRunning{Darwin.kill(process.processIdentifier,SIGKILL);_ = done.wait(timeout:.now()+3)}
   throw LibraryError("Wine 首次初始化超时，已停止此准备进程。请检查连接和 bootstrap.log。")
  }
  guard process.terminationStatus==0 else{throw LibraryError("Wine 初始化失败（\(process.terminationStatus)），请查看 bootstrap.log。")}
 }
}
