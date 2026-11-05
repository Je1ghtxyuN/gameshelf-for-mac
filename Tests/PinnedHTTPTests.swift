import Foundation
import Security
import CryptoKit

@main struct PinnedHTTPTests {
 static func check(_ value:@autoclosure ()throws->Bool,_ message:String)throws{if try !value(){throw NSError(domain:"PinnedHTTPTests",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
 static func rejects(_ label:String="framing/limit",_ work:()throws->Void)throws{do{try work()}catch{return};throw NSError(domain:"PinnedHTTPTests",code:2,userInfo:[NSLocalizedDescriptionKey:"Unsafe HTTP accepted: "+label])}
 static let url=URL(string:"https://localhost:9443/api/test")!
 static func parse(_ text:String,eof:Bool=false)throws->(Data,HTTPURLResponse)?{var parser=PinnedHTTPResponseParser(url:url);return try parser.append(Data(text.utf8),eof:eof)}
 static func main()throws {
  var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=Data("{}".utf8);request.setValue("Bearer synthetic-only",forHTTPHeaderField:"Authorization")
  let encoded=try PinnedHTTPRequest(request)
  let wire=String(decoding:encoded.bytes,as:UTF8.self)
  try check(wire.hasPrefix("POST /api/test HTTP/1.1\r\n"),"origin-form path/method")
  try check(wire.contains("Host: localhost:9443\r\n") && wire.contains("Content-Length: 2\r\n") && wire.contains("Connection: close\r\n") && wire.hasSuffix("\r\n\r\n{}"),"deterministic request framing")
  for address in ["http://localhost/","https://user:secret@localhost/","https://localhost/#fragment"] {
   try rejects(address){_ = try PinnedHTTPRequest(URLRequest(url:URL(string:address)!))}
  }
  // URLRequest itself erases CRLF/NUL headers on macOS. Exercise the same
  // production validator directly for values Foundation cannot preserve.
  for (header,value) in [("Authorization","Bearer x\r\nInjected: yes"),("X-Test","bad\u{0}value")] {
   try rejects(header){try PinnedHTTPRequest.validateHeader(name:header,value:value)}
  }
  for (header,value) in [("Authorization","Bearer token extra"),("Transfer-Encoding","chunked"),("Cookie","private=x"),("Content-Length","9"),("Host","other.example"),("Accept-Encoding","gzip")] {
   var invalid=request;invalid.setValue(value,forHTTPHeaderField:header);try rejects(header){_ = try PinnedHTTPRequest(invalid)}
  }
  var badMethod=request;badMethod.httpMethod="GET\r\nX: y";try rejects{_ = try PinnedHTTPRequest(badMethod)}
  var parser=PinnedHTTPResponseParser(url:url),result:(Data,HTTPURLResponse)?
  for byte in Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: yes\r\n\r\nhello".utf8){result=try parser.append(Data([byte]))}
  try check(result?.0==Data("hello".utf8) && result?.1.statusCode==200,"byte-split response")
  try check(try parse("HTTP/1.0 200 OK\r\n\r\nclose body",eof:true)?.0==Data("close body".utf8),"HTTP/1.0 EOF body")
  try check(try parse("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nEOF",eof:true)?.0==Data("EOF".utf8),"HTTP/1.1 EOF body")
  try check(try parse("HTTP/1.1 302 Found\r\nLocation: https://elsewhere.invalid/\r\nContent-Length: 0\r\n\r\n")?.1.statusCode==302,"redirect is returned, never followed")
  try check(try parse("HTTP/1.1 204 No Content\r\n\r\n")?.0.isEmpty==true,"bodyless response")
  for invalid in [
   "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
   "HTTP/1.1 200 OK\r\nContent-Length: 2, 2\r\n\r\n{}",
   "HTTP/1.1 200 OK\r\nContent-Length: +2\r\n\r\n{}",
   "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
   "HTTP/1.1 200 OK\r\nContent-Length: 999999999999999999999\r\n\r\n",
   "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
   "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
   "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{x}extra",
   "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}",
   "HTTP/1.1 200 OK\r\n Folded: yes\r\n\r\n",
   "HTTP/2 200 OK\r\n\r\n",
   "HTTP/1.1 200 OK\nContent-Length: 0\n\n"
  ]{try rejects(invalid){_ = try parse(invalid,eof:true)}}
  try rejects{_ = try parse("HTTP/1.1 200 OK\r\nX-Large: "+String(repeating:"a",count:65536)+"\r\n\r\n")}
  try rejects{_ = try parse("HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\n\r\n")}
  var limited=PinnedHTTPResponseParser(url:url)
  _ = try limited.append(Data("HTTP/1.0 200 OK\r\n\r\n".utf8))
  _ = try limited.append(Data(repeating:120,count:8*1024*1024))
  try rejects{_ = try limited.append(Data([120]))}
  var boundary=PinnedHTTPResponseParser(url:url)
  _ = try boundary.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 8388608\r\n\r\n".utf8))
  try check(try boundary.append(Data(repeating:120,count:8*1024*1024))?.0.count==8*1024*1024,"exact body boundary")
  print("PASS pinned HTTP pure tests: safe serialization, split/framing/EOF/redirects, strict lengths, headers 64KiB/body 8MiB bounds")
  if CommandLine.arguments.contains("--tls"){try tlsFixture()}
 }
 static func tlsFixture()throws {
  let fm=FileManager.default,root=URL(fileURLWithPath:"/private/tmp/PinnedHTTPFixture-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:false);defer{try? fm.removeItem(at:root)}
  let cert=root.appendingPathComponent("cert.pem"),key=root.appendingPathComponent("key.pem")
  let openssl=Process();openssl.executableURL=URL(fileURLWithPath:"/usr/bin/openssl")
  openssl.arguments=["req","-x509","-newkey","rsa:2048","-nodes","-sha256","-keyout",key.path,"-out",cert.path,"-days","1","-subj","/CN=localhost","-addext","subjectAltName=DNS:localhost","-addext","extendedKeyUsage=serverAuth","-addext","basicConstraints=critical,CA:FALSE","-addext","keyUsage=critical,digitalSignature,keyEncipherment"]
  openssl.standardOutput=FileHandle.nullDevice;openssl.standardError=FileHandle.nullDevice;try openssl.run();openssl.waitUntilExit();try check(openssl.terminationStatus==0,"fixture certificate generation")
  try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:key.path)
  let pem=try String(contentsOf:cert,encoding:.utf8),der=Data(base64Encoded:pem.components(separatedBy:.newlines).filter{!$0.hasPrefix("---")}.joined())!
  let pin=SHA256.hash(data:der).map{String(format:"%02x",$0)}.joined()
  let script=root.appendingPathComponent("server.py")
  try """
  import http.server,ssl,sys,pathlib
  root=pathlib.Path(sys.argv[1])
  class Handler(http.server.BaseHTTPRequestHandler):
   protocol_version='HTTP/1.1'
   def log_message(self,*args): pass
   def do_GET(self):
    with (root/'requests').open('a') as f: f.write(self.path+'\\n')
    if self.path=='/redirect':
     self.send_response(302);self.send_header('Location','https://elsewhere.invalid/');self.send_header('Content-Length','0');self.end_headers();return
    body=b'{"ok":true}'
    self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
  context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.minimum_version=ssl.TLSVersion.TLSv1_2
  context.load_cert_chain(str(root/'cert.pem'),str(root/'key.pem'));server.socket=context.wrap_socket(server.socket,server_side=True)
  (root/'port').write_text(str(server.server_port))
  server.serve_forever()
  """.write(to:script,atomically:true,encoding:.utf8)
  let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=[script.path,root.path];server.standardOutput=FileHandle.nullDevice;server.standardError=FileHandle.nullDevice
  try server.run();defer{server.terminate();server.waitUntilExit()}
  let deadline=Date().addingTimeInterval(10),portFile=root.appendingPathComponent("port")
  while !fm.fileExists(atPath:portFile.path) && server.isRunning && Date()<deadline{Thread.sleep(forTimeInterval:0.02)}
  try check(fm.fileExists(atPath:portFile.path),"fixture ready")
  let port=try String(contentsOf:portFile,encoding:.utf8)
  func perform(_ host:String,_ pin:String,path:String="/ok")->Result<(Data,HTTPURLResponse),Error>{
   let done=DispatchSemaphore(value:0),lock=NSLock();var result:Result<(Data,HTTPURLResponse),Error>?,calls=0
   var request=URLRequest(url:URL(string:"https://\(host):\(port)\(path)")!);request.setValue("Bearer synthetic-only",forHTTPHeaderField:"Authorization")
   PinnedHTTPTransport.request(request,certificateSHA256:pin){value in lock.lock();calls+=1;result=value;lock.unlock();done.signal()}
   guard done.wait(timeout:.now()+15) == .success else{return .failure(NSError(domain:"TLSFixtureTimeout",code:1))}
   Thread.sleep(forTimeInterval:0.05);lock.lock();defer{lock.unlock()}
   if calls != 1{return .failure(NSError(domain:"DuplicateCompletion",code:calls))};return result!
  }
  let success=try perform("localhost",pin).get();try check(success.1.statusCode==200 && success.0==Data("{\"ok\":true}".utf8),"valid explicitly pinned TLS")
  func count()throws->Int{try String(contentsOf:root.appendingPathComponent("requests"),encoding:.utf8).split(separator:"\n").count}
  let before=try count()
  if case .success=perform("localhost",String(repeating:"0",count:64)){throw NSError(domain:"WrongPinAccepted",code:1)}
  if case .success=perform("127.0.0.1",pin){throw NSError(domain:"WrongHostnameAccepted",code:1)}
  try check(try count()==before,"no HTTP/auth bytes before TLS verification")
  let redirect=try perform("localhost",pin,path:"/redirect").get();try check(redirect.1.statusCode==302 && count()==before+1,"redirect not followed")
  let certificate=SecCertificateCreateWithData(nil,der as CFData)!;var trust:SecTrust?
  try check(SecTrustCreateWithCertificates(certificate,SecPolicyCreateSSL(true,"localhost" as CFString),&trust)==errSecSuccess,"fixture trust creation")
  try check(!PinnedHTTPTrust.verify(trust!,host:"localhost",pin:pin,now:Date().addingTimeInterval(3*86400)),"expired leaf must fail even when anchored")
  print("PASS synthetic localhost TLS: valid pin succeeds, wrong pin/hostname fail before HTTP, expired anchored leaf fails, no redirect, one completion")
 }
}
