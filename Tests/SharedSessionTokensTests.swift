import Foundation
@main struct SharedSessionTokensTests {
 static func check(_ value:Bool,_ message:String){if !value{fatalError(message)}}
 static func main(){
  let a=UUID(),b=UUID();var current=SharedSessionTokens()
  check(current[a]==nil,"startup must require sign-in without reading stored credentials")
  current[a]="test-token-A";current[b]="test-token-B"
  check(current[a]=="test-token-A" && current[b]=="test-token-B","account sessions remain separate")
  check(current.activeConnectionID==b,"latest successful login is active")
  current.removeValue(forKey:a)
  check(current[a]==nil && current[b]=="test-token-B","logout clears only the selected account")
  check(current.activeConnectionID==b,"removing another login preserves active account")
  let restarted=SharedSessionTokens()
  check(restarted[a]==nil && restarted[b]==nil,"relaunch never restores a login session")
  current[b]="";check(current[b]==nil,"empty token cannot represent sign-in")
  check(current.activeConnectionID==nil && restarted.activeConnectionID==nil,"logout and relaunch clear active identity")
  print("PASS session-only authentication: fresh startup/relaunch signed out, account isolation, logout and empty-token rejection; no credential persistence")
 }
}
