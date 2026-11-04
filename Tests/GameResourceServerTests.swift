import Foundation
import Darwin

private func expect(_ condition:Bool,_ message:String)throws {
 if !condition {throw NSError(domain:"GameResourceServerTests",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
private func rejects(_ message:String,_ body:()throws->Void)throws {
 do {try body()} catch {return}
 throw NSError(domain:"GameResourceServerTests",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected rejection: "+message])
}
private final class Client {
 let fd:Int32
 init(port:UInt16)throws {
  fd=socket(AF_INET,SOCK_STREAM,0)
  guard fd>=0 else{throw POSIXError(.ENFILE)}
  var timeout=timeval(tv_sec:8,tv_usec:0)
  setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
  var noSignal:Int32=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,4)
  var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family=sa_family_t(AF_INET);address.sin_port=port.bigEndian
  address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"))
  let result=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
  if result != 0 {Darwin.close(fd);throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .ECONNREFUSED)}
 }
 deinit{Darwin.close(fd)}
 func send(_ text:String)throws {
  let data=Data(text.utf8)
  try data.withUnsafeBytes {bytes in
   var offset=0
   while offset<bytes.count {
    let n=Darwin.send(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset,0)
    if n<=0 {throw POSIXError(.EPIPE)};offset+=n
   }
  }
 }
 func receive()throws -> Data {
  var result=Data(),buffer=[UInt8](repeating:0,count:65536)
  while true {
   let n=Darwin.recv(fd,&buffer,buffer.count,0)
   if n==0 {return result}
   if n<0 {
    if errno==ECONNRESET{return result}
    throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
   }
   result.append(contentsOf:buffer.prefix(n))
  }
 }
}
private struct Response {
 let status:Int,headers:[String:String],body:Data
 init(_ bytes:Data)throws {
  guard let split=bytes.range(of:Data("\r\n\r\n".utf8)),let header=String(data:bytes[..<split.lowerBound],encoding:.utf8) else{throw POSIXError(.EPROTO)}
  let lines=header.components(separatedBy:"\r\n")
  status=Int(lines[0].split(separator:" ")[1]) ?? 0
  var fields:[String:String]=[:]
  for line in lines.dropFirst() {
   let parts=line.split(separator:":",maxSplits:1)
   if parts.count==2 {fields[String(parts[0]).lowercased()]=parts[1].trimmingCharacters(in:.whitespaces)}
  }
  headers=fields;body=Data(bytes[split.upperBound...])
 }
}
private final class Fixture {
 let base:URL,root:URL
 init()throws {
  base=FileManager.default.temporaryDirectory.appendingPathComponent("ResourceServer-"+UUID().uuidString)
  root=base.appendingPathComponent("资源 root")
  try FileManager.default.createDirectory(at:root.appendingPathComponent("data"),withIntermediateDirectories:true)
  try Data("<html>synthetic</html>".utf8).write(to:root.appendingPathComponent("index.html"))
  try Data("{\"synthetic\":true}".utf8).write(to:root.appendingPathComponent("data/中文.json"))
  try Data([0,97,115,109,1,0,0,0]).write(to:root.appendingPathComponent("engine.wasm"))
  try Data((0..<200_000).map{UInt8($0%251)}).write(to:root.appendingPathComponent("movie.webm"))
  try Data("PRIVATE SENTINEL".utf8).write(to:base.appendingPathComponent("secret.txt"))
  try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape.txt"),withDestinationURL:base.appendingPathComponent("secret.txt"))
  try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("external"),withDestinationURL:base)
  try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("internal.json").path,withDestinationPath:"data/中文.json")
  try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("internal-dir").path,withDestinationPath:"data")
  try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("chain.json").path,withDestinationPath:"internal.json")
 }
 deinit{try? FileManager.default.removeItem(at:base)}
 func request(_ server:GameResourceServer,_ path:String,method:String="GET",headers:String="",host:String?=nil)throws -> Response {
  let client=try Client(port:server.port)
  try client.send("\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(server.port)")\r\n\(headers)\r\n")
  return try Response(client.receive())
 }
}
@main struct GameResourceServerTests {
 static func main()throws {
  if CommandLine.arguments.contains("--burst-only") {try burstRequests();print("PASS: burst");return}
  if CommandLine.arguments.contains("--paths-only") {try pinnedRootFastPath();print("PASS: pinned root");return}
  try burstRequests()
  try pinnedRootFastPath()
  try servingAndRanges()
  try scriptSuffixes()
  try pathAndProtocolSafety()
  try stableOriginAndShutdown()
  try boundedRequests()
  try stopDuringStreaming()
  print("PASS: 8 actual-socket resource-server suites: streaming/HEAD/MIME/ranges, isolation/protocol, stable origin/shutdown, bounded requests")
 }
 static func scriptSuffixes()throws {
  let f=try Fixture(),file=f.root.appendingPathComponent("adapter.js")
  let original=Data("window.original=true;".utf8),suffix=Data("\nwindow.accountAdapter=true;".utf8)
  try original.write(to:file)
  let server=try GameResourceServer(root:f.root,scriptSuffixes:["adapter.js":suffix]);defer{server.stop()}
  let entry=try server.entryURL(relativePath:"index.html"),prefix=entry.deletingLastPathComponent().path+"/"
  let full=try f.request(server,prefix+"adapter.js")
  try expect(full.status==200 && full.body==original+suffix,"adapter suffix must be served after the actual script")
  try expect(Int(full.headers["content-length"] ?? "") == original.count+suffix.count,"adapter response size")
  let partial=try f.request(server,prefix+"adapter.js",headers:"Range: bytes=20-29\r\n")
  try expect(partial.status==206 && partial.body==Data((original+suffix)[20..<30]),"ranges must use transformed script bytes")
  let head=try f.request(server,prefix+"adapter.js",method:"HEAD")
  try expect(head.body.isEmpty && head.headers["content-length"]==String(original.count+suffix.count),"HEAD transformed length")
  try expect(try Data(contentsOf:file)==original,"serving must not rewrite source script")
  try rejects("non-script suffix") {_ = try GameResourceServer(root:f.root,scriptSuffixes:["movie.webm":suffix])}
  try rejects("suffix traversal") {_ = try GameResourceServer(root:f.root,scriptSuffixes:["../adapter.js":suffix])}
  try rejects("oversize suffix") {_ = try GameResourceServer(root:f.root,scriptSuffixes:["adapter.js":Data(repeating:65,count:262145)])}
 }
 static func servingAndRanges()throws {
  let f=try Fixture(),server=try GameResourceServer(root:f.root);defer{server.stop()}
  let entry=try server.entryURL(relativePath:"index.html")
  try expect(entry.host=="127.0.0.1" && entry.port==Int(server.port),"wrong bind origin")
  let prefix=entry.deletingLastPathComponent().path+"/"
  let wasm=try f.request(server,prefix+"engine.wasm")
  try expect(wasm.headers["cache-control"]=="no-store","NAS resources must not be retained in a browser disk cache")
  try expect(wasm.status==200 && wasm.headers["content-type"]=="application/wasm","WASM MIME")
  try expect(wasm.body==Data([0,97,115,109,1,0,0,0]),"WASM bytes")
  let json=try server.entryURL(relativePath:"data/中文.json")
  let response=try f.request(server,URLComponents(url:json,resolvingAgainstBaseURL:false)!.percentEncodedPath)
  try expect(response.status==200 && response.body==Data("{\"synthetic\":true}".utf8),"Unicode JSON")
  let internalLink=try f.request(server,prefix+"internal.json")
  try expect(internalLink.body==response.body,"internal resource link failed")
  for path in ["internal-dir/%E4%B8%AD%E6%96%87.json","chain.json"] {
   let linked=try f.request(server,prefix+path)
   try expect(linked.status==200 && linked.body==response.body,"internal directory/chained link fallback failed")
  }
  let expected=try Data(contentsOf:f.root.appendingPathComponent("movie.webm"))
  let full=try f.request(server,prefix+"movie.webm")
  try expect(full.body==expected && full.headers["content-type"]=="video/webm","stream over 64 KiB corrupted")
  let head=try f.request(server,prefix+"movie.webm",method:"HEAD")
  try expect(head.status==200 && head.body.isEmpty && head.headers["content-length"]=="200000","HEAD returned body/wrong size")
  for (range,low,high) in [("bytes=65530-65545",65530,65545),("bytes=-13",199987,199999),("bytes=199990-",199990,199999),("bytes=199990-999999",199990,199999)] {
   let result=try f.request(server,prefix+"movie.webm",headers:"Range: \(range)\r\n")
   try expect(result.status==206 && result.body==expected.subdata(in:low..<(high+1)),"single range incorrect")
   try expect(result.headers["content-range"]=="bytes \(low)-\(high)/200000","Content-Range incorrect")
  }
  for range in ["bytes=200000-","bytes=4-2","bytes=0-1,4-5","bytes=-0","bytes=9999999999999999999999999-"] {
   let result=try f.request(server,prefix+"movie.webm",headers:"Range: \(range)\r\n")
   try expect(result.status==416 && result.headers["content-range"]=="bytes */200000","invalid range accepted")
  }
  let headRange=try f.request(server,prefix+"movie.webm",method:"HEAD",headers:"Range: bytes=2-4\r\n")
  try expect(headRange.status==206 && headRange.body.isEmpty && headRange.headers["content-length"]=="3","HEAD range")
  for (name,mime) in [("a.js","application/javascript; charset=utf-8"),("a.ttf","font/ttf"),("a.ogg","audio/ogg")] {
   try Data("fixture".utf8).write(to:f.root.appendingPathComponent(name))
   try expect(try f.request(server,prefix+name).headers["content-type"]==mime,"MIME "+name)
  }
 }
 static func pathAndProtocolSafety()throws {
  let f=try Fixture(),server=try GameResourceServer(root:f.root);defer{server.stop()}
  let entry=try server.entryURL(relativePath:"index.html"),prefix=entry.deletingLastPathComponent().path+"/"
  for path in ["../secret.txt","%2e%2e/secret.txt","%2E%2E%2fsecret.txt","%252e%252e/secret.txt","external/secret.txt","escape.txt","data/","","%00index.html","..%5csecret.txt"] {
   let result=try f.request(server,prefix+path)
   try expect(result.status>=400 && result.body.range(of:Data("PRIVATE SENTINEL".utf8)) == nil,"unsafe path served: "+path)
  }
  try expect(try f.request(server,"/index.html").status>=400,"missing route token accepted")
  try expect(try f.request(server,entry.path,host:"localhost:\(server.port)").status==403,"wrong Host accepted")
  try expect(try f.request(server,entry.path,method:"POST",headers:"Content-Length: 0\r\n").status==405,"POST accepted")
  try expect(try f.request(server,entry.path,headers:"Host: evil.example\r\n").status==400,"duplicate Host accepted")
  try expect(try f.request(server,entry.path,headers:"Transfer-Encoding: chunked\r\n").status==400,"request body framing accepted")
  for path in ["../secret.txt","/index.html","external/secret.txt","escape.txt",""] {
   try rejects("entryURL "+path){_ = try server.entryURL(relativePath:path)}
  }
  try expect(try String(contentsOf:f.base.appendingPathComponent("secret.txt"),encoding:.utf8)=="PRIVATE SENTINEL","source modified")
 }
 static func stableOriginAndShutdown()throws {
  let f=try Fixture(),first=try GameResourceServer(root:f.root)
  let port=first.port,old=try first.entryURL(relativePath:"index.html")
  try expect(old.pathComponents[1].count==32,"route does not contain 128-bit token")
  try rejects("busy preferred port") {_ = try GameResourceServer(root:f.root,preferredPort:port)}
  let waiting=try Client(port:port);try waiting.send("GET ")
  first.stop();first.stop()
  try expect(try waiting.receive().isEmpty,"stop did not close pending connection")
  try rejects("stopped listener") {_ = try Client(port:port)}
  try rejects("stopped entryURL") {_ = try first.entryURL(relativePath:"index.html")}
  let second=try GameResourceServer(root:f.root,preferredPort:port);defer{second.stop()}
  let next=try second.entryURL(relativePath:"index.html")
  try expect(next.port==old.port && next.host==old.host && next.path != old.path,"origin/token restart semantics")
  try expect(try f.request(second,old.path).status>=400,"old token accepted")
 }
 static func boundedRequests()throws {
  let f=try Fixture(),server=try GameResourceServer(root:f.root);defer{server.stop()}
  let url=try server.entryURL(relativePath:"index.html")
  let huge=try f.request(server,url.path,headers:"X-Large: "+String(repeating:"a",count:18000)+"\r\n")
  try expect(huge.status==431,"header cap not enforced")
  let slow=try Client(port:server.port);try slow.send("GET ")
  let start=Date();let output=try slow.receive()
  try expect(Date().timeIntervalSince(start)<7,"header timeout not bounded")
  let slowStatus = output.isEmpty ? 408 : try Response(output).status
  try expect(slowStatus==408,"unexpected slow request response")
  var held:[Client]=[]
  // Fill 16 active + 128 pending sockets; overflow must be a visible bounded error.
  for _ in 0..<144 {let c=try Client(port:server.port);try c.send("GET ");held.append(c)}
  let extra=try Client(port:server.port);try extra.send("GET ")
  let rejected=try Response(extra.receive())
  try expect(rejected.status==503 && rejected.headers["retry-after"]=="1","bounded queue overflow must report 503")
  let stopStart=Date();server.stop()
  for client in held {_ = try client.receive()}
  try expect(Date().timeIntervalSince(stopStart)<2,"stop did not close active and queued sockets promptly")
 }
 static func stopDuringStreaming()throws {
  let f=try Fixture()
  let file=f.root.appendingPathComponent("large.webm")
  let fd=open(file.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
  guard fd>=0 else{throw POSIXError(.EIO)}
  let sized=ftruncate(fd,32*1024*1024);Darwin.close(fd)
  try expect(sized==0,"sparse fixture creation")
  var server:GameResourceServer?=try GameResourceServer(root:f.root)
  let port=server!.port,path=try server!.entryURL(relativePath:"large.webm").path
  let client=try Client(port:port)
  try client.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
  // Do not drain the socket: exercise backpressure and cancellation of a live transfer.
  Thread.sleep(forTimeInterval:0.1)
  let start=Date();server=nil
  try expect(Date().timeIntervalSince(start)<2,"deinit blocked on slow receiver")
  let response=try Response(client.receive())
  try expect(response.status==200 && response.body.count<32*1024*1024,"stream not interrupted")
  try rejects("deinit listener shutdown"){_ = try Client(port:port)}
  let replacement=try GameResourceServer(root:f.root,preferredPort:port);replacement.stop()
 }

 static func burstRequests()throws {
  let f=try Fixture(),server=try GameResourceServer(root:f.root);defer{server.stop()}
  let path=try server.entryURL(relativePath:"index.html").path
  for count in [32,101] {
   var clients:[Client]=[]
   // Hold 16 workers at the header boundary; later complete GETs must wait, not
   // consume additional workers or be dropped. This makes local disk speed irrelevant.
   for index in 0..<count {
    let c=try Client(port:server.port)
    try c.send("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n"+(index<16 ? "":"\r\n"))
    clients.append(c)
   }
   var waiting=pollfd(fd:clients[16].fd,events:Int16(POLLIN),revents:0)
   try expect(poll(&waiting,1,250)==0,"request 17 bypassed the 16-worker bound or was dropped")
   var successes=0
   for c in clients.prefix(16) {try? c.send("\r\n")}
   for c in clients {
    if let bytes=try? c.receive(),let response=try? Response(bytes),response.status==200,
       response.headers["cache-control"]=="no-store",
       response.body==Data("<html>synthetic</html>".utf8) {successes+=1}
   }
   try expect(successes==count,"legitimate burst dropped requests: \(successes)/\(count) succeeded")
  }
 }
 static func pinnedRootFastPath()throws {
  let f=try Fixture(),server=try GameResourceServer(root:f.root);defer{server.stop()}
  let url=try server.entryURL(relativePath:"data/中文.json")
  let prefix=try server.entryURL(relativePath:"index.html").deletingLastPathComponent().path+"/"
  // Renaming the root makes its old absolute pathname unavailable. Regular files must
  // still be opened relative to the pinned directory, not re-resolved from that pathname.
  let moved=f.base.appendingPathComponent("moved")
  try FileManager.default.moveItem(at:f.root,to:moved)
  let result=try f.request(server,URLComponents(url:url,resolvingAgainstBaseURL:false)!.percentEncodedPath)
  try expect(result.status==200 && result.body==Data("{\"synthetic\":true}".utf8),"normal paths still depend on absolute realpath")
  try FileManager.default.createDirectory(at:f.root,withIntermediateDirectories:true)
  try Data("replacement must not be served".utf8).write(to:f.root.appendingPathComponent("index.html"))
  let pinned=try f.request(server,prefix+"index.html")
  try expect(pinned.body==Data("<html>synthetic</html>".utf8),"server escaped pinned root after pathname replacement")
 }

}
