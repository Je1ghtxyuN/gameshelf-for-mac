import Foundation
import CryptoKit
import Darwin

/// Synchronous, worker-queue only. Downloads/builds only its own versioned source;
/// never initializes a prefix and never executes a game or a downloaded installer.
enum ManagedWine {
 enum Failure:Error,LocalizedError {
  case invalidManifest,unsafeArchive,downloadFailed,checksumMismatch,cancelled,rosettaRequired,unsupportedSystem,invalidInstallation
  var errorDescription:String? {
   switch self {
   case .invalidManifest:return "托管 Wine 清单缺失或无效。"
   case .unsafeArchive:return "Wine 归档包含不安全路径或超过解包限制。"
   case .downloadFailed:return "Wine 下载失败，请检查网络后重试。"
   case .checksumMismatch:return "Wine 下载校验失败，未安装运行环境。"
   case .cancelled:return "Wine 准备已取消，可重新尝试。"
   case .rosettaRequired:return "此 Wine 运行环境需要 Rosetta 2，请完成系统安装后重试。"
   case .unsupportedSystem:return "此 Wine 版本不支持当前系统或架构。"
   case .invalidInstallation:return "Wine 运行环境不完整或已改变，请重新准备。"
   }
  }
 }
 struct Manifest:Codable,Equatable {
  var id:String;var url:String;var size:Int64;var sha256:String;var archiveRoot:String;var winePath:String;var minimumMacOS:String;var architecture:String
  func validate()throws {
   guard !id.isEmpty,id.count<100,id.utf8.allSatisfy({(48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,95].contains($0)}),id != ".",id != "..",
    let u=URLComponents(string:url),u.scheme=="https",u.host=="github.com",u.user==nil,u.password==nil,u.query==nil,u.fragment==nil,
    u.path.hasPrefix("/Gcenx/macOS_Wine_builds/releases/download/"),size>0,size<=1024*1024*1024,
    sha256.count==64,sha256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
    archiveRoot==trySafePath(archiveRoot),!archiveRoot.contains("/"),winePath==trySafePath(winePath),architecture=="x86_64",
    minimumMacOS.split(separator:".").count>=2,minimumMacOS.split(separator:".").allSatisfy({Int($0) != nil}) else{throw Failure.invalidManifest}
  }
 }
 private struct Node:Codable,Equatable {let path:String;let kind:UInt32;let size:Int64;let seconds:Int64;let nanos:Int64;let target:String?}
 private struct Receipt:Codable {let manifest:Manifest;let wineSHA256:String;let serverSHA256:String;let nodes:[Node]}
 private final class Context {
  let lock=NSLock();var stopped=false;var process:Process?;var task:URLSessionTask?
  func check()throws{lock.lock();defer{lock.unlock()};if stopped{throw Failure.cancelled}}
  func stop(){lock.lock();stopped=true;let p=process,t=task;lock.unlock();t?.cancel();if let p,p.isRunning{p.terminate()}}
  func download(_ manifest:Manifest,to target:URL)throws {
   let operation=DownloadOperation(target:target,limit:manifest.size)
   let configuration=URLSessionConfiguration.ephemeral
   configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=900
   let session=URLSession(configuration:configuration,delegate:operation,delegateQueue:nil)
   defer{session.invalidateAndCancel()}
   let next=session.downloadTask(with:URL(string:manifest.url)!)
   lock.lock();if stopped{lock.unlock();throw Failure.cancelled};task=next;lock.unlock()
   defer{lock.lock();task=nil;lock.unlock()}
   next.resume()
   guard operation.done.wait(timeout:.now()+910) == .success else{next.cancel();throw Failure.downloadFailed}
   try check()
   guard operation.succeeded else{throw Failure.downloadFailed}
  }
  func run(_ p:Process)throws {
   lock.lock();if stopped{lock.unlock();throw Failure.cancelled};process=p
   do{try p.run()}catch{process=nil;lock.unlock();throw error};lock.unlock()
   p.waitUntilExit();lock.lock();process=nil;let cancelled=stopped;lock.unlock()
   if cancelled{throw Failure.cancelled}
   guard p.terminationStatus==0 else{throw Failure.downloadFailed}
  }
 }
 // URLSession uses macOS network/proxy settings, rather than a shell's proxy
 // environment. Its temporary file, redirects and transfer size are bounded.
 private final class DownloadOperation:NSObject,URLSessionDownloadDelegate,@unchecked Sendable {
  let target:URL,limit:Int64,done=DispatchSemaphore(value:0)
  var succeeded=false
  init(target:URL,limit:Int64){self.target=target;self.limit=limit}
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
   completionHandler(request.url?.scheme?.lowercased()=="https" ? request:nil)
  }
  func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didWriteData bytesWritten:Int64,totalBytesWritten:Int64,totalBytesExpectedToWrite:Int64){
   if totalBytesWritten>limit || totalBytesExpectedToWrite>limit{downloadTask.cancel()}
  }
  func urlSession(_ session:URLSession,downloadTask:URLSessionDownloadTask,didFinishDownloadingTo location:URL){
   guard (downloadTask.response as? HTTPURLResponse)?.statusCode==200,
         let size=try? FileManager.default.attributesOfItem(atPath:location.path)[.size] as? NSNumber,
         size.int64Value==limit else{return}
   do{try FileManager.default.moveItem(at:location,to:target);succeeded=true}catch{succeeded=false}
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){if error != nil{succeeded=false};done.signal()}
 }
 private static let contextsLock=NSLock()
 private static var contexts:[UUID:Context]=[:]
 static func cancel(){contextsLock.lock();let active=Array(contexts.values);contextsLock.unlock();active.forEach{$0.stop()}}
 private static func manifest()throws->Manifest {
  guard let url=Bundle.main.url(forResource:"ManagedWine",withExtension:"json") else{throw Failure.invalidManifest}
  let data=try boundedRead(url,limit:16384);let value=try JSONDecoder().decode(Manifest.self,from:data);try value.validate();return value
 }
 static func isManaged(source:URL)->Bool {
  guard source.isFileURL,let data=try? boundedRead(source.appendingPathComponent("Contents/Info.plist"),limit:65536),
   let info=(try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any],info["GameShelfManagedWine"] as? Bool==true else{return false}
  return ["wine64","wineserver"].allSatisfy{FileManager.default.isExecutableFile(atPath:source.appendingPathComponent("Contents/SharedSupport/wine/bin/"+$0).path)}
 }
 static func cached(root:URL)->URL? {
  guard let m=try? manifest() else{return nil};return cache(root:root,manifest:m)
 }
 // Settings only: never walk a multi-gigabyte engine from the main-thread timer.
 // resolve/install still perform complete cache verification on a worker queue.
 static func displaySource(root:URL)->URL? {
  guard let m=try? manifest() else{return nil}
  let source=root.appendingPathComponent(m.id+".app")
  return isManaged(source:source) ? source:nil
 }
 static func resolve(configured:URL?,root:URL,progress:@escaping(String)->Void)throws->URL {
  if let source=configured,source.isFileURL {
   if isManaged(source:source),let record=ownedReceipt(source:source),cache(root:source.deletingLastPathComponent(),manifest:record.manifest)?.path==source.path {try platform(record.manifest);return source}
   if !isManaged(source:source) && (["Contents/MacOS/wineskinlauncher","Contents/SharedSupport/wine/bin/wine64","Contents/SharedSupport/wine/bin/wineserver"].allSatisfy{FileManager.default.isExecutableFile(atPath:source.appendingPathComponent($0).path)} && FileManager.default.fileExists(atPath:source.appendingPathComponent("Contents/Frameworks").path)){return source}
  }
  let m=try manifest();try platform(m)
  return try install(manifest:m,root:root,progress:progress,download:{m,target,check in
   try check()
   guard let context=Thread.current.threadDictionary["GameShelfManagedWineContext"] as? Context else{throw Failure.cancelled}
   try context.download(m,to:target);try check()
  },verify:verifyEngine)
 }
 private static func platform(_ m:Manifest)throws {
  let version=ProcessInfo.processInfo.operatingSystemVersion,parts=m.minimumMacOS.split(separator:".").compactMap{Int($0)}
  guard parts.count>=2,(version.majorVersion>parts[0] || (version.majorVersion==parts[0] && version.minorVersion>=parts[1])) else{throw Failure.unsupportedSystem}
  var arm:Int32=0;var size=MemoryLayout.size(ofValue:arm)
  if sysctlbyname("hw.optional.arm64",&arm,&size,nil,0)==0 && arm==1 {
   guard rosettaAvailable() else{throw Failure.rosettaRequired}
  }
 }
 private static func rosettaAvailable()->Bool {
  let p=Process(),done=DispatchSemaphore(value:0)
  p.executableURL=URL(fileURLWithPath:"/usr/bin/arch");p.arguments=["-x86_64","/usr/bin/true"]
  p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;p.terminationHandler={_ in done.signal()}
  do{try p.run()}catch{return false}
  guard done.wait(timeout:.now()+10) == .success else{if p.isRunning{p.terminate()};if done.wait(timeout:.now()+2) != .success,p.isRunning{Darwin.kill(p.processIdentifier,SIGKILL);_ = done.wait(timeout:.now()+2)};return false}
  return p.terminationStatus==0
 }
 private static func cache(root:URL,manifest m:Manifest)->URL? {
  let source=root.appendingPathComponent(m.id+".app")
  guard (try? safeDirectory(root,create:false)) != nil,(try? safeDirectory(source,create:false)) != nil,isManaged(source:source),
   let receipt=ownedReceipt(source:source),receipt.manifest==m,
   // Older installs alias the deeply nested upstream engine. Wine's setupapi
   // truncates its wine.inf command at MAX_PATH, leaving clean prefixes empty.
   !isLink(source.appendingPathComponent("Contents/SharedSupport/wine/bin/wine")),
   let actual=try? inventory(source),actual==receipt.nodes,
   let w=try? digest(source.appendingPathComponent("Contents/SharedSupport/wine/bin/wine64"),check:{}),w==receipt.wineSHA256,
   let s=try? digest(source.appendingPathComponent("Contents/SharedSupport/wine/bin/wineserver"),check:{}),s==receipt.serverSHA256 else{return nil}
  return source
 }
 private static func ownedReceipt(source:URL)->Receipt? {
  guard (try? safeDirectory(source,create:false)) != nil,
   let infoData=try? boundedRead(source.appendingPathComponent("Contents/Info.plist"),limit:65536),let info=(try? PropertyListSerialization.propertyList(from:infoData,format:nil)) as? [String:Any],info["GameShelfManagedWine"] as? Bool==true else{return nil}
  let file=source.appendingPathComponent("Contents/managed-wine-receipt.json");var st=stat()
  guard lstat(file.path,&st)==0,st.st_uid==getuid(),st.st_nlink==1,st.st_mode&0o777==0o600,
   let data=try? boundedRead(file,limit:8*1024*1024),let receipt=try? JSONDecoder().decode(Receipt.self,from:data),
   (try? receipt.manifest.validate()) != nil,source.lastPathComponent==receipt.manifest.id+".app",info["GameShelfEngineID"] as? String==receipt.manifest.id,
   receipt.nodes.count<=100000 else{return nil}
  return receipt
 }
 private static func inventory(_ source:URL)throws->[Node] {
  var failed=false
  guard let iterator=FileManager.default.enumerator(at:source,includingPropertiesForKeys:nil,options:[],errorHandler:{_,_ in failed=true;return false}) else{throw Failure.invalidInstallation}
  var result:[Node]=[]
  for case let url as URL in iterator {
   let relative=String(url.path.dropFirst(source.path.count+1))
   if relative=="Contents/managed-wine-receipt.json"{continue}
   guard trySafePath(relative) != nil,result.count<100000 else{throw Failure.invalidInstallation}
   var st=stat();guard lstat(url.path,&st)==0 else{throw Failure.invalidInstallation};let kind=UInt32(st.st_mode&S_IFMT)
   guard [UInt32(S_IFREG),UInt32(S_IFDIR),UInt32(S_IFLNK)].contains(kind) else{throw Failure.invalidInstallation}
   let directory=kind==UInt32(S_IFDIR)
   result.append(Node(path:relative,kind:kind,size:directory ? 0:st.st_size,seconds:directory ? 0:Int64(st.st_mtimespec.tv_sec),nanos:directory ? 0:Int64(st.st_mtimespec.tv_nsec),target:kind==UInt32(S_IFLNK) ? try FileManager.default.destinationOfSymbolicLink(atPath:url.path):nil))
  }
  guard !failed else{throw Failure.invalidInstallation};return result.sorted{$0.path<$1.path}
 }
 /// Internal injection point for deterministic archive/cancellation tests only.
 static func install(manifest m:Manifest,root:URL,progress:@escaping(String)->Void,
                     download:(Manifest,URL,()throws->Void)throws->Void,verify:(URL)throws->Void)throws->URL {
  try m.validate();try safeDirectory(root,create:true)
  let context=Context(),ticket=UUID();contextsLock.lock();contexts[ticket]=context;contextsLock.unlock()
  defer{contextsLock.lock();contexts.removeValue(forKey:ticket);contextsLock.unlock()}
  let lockURL=root.appendingPathComponent(".managed-wine.lock")
  let fd=open(lockURL.path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw Failure.invalidInstallation};defer{close(fd)}
  var lockInfo=stat();guard fstat(fd,&lockInfo)==0,lockInfo.st_mode&S_IFMT==S_IFREG,lockInfo.st_nlink==1,lockInfo.st_uid==getuid() else{throw Failure.invalidInstallation}
  while flock(fd,LOCK_EX|LOCK_NB) != 0 {guard errno==EWOULDBLOCK || errno==EAGAIN else{throw Failure.invalidInstallation};try context.check();Thread.sleep(forTimeInterval:0.05)}
  defer{flock(fd,LOCK_UN)}
  try context.check();if let existing=cache(root:root,manifest:m){return existing}
  let destination=root.appendingPathComponent(m.id+".app")
  let repairing=FileManager.default.fileExists(atPath:destination.path) || isLink(destination)
  if repairing {guard !isLink(destination),let receipt=ownedReceipt(source:destination),receipt.manifest==m else{throw Failure.invalidInstallation}}
  let stage=root.appendingPathComponent(".preparing-"+UUID().uuidString),source=stage.appendingPathComponent("Source.app"),archive=stage.appendingPathComponent("download.tar.xz")
  try FileManager.default.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);var preserveStage=false;defer{if !preserveStage{try? FileManager.default.removeItem(at:stage)}}
  progress("正在下载 Wine 运行环境…")
  Thread.current.threadDictionary["GameShelfManagedWineContext"]=context
  defer{Thread.current.threadDictionary.removeObject(forKey:"GameShelfManagedWineContext")}
  try download(m,archive,context.check);try context.check()
  let attrs=try FileManager.default.attributesOfItem(atPath:archive.path)
  guard attrs[.type] as? FileAttributeType == .typeRegular,(attrs[.size] as? NSNumber)?.int64Value==m.size,try digest(archive,check:context.check)==m.sha256 else{throw Failure.checksumMismatch}
  progress("正在校验并解包 Wine…")
  let upstream=source.appendingPathComponent("Contents/Upstream")
  try FileManager.default.createDirectory(at:upstream,withIntermediateDirectories:true)
  try extract(archive,to:upstream,expectedRoot:m.archiveRoot,check:context.check)
  let original=upstream.appendingPathComponent(m.archiveRoot),engine=original.appendingPathComponent(m.winePath)
  guard FileManager.default.isExecutableFile(atPath:engine.appendingPathComponent("bin/wine").path),FileManager.default.isExecutableFile(atPath:engine.appendingPathComponent("bin/wineserver").path) else{throw Failure.invalidInstallation}
  try verify(engine)
  // Keep the pristine upstream bundle, including licenses and signatures. Wine
  // derives its data directory from the loaded libraries, resolving symlinks.
  // A real working engine avoids the extra Upstream/<bundle>/Contents nesting
  // overflowing setupapi's fixed command buffer during clean-prefix wineboot.
  let wine=source.appendingPathComponent("Contents/SharedSupport/wine"),bin=wine.appendingPathComponent("bin")
  try FileManager.default.createDirectory(at:wine.deletingLastPathComponent(),withIntermediateDirectories:true)
  try FileManager.default.copyItem(at:engine,to:wine)
  if !FileManager.default.fileExists(atPath:bin.appendingPathComponent("wine64").path){try FileManager.default.createSymbolicLink(atPath:bin.appendingPathComponent("wine64").path,withDestinationPath:"wine")}
  try FileManager.default.createDirectory(at:source.appendingPathComponent("Contents/Frameworks"),withIntermediateDirectories:true)
  let info:[String:Any]=["GameShelfManagedWine":true,"GameShelfEngineID":m.id,"CFBundleIdentifier":"local.gameshelf.managed-wine","CFBundleName":"GameShelf Managed Wine","CFBundlePackageType":"BNDL"]
  try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:source.appendingPathComponent("Contents/Info.plist"),options:.atomic)
  let receipt=Receipt(manifest:m,wineSHA256:try digest(engine.appendingPathComponent("bin/wine"),check:context.check),serverSHA256:try digest(engine.appendingPathComponent("bin/wineserver"),check:context.check),nodes:try inventory(source))
  let receiptData=try JSONEncoder().encode(receipt);guard receiptData.count<=8*1024*1024 else{throw Failure.invalidInstallation}
  let receiptURL=source.appendingPathComponent("Contents/managed-wine-receipt.json")
  try receiptData.write(to:receiptURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receiptURL.path)
  try context.check();guard isManaged(source:source) else{throw Failure.invalidInstallation}
  if repairing {
   // Atomic exchange keeps the stable path continuously present, including for
   // existing runtime engine links. Retain the old source, never delete it.
   guard renameatx_np(AT_FDCWD,source.path,AT_FDCWD,destination.path,UInt32(RENAME_SWAP))==0 else{throw Failure.invalidInstallation}
   let quarantine=root.appendingPathComponent(".invalid-"+UUID().uuidString)
   do{try FileManager.default.moveItem(at:source,to:quarantine)}catch{
    if renameatx_np(AT_FDCWD,source.path,AT_FDCWD,destination.path,UInt32(RENAME_SWAP)) != 0 {
     // Never let cleanup delete the displaced original after a failed rollback.
     preserveStage=true
    }
    throw Failure.invalidInstallation
   }
  } else {
   guard renameatx_np(AT_FDCWD,source.path,AT_FDCWD,destination.path,UInt32(RENAME_EXCL))==0 else{throw Failure.invalidInstallation}
  }
  progress("Wine 运行环境已准备好。")
  return destination
 }
 static func verifyEngine(_ engine:URL)throws {
  for name in ["wine","wineserver"] {
   let file=engine.appendingPathComponent("bin/"+name),handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()}
   let header=try handle.read(upToCount:8) ?? Data()
   guard header.count==8,Array(header.prefix(4))==[0xcf,0xfa,0xed,0xfe],Array(header.suffix(4))==[7,0,0,1] else{throw Failure.unsupportedSystem}
   let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/codesign");p.arguments=["--verify","--strict",file.path];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit();guard p.terminationStatus==0 else{throw Failure.invalidInstallation}
  }
 }
 private static func isLink(_ url:URL)->Bool{(try? FileManager.default.attributesOfItem(atPath:url.path)[.type]) as? FileAttributeType == .typeSymbolicLink}
 private static func safeDirectory(_ url:URL,create:Bool)throws {
  guard url.isFileURL,url.path.hasPrefix("/"),url.path != "/",!url.path.split(separator:"/").contains("..") else{throw Failure.invalidInstallation}
  var current=URL(fileURLWithPath:"/",isDirectory:true)
  for component in url.path.split(separator:"/") {
   current.appendPathComponent(String(component));if create && !FileManager.default.fileExists(atPath:current.path) && !isLink(current){try FileManager.default.createDirectory(at:current,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
   guard let info=try? FileManager.default.attributesOfItem(atPath:current.path),info[.type] as? FileAttributeType == .typeDirectory else{throw Failure.invalidInstallation}
  }
 }
 private static func boundedRead(_ url:URL,limit:Int)throws->Data {
  guard !isLink(url),let info=try? FileManager.default.attributesOfItem(atPath:url.path),info[.type] as? FileAttributeType == .typeRegular,(info[.size] as? NSNumber)?.intValue ?? Int.max<=limit else{throw Failure.invalidInstallation}
  let f=try FileHandle(forReadingFrom:url);defer{try? f.close()};let data=try f.read(upToCount:limit+1) ?? Data();guard data.count<=limit else{throw Failure.invalidInstallation};return data
 }
 private static func digest(_ url:URL,check:()throws->Void)throws->String {
  let f=try FileHandle(forReadingFrom:url);defer{try? f.close()};var hash=SHA256()
  while true{try check();let data=try f.read(upToCount:1024*1024) ?? Data();if data.isEmpty{break};hash.update(data:data)}
  return hash.finalize().map{String(format:"%02x",$0)}.joined()
 }
 private static func trySafePath(_ name:String)->String? {
  guard !name.isEmpty,name.utf8.count<=4096,!name.hasPrefix("/"),!name.contains("\\"),!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),name.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else{return nil};return name
 }
 // System libarchive is part of macOS (including its dyld shared cache).
 // Read typed metadata directly: never parse `tar -t` text containing attacker names.
 private final class Archive {
  typealias New = @convention(c) ()->OpaquePointer?
  typealias Unary = @convention(c) (OpaquePointer?)->Int32
  typealias Open = @convention(c) (OpaquePointer?,UnsafePointer<CChar>?,Int)->Int32
  typealias Next = @convention(c) (OpaquePointer?,UnsafeMutablePointer<OpaquePointer?>?)->Int32
  typealias Name = @convention(c) (OpaquePointer?)->UnsafePointer<CChar>?
  typealias Number = @convention(c) (OpaquePointer?)->Int64
  typealias Kind = @convention(c) (OpaquePointer?)->UInt32
  typealias Read = @convention(c) (OpaquePointer?,UnsafeMutableRawPointer?,Int)->Int
  let library:UnsafeMutableRawPointer;let handle:OpaquePointer
  let next:Next;let name:Name;let link:Name;let hard:Name;let size:Number;let kind:Kind;let perm:Kind;let read:Read;let free:Unary
  init(_ url:URL)throws {
   guard let lib=dlopen("/usr/lib/libarchive.2.dylib",RTLD_NOW|RTLD_LOCAL) else{throw Failure.unsafeArchive}
   library=lib
   func symbol<T>(_ name:String,_ type:T.Type)throws->T{guard let p=dlsym(lib,name) else{throw Failure.unsafeArchive};return unsafeBitCast(p,to:type)}
   do {
    let new=try symbol("archive_read_new",New.self);guard let a=new() else{throw Failure.unsafeArchive};handle=a
    free=try symbol("archive_read_free",Unary.self)
    let filter=try symbol("archive_read_support_filter_all",Unary.self),format=try symbol("archive_read_support_format_tar",Unary.self),open=try symbol("archive_read_open_filename",Open.self)
    next=try symbol("archive_read_next_header",Next.self);name=try symbol("archive_entry_pathname",Name.self);link=try symbol("archive_entry_symlink",Name.self);hard=try symbol("archive_entry_hardlink",Name.self);size=try symbol("archive_entry_size",Number.self);kind=try symbol("archive_entry_filetype",Kind.self);perm=try symbol("archive_entry_perm",Kind.self);read=try symbol("archive_read_data",Read.self)
    guard filter(a)==0,format(a)==0,url.path.withCString({open(a,$0,65536)})==0 else{_ = free(a);throw Failure.unsafeArchive}
   }catch{dlclose(lib);throw error}
  }
  deinit{_ = free(handle);dlclose(library)}
 }
 private struct Entry:Equatable {let path:String;let kind:UInt32;let size:Int64;let executable:Bool;let link:String?}
 private static func entries(_ archive:Archive,expectedRoot:String,check:()throws->Void)throws->[Entry] {
  var result:[Entry]=[],names=Set<String>(),total:Int64=0
  while true {
   try check();var entry:OpaquePointer?;let status=archive.next(archive.handle,&entry);if status==1{break}
   guard status==0,let entry,let c=archive.name(entry),let raw=String(validatingUTF8:c) else{throw Failure.unsafeArchive}
   let name=raw.hasSuffix("/") ? String(raw.dropLast()):raw
   guard trySafePath(name) != nil,(name==expectedRoot || name.hasPrefix(expectedRoot+"/")),names.insert(name).inserted,result.count<50000,archive.hard(entry)==nil else{throw Failure.unsafeArchive}
   let kind=archive.kind(entry),size=archive.size(entry)
   guard [UInt32(0o100000),UInt32(0o40000),UInt32(0o120000)].contains(kind),size>=0,size<=512*1024*1024 else{throw Failure.unsafeArchive}
   if kind==0o100000{total+=size;guard total<=2*1024*1024*1024 else{throw Failure.unsafeArchive}}
   var link:String?
   if kind==0o120000 {
    guard let target=archive.link(entry),let value=String(validatingUTF8:target),!value.isEmpty,!value.hasPrefix("/"),!value.contains("\\"),!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw Failure.unsafeArchive}
    var parts=name.split(separator:"/").dropLast().map(String.init)
    for component in value.split(separator:"/") {
     if component=="."{continue};if component==".."{guard parts.count>1 else{throw Failure.unsafeArchive};parts.removeLast()}else{parts.append(String(component))}
    }
    guard parts.first==expectedRoot else{throw Failure.unsafeArchive};link=value
   }
   result.append(Entry(path:name,kind:kind,size:size,executable:archive.perm(entry)&0o111 != 0,link:link))
  }
  let nonDirectories=Set(result.filter{$0.kind != 0o40000}.map(\.path))
  let links=Dictionary(uniqueKeysWithValues:result.compactMap{e in e.link.map{(e.path,$0)}})
  var nodes=names
  for e in result {
   var parents=e.path.split(separator:"/").dropLast().map(String.init)
   while !parents.isEmpty {let path=parents.joined(separator:"/");guard !nonDirectories.contains(path) else{throw Failure.unsafeArchive};nodes.insert(path);parents.removeLast()}
  }
  // Resolve link chains using archive metadata, including '..' AFTER resolving
  // a linked directory. Lexical normalization alone misses indirect escapes.
  for e in result where e.link != nil {
   var queue=e.path.split(separator:"/").map(String.init),resolved:[String]=[],hops=0
   while !queue.isEmpty {
    let part=queue.removeFirst();if part=="."{continue}
    if part==".." {guard resolved.count>1 else{throw Failure.unsafeArchive};resolved.removeLast();continue}
    let candidate=(resolved+[part]).joined(separator:"/")
    if let target=links[candidate] {hops+=1;guard hops<=64 else{throw Failure.unsafeArchive};queue=target.split(separator:"/").map(String.init)+queue}
    else{guard nodes.contains(candidate) else{throw Failure.unsafeArchive};resolved.append(part)}
   }
   guard resolved.first==expectedRoot else{throw Failure.unsafeArchive}
  }
  return result
 }
 static func validateArchive(at url:URL,expectedRoot:String)throws {
  guard trySafePath(expectedRoot) != nil,!expectedRoot.contains("/") else{throw Failure.unsafeArchive}
  _ = try entries(Archive(url),expectedRoot:expectedRoot,check:{})
 }
 private static func extract(_ url:URL,to target:URL,expectedRoot:String,check:()throws->Void)throws {
  let approved=try entries(Archive(url),expectedRoot:expectedRoot,check:check)
  let archive=try Archive(url);var position=0
  var buffer=[UInt8](repeating:0,count:1024*1024)
  while true {
   try check();var pointer:OpaquePointer?;let status=archive.next(archive.handle,&pointer);if status==1{break}
   guard status==0,let pointer,position<approved.count else{throw Failure.unsafeArchive}
   let e=approved[position];position+=1
   guard let named=archive.name(pointer),String(cString:named).trimmingCharacters(in:CharacterSet(charactersIn:"/"))==e.path,archive.kind(pointer)==e.kind,archive.size(pointer)==e.size else{throw Failure.unsafeArchive}
   let destination=target.appendingPathComponent(e.path)
   if e.kind==0o40000 {try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755]);continue}
   if e.kind==0o120000{continue} // Publish all links last; never traverse one while writing.
   try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
   let fd=open(destination.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,e.executable ? 0o755:0o644)
   guard fd>=0 else{throw Failure.unsafeArchive}
   do {
    var total:Int64=0
    while true {
     try check();let count=archive.read(archive.handle,&buffer,buffer.count);guard count>=0 else{throw Failure.unsafeArchive};if count==0{break}
     total+=Int64(count);guard total<=e.size else{throw Failure.unsafeArchive}
     var offset=0
     while offset<count {let written=buffer.withUnsafeBytes{Darwin.write(fd,$0.baseAddress!.advanced(by:offset),count-offset)};if written<0 && errno==EINTR{continue};guard written>0 else{throw Failure.unsafeArchive};offset+=written}
    }
    guard total==e.size else{throw Failure.unsafeArchive};close(fd)
   }catch{close(fd);throw error}
  }
  guard position==approved.count else{throw Failure.unsafeArchive}
  for e in approved where e.kind==0o120000 {
   try check();let file=target.appendingPathComponent(e.path);try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
   try FileManager.default.createSymbolicLink(atPath:file.path,withDestinationPath:e.link!)
  }
  let allowed=target.appendingPathComponent(expectedRoot).standardizedFileURL.path
  for e in approved where e.kind==0o120000 {
   let file=target.appendingPathComponent(e.path),resolved=file.resolvingSymlinksInPath().standardizedFileURL.path
   guard (resolved==allowed || resolved.hasPrefix(allowed+"/")),FileManager.default.fileExists(atPath:file.path) else{throw Failure.unsafeArchive}
  }
 }
}
