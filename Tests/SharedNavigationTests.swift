import Foundation
@main struct SharedNavigationTests {
 static func check(_ value:Bool,_ message:String){if !value{fatalError(message)}}
 static func main(){
  let a=SharedConnection(name:"First",address:"https://first.example",serverID:"first",accountID:"owner",username:"Owner",isAdministrator:true)
  let b=SharedConnection(name:"Second",address:"https://first.example",serverID:"first",accountID:"player",username:"Player",isAdministrator:false)
  check(SharedNavigation.preferred(connections:[],boundID:nil)==nil,"empty state needs connection")
  check(SharedNavigation.preferred(connections:[a],boundID:nil)?.id==a.id,"one connection enters directly")
  check(SharedNavigation.preferred(connections:[a,b],boundID:b.id)?.id==b.id,"bound personal account takes priority")
  check(SharedNavigation.preferred(connections:[a,b],boundID:nil)==nil,"multiple unbound accounts require explicit selection")
  check(SharedNavigation.preferred(connections:[a,b],boundID:UUID())==nil,"missing identity must not select another account")
  check(SharedNavigation.destination(accountRequested:true,authenticated:true) == .account,"manage account must open account, not server selector/catalog")
  check(SharedNavigation.destination(accountRequested:false,authenticated:true) == .catalog,"library opens catalog")
  check(SharedNavigation.destination(accountRequested:true,authenticated:false) == .login,"expired credentials require login")
  check(SharedNavigation.preferred(connections:[a,b],boundID:a.id,activeID:b.id)?.id==b.id,"reopening library keeps signed-in guest instead of bound owner")
  check(SharedNavigation.preferred(connections:[a,b],boundID:a.id,activeID:UUID())?.id==a.id,"unknown active connection uses normal fallback")
  check(SharedNavigation.loginUsername(connection:a,authenticated:false).isEmpty,"signed-out login must not prefill bound owner")
  check(SharedNavigation.loginUsername(connection:b,authenticated:false).isEmpty,"signed-out login is neutral for every account")
  check(SharedNavigation.loginUsername(connection:b,authenticated:true)==b.username,"active session retains its account identity")
  print("PASS account navigation: exact bound identity, single/multiple servers and authenticated account/catalog routes")
 }
}
