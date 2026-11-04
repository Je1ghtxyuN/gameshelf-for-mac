import AppKit
import WebKit

extension App {
 func prepareSharedWeb(_ game:Game) {
  guard let ref=game.shared else{return}
  let request=UUID();pendingWebLaunch=request;setBusy(true,"正在准备游戏存档…")
  DispatchQueue.global(qos:.userInitiated).async {
   let result:Result<(GameResourceServer,SharedWebKitSession),Error>=Result {
    let folder=URL(fileURLWithPath:game.folder)
    guard game.entry.path=="index.html",MZWebProfile.matches(at:folder) else{throw LibraryError("此网页引擎的账号存档尚未适配，请选择可用的 Windows 入口。")}
    let adapter=folder.appendingPathComponent(SharedWebKitSession.adapterPath)
    let attributes=try FileManager.default.attributesOfItem(atPath:adapter.path)
    guard let bytes=attributes[.size] as? NSNumber,bytes.int64Value>0,bytes.int64Value<=2*1024*1024 else{throw LibraryError("网页存储组件不可用。")}
    guard let tool=Bundle.main.url(forResource:"shared_web_storage",withExtension:"js",subdirectory:"Tools"),let library=try? String(contentsOf:tool,encoding:.utf8),library.utf8.count<=262144 else{throw LibraryError("缺少共享存档组件。")}
    let profile=try SharedProfile.networkProfile(game:game)
    let store=try SharedWebSaveStore(profileRoot:profile,identity:ref.storageKey)
    let server=try GameResourceServer(root:folder,scriptSuffixes:[SharedWebKitSession.adapterPath:SharedWebKitSession.resourceSuffix,SharedWebKitSession.managerPath:SharedWebKitSession.managerSuffix])
    do {
     _ = try server.entryURL(relativePath:SharedWebKitSession.adapterPath)
     let entry=try server.entryURL(relativePath:game.entry.path)
     return (server,SharedWebKitSession(store:store,entryURL:entry,library:library))
    }catch{server.stop();throw error}
   }
   self.preparationReady {
    guard self.pendingWebLaunch==request else{if case .success(let value)=result{value.0.stop()};return}
    self.pendingWebLaunch=nil;self.setBusy(false,"")
    switch result {
    case .success(let value):self.gameResourceServer=value.0;self.sharedWebKitSession=value.1;self.playWeb(game,entry:URL(fileURLWithPath:game.folder).appendingPathComponent(game.entry.path),folder:URL(fileURLWithPath:game.folder),hostedEntry:value.1.entryURL,sharedSession:value.1)
    case .failure(let error):self.errorAlert(error);self.releaseShared(game.id)
    }
   }
  }
 }
}
