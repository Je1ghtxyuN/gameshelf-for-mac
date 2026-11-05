import AppKit
import ImageIO
import CryptoKit

struct LibraryCoverPayload:Codable {
 var data:String
 var mime:String?
 var sha256:String?
 func checkedBytes(expectedHash:String?=nil)throws->Data {
  guard data.utf8.count<=350000,let bytes=Data(base64Encoded:data),bytes.count<=256*1024,bytes.count>=4,bytes.prefix(2)==Data([0xff,0xd8]),
        let source=CGImageSourceCreateWithData(bytes as CFData,nil),CGImageSourceGetCount(source)==1,
        CGImageSourceGetType(source) as String? == "public.jpeg",
        let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
        let width=properties[kCGImagePropertyPixelWidth] as? NSNumber,let height=properties[kCGImagePropertyPixelHeight] as? NSNumber,
        (1...2048).contains(width.intValue),(1...2048).contains(height.intValue) else{throw LibraryError("封面图片格式或大小无效。")}
  let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
  guard sha256.map({$0==digest}) ?? true,expectedHash.map({$0==digest}) ?? true,mime.map({$0=="image/jpeg"}) ?? true else{throw LibraryError("封面校验不一致。")}
  return bytes
 }
 static func thumbnail(at url:URL)throws->Self {
  let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
  guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,(1...8*1024*1024).contains(size) else{throw LibraryError("封面文件不可用或过大。")}
  let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
  let data=try handle.read(upToCount:8*1024*1024+1) ?? Data()
  guard data.count<=8*1024*1024,let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
        let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
        let width=properties[kCGImagePropertyPixelWidth] as? NSNumber,let height=properties[kCGImagePropertyPixelHeight] as? NSNumber,
        width.doubleValue>0,height.doubleValue>0,width.doubleValue*height.doubleValue<=50000000,
        let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:384,kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
        let bytes=NSBitmapImageRep(cgImage:image).representation(using:.jpeg,properties:[.compressionFactor:0.8]),bytes.count<=256*1024 else{throw LibraryError("无法生成封面缩略图。")}
  return Self(data:bytes.base64EncodedString(),mime:"image/jpeg",sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined())
 }
}

extension SharedAPI {
 func value<T:Decodable>(_ path:String,method:String="GET",token:String?=nil,body:[String:Any]?=nil)async throws->T {
  try await withCheckedThrowingContinuation{continuation in request(path,method:method,token:token,body:body){(result:Result<T,Error>) in continuation.resume(with:result)}}
 }
}
