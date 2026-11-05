import Foundation
import Network
import Security
import CryptoKit

enum PinnedHTTPError:Error,LocalizedError {
 case invalidRequest,invalidResponse,tooLarge,invalidPin,untrustedCertificate,timeout,connectionFailed
 var errorDescription:String? {
  switch self {
  case .invalidRequest:return "固定证书 HTTPS 请求无效。"
  case .invalidResponse:return "固定证书 HTTPS 响应格式无效。"
  case .tooLarge:return "HTTPS 请求或响应超过大小限制。"
  case .invalidPin:return "证书 SHA-256 指纹无效。"
  case .untrustedCertificate:return "服务器证书、主机名或有效期校验失败。"
  case .timeout:return "服务器连接或读取超时。"
  case .connectionFailed:return "固定证书 HTTPS 连接失败。"
  }
 }
}

private func httpToken(_ value:String)->Bool {
 !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||Array("!#$%&'*+-.^_`|~".utf8).contains($0) }
}

/// One bounded origin-form request. No cookie jar, proxy, redirect or body stream.
struct PinnedHTTPRequest {
 let url:URL
 let host:String
 let port:UInt16
 let bytes:Data
 static func validateHeader(name:String,value:String)throws {
  guard httpToken(name),value.utf8.count<=8192,value.utf8.allSatisfy({(32...126).contains($0)}) else{throw PinnedHTTPError.invalidRequest}
  if name.lowercased()=="authorization" {
   guard value.hasPrefix("Bearer ") else{throw PinnedHTTPError.invalidRequest}
   let token=value.dropFirst(7),alphabet=Array("-._~+/=".utf8)
   guard !token.isEmpty,token.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||alphabet.contains($0)}) else{throw PinnedHTTPError.invalidRequest}
  }
 }
 init(_ request:URLRequest)throws {
  guard let url=request.url,let parts=URLComponents(url:url,resolvingAgainstBaseURL:false),parts.scheme?.lowercased()=="https",
        parts.user==nil,parts.password==nil,parts.fragment==nil,let rawHost=parts.host,!rawHost.isEmpty,
        !(parts.percentEncodedHost ?? "").contains("%"),request.httpBodyStream==nil else{throw PinnedHTTPError.invalidRequest}
  let host=rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()):rawHost
  let port=parts.port ?? 443
  guard (1...65535).contains(port),host.utf8.count<=253,!host.contains("%") else{throw PinnedHTTPError.invalidRequest}
  if IPv4Address(host)==nil && IPv6Address(host)==nil {
   let dns=host.hasSuffix(".") ? String(host.dropLast()):host
   guard dns.split(separator:".",omittingEmptySubsequences:false).allSatisfy({ label in
    let bytes=Array(label.utf8)
    func alnum(_ b:UInt8)->Bool{(48...57).contains(b)||(65...90).contains(b)||(97...122).contains(b)}
    return !bytes.isEmpty && bytes.count<=63 && alnum(bytes[0]) && alnum(bytes[bytes.count-1]) && bytes.allSatisfy{alnum($0)||$0==45}
   }) else{throw PinnedHTTPError.invalidRequest}
  }
  let method=request.httpMethod ?? "GET"
  guard ["GET","POST","DELETE"].contains(method) else{throw PinnedHTTPError.invalidRequest}
  var path=parts.percentEncodedPath.isEmpty ? "/":parts.percentEncodedPath
  if let query=parts.percentEncodedQuery{path+="?"+query}
  guard path.hasPrefix("/"),!path.hasPrefix("//"),path.utf8.count<=16384,
        path.utf8.allSatisfy({(33...126).contains($0) && $0 != 92}),
        let decoded=path.removingPercentEncoding,!decoded.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw PinnedHTTPError.invalidRequest}
  let body=request.httpBody ?? Data()
  guard body.count<=8*1024*1024 else{throw PinnedHTTPError.tooLarge}
  guard method != "GET" || body.isEmpty else{throw PinnedHTTPError.invalidRequest}
  let authority=(host.contains(":") ? "["+host+"]":host)+(port==443 ? "":":"+String(port))
  var headers:[String:String]=[:]
  for (name,value) in request.allHTTPHeaderFields ?? [:] {
   let key=name.lowercased()
   try Self.validateHeader(name:name,value:value)
   guard headers[key]==nil else{throw PinnedHTTPError.invalidRequest}
   guard !["transfer-encoding","trailer","expect","cookie","cookie2","proxy-authorization","upgrade"].contains(key) else{throw PinnedHTTPError.invalidRequest}
   if key=="host" && value.lowercased() != authority.lowercased(){throw PinnedHTTPError.invalidRequest}
   if key=="content-length" && value != String(body.count){throw PinnedHTTPError.invalidRequest}
   if key=="connection" && value.lowercased() != "close"{throw PinnedHTTPError.invalidRequest}
   if key=="accept-encoding" && value.lowercased() != "identity"{throw PinnedHTTPError.invalidRequest}
   headers[key]=value
  }
  headers.removeValue(forKey:"host");headers.removeValue(forKey:"content-length");headers.removeValue(forKey:"connection");headers.removeValue(forKey:"accept-encoding")
  var head="\(method) \(path) HTTP/1.1\r\nHost: \(authority)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
  for key in headers.keys.sorted(){head+="\(key): \(headers[key]!)\r\n"}
  head+="\r\n"
  guard head.utf8.count<=65536 else{throw PinnedHTTPError.tooLarge}
  var bytes=Data(head.utf8);bytes.append(body)
  self.url=url;self.host=host;self.port=UInt16(port);self.bytes=bytes
 }
}

/// Strict single-response framing; Transfer-Encoding is deliberately unsupported.
struct PinnedHTTPResponseParser {
 private let url:URL
 private var header=Data(),body=Data()
 private var response:HTTPURLResponse?
 private var expected:Int?
 private var noBody=false
 private var finished=false
 init(url:URL){self.url=url}
 mutating func append(_ bytes:Data,eof:Bool=false)throws->(Data,HTTPURLResponse)? {
  guard !finished else{throw PinnedHTTPError.invalidResponse}
  var payload=bytes
  if response==nil {
   // The receiver supplies chunks <=64 KiB. Even direct test input cannot
   // cause an unbounded allocation before a header delimiter is identified.
   let consumed=min(bytes.count,65536-header.count)
   header.append(bytes.prefix(consumed))
   if let end=header.range(of:Data("\r\n\r\n".utf8)) {
    guard header.count-end.upperBound+bytes.count-consumed<=8*1024*1024 else{throw PinnedHTTPError.tooLarge}
    try decodeHeader(Data(header[..<end.lowerBound]))
    payload=Data(header[end.upperBound...]);payload.append(bytes.dropFirst(consumed));header.removeAll()
   }else{
    guard consumed==bytes.count else{throw PinnedHTTPError.tooLarge}
    if eof{throw PinnedHTTPError.invalidResponse};return nil
   }
  }
  guard payload.count<=8*1024*1024-body.count else{throw PinnedHTTPError.tooLarge}
  body.append(payload)
  if noBody {
   guard body.isEmpty else{throw PinnedHTTPError.invalidResponse}
  }else if let expected {
   guard body.count<=expected else{throw PinnedHTTPError.invalidResponse}
   if body.count<expected{if eof{throw PinnedHTTPError.invalidResponse};return nil}
  }else if !eof{return nil}
  guard let response else{throw PinnedHTTPError.invalidResponse}
  finished=true;return (body,response)
 }
 private mutating func decodeHeader(_ data:Data)throws {
  guard data.allSatisfy({$0==9 || $0==10 || $0==13 || (32...126).contains($0)}),let text=String(data:data,encoding:.utf8) else{throw PinnedHTTPError.invalidResponse}
  let lines=text.components(separatedBy:"\r\n"),status=lines[0].split(separator:" ",maxSplits:2,omittingEmptySubsequences:false)
  guard status.count>=2,["HTTP/1.0","HTTP/1.1"].contains(String(status[0])),status[1].count==3,status[1].utf8.allSatisfy({(48...57).contains($0)}),let code=Int(status[1]),(200...599).contains(code),
        !lines[0].contains("\r"),!lines[0].contains("\n"),!lines[0].contains("\t") else{throw PinnedHTTPError.invalidResponse}
  var fields:[String:String]=[:]
  for line in lines.dropFirst() {
   guard let colon=line.firstIndex(of:":"),line.first != " ",line.first != "\t" else{throw PinnedHTTPError.invalidResponse}
   let name=String(line[..<colon]),key=name.lowercased(),value=String(line[line.index(after:colon)...]).trimmingCharacters(in:CharacterSet(charactersIn:" \t"))
   guard httpToken(name),fields[key]==nil,!value.contains("\r"),!value.contains("\n") else{throw PinnedHTTPError.invalidResponse}
   fields[key]=value
  }
  guard fields["transfer-encoding"]==nil,fields["content-encoding"].map({$0.lowercased()=="identity"}) ?? true else{throw PinnedHTTPError.invalidResponse}
  if let length=fields["content-length"] {
   guard !length.isEmpty,length.utf8.allSatisfy({(48...57).contains($0)}),let size=Int(length) else{throw PinnedHTTPError.invalidResponse}
   guard size<=8*1024*1024 else{throw PinnedHTTPError.tooLarge};expected=size
  }
  noBody=[204,205,304].contains(code)
  if [204,205].contains(code),let expected,expected != 0{throw PinnedHTTPError.invalidResponse}
  guard let value=HTTPURLResponse(url:url,statusCode:code,httpVersion:String(status[0]),headerFields:fields) else{throw PinnedHTTPError.invalidResponse}
  response=value
 }
}

enum PinnedHTTPTrust {
 static func verify(_ trust:SecTrust,host:String,pin:String,now:Date=Date())->Bool {
  guard let chain=SecTrustCopyCertificateChain(trust) as? [SecCertificate],let leaf=chain.first else{return false}
  let digest=SHA256.hash(data:SecCertificateCopyData(leaf) as Data).map{String(format:"%02x",$0)}.joined()
  guard digest==pin else{return false}
  let oids=[kSecOIDX509V1ValidityNotBefore,kSecOIDX509V1ValidityNotAfter]
  guard let values=SecCertificateCopyValues(leaf,oids as CFArray,nil) as? [String:Any] else{return false}
  func date(_ oid:CFString)->Date? {
   guard let property=values[oid as String] as? [String:Any] else{return nil}
   if let date=property[kSecPropertyKeyValue as String] as? Date{return date}
   if let number=property[kSecPropertyKeyValue as String] as? NSNumber,number.doubleValue.isFinite{return Date(timeIntervalSinceReferenceDate:number.doubleValue)}
   return nil
  }
  guard let start=date(oids[0]),let end=date(oids[1]),start<=now,now<=end else{return false}
  guard SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,host as CFString))==errSecSuccess,
        SecTrustSetAnchorCertificates(trust,[leaf] as CFArray)==errSecSuccess,
        SecTrustSetAnchorCertificatesOnly(trust,true)==errSecSuccess,
        SecTrustSetNetworkFetchAllowed(trust,false)==errSecSuccess,
        SecTrustSetVerifyDate(trust,now as CFDate)==errSecSuccess else{return false}
  return SecTrustEvaluateWithError(trust,nil)
 }
}

enum PinnedHTTPTransport {
 static func request(_ request:URLRequest,certificateSHA256:String,completion:@escaping(Result<(Data,HTTPURLResponse),Error>)->Void) {
  do {
   let pin=certificateSHA256.lowercased()
   guard pin.utf8.count==64,pin.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw PinnedHTTPError.invalidPin}
   PinnedHTTPOperation(request:try PinnedHTTPRequest(request),pin:pin,completion:completion).start()
  }catch{completion(.failure(error))}
 }
}

private final class PinnedHTTPOperation {
 private let request:PinnedHTTPRequest
 private let pin:String
 private let queue=DispatchQueue(label:"GameShelf.pinned-https")
 private let verifyQueue=DispatchQueue(label:"GameShelf.pinned-https.verify")
 private var completion:((Result<(Data,HTTPURLResponse),Error>)->Void)?
 private var connection:NWConnection?
 private var parser:PinnedHTTPResponseParser
 private var lifetime:PinnedHTTPOperation?
 private var total:DispatchSourceTimer?,idle:DispatchSourceTimer?
 private var ready=false
 private var verified=false
 private let verificationLock=NSLock()
 init(request:PinnedHTTPRequest,pin:String,completion:@escaping(Result<(Data,HTTPURLResponse),Error>)->Void){self.request=request;self.pin=pin;self.completion=completion;parser=PinnedHTTPResponseParser(url:request.url)}
 func start(){lifetime=self;queue.async{self.connect()}}
 private func timer(_ seconds:Int)->DispatchSourceTimer {
  let timer=DispatchSource.makeTimerSource(queue:queue);timer.schedule(deadline:DispatchTime.now() + .seconds(seconds));timer.setEventHandler{[weak self] in self?.finish(.failure(PinnedHTTPError.timeout))};timer.resume();return timer
 }
 private func resetIdle(){idle?.cancel();idle=timer(30)}
 private func connect(){
  total=timer(120);resetIdle()
  let tls=NWProtocolTLS.Options(),options=tls.securityProtocolOptions
  sec_protocol_options_set_min_tls_protocol_version(options,.TLSv12)
  sec_protocol_options_set_tls_server_name(options,request.host)
  sec_protocol_options_add_tls_application_protocol(options,"http/1.1")
  sec_protocol_options_set_peer_authentication_required(options,true)
  sec_protocol_options_set_tls_resumption_enabled(options,false)
  sec_protocol_options_set_tls_tickets_enabled(options,false)
  sec_protocol_options_set_tls_false_start_enabled(options,false)
  let host=request.host,pin=self.pin
  sec_protocol_options_set_verify_block(options,{[weak self] _,trust,verify in
   let accepted=PinnedHTTPTrust.verify(sec_trust_copy_ref(trust).takeRetainedValue(),host:host,pin:pin)
   if let self{self.verificationLock.lock();self.verified=accepted;self.verificationLock.unlock()}
   verify(accepted)
  },verifyQueue)
  let tcp=NWProtocolTCP.Options();tcp.connectionTimeout=30
  let parameters=NWParameters(tls:tls,tcp:tcp)
  // Match private-endpoint URLSession routing: system proxy selection can
  // otherwise stall overlay-network connections before certificate verification.
  parameters.preferNoProxies=true
  let connection=NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:request.port)!,using:parameters);self.connection=connection
  connection.stateUpdateHandler={[weak self] state in
   guard let self,self.completion != nil else{return}
   switch state {
   case .ready:
    guard !self.ready else{return};self.ready=true
    self.verificationLock.lock();let verified=self.verified;self.verificationLock.unlock()
    guard verified else{self.finish(.failure(PinnedHTTPError.untrustedCertificate));return}
    self.resetIdle()
    // This is the ONLY send: TLS verification and ready both precede any HTTP
    // header/body, including bearer credentials. No TLS early/resumed writes.
    connection.send(content:self.request.bytes,completion:.contentProcessed{[weak self] error in
     guard let self,self.completion != nil else{return}
     if error != nil{self.finish(.failure(PinnedHTTPError.connectionFailed))}else{self.resetIdle();self.receive()}
    })
   case .failed,.waiting:self.finish(.failure(PinnedHTTPError.connectionFailed))
   case .cancelled:self.finish(.failure(PinnedHTTPError.connectionFailed))
   default:break
   }
  }
  connection.start(queue:queue)
 }
 private func receive(){
  connection?.receive(minimumIncompleteLength:1,maximumLength:65536){[weak self] data,_,complete,error in
   guard let self,self.completion != nil else{return}
   if error != nil{self.finish(.failure(PinnedHTTPError.connectionFailed));return}
   do {
    if let result=try self.parser.append(data ?? Data(),eof:complete){self.finish(.success(result))}
    else{if !(data?.isEmpty ?? true){self.resetIdle()};self.receive()}
   }catch{self.finish(.failure(error))}
  }
 }
 private func finish(_ result:Result<(Data,HTTPURLResponse),Error>){
  guard let callback=completion else{return};completion=nil
  total?.cancel();idle?.cancel();total=nil;idle=nil
  connection?.stateUpdateHandler=nil;connection?.cancel();connection=nil
  lifetime=nil;callback(result)
 }
}
