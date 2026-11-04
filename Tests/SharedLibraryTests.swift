import Foundation

@main struct SharedLibraryTests {
 static func main() throws {
  struct Failure:Error {let message:String}
  func check(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(message:message)}}
  var passed=0
  for host in ["127.0.0.1","10.1.2.3","172.16.1.2","192.168.1.2","100.64.0.1","100.127.255.254","nas.local","mac.tailnet.ts.net","[::1]","[fd7a:115c:a1e0::1]"] {
   try check(SharedServerAddress.usesDirectConnection(host:host),"private network must bypass an unrelated proxy: "+host)
  }
  for host in ["100.63.255.255","100.128.0.1","172.32.0.1","games.example.org","nas.local.example.org","[2001:4860:4860::8888]"] {
   try check(!SharedServerAddress.usesDirectConnection(host:host),"public server must retain user proxy policy: "+host)
  }
  func rejects(_ value:String)throws {
   do {_ = try SharedServerAddress.parse(value);throw Failure(message:"accepted unsafe server address: "+value)}
   catch is Failure {throw Failure(message:"accepted unsafe server address: "+value)} catch {passed+=1}
  }
  for address in ["http://example.org", "https://user:pass@example.org", "https://example.org/?token=secret", "https://example.org/#fragment", "file:///tmp/server", "http://127.0.0.1.evil.test", "https://example.org/api"] {try rejects(address)}
  try check(try SharedServerAddress.parse("https://games.example.org/").absoluteString=="https://games.example.org", "canonical HTTPS root")
  try check(try SharedServerAddress.parse("http://127.0.0.1:8787").host=="127.0.0.1", "loopback test server")
  try check(try SharedServerAddress.certificatePin(String(repeating:"ab:",count:31)+"ab")==String(repeating:"ab",count:32),"certificate fingerprint normalization")
  do{_ = try SharedServerAddress.certificatePin("anything");throw Failure(message:"invalid certificate pin accepted")}catch is Failure{throw Failure(message:"invalid certificate pin accepted")}catch{}
  let one=SharedGameReference(connectionID:UUID(),serverID:"server-one",accountID:"account-one",gameID:"game-one")
  var other=one;other.accountID="account-two"
  try check(one.storageKey != other.storageKey,"different accounts collide")
  try check(one.gameIdentity != other.gameIdentity,"library identities collide across accounts")
  var renamedConnection=one;renamedConnection.connectionID=UUID()
  try check(one.gameIdentity==renamedConnection.gameIdentity,"reconnecting same account duplicates identity")
  let base=FileManager.default.temporaryDirectory.appendingPathComponent("shared-library-test-"+UUID().uuidString)
  defer{try? FileManager.default.removeItem(at:base)}
  let connection=SharedConnection(id:one.connectionID,name:"Friends",address:"https://games.example.org",serverID:one.serverID,accountID:one.accountID,username:"alice",isAdministrator:false)
  let store=try SharedConnectionStore(root:base)
  try store.save(connection)
  let restored=try SharedConnectionStore(root:base)
  try check(restored.connections==[connection],"connection persistence")
  let data=try String(contentsOf:base.appendingPathComponent("shared-connections.json"),encoding:.utf8)
  try check(!data.contains("password") && !data.contains("token"),"credentials persisted outside Keychain")
  var changed=connection;changed.accountID="bob"
  do{try store.save(changed);throw Failure(message:"account switch accepted under same connection")}
  catch is Failure{throw Failure(message:"account switch accepted under same connection")}catch{}
  let remote=SharedCatalogGame(id:"game-one",title:"Example",entries:[Candidate(path:"Game.exe",backend:.wine,engine:"Windows")])
  let library=try LibraryStore(root:base.appendingPathComponent("library"))
  let first=try library.addShared(remote,entry:remote.entries[0],connection:connection,mountRoot:base)
  try library.renameGame(first.id,name:"My title")
  let again=try library.addShared(remote,entry:remote.entries[0],connection:connection,mountRoot:base)
  try check(first.id==again.id && again.title=="My title" && library.games.count==1,"readd lost identity/title")
  try check(again.shared?.accountID=="account-one","missing source binding")
  print("PASS SharedLibrary: \(passed+10) address, account identity, persistence and library binding checks")
 }
}
