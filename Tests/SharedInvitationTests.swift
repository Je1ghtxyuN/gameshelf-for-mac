import Foundation
@main struct SharedInvitationTests {
 static func main()throws {
  struct Failure:Error{let message:String}
  func check(_ value:Bool,_ message:String)throws{if !value{throw Failure(message:message)}}
  let bytes=try JSONSerialization.data(withJSONObject:["version":1,"address":"https://games.example.org","name":"Home library","certificateSHA256":String(repeating:"ab",count:32)])
  let invitation=try SharedServerInvitation.read(bytes)
  try check(invitation.address=="https://games.example.org" && invitation.name=="Home library","invitation lost server metadata")
  for invalid in [Data(repeating:32,count:4097),try JSONSerialization.data(withJSONObject:["version":1,"address":"file:///private" ]) ,try JSONSerialization.data(withJSONObject:["version":1,"address":"https://user:pass@example.org"])] {
   do{_ = try SharedServerInvitation.read(invalid);throw Failure(message:"unsafe invitation accepted")}catch is Failure{throw Failure(message:"unsafe invitation accepted")}catch{}
  }
  try check(try SharedServerAddress.userInput("games.example.org:8787").absoluteString=="https://games.example.org:8787","ordinary server address requires typing a scheme")
  print("PASS SharedInvitation: bounded non-secret connection profile, safe address and HTTPS default")
 }
}
