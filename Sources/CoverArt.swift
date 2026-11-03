import Foundation
import AppKit
import ImageIO

struct CoverMatch {
 let title:String
 let aliases:[String]
 let image:URL
 let page:URL
 let source:String
 var steamID:Int?=nil
}
private final class CoverNetworkGate:NSObject,URLSessionTaskDelegate,URLSessionDownloadDelegate {
 let origin:URL
 init(_ origin:URL){self.origin=origin}
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
  completionHandler(request.url.map{CoverArt.allowedRedirect(from:origin,to:$0)} == true ? request:nil)
 }
 func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){}
 func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){if totalBytesWritten>8*1024*1024 || totalBytesExpectedToWrite>8*1024*1024{downloadTask.cancel()}}
}
enum CoverArt {
 static func allowedRedirect(from origin:URL,to target:URL)->Bool {
  target.scheme=="https" && target.user==nil && target.password==nil && (target.host==origin.host || (allowedImage(origin) && allowedImage(target)))
 }
 static func steamID(_ url:String)->Int? {
  guard let u=URL(string:url),u.scheme=="https",u.host=="store.steampowered.com" else{return nil}
  let parts=u.path.split(separator:"/");guard parts.count>=2,parts[0]=="app" else{return nil};return Int(parts[1])
 }
 static func merge(_ a:[CoverMatch],_ b:[CoverMatch])->[CoverMatch] {
  a+b.filter{row in !a.contains{first in first.steamID != nil && first.steamID==row.steamID}}
 }

 static func query(_ title:String)->String {
  var text=title.replacingOccurrences(of:#"\[[^\]]*\]|【[^】]*】"#,with:" ",options:.regularExpression)
  text=text.replacingOccurrences(of:#"(?i)\s+[vV]?\d+(?:\.\d+)+(?:[-_\w.]*)\s*$"#,with:"",options:.regularExpression)
  text=text.replacingOccurrences(of:#"(?i)(?:[-_ ](?:pc|windows|win64|win32|汉化版|中文版|汉化|中文|完整版))+$"#,with:"",options:.regularExpression)
  return String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(160))
 }
 static func key(_ text:String)->String {
  text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX")).unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.map(String.init).joined()
 }
 static func exact(_ matches:[CoverMatch],query:String)->CoverMatch? {
  let k=key(query);guard k.count>=2 else{return nil}
  let rows=matches.filter{([$0.title]+$0.aliases).contains{key($0)==k}}
  return rows.count==1 ? rows[0]:nil
 }
 static func allowedImage(_ u:URL)->Bool {
  guard u.scheme=="https",let h=u.host?.lowercased(),u.user==nil,u.password==nil else{return false}
  return ["t.vndb.org","s.vndb.org","shared.fastly.steamstatic.com","shared.akamai.steamstatic.com","cdn.akamai.steamstatic.com","cdn.cloudflare.steamstatic.com","steamcdn-a.akamaihd.net"].contains(h)
 }
 static func parseVNDB(_ data:Data)throws->[CoverMatch] {
  let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
  return (json?["results"] as? [[String:Any]] ?? []).compactMap{r in
   guard let id=r["id"] as? String,id.range(of:#"^v\d+$"#,options:.regularExpression) != nil,let name=r["title"] as? String,let im=r["image"] as? [String:Any],let rating=im["sexual"] as? Double,rating<0.5,let raw=(im["thumbnail"] ?? im["url"]) as? String,let url=URL(string:raw),allowedImage(url) else{return nil}
   let aliases=(r["titles"] as? [[String:Any]] ?? []).flatMap{[$0["title"] as? String,$0["latin"] as? String].compactMap{$0}}
   var match=CoverMatch(title:name,aliases:aliases,image:url,page:URL(string:"https://vndb.org/"+id)!,source:"VNDB")
   match.steamID=(r["extlinks"] as? [[String:Any]] ?? []).compactMap{($0["url"] as? String).flatMap{steamID($0)}}.first
   return match
  }
 }
 static func request(_ url:URL,body:[String:Any]?=nil)async throws->Data {
  let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=25;config.httpCookieStorage=nil;config.urlCache=nil
  let session=URLSession(configuration:config,delegate:CoverNetworkGate(url),delegateQueue:nil);defer{session.invalidateAndCancel()}
  var request=URLRequest(url:url);request.setValue("GameShelf/1.0 (personal macOS game library)",forHTTPHeaderField:"User-Agent")
  if let body {request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONSerialization.data(withJSONObject:body)}
  let (temp,response)=try await session.download(for:request);defer{try? FileManager.default.removeItem(at:temp)}
  guard let http=response as? HTTPURLResponse,http.statusCode==200,let final=http.url,final.scheme=="https",(final.host==url.host || (allowedImage(url) && allowedImage(final))) else{throw LibraryError("封面服务暂不可用，请稍后重试。")}
  let size=try temp.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
  guard size<=8*1024*1024 else{throw LibraryError("封面文件过大。")}
  return try Data(contentsOf:temp)
 }
 static func search(_ title:String)async throws->[CoverMatch] {
  let q=query(title);guard q.count>=2 else{return []}
  var matches:[CoverMatch]=[]
  var succeeded=false
  do {
   let data=try await request(URL(string:"https://api.vndb.org/kana/vn")!,body:["filters":["search","=",q],"fields":"title,titles.title,titles.latin,image.thumbnail,image.sexual,extlinks.url","sort":"searchrank","results":8])
   matches=try parseVNDB(data);succeeded=true
  }catch{}
  var parts=URLComponents(string:"https://store.steampowered.com/api/storesearch/")!
  parts.queryItems=[URLQueryItem(name:"term",value:q),URLQueryItem(name:"l",value:"schinese"),URLQueryItem(name:"cc",value:"cn")]
  do {
   let data=try await request(parts.url!)
   let json=try JSONSerialization.jsonObject(with:data) as? [String:Any]
   for row in (json?["items"] as? [[String:Any]] ?? []).prefix(8) {
    guard let id=row["id"] as? Int,let name=row["name"] as? String,let raw=row["tiny_image"] as? String,let u=URL(string:raw),allowedImage(u) else{continue}
    let row=CoverMatch(title:name,aliases:[],image:u,page:URL(string:"https://store.steampowered.com/app/\(id)/")!,source:"Steam",steamID:id)
    matches=merge(matches,[row])
   };succeeded=true
  }catch{}
  guard succeeded else{throw LibraryError("联网查找失败，请检查网络后重试；不影响游戏启动。")}
  return matches
 }
 static func save(_ match:CoverMatch,to root:URL,id:UUID)async throws->String {
  guard allowedImage(match.image) else{throw LibraryError("不支持此封面来源。")}
  let data=try await request(match.image)
  guard let src=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else{throw LibraryError("封面图片无法读取。")}
  let bitmap=NSBitmapImageRep(cgImage:image)
  guard let png=bitmap.representation(using:.png,properties:[:]) else{throw LibraryError("封面保存失败。")}
  let dir=root.appendingPathComponent("Covers");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  let dest=dir.appendingPathComponent(id.uuidString+"-"+UUID().uuidString+".png")
  try png.write(to:dest,options:.atomic)
  let receipt:[String:String]=["title":match.title,"source":match.source,"page":match.page.absoluteString,"image":match.image.absoluteString]
  try JSONSerialization.data(withJSONObject:receipt,options:.prettyPrinted).write(to:dest.appendingPathExtension("json"),options:.atomic)
  return dest.path
 }
}
