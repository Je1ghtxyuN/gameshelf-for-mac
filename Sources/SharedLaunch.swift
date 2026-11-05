import AppKit

struct SharedLease:Decodable {
 let leaseID:String
 let expiresAt:Double
 let serverID:String
 let userID:String
 let game:SharedCatalogGame
 let profileKey:String
 let share:SharedSMBShare
}
private struct SharedHeartbeat:Decodable {let leaseID:String;let expiresAt:Double}
final class SharedRunningSession {
 let lease:SharedLease
 let mounted:MountedLibraryShare
 let api:SharedAPI
 let token:String
 var timer:Timer?
 var closing=false
 var unmounted=false
 var reportedFailure=false
 init(lease:SharedLease,mounted:MountedLibraryShare,api:SharedAPI,token:String){self.lease=lease;self.mounted=mounted;self.api=api;self.token=token}
 deinit{timer?.invalidate()}
}

extension App {
 func sharedBackgroundToken(for connection:SharedConnection)throws->String?{
  if let token=sharedAccessTokens[connection.id]{return token}
  return try SharedCredentialStore.readWithoutInteraction(connectionID:connection.id)
 }
 func sharedToken(for connection:SharedConnection)throws->String? {
  if let token=sharedAccessTokens[connection.id]{return token}
  return try SharedCredentialStore.read(connectionID:connection.id)
 }
 @objc func showSharedLibrary(){
  do{if sharedLibraryWindow==nil{sharedLibraryWindow=try SharedLibraryWindowController(app:self)};sharedLibraryWindow?.openLibrary();sharedLibraryWindow?.showWindow(nil);sharedLibraryWindow?.window?.makeKeyAndOrderFront(nil)}catch{errorAlert(error)}
 }
 func showSharedAccount(connectionID:UUID){
  do{if sharedLibraryWindow==nil{sharedLibraryWindow=try SharedLibraryWindowController(app:self)};sharedLibraryWindow?.openAccount(connectionID:connectionID);sharedLibraryWindow?.showWindow(nil);sharedLibraryWindow?.window?.makeKeyAndOrderFront(nil)}catch{errorAlert(error)}
 }
 @objc func showDiscovery(){
  do{if discoveryWindow==nil{discoveryWindow=try DiscoveryWindowController(app:self)};discoveryWindow?.showWindow(nil);discoveryWindow?.window?.makeKeyAndOrderFront(nil)}catch{errorAlert(error)}
 }
 func runtimeDataRoot(for game:Game)->URL {game.shared == nil ? runtimeRoot:SharedProfile.localRuntimeRoot(game:game,root:root)}
 func saveDataRoot(for game:Game)throws->URL {game.shared == nil ? runtimeRoot:try SharedProfile.networkProfile(game:game)}
 private func sharedGameIsRunning(_ id:UUID)->Bool {
  wineSessions.contains(id) || running[id]?.isRunning==true || nativeRunning[id]?.isRunning==true || nativeApplications[id].map{!$0.isTerminated}==true || nativeLaunching.contains(id) || active?.id==id || pendingWebLaunch != nil || busy
 }
 func launchShared(_ game:Game){
  guard !busy,let ref=game.shared,sharedSessions[game.id]==nil else{return}
  do {
   let connections=try SharedConnectionStore(root:root)
   guard let connection=connections.connections.first(where:{$0.id==ref.connectionID}),connection.serverID==ref.serverID,connection.accountID==ref.accountID else{throw LibraryError("这个共享库连接不可用。请连接原服务器和账号，个人存档不会自动切换到别的账号。")}
   guard let token=try sharedToken(for:connection) else{showSharedLibrary();throw LibraryError("请先登录这个游戏所属的共享账号。")}
   guard Self.safeSharedID(ref.gameID) else{throw LibraryError("共享游戏标识无效。")}
   let client=try SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256)
   let device:String
   if let existing=UserDefaults.standard.string(forKey:"SharedDeviceID"){device=existing}else{device=UUID().uuidString;UserDefaults.standard.set(device,forKey:"SharedDeviceID")}
   setBusy(true,"正在连接共享游戏库…")
   client.request("/api/games/"+ref.gameID+"/session",method:"POST",token:token,body:["deviceID":device]){[weak self] (result:Result<SharedLease,Error>) in
    guard let self else{return}
    switch result {
    case .failure(let error):self.preparationReady{self.setBusy(false,"");self.errorAlert(error)}
    case .success(let lease):
     DispatchQueue.global(qos:.userInitiated).async {
      var mounted:MountedLibraryShare?
      do {
       guard Self.safeSharedID(lease.leaseID),lease.serverID==ref.serverID,lease.userID==ref.accountID,lease.game.id==ref.gameID,lease.game.entries.contains(game.entry),lease.expiresAt>Date().timeIntervalSince1970 else{throw LibraryError("服务器会话身份、有效期或游戏入口不匹配，未启动。")}
       let target=self.root.appendingPathComponent("NetworkMounts/"+ref.storageKey)
       let receipts=self.root.appendingPathComponent("NetworkReceipts")
       try FileManager.default.createDirectory(at:receipts,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
       let receipt=receipts.appendingPathComponent(ref.storageKey+".json")
       // A new server lease is the prerequisite: it proves an old server
       // writer was revoked. Locally, recover only an exact private receipt.
       if let stale=try NetworkLibraryMount.recoverReceipt(at:receipt,target:target,identityKey:ref.storageKey) {
        try NetworkLibraryMount.unmount(stale)
        _ = try NetworkLibraryMount.recoverReceipt(at:receipt,target:target,identityKey:ref.storageKey)
       }
       try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
       let mount=try NetworkLibraryMount.mount(share:lease.share,at:target);mounted=mount
       try NetworkLibraryMount.persistReceipt(mounted:mount,identityKey:ref.storageKey,to:receipt)
       guard mount.url.standardizedFileURL==URL(fileURLWithPath:game.folder).standardizedFileURL else{throw LibraryError("共享游戏挂载位置发生变化，未使用其他目录。")}
       _ = try SharedProfile.networkProfile(game:game)
       try FileManager.default.createDirectory(at:self.runtimeDataRoot(for:game),withIntermediateDirectories:true)
       self.preparationReady {
        guard !self.quitting else{self.discardShared(lease:lease,mount:mount,api:client,token:token);return}
        let session=SharedRunningSession(lease:lease,mounted:mount,api:client,token:token);self.sharedSessions[game.id]=session
        let timer=Timer(timeInterval:25,repeats:true){[weak self] _ in self?.heartbeatShared(game.id)};session.timer=timer;RunLoop.main.add(timer,forMode:.common)
        self.setBusy(false,"");self.launch(game)
        // Preparation errors are synchronous or asynchronous; an idle session
        // is released by the next heartbeat if no launcher remains active.
       }
      }catch {
       self.discardShared(lease:lease,mount:mounted,api:client,token:token)
       self.preparationReady{self.setBusy(false,"");self.errorAlert(error)}
      }
     }
    }
   }
  }catch{errorAlert(error)}
 }
 private static func safeSharedID(_ value:String)->Bool {!value.isEmpty && value.count<=128 && value.unicodeScalars.allSatisfy{CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)}}
 private func discardShared(lease:SharedLease,mount:MountedLibraryShare?,api:SharedAPI,token:String){
  DispatchQueue.global(qos:.utility).async {
   if let mount{try? NetworkLibraryMount.unmount(mount)}
   if Self.safeSharedID(lease.leaseID){api.request("/api/sessions/"+lease.leaseID,method:"DELETE",token:token){(_:Result<SharedOK,Error>) in}}
  }
 }
 func heartbeatShared(_ id:UUID){
  guard let session=sharedSessions[id],!session.closing else{return}
  if !sharedGameIsRunning(id){releaseShared(id);return}
  session.api.request("/api/sessions/"+session.lease.leaseID+"/heartbeat",method:"POST",token:session.token,body:[:]){[weak self,weak session] (result:Result<SharedHeartbeat,Error>) in DispatchQueue.main.async {
   guard let self,let session,self.sharedSessions[id] === session else{return}
   if case .failure = result,!session.reportedFailure {session.reportedFailure=true;self.showStatus("共享会话暂时无法续期。请检查连接；网络中断可能影响存档，请勿在其他设备重复打开此游戏。")}
  }}
 }
 func releaseShared(_ id:UUID){
  guard let session=sharedSessions[id],!session.closing,!sharedGameIsRunning(id) else{return}
  session.closing=true
  DispatchQueue.global(qos:.utility).async {
   do {
    // Unmount first so the operating system flushes outstanding writes.
    if !session.unmounted {try NetworkLibraryMount.unmount(session.mounted)}
    DispatchQueue.main.async {
     session.unmounted=true
     session.api.request("/api/sessions/"+session.lease.leaseID,method:"DELETE",token:session.token){[weak self,weak session] (result:Result<SharedOK,Error>) in DispatchQueue.main.async {
     guard let self,let session,self.sharedSessions[id] === session else{return}
     switch result {
     case .success:session.timer?.invalidate();self.sharedSessions.removeValue(forKey:id);self.showStatus("共享游戏已退出，个人会话已关闭。")
     case .failure(let error):
      let status=(error as? SharedRequestError)?.statusCode
      if status==404 || status==401 || status==403 {
       // The local writer is already flushed and gone. A missing lease is
       // closed; revoked/expired credentials cannot be retried forever with
       // this captured token. Any surviving remote lease expires without its
       // heartbeat and must still pass the server's next-writer barrier.
       session.timer?.invalidate();self.sharedSessions.removeValue(forKey:id)
       self.showStatus(status==404 ? "共享游戏已退出，个人会话已关闭。":"共享游戏已退出，请重新登录共享库。")
      }else{session.closing=false;self.showStatus("网络共享已卸载，正在等待服务器关闭个人会话。")}
     }
     }}
    }
   }catch{DispatchQueue.main.async{session.closing=false;self.showStatus("网络目录仍被占用，暂未关闭会话；请关闭正在访问它的窗口或程序。")}}
  }
 }
}
