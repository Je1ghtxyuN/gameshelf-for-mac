import Foundation
@main struct NativeVolumePolicyTests {
 static func main()throws {
  let fm=FileManager.default,root=URL(fileURLWithPath:"/private/tmp/native-volume-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:false);defer{try? fm.removeItem(at:root)}
  precondition(!NativeVolumePolicy.usesSMB(root),"local filesystem must keep ordinary close semantics")
  precondition(!NativeVolumePolicy.usesSMB(root.appendingPathComponent("missing")),"unresolved volume must not enable compatibility")
  precondition(!NativeVolumePolicy.usesSMB(URL(string:"https://example.org/game")!),"remote URLs are not mounted SMB resources")
  let link=root.appendingPathComponent("local-link");try fm.createSymbolicLink(at:link,withDestinationURL:root)
  precondition(!NativeVolumePolicy.usesSMB(link),"a symlink does not make a local filesystem SMB")
  if CommandLine.arguments.count==2 {
   let remote=URL(fileURLWithPath:CommandLine.arguments[1])
   precondition(NativeVolumePolicy.usesSMB(remote),"expected actual mounted SMB test directory")
   let alias=root.appendingPathComponent("remote-link");try fm.createSymbolicLink(at:alias,withDestinationURL:remote)
   precondition(NativeVolumePolicy.usesSMB(alias),"local cache payload link must use its SMB target volume")
  }
  print("PASS native volume policy: local/missing/URL/symlink stay off; optional mounted SMB checked")
 }
}
