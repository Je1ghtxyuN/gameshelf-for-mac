import Foundation
import Darwin

enum RosettaPreparation {
 static func available()->Bool {
  var arm:Int32=0;var size=MemoryLayout.size(ofValue:arm)
  guard sysctlbyname("hw.optional.arm64",&arm,&size,nil,0)==0,arm==1 else{return true}
  let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/arch")
  process.arguments=["-x86_64","/usr/bin/true"]
  process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
  let done=DispatchSemaphore(value:0);process.terminationHandler={_ in done.signal()}
  do{try process.run()}catch{return false}
  guard done.wait(timeout:.now()+10) == .success else{stop(process,done:done);return false}
  return process.terminationStatus==0
 }
 // Called only after the user selects "Agree and install" in the dependency dialog.
 static func prepare(available:()->Bool=RosettaPreparation.available,
                     install:()throws->Void=RosettaPreparation.install)throws {
  if available(){return}
  try install()
  guard available() else{throw LibraryError("Rosetta 2 尚未可用，请完成系统安装后重试。")}
 }
 private static func install()throws {
  let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/softwareupdate")
  process.arguments=["--install-rosetta","--agree-to-license"]
  process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
  let done=DispatchSemaphore(value:0);process.terminationHandler={_ in done.signal()}
  try PreparationTasks.shared.run(process);defer{PreparationTasks.shared.finish(process)}
  guard done.wait(timeout:.now()+900) == .success else{stop(process,done:done);throw LibraryError("Rosetta 2 安装超时，请检查网络后重试。")}
  guard process.terminationStatus==0 else{throw LibraryError("Rosetta 2 安装未完成。请检查网络与系统安装权限后重试。")}
 }
 private static func stop(_ process:Process,done:DispatchSemaphore){
  if process.isRunning{process.terminate()}
  if done.wait(timeout:.now()+3) != .success,process.isRunning{Darwin.kill(process.processIdentifier,SIGKILL);_ = done.wait(timeout:.now()+3)}
 }
}
