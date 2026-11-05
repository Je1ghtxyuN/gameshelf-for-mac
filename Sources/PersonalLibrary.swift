import Foundation
import CryptoKit

struct PersonalGameMetadata:Codable,Equatable {
 var id:UUID
 var title:String
 var favorite:Bool
 var collectionIDs:[UUID]
 var playtimeSeconds:Double
 var lastPlayed:Double?
}
struct PersonalCollectionMetadata:Codable,Equatable {var id:UUID;var name:String}
struct PersonalLibrarySnapshot:Codable,Equatable {
 var version=1
 var games:[PersonalGameMetadata]
 var collections:[PersonalCollectionMetadata]
 static func make(games:[Game],collections:[GameCollection],serverID:String,accountID:String,playtime:(UUID)->Double)throws->Self {
  let allowed=games.filter{$0.shared==nil || ($0.shared?.serverID==serverID && $0.shared?.accountID==accountID)}
  let groups=collections.sorted{$0.id.uuidString<$1.id.uuidString}
  let result=Self(games:allowed.map{game in
   PersonalGameMetadata(id:game.id,title:game.title,favorite:game.favorite,collectionIDs:groups.filter{$0.gameIDs.contains(game.id)}.map{$0.id},playtimeSeconds:playtime(game.id),lastPlayed:game.lastPlayed?.timeIntervalSince1970)
  }.sorted{$0.id.uuidString<$1.id.uuidString},collections:groups.map{PersonalCollectionMetadata(id:$0.id,name:$0.name)})
  try result.validate();return result
 }
 func validate()throws {
  func text(_ s:String,_ limit:Int)->Bool{!s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && s.utf8.count<=limit && !s.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}}
  guard version==1,games.count<=1000,collections.count<=200,Set(games.map(\.id)).count==games.count,Set(collections.map(\.id)).count==collections.count,
        collections.allSatisfy({text($0.name,240)}) else{throw LibraryError("个人游戏库资料格式无效。")}
  let groupIDs=Set(collections.map(\.id))
  for game in games {
   guard text(game.title,1024),game.playtimeSeconds.isFinite,(0...31557600000).contains(game.playtimeSeconds),game.lastPlayed.map({$0.isFinite && (0...253402300799).contains($0)}) ?? true,
         Set(game.collectionIDs).count==game.collectionIDs.count,Set(game.collectionIDs).isSubset(of:groupIDs) else{throw LibraryError("游戏名称、分类或时长资料无效。")}
  }
 }
 func encoded()throws->Data {
  try validate();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(self)
  guard data.count<=512*1024 else{throw LibraryError("个人游戏库资料过大。")};return data
 }
 func fingerprint()throws->String{SHA256.hash(data:try encoded()).map{String(format:"%02x",$0)}.joined()}
}
struct PersonalLibraryDocument:Codable {var deviceID:UUID;var revision:Int;var snapshot:PersonalLibrarySnapshot}
struct PersonalLibraryBinding:Codable,Equatable {
 var deviceID:UUID=UUID()
 var connectionID:UUID
 var serverID:String
 var accountID:String
 var revision=0
 var fingerprint:String?
 var coverHashes:[String:String]=[:]
}
final class PersonalLibraryBindingStore {
 private let file:URL
 private(set) var binding:PersonalLibraryBinding?
 init(root:URL)throws {
  file=root.appendingPathComponent("personal-library-binding.json")
  if FileManager.default.fileExists(atPath:file.path) {
   do{
    let attributes=try FileManager.default.attributesOfItem(atPath:file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,(attributes[.size] as? NSNumber)?.intValue ?? Int.max<=262144 else{throw LibraryError("个人账号绑定文件不可用。")}
    let value=try JSONDecoder().decode(PersonalLibraryBinding.self,from:Data(contentsOf:file))
    guard !value.serverID.isEmpty,value.serverID.utf8.count<=128,!value.accountID.isEmpty,value.accountID.utf8.count<=128,value.revision>=0,value.coverHashes.count<=1000 else{throw LibraryError("个人账号绑定无效。")}
    binding=value
   }catch{throw LibraryError("个人账号绑定无法读取，原文件已保留。")}
  }
 }
 @discardableResult func bind(to connection:SharedConnection)throws->PersonalLibraryBinding {
  if var old=binding {
   guard old.serverID==connection.serverID,old.accountID==connection.accountID else{throw LibraryError("本机游戏库已绑定另一个账号，请先解除原账号绑定。")}
   old.connectionID=connection.id;try save(old);return old
  }
  let value=PersonalLibraryBinding(connectionID:connection.id,serverID:connection.serverID,accountID:connection.accountID)
  try save(value);return value
 }
 func acknowledge(identity:PersonalLibraryBinding,revision:Int,fingerprint:String,coverHashes:[String:String])throws {
  guard var current=binding,current.serverID==identity.serverID,current.accountID==identity.accountID,current.deviceID==identity.deviceID,current.revision==identity.revision,
        revision>=identity.revision,revision<=Int.max-1,fingerprint.count==64,coverHashes.count<=1000 else{throw LibraryError("个人游戏库绑定或同步版本发生变化。")}
  current.revision=revision;current.fingerprint=fingerprint;current.coverHashes=coverHashes;try save(current)
 }
 private func save(_ value:PersonalLibraryBinding)throws {
  let data=try JSONEncoder().encode(value);try data.write(to:file,options:[.atomic]);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);binding=value
 }
}
