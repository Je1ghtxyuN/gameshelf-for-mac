import AppKit
import ImageIO

@main struct PersonalLibraryMediaTests {
 static func main()throws {
  struct Failure:Error{}
  func check(_ value:Bool)throws{if !value{throw Failure()}}
  func rejects(_ action:()throws->Void)throws{do{try action();throw Failure()}catch is Failure{throw Failure()}catch{}}
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("PersonalMedia-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:600,pixelsHigh:800,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  for y in 0..<800{for x in 0..<600{bitmap.setColor(NSColor(deviceRed:0.2,green:0.4,blue:0.8,alpha:1),atX:x,y:y)}}
  let original=bitmap.representation(using:.png,properties:[:])!,file=root.appendingPathComponent("cover.png");try original.write(to:file)
  let payload=try LibraryCoverPayload.thumbnail(at:file),bytes=try payload.checkedBytes(expectedHash:payload.sha256)
  try check(bytes.count<=256*1024 && payload.mime=="image/jpeg")
  let image=NSBitmapImageRep(data:bytes)!;try check(image.pixelsWide<=384 && image.pixelsHigh<=384)
  try check(try Data(contentsOf:file)==original)
  try rejects{_ = try payload.checkedBytes(expectedHash:String(repeating:"0",count:64))}
  try rejects{_ = try LibraryCoverPayload(data:Data("not image".utf8).base64EncodedString(),mime:"image/jpeg",sha256:nil).checkedBytes()}
  try rejects{_ = try LibraryCoverPayload(data:String(repeating:"A",count:350001),mime:nil,sha256:nil).checkedBytes()}
  let linked=root.appendingPathComponent("linked.jpg");try FileManager.default.createSymbolicLink(at:linked,withDestinationURL:file)
  try rejects{_ = try LibraryCoverPayload.thumbnail(at:linked)}
  print("PASS PersonalLibraryMedia: bounded thumbnail roundtrip, original untouched, mismatched digest, malformed/oversized payload and source-link rejection")
 }
}
