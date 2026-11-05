import AppKit
@main struct VerifiedGameMetadataTests {
 static func main()throws {
  let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("GameShelfMetadataApply-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let image=root.appendingPathComponent("cover.png")
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  try bitmap.representation(using:.png,properties:[:])!.write(to:image)
  let catalog=GameMetadataCatalog(root:root)
  try catalog.remember(title:"Example Novel",aliases:["ExampleNovel-1.1-win"],imageURL:image,source:"Developer",page:"https://example.com/novel")
  let game=Game(title:"ExampleNovel-1.1-win",folder:"/games/example",originalFolder:"/games/example",entry:Candidate(path:"Play_cn.exe",backend:.wine,engine:"Windows"),favorite:true,lastPlayed:Date(timeIntervalSince1970:100),windowSize:"1280x720")
  let updated=game.applyingKnownMetadata(catalog)
  precondition(updated.title=="Example Novel" && updated.cover != nil)
  func untouched(_ x:Game)throws->Data{var v=x;v.title="";v.cover=nil;v.coverOrigin=nil;v.defaultCoverSHA256=nil;let e=JSONEncoder();e.outputFormatting = [.sortedKeys];return try e.encode(v)}
  let before=try untouched(game),after=try untouched(updated);precondition(before==after)
  var custom=game;custom.title="My own title";custom.cover="/custom/cover.png"
  let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys];let customBefore=try encoder.encode(custom),customAfter=try encoder.encode(custom.applyingKnownMetadata(catalog));precondition(customBefore==customAfter)
  custom.title=game.title;custom.titleIsCustom=true;let keptTitle=custom.applyingKnownMetadata(catalog);precondition(keptTitle.title==game.title)
  custom.titleIsCustom=nil;let preserved=custom.applyingKnownMetadata(catalog)
  precondition(preserved.cover==custom.cover && preserved.title=="Example Novel")
  print("PASS confirmed aliases apply without changing launch/save identity, custom names or custom artwork")
 }
}
