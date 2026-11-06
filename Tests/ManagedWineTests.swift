import Foundation
import CryptoKit
@main struct ManagedWineTests {
 static func check(_ ok:Bool,_ message:String){precondition(ok,message)}
 static func main()throws {
  let args=CommandLine.arguments
  if args.count==4,args[1]=="--audit" {
   do{try ManagedWine.validateArchive(at:URL(fileURLWithPath:args[2]),expectedRoot:args[3]);print("PASS safe archive");exit(0)}catch{print("REJECT unsafe archive");exit(1)}
  }
  if args.count==5,args[1]=="--install-official" {
   let m=try JSONDecoder().decode(ManagedWine.Manifest.self,from:Data(contentsOf:URL(fileURLWithPath:args[4])))
   let source=try ManagedWine.install(manifest:m,root:URL(fileURLWithPath:args[3]),progress:{print($0)},download:{_,target,check in try check();try FileManager.default.copyItem(at:URL(fileURLWithPath:args[2]),to:target)},verify:ManagedWine.verifyEngine)
   print("PASS official install: "+source.path);return
  }
  let fm=FileManager.default,base=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("ManagedWineTests-"+UUID().uuidString)
  try fm.createDirectory(at:base,withIntermediateDirectories:true);defer{try? fm.removeItem(at:base)}
  check(ManagedWine.cached(root:base)==nil,"Empty cache")
  let custom=base.appendingPathComponent("Existing.app")
  for path in ["Contents/MacOS/wineskinlauncher","Contents/SharedSupport/wine/bin/wine64","Contents/SharedSupport/wine/bin/wineserver"] {
   let url=custom.appendingPathComponent(path);try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("inert".utf8).write(to:url);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:url.path)
  }
  try fm.createDirectory(at:custom.appendingPathComponent("Contents/Frameworks"),withIntermediateDirectories:true)
  let chosen=try ManagedWine.resolve(configured:custom,root:base.appendingPathComponent("must-not-create")){_ in fatalError("existing source should not install")}
  check(chosen==custom && !fm.fileExists(atPath:base.appendingPathComponent("must-not-create").path),"Existing source priority")
  check(!ManagedWine.isManaged(source:custom),"Wineskin is not managed")
  let manifest=ManagedWine.Manifest(id:"fixture",url:"https://github.com/Gcenx/macOS_Wine_builds/releases/download/fixture/fixture.tar.xz",size:1,sha256:String(repeating:"0",count:64),archiveRoot:"Wine.app",winePath:"Contents/Resources/wine",minimumMacOS:"10.15",architecture:"x86_64")
  let fixture=base.appendingPathComponent("Fixture"),package=fixture.appendingPathComponent("Wine.app/Contents/Resources/wine/bin")
  try fm.createDirectory(at:package,withIntermediateDirectories:true)
  for name in ["wine","wineserver"]{try Data("inert".utf8).write(to:package.appendingPathComponent(name));try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:package.appendingPathComponent(name).path)}
  let license=fixture.appendingPathComponent("Wine.app/LICENSE");try Data("UPSTREAM LICENSE fixture".utf8).write(to:license)
  let archive=base.appendingPathComponent("fixture.tar.xz"),tar=Process();tar.executableURL=URL(fileURLWithPath:"/usr/bin/tar");tar.arguments=["-cJf",archive.path,"-C",fixture.path,"Wine.app"];try tar.run();tar.waitUntilExit();check(tar.terminationStatus==0,"fixture archive")
  var fixed=manifest;let bytes=try Data(contentsOf:archive);fixed.size=Int64(bytes.count);fixed.sha256=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
  let root=base.appendingPathComponent("Engines");var downloads=0
  let install=try ManagedWine.install(manifest:fixed,root:root,progress:{_ in},download:{_,target,_ in downloads+=1;try fm.copyItem(at:archive,to:target)},verify:{_ in})
  check(ManagedWine.isManaged(source:install),"Managed skeleton")
  let installedWine=install.appendingPathComponent("Contents/SharedSupport/wine/bin/wine")
  check((try? fm.destinationOfSymbolicLink(atPath:installedWine.path))==nil,"Loader must have a real managed engine path")
  check(installedWine.resolvingSymlinksInPath().path.hasSuffix("/Contents/SharedSupport/wine/bin/wine"),"Managed engine must not resolve back into the deeply nested upstream bundle")

  check(!fm.fileExists(atPath:install.appendingPathComponent("Contents/MacOS/wineskinlauncher").path),"No fake launcher")
  check(!fm.fileExists(atPath:install.appendingPathComponent("Contents/SharedSupport/prefix").path),"No seeded prefix")
  check(try String(contentsOf:install.appendingPathComponent("Contents/Upstream/Wine.app/LICENSE"),encoding:.utf8)=="UPSTREAM LICENSE fixture","Preserve upstream license")
  let reused=try ManagedWine.install(manifest:fixed,root:root,progress:{_ in},download:{_,_,_ in fatalError("cache redownloaded")},verify:{_ in})
  check(reused.path==install.path && downloads==1,"Reuse")
  let dataBefore=try Data(contentsOf:install.appendingPathComponent("Contents/Info.plist"))
  check(try Data(contentsOf:install.appendingPathComponent("Contents/Info.plist"))==dataBefore,"Cache read only")
  let unrelatedPrefix=base.appendingPathComponent("Runtime/drive_c/account.save")
  try fm.createDirectory(at:unrelatedPrefix.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("private progress".utf8).write(to:unrelatedPrefix)
  try Data("damaged".utf8).write(to:install.appendingPathComponent("Contents/SharedSupport/wine/bin/wine64"))
  check(try String(contentsOf:install.appendingPathComponent("Contents/Upstream/Wine.app/Contents/Resources/wine/bin/wine"),encoding:.utf8)=="inert","Working engine writes must not change pristine upstream")
  let repaired=try ManagedWine.install(manifest:fixed,root:root,progress:{_ in},download:{_,target,_ in try fm.copyItem(at:archive,to:target)},verify:{_ in})
  check(repaired.path==install.path && ManagedWine.isManaged(source:repaired),"Corrupt owned cache repair")
  check(try String(contentsOf:unrelatedPrefix,encoding:.utf8)=="private progress","Repair cannot touch runtime prefix")
  check(try fm.contentsOfDirectory(atPath:root.path).contains(where:{$0.hasPrefix(".invalid-")}),"Keep corrupt source for inspection")
  var unknown=fixed;unknown.id="caller";let caller=root.appendingPathComponent("caller.app")
  try fm.createDirectory(at:caller,withIntermediateDirectories:true);try Data("untouched".utf8).write(to:caller.appendingPathComponent("sentinel"))
  do{_ = try ManagedWine.install(manifest:unknown,root:root,progress:{_ in},download:{_,_,_ in fatalError("Unknown destination downloaded")},verify:{_ in});fatalError("Unknown caller directory adopted")}catch{}
  check(try String(contentsOf:caller.appendingPathComponent("sentinel"),encoding:.utf8)=="untouched","Unknown directory preserved")
  var bad=fixed;bad.id="bad";bad.sha256=String(repeating:"0",count:64)
  do{_ = try ManagedWine.install(manifest:bad,root:root,progress:{_ in},download:{_,target,_ in try fm.copyItem(at:archive,to:target)},verify:{_ in});fatalError("bad SHA accepted")}catch{}
  check(!fm.fileExists(atPath:root.appendingPathComponent("bad.app").path),"No partial publish")
  var cancelled=fixed;cancelled.id="cancelled"
  do{_ = try ManagedWine.install(manifest:cancelled,root:root,progress:{_ in},download:{_,_,_ in ManagedWine.cancel()},verify:{_ in});fatalError("cancellation ignored")}catch{}
  let retried=try ManagedWine.install(manifest:cancelled,root:root,progress:{_ in},download:{_,target,_ in try fm.copyItem(at:archive,to:target)},verify:{_ in})
  check(ManagedWine.isManaged(source:retried),"Cancellation retry")
  print("PASS managed Wine: existing source priority, verified install, pristine payload/license, no prefix/launcher, reuse, checksum failure, cancel/retry")
 }
}
