import Foundation
import AppKit
import Darwin

@main struct GameMetadataCatalogTests {
 struct Failed:Error {let message:String}
 static func check(_ value:@autoclosure ()throws->Bool,_ message:String)throws{if try !value(){throw Failed(message:message)}}
 static func rejects(_ action:()throws->Void)throws{do{try action()}catch{return};throw Failed(message:"Unsafe or corrupt catalog input accepted")}
 static func image(_ url:URL)throws->Data {
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:12,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  for y in 0..<12{for x in 0..<8{bitmap.setColor(NSColor(deviceRed:0.1,green:0.4,blue:0.7,alpha:1),atX:x,y:y)}}
  let bytes=bitmap.representation(using:.png,properties:[:])!;try bytes.write(to:url);return bytes
 }
 static func main(){do{try run()}catch{print("FAIL: \(error)");exit(1)}}
 static func run()throws {
  let fm=FileManager.default,base=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("MetadataCatalog-"+UUID().uuidString)
  try fm.createDirectory(at:base,withIntermediateDirectories:false);defer{try? fm.removeItem(at:base)}
  let original=base.appendingPathComponent("selected.png"),bytes=try image(original),root=base.appendingPathComponent("library")
  if CommandLine.arguments.contains("--concurrent-alias") {
   try concurrentAliasMerge(base:base,original:original)
   print("PASS concurrent same-ID alias merge")
   return
  }
  try sequentialAliasMerge(base:base,original:original)
  try concurrentAliasMerge(base:base,original:original)
  let store=GameMetadataCatalog(root:root)
  try check(store.match("Unverified")==nil,"empty catalog must not guess")
  let saved=try store.remember(title:"Café: Example",aliases:["ＣＡＦＥ Example","別名"],imageURL:original,source:"Official",page:"https://example.invalid/game")
  try check(store.match("Cafe\u{301} Example")?.id==saved.id,"Unicode normalized exact alias")
  try check(store.match("別名")?.id==saved.id,"explicit alias reused")
  try check(store.match("Café Example 2")==nil && store.match("Café Example v1.0")==nil,"no prefix/version heuristics")
  let cached=try require(store.coverURL(saved));try check(try Data(contentsOf:cached)==bytes,"cache exact validated bytes")
  try check(try Data(contentsOf:original)==bytes,"source image unchanged")
  try check(!saved.image.contains("/") && saved.image != original.path,"only relative cached image filename")
  let path=root.appendingPathComponent("Metadata/catalog.json"),serialized=try Data(contentsOf:path)
  let json=try JSONSerialization.jsonObject(with:serialized) as! [String:Any]
  try check(json["version"] as? Int==1,"versioned catalog")
  let rows=json["records"] as! [[String:Any]]
  try check(Set(rows[0].keys)==["id","title","aliases","image","source","page"],"metadata whitelist, no local paths or credentials")
  try check(!String(decoding:serialized,as:UTF8.self).contains(original.path),"no source path serialized")
  let fresh=GameMetadataCatalog(root:root);try check(fresh.match("別名")?.id==saved.id,"restart reuses private record")
  let repeated=try fresh.remember(title:"Café: Example",aliases:["別名"],imageURL:original,source:"Official",page:"https://example.invalid/game")
  try check(repeated.id==saved.id,"remember without explicit ID has stable identity")
  _ = try fresh.remember(title:"Renamed",aliases:["Café Example"],imageURL:original,source:"Official",page:"https://example.invalid/game",id:saved.id)
  try check(store.match("Café Example")?.title=="Renamed","other instances observe replacement by ID")
  _ = try fresh.remember(title:"Another edition",aliases:["Café Example"],imageURL:original,source:"Official",page:"https://example.invalid/other",id:"other-edition")
  try check(store.match("Café Example")==nil,"ambiguous aliases never pick first")
  try check(store.match("Another edition")?.id=="other-edition","distinct canonical title still matches")
  var forged=saved;forged.image="../selected.png";try check(store.coverURL(forged)==nil,"record cannot escape cover directory")
  let valid=try Data(contentsOf:path)
  try Data("broken".utf8).write(to:path)
  try check(store.match("Renamed")==nil,"external corruption fails closed")
  try check(GameMetadataCatalog(root:root).match("Renamed")==nil,"damaged store construction is harmless")
  try rejects{_ = try store.remember(title:"New",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/new")}
  try check(try Data(contentsOf:path)==Data("broken".utf8),"corrupt catalog is never reset")
  try valid.write(to:path)
  let linked=base.appendingPathComponent("linked.png");try fm.createSymbolicLink(at:linked,withDestinationURL:original)
  try rejects{_ = try store.remember(title:"Linked",aliases:[],imageURL:linked,source:"Official",page:"https://example.invalid/linked")}
  let invalid=base.appendingPathComponent("invalid.png");try Data("not an image".utf8).write(to:invalid)
  try rejects{_ = try store.remember(title:"Bad",aliases:[],imageURL:invalid,source:"Official",page:"https://example.invalid/bad")}
  let huge=base.appendingPathComponent("huge.png");try Data(repeating:0,count:8*1024*1024+1).write(to:huge)
  try rejects{_ = try store.remember(title:"Huge",aliases:[],imageURL:huge,source:"Official",page:"https://example.invalid/huge")}
  for page in ["http://example.invalid/game","https://user:secret@example.invalid/game","https://example.invalid/game?token=secret","file:///private/test"] {
   try rejects{_ = try store.remember(title:"Unsafe",aliases:[],imageURL:original,source:"Official",page:page)}
  }
  try rejects{_ = try store.remember(title:String(repeating:"x",count:1025),aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/large")}
  try check(try Data(contentsOf:path)==valid,"invalid input never changes prior catalog")
  let record=try require(store.match("Renamed")),cover=try require(store.coverURL(record))
  try fm.removeItem(at:cover);try fm.createSymbolicLink(at:cover,withDestinationURL:original)
  try check(store.coverURL(record)==nil,"linked cached image rejected")
  try fm.removeItem(at:cover);try Data("damaged".utf8).write(to:cover)
  try check(store.coverURL(record)==nil,"damaged cached image rejected")
  try bytes.write(to:cover)
  try fm.removeItem(at:path);try fm.createSymbolicLink(at:path,withDestinationURL:original)
  try check(store.match("Renamed")==nil,"linked catalog rejected")
  try rejects{_ = try store.remember(title:"No",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/no")}
  try check(try Data(contentsOf:original)==bytes,"linked target untouched")
  let other=base.appendingPathComponent("other");try fm.createDirectory(at:other,withIntermediateDirectories:false)
  let parentLink=base.appendingPathComponent("parent-link");try fm.createSymbolicLink(at:parentLink,withDestinationURL:other)
  let linkedStore=GameMetadataCatalog(root:parentLink)
  try check(linkedStore.match("Renamed")==nil,"linked store reads fail closed")
  try rejects{_ = try linkedStore.remember(title:"Linked",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/linked")}
  let root2=base.appendingPathComponent("library2"),store2=GameMetadataCatalog(root:root2)
  _ = try store2.remember(title:"Safe",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/safe")
  let covers=root2.appendingPathComponent("Metadata/Covers");try fm.removeItem(at:covers);try fm.createSymbolicLink(at:covers,withDestinationURL:other)
  try check(store2.match("Safe")==nil,"linked cover directory fails closed")
  try rejects{_ = try store2.remember(title:"Linked",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/linked")}
  try check(try fm.contentsOfDirectory(atPath:other.path).isEmpty,"linked storage never written")
  // Independent instances must serialize read-modify-write without losing records.
  let concurrentRoot=base.appendingPathComponent("concurrent"),errorLock=NSLock()
  var failures=[String]()
  DispatchQueue.concurrentPerform(iterations:12){index in
   do{_ = try GameMetadataCatalog(root:concurrentRoot).remember(title:"Concurrent \(index)",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/concurrent/\(index)",id:"record-\(index)")}
   catch{errorLock.lock();failures.append(String(describing:error));errorLock.unlock()}
  }
  try check(failures.isEmpty,"concurrent writes succeed: \(failures)")
  let concurrent=GameMetadataCatalog(root:concurrentRoot)
  for index in 0..<12{try check(concurrent.match("Concurrent \(index)")?.id=="record-\(index)","no lost update across instances")}
  let documentURL=concurrentRoot.appendingPathComponent("Metadata/catalog.json"),documentBytes=try Data(contentsOf:documentURL)
  let permissions=try fm.attributesOfItem(atPath:documentURL.path)[.posixPermissions] as! NSNumber
  try check(permissions.intValue & 0o777 == 0o600,"catalog stays private")
  let coverPermissions=try fm.attributesOfItem(atPath:concurrentRoot.appendingPathComponent("Metadata/Covers").path)[.posixPermissions] as! NSNumber
  try check(coverPermissions.intValue & 0o777 == 0o700,"cover directory stays private")
  let document=try JSONSerialization.jsonObject(with:documentBytes) as! [String:Any]
  let validRows=document["records"] as! [[String:Any]]
  var corruptDocuments=[[String:Any]]()
  var changed=document;changed["version"]=2;corruptDocuments.append(changed)
  changed=document;changed["records"]=[validRows[0],validRows[0]];corruptDocuments.append(changed)
  changed=document;changed["credentials"]="forbidden";corruptDocuments.append(changed)
  var changedRow=validRows[0];changedRow["executable"]="/private/never-read";changed=document;changed["records"]=[changedRow];corruptDocuments.append(changed)
  changedRow=validRows[0];changedRow["image"]="../selected.png";changed=document;changed["records"]=[changedRow];corruptDocuments.append(changed)
  changed=document;changed["records"]=(0...1000).map{index -> [String:Any] in var row=validRows[0];row["id"]="overflow-\(index)";return row};corruptDocuments.append(changed)
  for corrupted in corruptDocuments {
   let encoded=try JSONSerialization.data(withJSONObject:corrupted)
   try encoded.write(to:documentURL)
   try check(concurrent.match("Concurrent 0")==nil,"invalid schema/count fails closed")
   try rejects{_ = try concurrent.remember(title:"Forbidden",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/forbidden")}
   try check(try Data(contentsOf:documentURL)==encoded,"rejected catalog remains unchanged")
  }
  try Data(repeating:32,count:4*1024*1024+1).write(to:documentURL)
  try check(concurrent.match("Concurrent 0")==nil,"oversize catalog fails closed")
  try rejects{_ = try concurrent.remember(title:"Forbidden",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/forbidden")}
  try documentBytes.write(to:documentURL)
  let wide=base.appendingPathComponent("wide.png")
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4097,pixelsHigh:1,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  try bitmap.representation(using:.png,properties:[:])!.write(to:wide)
  try rejects{_ = try concurrent.remember(title:"Wide",aliases:[],imageURL:wide,source:"Official",page:"https://example.invalid/wide")}
  let truncated=base.appendingPathComponent("truncated.png");try bytes.prefix(40).write(to:truncated)
  try rejects{_ = try concurrent.remember(title:"Truncated",aliases:[],imageURL:truncated,source:"Official",page:"https://example.invalid/truncated")}
  let sourceDirectoryLink=base.appendingPathComponent("image-parent");try fm.createSymbolicLink(at:sourceDirectoryLink,withDestinationURL:base)
  try rejects{_ = try concurrent.remember(title:"Linked ancestor",aliases:[],imageURL:sourceDirectoryLink.appendingPathComponent("selected.png"),source:"Official",page:"https://example.invalid/link")}
  let hard=base.appendingPathComponent("hard.png");try fm.linkItem(at:original,to:hard)
  try rejects{_ = try concurrent.remember(title:"Hard link",aliases:[],imageURL:hard,source:"Official",page:"https://example.invalid/hard")}
  try fm.removeItem(at:hard)
  let fifo=base.appendingPathComponent("pipe.png");try check(mkfifo(fifo.path,0o600)==0,"fixture FIFO created")
  try rejects{_ = try concurrent.remember(title:"FIFO",aliases:[],imageURL:fifo,source:"Official",page:"https://example.invalid/fifo")}
  try check(try Data(contentsOf:documentURL)==documentBytes,"all rejected inputs preserve prior committed data")
  let beforeImage=try require(concurrent.match("Concurrent 0")),beforeURL=try require(concurrent.coverURL(beforeImage))
  try fm.removeItem(at:beforeURL);try bytes.write(to:beforeURL)
  // A valid image changed in-place must also fail the immutable content identity.
  let alternate=NSBitmapImageRep(data:bytes)!;alternate.setColor(.red,atX:0,y:0)
  try alternate.representation(using:.png,properties:[:])!.write(to:beforeURL)
  try check(concurrent.coverURL(beforeImage)==nil,"different valid cover bytes cannot impersonate cached content")
  try rejects{_ = try concurrent.remember(title:"Concurrent 0",aliases:[],imageURL:original,source:"Official",page:"https://example.invalid/concurrent/0",id:"record-0")}
  try check(try Data(contentsOf:documentURL)==documentBytes,"failed immutable-image validation never publishes a record")
  print("PASS metadata catalog: stable private records, Unicode exact/ambiguous aliases, ID replacement, validated byte reuse, bounded parsing, corrupt/link rejection and source preservation")
 }
 static func sequentialAliasMerge(base:URL,original:URL)throws {
  let root=base.appendingPathComponent("alias-merge"),store=GameMetadataCatalog(root:root)
  let first=try store.remember(title:"Café Game",aliases:["First only","Folder A","ＣＡＦＥ Game"],imageURL:original,source:"Official",page:"https://example.invalid/alias-merge")
  let second=try GameMetadataCatalog(root:root).remember(title:"CAFE GAME",aliases:["Folder B","ＦＯＬＤＥＲ A","Cafe\u{301} Game"],imageURL:original,source:"Official",page:"https://example.invalid/alias-merge")
  try check(first.id==second.id,"same official selection retains computed ID")
  try check(store.match("First only")?.id==first.id,"later automatic remember preserves first confirmed alias")
  try check(store.match("Folder B")?.id==first.id,"later automatic remember adds new confirmed alias")
  try check(second.aliases==["First only","Folder A","Folder B"],"merge deduplicates normalized keys including canonical title")
  let replacement=try store.remember(title:"Explicit replacement",aliases:["Only replacement"],imageURL:original,source:"Official",page:"https://example.invalid/replacement",id:first.id)
  try check(replacement.aliases==["Only replacement"] && store.match("First only")==nil && store.match("Folder A")==nil && store.match("Folder B")==nil,"explicit ID remains full replacement")
  let bounded=GameMetadataCatalog(root:base.appendingPathComponent("alias-boundary"))
  let sixtyFour=(0..<64).map{"Bounded alias \($0)"}
  let full=try bounded.remember(title:"Bounded game",aliases:sixtyFour,imageURL:original,source:"Official",page:"https://example.invalid/alias-boundary")
  let path=base.appendingPathComponent("alias-boundary/Metadata/catalog.json"),before=try Data(contentsOf:path)
  try rejects{_ = try bounded.remember(title:"Bounded game",aliases:["Alias 65"],imageURL:original,source:"Official",page:"https://example.invalid/alias-boundary")}
  try check(try Data(contentsOf:path)==before,"merged alias overflow leaves committed catalog unchanged")
  let unchanged=try bounded.remember(title:"Bounded game",aliases:["BOUNDED ALIAS 0","Bounded game"],imageURL:original,source:"Official",page:"https://example.invalid/alias-boundary")
  try check(unchanged.aliases==full.aliases && unchanged.aliases.count==64,"deduplicated merge fits exact 64-alias boundary")
 }
 static func concurrentAliasMerge(base:URL,original:URL)throws {
  let root=base.appendingPathComponent("concurrent-alias-merge"),errorLock=NSLock()
  var failures=[String]()
  DispatchQueue.concurrentPerform(iterations:12){index in
   do{_ = try GameMetadataCatalog(root:root).remember(title:"Same canonical game",aliases:["Confirmed alias \(index)"],imageURL:original,source:"Official",page:"https://example.invalid/concurrent-alias-merge")}
   catch{errorLock.lock();failures.append(String(describing:error));errorLock.unlock()}
  }
  try check(failures.isEmpty,"concurrent alias merges succeed: \(failures)")
  let store=GameMetadataCatalog(root:root),record=try require(store.match("Same canonical game"))
  try check(record.aliases.count==12,"concurrent same-ID remember retains all confirmed aliases")
  for index in 0..<12{try check(store.match("Confirmed alias \(index)")?.id==record.id,"concurrent aliases match the same stable ID")}
 }
 static func require<T>(_ value:T?)throws->T{guard let value else{throw Failed(message:"Expected verified value")};return value}
}
