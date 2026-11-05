import Foundation

@main struct OnboardingTests {
 static func check(_ value:@autoclosure ()throws->Bool,_ message:String)throws {
  if try !value(){throw LibraryError(message)}
 }
 static func rejects(_ action:()throws->Void)throws {
  do{try action()}catch{return};throw LibraryError("Invalid onboarding input accepted")
 }
 static func main()throws {
  let fm=FileManager.default,root=URL(fileURLWithPath:"/private/tmp/OnboardingTests-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
  let fresh=try OnboardingState(root:root.appendingPathComponent("fresh"))
  try check(fresh.needsPresentation(existingGameCount:0),"Fresh empty installation must onboard")
  try check(!fresh.needsPresentation(existingGameCount:7),"Existing libraries must skip onboarding")
  try check(!fm.fileExists(atPath:root.appendingPathComponent("fresh").path),"Read-only decision must not write")
  for choice in [OnboardingChoice.local,.connect,.create] {
   let path=root.appendingPathComponent(choice.rawValue),state=try OnboardingState(root:path)
   try check(state.needsPresentation(existingGameCount:0),"Each root has independent completion")
   try state.complete(choice:choice)
   try check(!state.needsPresentation(existingGameCount:0),"Completion must update current model")
   try check(try !OnboardingState(root:path).needsPresentation(existingGameCount:0),"Completion must survive reopen")
   let names=try fm.contentsOfDirectory(atPath:path.path)
   try check(names==["onboarding.json"],"Onboarding must persist only its own state file")
  }
  let bad=root.appendingPathComponent("bad");try fm.createDirectory(at:bad,withIntermediateDirectories:false)
  let file=bad.appendingPathComponent("onboarding.json"),bytes=Data("corrupt".utf8);try bytes.write(to:file)
  try rejects{_ = try OnboardingState(root:bad)}
  try check(try Data(contentsOf:file)==bytes,"Corruption must be retained")
  try fm.removeItem(at:file)
  let outside=root.appendingPathComponent("outside.json");try bytes.write(to:outside)
  try fm.createSymbolicLink(at:file,withDestinationURL:outside)
  try rejects{_ = try OnboardingState(root:bad)}
  try check(try Data(contentsOf:outside)==bytes,"State symlink must not be followed")

  let token=String(repeating:"A",count:32)
  let base:[String:Any]=["kind":"administrator-setup","version":1,"address":"https://setup.example.org/","setupToken":token]
  func read(_ object:[String:Any])throws->AdministratorSetupInvitation {
   try AdministratorSetupInvitation.read(JSONSerialization.data(withJSONObject:object))
  }
  let invitation=try read(base)
  try check(invitation.address=="https://setup.example.org" && invitation.setupToken==token,"Setup invitation must preserve capability in memory and normalize root URL")
  var named=base;named["name"]="Private library";named["certificateSHA256"]=String(repeating:"AB:",count:31)+"AB"
  let withMetadata=try read(named)
  try check(withMetadata.name=="Private library" && withMetadata.certificateSHA256==String(repeating:"ab",count:32),"Name/certificate pin must retain existing validation")
  for (field,value) in [("kind","shared-library" as Any),("version",2),("version",true),("address","http://remote.example.org"),("address","https://user:pass@setup.example.org"),("address","https://setup.example.org/path"),("address","https://setup.example.org/?secret=x"),("name","bad\nname"),("certificateSHA256","invalid"),("unexpected",true)] {
   var object=base;object[field]=value;try rejects{_ = try read(object)}
  }
  for field in ["kind","version","address","setupToken"] {
   var object=base;object.removeValue(forKey:field);try rejects{_ = try read(object)}
  }
  for value in [String(repeating:"a",count:31),String(repeating:"a",count:129),token+"=",token+"/",token+"+",token+"%41",token+"\n",token+"é"] {
   var object=base;object["setupToken"]=value;try rejects{_ = try read(object)}
  }
  for length in [32,128] {
   var object=base;object["setupToken"]=String(repeating:"_-",count:length/2)
   try check(try read(object).setupToken.utf8.count==length,"URL-safe token boundaries must be accepted")
  }
  try rejects{_ = try AdministratorSetupInvitation.read(Data(repeating:32,count:4097))}
  try rejects{_ = try AdministratorSetupInvitation.read(Data("[]".utf8))}
  try rejects{_ = try read(["version":1,"address":"https://setup.example.org"])}
  let password="fixture-password-only"
  try AdministratorSetupValidation.credentials(username:"Fixture_Admin",password:password,confirmation:password)
  for name in ["","bad name","../name","Fixture\n",String(repeating:"a",count:65)] {
   try rejects{try AdministratorSetupValidation.credentials(username:name,password:password,confirmation:password)}
  }
  try rejects{try AdministratorSetupValidation.credentials(username:"Fixture",password:"short",confirmation:"short")}
  try rejects{try AdministratorSetupValidation.credentials(username:"Fixture",password:password,confirmation:password+"x")}
  try rejects{try AdministratorSetupValidation.credentials(username:"Fixture",password:"fixture-é-123456",confirmation:"fixture-e\u{301}-123456")}
  try check(!String(describing:invitation).contains(token) && !String(reflecting:invitation).contains(token),"Invitation descriptions must redact the capability")
  let response=SharedLoginResponse(token:"fixture-session",user:SharedLoginUser(id:"fixture-user",username:"Fixture_Admin",admin:true),serverID:"fixture-server")
  try AdministratorSetupValidation.response(response,expectedServerID:"fixture-server")
  try rejects{try AdministratorSetupValidation.response(response,expectedServerID:"other-server")}
  var nonAdmin=response;nonAdmin.user.admin=false
  try rejects{try AdministratorSetupValidation.response(nonAdmin,expectedServerID:"fixture-server")}
  let persisted=try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter{$0.hasDirectoryPath}
  for path in persisted where path.lastPathComponent != "bad" {
   let file=path.appendingPathComponent("onboarding.json")
   if fm.fileExists(atPath:file.path){try check(try !String(contentsOf:file,encoding:.utf8).contains(token),"Setup capability must never enter onboarding state")}
  }
  print("PASS onboarding pure models: fresh/existing/per-root completion; strict private capability invitations; credential confirmation and exact administrator/server identity; no network/UI")
 }
}
