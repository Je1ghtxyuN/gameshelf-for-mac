import Foundation
@main struct SharedAdministrationTests {
 static func main()throws {
  let data=Data(#"{"candidates":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","root_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","title":"Example","relative":"Example/macOS","entries":[{"path":"Example.app","backend":"native","engine":"macOS"}],"available":true,"detectedSavePaths":[]}]}"#.utf8)
  let response=try JSONDecoder().decode(SharedAdminCandidates.self,from:data)
  guard response.candidates.count==1,response.candidates[0].rootID==String(repeating:"b",count:32),response.candidates[0].entries.first?.path=="Example.app" else{fatalError("candidate decode")}
  guard try SharedAdminPath.scan(String(repeating:"a",count:32))=="/api/admin/roots/"+String(repeating:"a",count:32)+"/scan" else{fatalError("route")}
  for id in ["../login","",String(repeating:"a",count:31),String(repeating:"A",count:32)] {
   do{_ = try SharedAdminPath.publish(id);fatalError("invalid identity accepted")}catch{}
  }
  let users=try JSONDecoder().decode(SharedAdminUsers.self,from:Data(#"{"users":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","username":"Owner","admin":true,"disabled":false}]}"#.utf8))
  guard users.users.first?.admin==true else{fatalError("role decode")}
  let rules=try SharedAdminSaveRule.parse(files:"progress.dat\nstate/player.json",directories:"save\nprofiles")
  guard rules.count==4,rules.first?.kind=="file" else{fatalError("save rule editor")}
  for unsafe in ["../other","/absolute","save/../other","save//other",".gameshelf-profile/token","C:\\save"]{
   do{_ = try SharedAdminSaveRule.parse(files:unsafe,directories:"");fatalError("unsafe save path accepted")}catch{}
  }
  do{_ = try SharedAdminSaveRule.parse(files:"save",directories:"save");fatalError("conflicting path kinds")}catch{}
  print("PASS administration models: real API keys, platform entries, account roles and strict mutation route identities")
 }
}
