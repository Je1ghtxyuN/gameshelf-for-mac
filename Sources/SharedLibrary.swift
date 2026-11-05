import Foundation
import Security
import CryptoKit
import Darwin

enum SharedServerAddress {
 static func usesDirectConnection(host:String)->Bool {
  let host=host.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
  if host=="localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net"){return true}
  var ipv4=in_addr()
  if inet_pton(AF_INET,host,&ipv4)==1 {
   let number=UInt32(bigEndian:ipv4.s_addr),first=number>>24,second=(number>>16)&255
   return first==10 || first==127 || (first==172 && (16...31).contains(second)) ||
    (first==192 && second==168) || (first==169 && second==254) ||
    (first==100 && (64...127).contains(second))
  }
  var ipv6=in6_addr()
  if inet_pton(AF_INET6,host,&ipv6)==1 {
   let bytes=withUnsafeBytes(of:&ipv6){Array($0)}
   return bytes.dropLast().allSatisfy{$0==0} && bytes.last==1 ||
    bytes[0]&0xfe==0xfc || (bytes[0]==0xfe && bytes[1]&0xc0==0x80)
  }
  return false
 }
 static func userInput(_ text:String)throws->URL {
  let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !value.isEmpty else{throw LibraryError("请输入服务器地址。")}
  return try parse(value.contains("://") ? value:"https://"+value)
 }
 static func certificatePin(_ text:String)throws->String? {
  let value=text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:":",with:"").lowercased()
  if value.isEmpty{return nil}
  guard value.count==64,value.allSatisfy({"0123456789abcdef".contains($0)}) else{throw LibraryError("证书指纹须为服务器提供的 SHA-256 指纹（64 位十六进制）。")}
  return value
 }
 static func parse(_ text:String)throws->URL {
  guard var parts=URLComponents(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
        let host=parts.host,!host.isEmpty,parts.user==nil,parts.password==nil,
        parts.query==nil,parts.fragment==nil,["","/"].contains(parts.percentEncodedPath),
        parts.port.map({(1...65535).contains($0)}) ?? true else {throw LibraryError("请输入服务器根地址，不含账号、路径或参数。")}
  let scheme=parts.scheme?.lowercased()
  guard scheme=="https" || (scheme=="http" && ["localhost","127.0.0.1","::1","[::1]"].contains(host.lowercased())) else {throw LibraryError("共享库需要 HTTPS；HTTP 仅用于本机回环测试。")}
  parts.scheme=scheme;parts.path=""
  guard let url=parts.url else{throw LibraryError("服务器地址无效。")}
  return url
 }
}

struct SharedConnection:Codable,Equatable,Identifiable {
 var id:UUID=UUID()
 var name:String
 var address:String
 var serverID:String
 var accountID:String
 var username:String
 var isAdministrator:Bool
 var certificateSHA256:String?=nil
 var rememberLogin:Bool?=nil
}
struct SharedServerInvitation:Codable {
 var version:Int=1
 var address:String
 var name:String?
 var certificateSHA256:String?
 static func read(_ data:Data)throws->SharedServerInvitation {
  guard data.count<=4096 else{throw LibraryError("邀请文件过大。")}
  guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],object["setupToken"]==nil,object["kind"]==nil else{throw LibraryError("此文件用于管理员初始化，请使用创建共享库入口。")}
  var invitation=try JSONDecoder().decode(Self.self,from:data)
  guard invitation.version==1 else{throw LibraryError("此邀请文件版本暂不支持。")}
  invitation.address=try SharedServerAddress.parse(invitation.address).absoluteString
  invitation.certificateSHA256=try SharedServerAddress.certificatePin(invitation.certificateSHA256 ?? "")
  if let name=invitation.name {guard !name.isEmpty,name.count<=80,!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw LibraryError("邀请文件的服务器名称无效。")}}
  return invitation
 }
}
struct SharedCatalogGame:Codable,Equatable,Identifiable {
 var id:String
 var title:String
 var entries:[Candidate]
 var coverSHA256:String?=nil
}
struct SharedCatalog:Codable {var games:[SharedCatalogGame]}
struct SharedLoginUser:Codable {var id:String;var username:String;var admin:Bool}
struct SharedLoginResponse:Codable {var token:String;var user:SharedLoginUser;var serverID:String}
struct SharedServerInfo:Codable {var name:String;var serverID:String;var version:String;var setupRequired:Bool?=nil}
struct SharedRequestError:LocalizedError {
 let statusCode:Int
 var errorDescription:String? {
  switch statusCode {case 401:return "登录已失效，请重新登录共享库。";case 403:return "此账号没有访问权限。";case 409:return "此游戏仍由另一个会话使用，请先退出。";default:return "共享库请求失败（\(statusCode)）。"}
 }
}

final class SharedConnectionStore {
 let root:URL
 private(set) var connections:[SharedConnection]=[]
 init(root:URL)throws {
  self.root=root
  let file=root.appendingPathComponent("shared-connections.json")
  if FileManager.default.fileExists(atPath:file.path) {
   do{connections=try JSONDecoder().decode([SharedConnection].self,from:Data(contentsOf:file))}
   catch{throw LibraryError("共享库配置无法读取，原文件已保留。")}
   guard Set(connections.map(\.id)).count==connections.count else{throw LibraryError("共享库配置包含重复标识。")}
   for connection in connections {_ = try SharedServerAddress.parse(connection.address)}
  }
 }
 func save(_ connection:SharedConnection)throws {
  _ = try SharedServerAddress.parse(connection.address)
  guard !connection.serverID.isEmpty,!connection.accountID.isEmpty,!connection.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw LibraryError("共享库身份或名称为空。")}
  var next=connections
  if let index=next.firstIndex(where:{$0.id==connection.id}) {
   guard next[index].serverID==connection.serverID,next[index].accountID==connection.accountID else{throw LibraryError("这个连接属于另一个账号，请新建连接，避免混用存档。")}
   next[index]=connection
  }else{next.append(connection)}
  try commit(next)
 }
 func remove(_ id:UUID)throws {try commit(connections.filter{$0.id != id})}
 private func commit(_ next:[SharedConnection])throws {
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
  try encoder.encode(next).write(to:root.appendingPathComponent("shared-connections.json"),options:.atomic)
  connections=next
 }
}

extension LibraryStore {
 @discardableResult func addShared(_ remote:SharedCatalogGame,entry:Candidate,connection:SharedConnection,mountRoot:URL)throws->Game {
  guard remote.entries.contains(entry),!remote.id.isEmpty else{throw LibraryError("共享游戏入口不存在。")}
  try EntryPolicy.validate(entry)
  let ref=SharedGameReference(connectionID:connection.id,serverID:connection.serverID,accountID:connection.accountID,gameID:remote.id)
  let folder=mountRoot.appendingPathComponent("NetworkMounts/"+ref.storageKey).path
  if var existing=games.first(where:{$0.id==ref.gameIdentity}) {
   guard existing.shared?.serverID==ref.serverID,existing.shared?.accountID==ref.accountID,existing.shared?.gameID==ref.gameID else{throw LibraryError("共享游戏标识冲突，未覆盖本地条目。")}
   existing.shared=ref;existing.entry=entry;existing.folder=folder
   try update(existing);return existing
  }
  let game=Game(id:ref.gameIdentity,title:remote.title,folder:folder,originalFolder:"gameshelf://"+ref.storageKey,entry:entry,windowSize:entry.backend == .wine ? "1280x720":nil,shared:ref)
  games.append(game)
  do{try save()}catch{games.removeLast();throw error}
  return game
 }
}

/// No redirects: a server redirect must never forward account credentials elsewhere.
private final class SharedNoRedirect:NSObject,URLSessionTaskDelegate {
 let pin:String?
 init(pin:String?){self.pin=pin}
 func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
 func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
  guard challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust,let pin else{completionHandler(.performDefaultHandling,nil);return}
  guard let trust=challenge.protectionSpace.serverTrust,let chain=SecTrustCopyCertificateChain(trust) as? [SecCertificate],let certificate=chain.first else{completionHandler(.cancelAuthenticationChallenge,nil);return}
  let digest=SHA256.hash(data:SecCertificateCopyData(certificate) as Data).map{String(format:"%02x",$0)}.joined()
  guard digest==pin else{completionHandler(.cancelAuthenticationChallenge,nil);return}
  // Trust only this explicitly supplied certificate, while retaining SSL host
  // validation. No certificate is installed into the system trust store.
  SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,challenge.protectionSpace.host as CFString))
  SecTrustSetAnchorCertificates(trust,[certificate] as CFArray)
  SecTrustSetAnchorCertificatesOnly(trust,true)
  guard SecTrustEvaluateWithError(trust,nil) else{completionHandler(.cancelAuthenticationChallenge,nil);return}
  completionHandler(.useCredential,URLCredential(trust:trust))
 }
}
final class SharedAPI {
 let address:URL
 private let session:URLSession
 init(address:String,certificateSHA256:String?=nil)throws {
  self.address=try SharedServerAddress.parse(address)
  let pin=try SharedServerAddress.certificatePin(certificateSHA256 ?? "")
  let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=120
  // LAN and overlay-network destinations are reached directly. Sending these
  // private endpoints through an unrelated system proxy can stall TLS entirely.
  // This affects routing only; certificate pin and hostname validation remain.
  if SharedServerAddress.usesDirectConnection(host:self.address.host ?? ""){config.connectionProxyDictionary=[:]}
  config.httpCookieStorage=nil;config.urlCache=nil;config.httpShouldSetCookies=false
  session=URLSession(configuration:config,delegate:SharedNoRedirect(pin:pin),delegateQueue:nil)
 }
 deinit{session.invalidateAndCancel()}
 func request<T:Decodable>(_ path:String,method:String="GET",token:String?=nil,body:[String:Any]?=nil,completion:@escaping(Result<T,Error>)->Void) {
  guard path.hasPrefix("/api/"),!path.contains("?"),!path.contains("#"),!path.contains(".."),!path.contains("%"),
        let url=URL(string:address.absoluteString+path) else{completion(.failure(LibraryError("共享库请求路径无效。")));return}
  var request=URLRequest(url:url);request.httpMethod=method
  request.setValue("application/json",forHTTPHeaderField:"Accept")
  if let token{request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
  do {if let body{request.httpBody=try JSONSerialization.data(withJSONObject:body);request.setValue("application/json",forHTTPHeaderField:"Content-Type")}}
  catch{completion(.failure(error));return}
  session.dataTask(with:request){[self] data,response,error in
   _ = self.address // Keep the API/session alive through one-shot cleanup calls.
   if let error{completion(.failure(error));return}
   guard let http=response as? HTTPURLResponse,let data,data.count<=8*1024*1024 else{completion(.failure(LibraryError("共享库响应无效或过大。")));return}
   guard (200..<300).contains(http.statusCode) else {
    completion(.failure(SharedRequestError(statusCode:http.statusCode)));return
   }
   do{completion(.success(try JSONDecoder().decode(T.self,from:data)))}catch{completion(.failure(LibraryError("共享库响应格式不兼容。")))}
  }.resume()
 }
 func login(username:String,password:String,completion:@escaping(Result<SharedLoginResponse,Error>)->Void) {
  request("/api/login",method:"POST",body:["username":username,"password":password],completion:completion)
 }
 func catalog(token:String,completion:@escaping(Result<SharedCatalog,Error>)->Void){request("/api/catalog",token:token,completion:completion)}
}
