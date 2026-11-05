import Foundation

@main struct SharedHTTPSBundleProbe {
 static func main()throws {
  guard CommandLine.arguments.count==4,Bundle.main.bundleIdentifier != nil else{exit(2)}
  let input=CommandLine.arguments,url=input[1],pin=input[2]=="-" ? nil:input[2],expectSuccess=input[3]=="success"
  let api=try SharedAPI(address:url,certificateSHA256:pin),signal=DispatchSemaphore(value:0)
  var success=false
  api.request("/api/server-info"){(result:Result<SharedServerInfo,Error>) in
   if case .success(let info)=result{success=info.serverID=="isolated-fixture"}
   signal.signal()
  }
  guard signal.wait(timeout:.now()+20) == .success,success==expectSuccess else{exit(1)}
  print(expectSuccess ? "PASS bundled explicit-pin HTTPS":"PASS bundled rejected untrusted TLS")
 }
}
