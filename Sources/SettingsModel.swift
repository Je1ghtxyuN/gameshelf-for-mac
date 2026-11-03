import Foundation
import Darwin

struct SettingsActivity {
 let preparing:Bool
 let wineSessions:Int
 let nativeProcesses:Int
 let nativeApplications:Int
 let pendingNative:Int
 let webActive:Bool
 let pendingWeb:Bool
 var canChangeLocations:Bool {
  !preparing && wineSessions==0 && nativeProcesses==0 && nativeApplications==0 && pendingNative==0 && !webActive && !pendingWeb
 }
 var restrictionText:String? {
  if preparing{return "正在准备游戏或处理文件，完成后可更改位置。"}
  return canChangeLocations ? nil : "请先保存并退出正在运行或启动中的游戏，再更改位置。"
 }
}
struct SettingsVolumeInfo {
 let name:String
 let capacity:Int64?
 let available:Int64?
 let isMounted:Bool
 let isNetwork:Bool
 let statusText:String
 var usedFraction:Double? {
  guard isMounted,let capacity,capacity>0,let available,available>=0,available<=capacity else{return nil}
  return Double(capacity-available)/Double(capacity)
 }
}
struct SettingsMountedVolume {let path:String;let name:String;let isNetwork:Bool}
struct SettingsVolumeValues {let name:String;let capacity:Int64?;let available:Int64?}

enum SettingsStorageProbe {
 private static let mountLock=NSLock()
 // Kernel mount inventory uses MNT_NOWAIT: a missing NAS is rejected without
 // probing /Volumes or accidentally presenting the local root disk as its NAS.
 static func mountedVolumes()->[SettingsMountedVolume] {
  mountLock.lock();defer{mountLock.unlock()}
  var pointer:UnsafeMutablePointer<statfs>?
  let count=getmntinfo(&pointer,MNT_NOWAIT)
  guard count>0,let pointer else{return []}
  var result:[SettingsMountedVolume]=[]
  for i in 0..<Int(count) {
   var item=pointer[i]
   let path=withUnsafePointer(to:&item.f_mntonname){ptr in ptr.withMemoryRebound(to:CChar.self,capacity:Int(MAXPATHLEN)){String(cString:$0)}}
   let kind=withUnsafePointer(to:&item.f_fstypename){ptr in ptr.withMemoryRebound(to:CChar.self,capacity:Int(MFSNAMELEN)){String(cString:$0)}}
   let name=path=="/" ? "本地磁盘":URL(fileURLWithPath:path).lastPathComponent
   result.append(SettingsMountedVolume(path:path,name:name,isNetwork:["smbfs","nfs","webdav","afpfs"].contains(kind)))
  }
  return result
 }
 // Resource properties may contact a mounted server: caller must use a worker,
 // never the UI thread. No game tree is scanned and no file is created.
 static func read(_ path:URL)->SettingsVolumeInfo {
  read(path,mounts:mountedVolumes()){url in
   let v=try url.resourceValues(forKeys:[.volumeNameKey,.volumeTotalCapacityKey,.volumeAvailableCapacityKey])
   return SettingsVolumeValues(name:v.volumeName ?? "磁盘",capacity:v.volumeTotalCapacity.map(Int64.init),available:v.volumeAvailableCapacity.map(Int64.init))
  }
 }
 static func read(_ path:URL,mounts:[SettingsMountedVolume],resources:(URL)throws->SettingsVolumeValues)->SettingsVolumeInfo {
  let name=path.path
  let matches=mounts.filter {volume in name==volume.path || name.hasPrefix(volume.path=="/" ? "/":volume.path+"/")}.sorted{$0.path.count>$1.path.count}
  let components=path.pathComponents
  let external=components.count>2 && components[1]=="Volumes"
  let volume=matches.first
  if volume == nil || (external && !(volume!.path.hasPrefix("/Volumes/"))) {
   return SettingsVolumeInfo(name:external ? components[2]:"位置",capacity:nil,available:nil,isMounted:false,isNetwork:false,statusText:external ? "未连接":"位置不可用")
  }
  let selected=volume!
  do {
   let values=try resources(path)
   let total=values.capacity.flatMap{$0>=0 ? $0:nil},free=values.available.flatMap{$0>=0 ? $0:nil}
   return SettingsVolumeInfo(name:values.name,capacity:total,available:free,isMounted:true,isNetwork:selected.isNetwork,statusText:"已挂载")
  }catch {
   return SettingsVolumeInfo(name:selected.name,capacity:nil,available:nil,isMounted:true,isNetwork:selected.isNetwork,statusText:"暂时无法读取此位置")
  }
 }
}
