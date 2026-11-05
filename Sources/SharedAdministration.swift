import Foundation

struct SharedAdminRoot:Decodable {let id:String;let title:String;let path:String}
struct SharedAdminRoots:Decodable {let roots:[SharedAdminRoot]}
struct SharedAdminCandidate:Decodable {
 let id:String;let rootID:String;let title:String;let relative:String;let entries:[Candidate];let available:Bool;let detectedSavePaths:[SharedAdminSaveRule]
 enum CodingKeys:String,CodingKey {case id,title,relative,entries,available,detectedSavePaths;case rootID="root_id"}
}
struct SharedAdminSaveRule:Codable {
 let path:String;let kind:String
 static func parse(files:String,directories:String)throws->[Self]{
  var result:[Self]=[];var seen:[String:String]=[:]
  for (text,kind) in [(files,"file"),(directories,"directory")] {
   guard text.utf8.count<=256*1024 else{throw LibraryError("存档路径过多。")}
   for line in text.components(separatedBy:.newlines){
    let path=line.trimmingCharacters(in:.whitespaces);if path.isEmpty{continue}
    let components=path.split(separator:"/",omittingEmptySubsequences:false)
    guard path.count<=4096,components.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}),components.first != ".gameshelf-profile",!path.contains("\\"),!path.contains(":"),!path.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw LibraryError("存档路径须为游戏内的相对路径。")}
    if let previous=seen[path]{guard previous==kind else{throw LibraryError("同一路径不能同时是文件和文件夹。")};continue}
    seen[path]=kind;result.append(Self(path:path,kind:kind));guard result.count<=2048 else{throw LibraryError("存档路径过多。")}
   }
  }
  return result
 }
}
struct SharedAdminCandidates:Decodable {let candidates:[SharedAdminCandidate]}
struct SharedAdminUser:Decodable {let id:String;let username:String;let admin:Bool;let disabled:Bool}
struct SharedAdminUsers:Decodable {let users:[SharedAdminUser]}
struct SharedAdminGrant:Decodable {let userID:String;let gameID:String}
struct SharedAdminGrants:Decodable {let grants:[SharedAdminGrant]}
struct SharedAdminScan:Decodable {let complete:Bool;let discovered:Int;let issues:[String]}
struct SharedAdminOK:Decodable {}
enum SharedAdminPath {
 private static func id(_ value:String)throws->String {
  guard value.count==32,value.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw LibraryError("服务器记录标识无效，请刷新后重试。")};return value
 }
 static func scan(_ value:String)throws->String{"/api/admin/roots/"+(try id(value))+"/scan"}
 static func publish(_ value:String)throws->String{"/api/admin/candidates/"+(try id(value))+"/publish"}
 static func disable(_ value:String)throws->String{"/api/admin/users/"+(try id(value))+"/disable"}
}
