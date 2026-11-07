import Foundation
import Darwin

/// Persistent host-local render caches only. No prefix, save, or game data is relocated.
enum WineRenderCachePolicy {
 private static let lock=NSLock()
 private static let failure=LibraryError("无法准备本机渲染缓存，请检查本地缓存目录及权限。")
 static var defaultRoot:URL {
  // Optional host-local override, also used by tests to avoid touching the user's cache.
  if let path=ProcessInfo.processInfo.environment["GAMESHELF_WINE_CACHE_ROOT"] {
   return URL(fileURLWithPath:path)
  }
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GameShelf")
 }
 static func prepare(game:Game,runtime:URL,root:URL=defaultRoot,migrateLegacy:Bool=true)throws->[String:String] {
  lock.lock();defer{lock.unlock()}
  // Compare resolved paths too: an alias must not redirect caches into payloads/saves.
  let identity=game.shared.map{"shared-"+$0.storageKey} ?? "game-"+game.id.uuidString.lowercased()
  let cache=root.appendingPathComponent("WineRenderCache/"+identity)
  let target=cache.resolvingSymlinksInPath().standardizedFileURL.path
  for url in [URL(fileURLWithPath:game.folder),runtime] {
   let forbidden=url.resolvingSymlinksInPath().standardizedFileURL.path
   guard target != forbidden,!target.hasPrefix(forbidden+"/"),!forbidden.hasPrefix(target+"/") else {throw failure}
  }
  let rootFD=try directory(root,create:true);defer{close(rootFD)}
  var volume=statfs()
  guard fstatfs(rootFD,&volume)==0,(volume.f_flags & UInt32(MNT_LOCAL)) != 0 else {throw failure}
  let cacheFD=try directory(cache,create:true);defer{close(cacheFD)}
  // Serialize optional seeding across processes as well as within this process.
  guard flock(cacheFD,LOCK_EX)==0 else {throw failure};defer{flock(cacheFD,LOCK_UN)}
  let state=cache.appendingPathComponent("DXVK"),shader=cache.appendingPathComponent("Shaders"),xdg=cache.appendingPathComponent("XDG")
  let stateFD=try directory(state,create:true);defer{close(stateFD)}
  for url in [shader,xdg] {let fd=try directory(url,create:true);close(fd)}
  if migrateLegacy {migrate(runtime:runtime,destination:stateFD)}
  return ["DXVK_STATE_CACHE_PATH":state.path,"DXVK_SHADER_CACHE_PATH":shader.path,"XDG_CACHE_HOME":xdg.path]
 }

 /// Walk every component with O_NOFOLLOW, including non-final ancestors. System
 /// /var and /tmp aliases are canonicalized explicitly; arbitrary aliases are rejected.
 private static func directory(_ url:URL,create:Bool)throws->Int32 {
  var path=url.standardizedFileURL.path
  if path=="/var" || path.hasPrefix("/var/") || path=="/tmp" || path.hasPrefix("/tmp/") {path="/private"+path}
  var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
  guard fd>=0 else {throw failure}
  for part in path.split(separator:"/").map(String.init) {
   if create {
    var volume=statfs()
    guard fstatfs(fd,&volume)==0,(volume.f_flags & UInt32(MNT_LOCAL)) != 0 else {close(fd);throw failure}
    if mkdirat(fd,part,0o700) != 0 && errno != EEXIST {close(fd);throw failure}
   }
   let next=openat(fd,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
   close(fd)
   guard next>=0 else {throw failure}
   fd=next
  }
  return fd
 }

 /// Best-effort bounded, shallow, copy-only seeding from the old owned Cache.
 /// No game-folder enumeration, symlink traversal, or retry on a completed import.
 private static func migrate(runtime:URL,destination:Int32) {
  let marker=".legacy-imported"
  var st=stat()
  if fstatat(destination,marker,&st,AT_SYMLINK_NOFOLLOW)==0 {return}
  guard let source=try? directory(runtime.appendingPathComponent("Contents/SharedSupport/Cache"),create:false) else {return}
  defer{close(source)}
  guard let stream=fdopendir(dup(source)) else {return}
  defer{closedir(stream)}
  var scanned=0,total=0
  while let entry=readdir(stream),scanned<512 {
   scanned+=1
   let name=withUnsafePointer(to:&entry.pointee.d_name) {pointer in
    pointer.withMemoryRebound(to:CChar.self,capacity:256){String(cString:$0)}
   }
   guard !name.hasPrefix("."),name.hasSuffix(".dxvk-cache"),!name.contains("/"),!name.contains("\\"),!name.contains(":"),!name.unicodeScalars.contains(where:{$0.value<32}) else {continue}
   // Skip any existing destination, including dangling links and empty files.
   guard fstatat(destination,name,&st,AT_SYMLINK_NOFOLLOW) != 0,errno==ENOENT else {continue}
   guard fstatat(source,name,&st,AT_SYMLINK_NOFOLLOW)==0,(st.st_mode & S_IFMT)==S_IFREG,st.st_nlink==1,st.st_size>=12,st.st_size<=64*1024*1024,total+Int(st.st_size)<=256*1024*1024 else {continue}
   let input=openat(source,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
   guard input>=0 else {continue}
   defer{close(input)}
   var before=stat()
   guard fstat(input,&before)==0,(before.st_mode & S_IFMT)==S_IFREG,before.st_nlink==1,before.st_ino==st.st_ino,before.st_dev==st.st_dev,before.st_size==st.st_size else {continue}
   let size=Int(before.st_size)
   total+=size
   var bytes=[UInt8](repeating:0,count:size),offset=0
   while offset<size {
    let count=bytes.withUnsafeMutableBytes{read(input,$0.baseAddress!.advanced(by:offset),size-offset)}
    if count<=0 {break};offset+=count
   }
   var after=stat()
   guard offset==size,bytes.prefix(4)==[68,88,86,75],fstat(input,&after)==0,after.st_size==before.st_size,after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,after.st_ctimespec.tv_sec==before.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==before.st_ctimespec.tv_nsec else {continue}
   let temporary=".import-"+UUID().uuidString
   let output=openat(destination,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
   guard output>=0 else {continue}
   defer{close(output);unlinkat(destination,temporary,0)}
   offset=0
   while offset<size {
    let count=bytes.withUnsafeBytes{write(output,$0.baseAddress!.advanced(by:offset),size-offset)}
    if count<=0 {break};offset+=count
   }
   // linkat is atomic and cannot replace an existing good cache (even in a race).
   if offset==size && fsync(output)==0 {_ = linkat(destination,temporary,destination,name,0)}
  }
  let receipt=openat(destination,marker,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
  if receipt>=0 {close(receipt)}
 }
}
