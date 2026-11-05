import Foundation
import Darwin

enum OnboardingChoice:String,Codable,Equatable {case local,connect,create}

final class OnboardingState {
 private struct Record:Codable {let version:Int;let choice:OnboardingChoice}
 private let root:URL
 private var completed:Bool
 private var file:URL{root.appendingPathComponent("onboarding.json")}
 init(root:URL)throws {
  guard root.isFileURL else{throw LibraryError("初次使用记录位置无效。")}
  self.root=root;completed=false
  completed=try read() != nil
 }
 func needsPresentation(existingGameCount:Int)->Bool {existingGameCount<=0 && !completed}
 func complete(choice:OnboardingChoice)throws {
  _ = try read() // Never overwrite unreadable/corrupt state with a fresh record.
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  try encoder.encode(Record(version:1,choice:choice)).write(to:file,options:.atomic)
  completed=true
 }
 private func read()throws->Record? {
  let fd=open(file.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
  if fd<0 && errno==ENOENT{return nil}
  guard fd>=0 else{throw LibraryError("初次使用记录无法读取，原件已保留。")}
  defer{Darwin.close(fd)}
  var info=stat()
  guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size>0,info.st_size<=4096 else{throw LibraryError("初次使用记录无效，原件已保留。")}
  var bytes=Data(),buffer=[UInt8](repeating:0,count:4097)
  while bytes.count<buffer.count {
   let count=buffer.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress,$0.count-bytes.count)}
   if count<0 && errno==EINTR{continue}
   guard count>=0 else{throw LibraryError("初次使用记录无法读取，原件已保留。")}
   if count==0{break};bytes.append(contentsOf:buffer.prefix(count))
  }
  guard bytes.count<=4096,let record=try? JSONDecoder().decode(Record.self,from:bytes),record.version==1 else{throw LibraryError("初次使用记录损坏，原件已保留。")}
  return record
 }
}

/// This private capability is intentionally not Encodable. Ordinary connection
/// invitations have no setup authority. Keep it in memory only for the wizard.
struct AdministratorSetupInvitation:CustomStringConvertible,CustomDebugStringConvertible {
 let kind:String
 let version:Int
 let address:String
 let name:String?
 let certificateSHA256:String?
 let setupToken:String
 var description:String{"AdministratorSetupInvitation(address: \(address), setupToken: <redacted>)"}
 var debugDescription:String{description}
 private struct Wire:Decodable {
  let kind:String;let version:Int;let address:String;let name:String?;let certificateSHA256:String?;let setupToken:String
 }
 private init(wire:Wire,address:String,pin:String?) {
  kind=wire.kind;version=wire.version;self.address=address;name=wire.name;certificateSHA256=pin;setupToken=wire.setupToken
 }
 static func read(_ data:Data)throws->Self {
  guard !data.isEmpty,data.count<=4096,
        let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
        Set(object.keys).isSubset(of:["kind","version","address","name","certificateSHA256","setupToken"]),
        let wire=try? JSONDecoder().decode(Wire.self,from:data),wire.kind=="administrator-setup",wire.version==1 else{throw LibraryError("管理员邀请文件无效。")}
  let token=Array(wire.setupToken.utf8)
  guard (32...128).contains(token.count),token.allSatisfy({(65...90).contains($0)||(97...122).contains($0)||(48...57).contains($0)||$0==45||$0==95}) else{throw LibraryError("管理员邀请凭据无效。")}
  if let name=wire.name {
   guard !name.isEmpty,name.count<=80,!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw LibraryError("服务器名称无效。")}
  }
  let address=try SharedServerAddress.parse(wire.address).absoluteString
  let pin=try SharedServerAddress.certificatePin(wire.certificateSHA256 ?? "")
  return Self(wire:wire,address:address,pin:pin)
 }
}

enum AdministratorSetupValidation {
 static func credentials(username:String,password:String,confirmation:String)throws {
  guard username.range(of:"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$",options:.regularExpression) != nil else{throw LibraryError("账号须为 1–64 位字母、数字、点、下划线或短横线，并以字母或数字开头。")}
  guard (12...1024).contains(password.unicodeScalars.count),!password.unicodeScalars.contains(where:{$0.value<32}) else{throw LibraryError("密码须为 12–1024 个字符，不能包含控制字符。")}
  guard password.utf8.elementsEqual(confirmation.utf8) else{throw LibraryError("两次密码不一致。")}
 }
 static func response(_ response:SharedLoginResponse,expectedServerID:String)throws {
  guard !expectedServerID.isEmpty,response.serverID.utf8.elementsEqual(expectedServerID.utf8),response.user.admin,
        !response.user.id.isEmpty,response.user.id.utf8.count<=128,!response.token.isEmpty,response.token.utf8.count<=4096 else{throw LibraryError("服务器或管理员身份不匹配，未连接账号。")}
 }
}
