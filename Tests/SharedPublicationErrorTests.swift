import Foundation
@main struct SharedPublicationErrorTests {
 struct Failure:Error{let text:String}
 static func main()throws {
  let pinned:[PinnedHTTPError]=[.invalidRequest,.invalidResponse,.tooLarge,.invalidPin,.untrustedCertificate,.timeout,.connectionFailed]
  for error in pinned {
   precondition(SharedPublicationError.shouldStopBatch(error))
   precondition(!SharedPublicationError.isMappingFailure(error))
   precondition(!SharedPublicationError.message(error).contains("/private"))
  }
  for error:Error in [SharedRequestError(statusCode:401),SharedRequestError(statusCode:403),CancellationError(),URLError(.timedOut),NSError(domain:NSURLErrorDomain,code:-1004,userInfo:[NSLocalizedDescriptionKey:"/private/secret password=hidden"])] {
   precondition(SharedPublicationError.shouldStopBatch(error))
   let message=SharedPublicationError.message(error)
   precondition(!message.contains("secret") && !message.contains("hidden"))
  }
  for error:Error in [SharedRequestError(statusCode:400),SharedRequestError(statusCode:404),SharedRequestError(statusCode:409),SharedRequestError(statusCode:412),SharedRequestError(statusCode:413),SharedRequestError(statusCode:503),LibraryError("所选游戏不在对应目录中。"),NSError(domain:NSCocoaErrorDomain,code:NSFileReadNoSuchFileError)] {
   precondition(!SharedPublicationError.shouldStopBatch(error))
  }
  precondition(SharedPublicationError.message(PinnedHTTPError.timeout)=="连接超时，请检查网络和共享服务后重试。")
  precondition(SharedPublicationError.message(PinnedHTTPError.connectionFailed)=="无法连接共享服务，请检查网络后重试。")
  precondition(SharedPublicationError.message(PinnedHTTPError.untrustedCertificate)=="TLS 验证失败，请核对服务器地址和可信证书配置。")
  func body(_ message:String,_ code:Int)->Data{try! JSONSerialization.data(withJSONObject:["error":["code":code,"message":message]])}
  let busy=SharedRequestError(statusCode:409,responseBody:body("Another scan is running",409))
  precondition(busy.reason == .scanBusy && !SharedPublicationError.isMappingFailure(busy))
  precondition(SharedPublicationError.message(busy).contains("扫描"))
  let ambiguous=SharedRequestError(statusCode:409,responseBody:body("Ambiguous Unicode path component",409))
  precondition(ambiguous.reason == .unicodePathAmbiguous && !SharedPublicationError.isMappingFailure(ambiguous))
  precondition(SharedPublicationError.message(ambiguous).contains("名称") && !SharedPublicationError.message(ambiguous).contains("重新选择"))
  precondition(SharedRequestError(statusCode:400,responseBody:body("Ambiguous Unicode path component",400)).reason==nil)
  let mismatch=SharedRequestError(statusCode:412,responseBody:body("Selected entry fingerprint does not match",412))
  precondition(SharedPublicationError.isMappingFailure(mismatch))
  for (code,message,reason) in [(409,"Multiple save-rule editions exist; specify reviewed savePaths",SharedRequestError.Reason.rulesReview),(409,"Edition changed; scan and publish a new edition",.sourceChanged),(404,"Candidate not found",.candidateMissing),(400,"Reserved profile path",.reservedProfile),(400,"Too many directory entries",.tooManyEntries)] {
   let error=SharedRequestError(statusCode:code,responseBody:body(message,code))
   precondition(error.reason == reason && !SharedPublicationError.isMappingFailure(error))
   precondition(!SharedPublicationError.message(error).contains("另一个会话"))
  }
  for bytes in [Data("broken".utf8),body("/private/secret/password=hidden",400),body("Another scan is running",400),Data(repeating:32,count:4097),Data("{\"error\":{\"code\":400,\"message\":12}}".utf8)] {
   let error=SharedRequestError(statusCode:400,responseBody:bytes)
   precondition(error.reason==nil && !SharedPublicationError.isMappingFailure(error))
   precondition(!SharedPublicationError.message(error).contains("secret") && !String(describing:error).contains("hidden"))
  }
  precondition(!SharedPublicationError.isMappingFailure(SharedRequestError(statusCode:404)))
  precondition(SharedPublicationError.isMappingFailure(SharedRequestError(statusCode:404,responseBody:body("Selected path is unavailable on this server",404))))
  precondition(!SharedPublicationError.isMappingFailure(SharedRequestError(statusCode:400,responseBody:body("Selected path cannot be read without following links",400))))
  precondition(!SharedPublicationError.message(SharedRequestError(statusCode:409)).contains("游戏仍"))
  // Real HTTP transport must retain the safe reason, never arbitrary server text.
  let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
  server.arguments=["-u","-c",#"""
from http.server import HTTPServer,BaseHTTPRequestHandler
import json
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  paths={'/api/busy':(409,'Another scan is running'),'/api/missing':(404,'Selected game is unavailable on this server'),'/api/rules':(409,'Detected save exclusions changed; specify reviewed savePaths'),'/api/changed':(409,'Edition changed; scan and publish a new edition'),'/api/fingerprint':(412,'Selected entry fingerprint does not match'),'/api/ambiguous':(409,'Ambiguous Unicode path component'),'/api/unsafe':(400,'/private/secret/password=hidden')}
  code,message=paths.get(self.path,(400,'unknown'))
  data=b'x'*4097 if self.path=='/api/oversized' else (b'broken' if self.path=='/api/malformed' else json.dumps({'error':{'code':code,'message':message}}).encode())
  self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
s=HTTPServer(('127.0.0.1',0),Handler);print(s.server_port,flush=True);s.serve_forever()
"""#]
  let pipe=Pipe();server.standardOutput=pipe;try server.run();defer{server.terminate();server.waitUntilExit()}
  var port=Data();while let b=try pipe.fileHandleForReading.read(upToCount:1),!b.isEmpty,b != Data([10]){port.append(b)}
  guard let number=Int(String(decoding:port,as:UTF8.self)) else{throw Failure(text:"fixture startup failed")}
  let api=try SharedAPI(address:"http://127.0.0.1:\(number)")
  struct Empty:Decodable{}
  for (path,reason,mapping) in [("/api/busy",SharedRequestError.Reason.scanBusy,false),("/api/missing",.folderMissing,true),("/api/rules",.rulesReview,false),("/api/changed",.sourceChanged,false),("/api/fingerprint",.fingerprintMismatch,true),("/api/ambiguous",.unicodePathAmbiguous,false)] {
   let done=DispatchSemaphore(value:0);var received:SharedRequestError?
   api.request(path){(result:Result<Empty,Error>) in if case .failure(let e)=result{received=e as? SharedRequestError};done.signal()}
   precondition(done.wait(timeout:.now()+10) == .success)
   precondition(received?.reason==reason && SharedPublicationError.isMappingFailure(received!)==mapping)
  }
  for path in ["/api/unsafe","/api/oversized","/api/malformed"] {
   let done=DispatchSemaphore(value:0);var received:SharedRequestError?
   api.request(path){(result:Result<Empty,Error>) in if case .failure(let e)=result{received=e as? SharedRequestError};done.signal()}
   precondition(done.wait(timeout:.now()+10) == .success)
   precondition(received?.reason==nil && received?.statusCode==400)
   precondition(!SharedPublicationError.message(received!).contains("secret") && !String(describing:received!).contains("hidden"))
  }
  print("PASS safe publication errors: real HTTP, known reasons/status pairs, malformed/oversized/unknown redaction, strict mapping classification")
 }
}
