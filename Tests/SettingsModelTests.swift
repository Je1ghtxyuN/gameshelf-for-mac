import Foundation
@main struct SettingsModelTests {
 static func main()throws {
  func check(_ value:Bool,_ label:String){if !value{fatalError(label)}}
  func activity(_ index:Int)->SettingsActivity {SettingsActivity(preparing:index==0,wineSessions:index==1 ? 1:0,nativeProcesses:index==2 ? 1:0,nativeApplications:index==3 ? 1:0,pendingNative:index==4 ? 1:0,webActive:index==5,pendingWeb:index==6)}
  check(SettingsActivity(preparing:false,wineSessions:0,nativeProcesses:0,nativeApplications:0,pendingNative:0,webActive:false,pendingWeb:false).canChangeLocations,"idle settings may change paths")
  for i in 0...6 {check(!activity(i).canChangeLocations,"active mode \(i) must block location changes");check(activity(i).restrictionText != nil,"blocked setting explains why")}
  let info=SettingsVolumeInfo(name:"Disk",capacity:100,available:25,isMounted:true,isNetwork:false,statusText:"ok")
  check(info.usedFraction==0.75,"volume bar describes total disk use")
  for pair:(Int64?,Int64?) in [(0,0),(100,101),(100,-1),(nil,20),(100,nil)] {
   check(SettingsVolumeInfo(name:"Disk",capacity:pair.0,available:pair.1,isMounted:true,isNetwork:false,statusText:"").usedFraction == nil,"invalid/missing capacity must not invent percent")
  }
  var calls=0
  let missing=SettingsStorageProbe.read(URL(fileURLWithPath:"/Volumes/TestShare/Game/.GameShelf"),mounts:[SettingsMountedVolume(path:"/",name:"Local",isNetwork:false)]){_ in calls+=1;return SettingsVolumeValues(name:"Wrong local",capacity:100,available:40)}
  check(!missing.isMounted && missing.capacity==nil && calls==0,"disconnected NAS must not inherit root volume data or query unavailable share")
  let network=SettingsMountedVolume(path:"/Volumes/TestShare",name:"TestShare",isNetwork:true)
  let valid=SettingsStorageProbe.read(URL(fileURLWithPath:"/Volumes/TestShare/Game/.GameShelf"),mounts:[SettingsMountedVolume(path:"/",name:"Local",isNetwork:false),network]){_ in calls+=1;return SettingsVolumeValues(name:"NAS",capacity:1000,available:400)}
  check(valid.isMounted && valid.isNetwork && valid.usedFraction==0.6 && calls==1,"mounted NAS displays its own volume values")
  let boundary=SettingsStorageProbe.read(URL(fileURLWithPath:"/Volumes/TestShare-other/Game"),mounts:[network]){_ in fatalError("mount prefix boundary violated")}
  check(!boundary.isMounted,"share prefix must respect path boundaries")
  let failed=SettingsStorageProbe.read(URL(fileURLWithPath:"/Volumes/TestShare/Game"),mounts:[network]){_ in throw NSError(domain:"fixture",code:1)}
  check(failed.isMounted && failed.capacity==nil && failed.usedFraction==nil,"read failure keeps mount state without fake size")
  print("PASS settings activity guards for all running modes; volume integrity, NAS disconnect, mount boundary and probe failures")
 }
}
