import Foundation
import Darwin

enum NativeVolumePolicy {
 static func usesSMB(_ directory:URL)->Bool {
  guard directory.isFileURL else{return false}
  var volume=statfs()
  guard statfs(directory.path,&volume)==0 else{return false}
  return withUnsafeBytes(of:volume.f_fstypename) { bytes in
   guard let name=bytes.bindMemory(to:CChar.self).baseAddress else{return false}
   return String(cString:name)=="smbfs"
  }
 }
}
