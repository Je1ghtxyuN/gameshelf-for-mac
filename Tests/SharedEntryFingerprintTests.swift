import Foundation
import CryptoKit
@main struct SharedEntryFingerprintTests {
 static func main()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("SharedEntryHash-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root.appendingPathComponent("Native.app/Contents"),withIntermediateDirectories:true)
  defer{try? FileManager.default.removeItem(at:root)}
  let bytes=Data("MZ same executable".utf8);try bytes.write(to:root.appendingPathComponent("Game.exe"))
  let expected=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
  let wine=Candidate(path:"Game.exe",backend:.wine,engine:"Windows")
  precondition(tryHash(root,wine)==expected)
  try Data("changed executable".utf8).write(to:root.appendingPathComponent("Game.exe"));precondition(tryHash(root,wine) != expected)
  try bytes.write(to:root.appendingPathComponent("Native.app/Contents/Info.plist"))
  precondition(tryHash(root,Candidate(path:"Native.app",backend:.native,engine:"macOS"))==expected)
  try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.exe"),withDestinationURL:root.appendingPathComponent("Game.exe"))
  do{_ = try SharedEntryFingerprint.hash(folder:root,entry:Candidate(path:"link.exe",backend:.wine,engine:"Windows"));fatalError("linked entry accepted")}catch{}
  print("PASS bounded publication entry fingerprints: exact bytes, native bundle and symlink rejection")
 }
 static func tryHash(_ root:URL,_ entry:Candidate)->String{try! SharedEntryFingerprint.hash(folder:root,entry:entry)}
}
