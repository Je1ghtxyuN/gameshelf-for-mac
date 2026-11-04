import AppKit
import WebKit

/// One page, one account/game store. All disk work is serialized and acknowledged
/// before a save promise resolves; the bridge exposes no filesystem paths.
final class SharedWebKitSession:NSObject,WKScriptMessageHandlerWithReply {
 static let handlerName="gameshelfSharedSave"
 static let adapterPath="js/libs/localforage.min.js"
 static let resourceSuffix=Data("\n;window.__GameShelfConnectSharedStorage();\n".utf8)
 static let managerPath="js/rmmz_managers.js"
 static let managerSuffix=Data("\n;window.GameShelfSharedWebStorage.trackMZEngine(window.StorageManager,window.DataManager,window.ConfigManager);\n".utf8)
 let entryURL:URL
 let documentScript:String
 weak var webView:WKWebView?
 private let store:SharedWebSaveStore
 private let nonce:String
 private let queue=DispatchQueue(label:"GameShelf.shared-web-saves",qos:.userInitiated)
 private let lock=NSLock()
 private var accepting=true
 private var pending=0
 private var pendingBytes=0
 /// Decode before reserving queue budget. Only these typed values may be
 /// retained by the worker; arbitrary bridged arrays/dictionaries never enter.
 private enum Request {
  case get(String),set(String,String),remove(String),keys,clear
  init?(_ body:[String:Any]) {
   guard let op=body["op"] as? String else{return nil}
   let fields:Set<String>
   switch op {
   case "get","remove":fields=["nonce","op","key"]
   case "set":fields=["nonce","op","key","value"]
   case "keys","clear":fields=["nonce","op"]
   default:return nil
   }
   guard Set(body.keys)==fields else{return nil}
   switch op {
   case "get","set","remove":
    guard let key=body["key"] as? String,key.utf8.prefix(1025).count<=1024 else{return nil}
    if op=="set" {
     guard let value=body["value"] as? String,value.utf8.prefix(4*1024*1024+1).count<=4*1024*1024 else{return nil}
     self = .set(key,value)
    }else{self = op=="get" ? .get(key):.remove(key)}
   case "keys":self = .keys
   case "clear":self = .clear
   default:return nil
   }
  }
  var cost:Int {
   switch self {
   case .get(let key),.remove(let key):return key.utf8.count+128
   case .set(let key,let value):return key.utf8.count+value.utf8.count+128
   case .keys,.clear:return 128
   }
  }
 }
 init(store:SharedWebSaveStore,entryURL:URL,library:String) {
  let nonce=UUID().uuidString;self.nonce=nonce
  self.store=store;self.entryURL=entryURL
  documentScript="(function(module,define){\n"+library+"\n})(undefined,undefined);\n"+"""
  window.__GameShelfConnectSharedStorage=function(){
   if(!window.localforage||!window.GameShelfSharedWebStorage)throw Error('Shared save adapter is unavailable');
   const facade=Object.create(null);
   window.GameShelfSharedWebStorage.install(facade,function(request){
    return window.webkit.messageHandlers.gameshelfSharedSave.postMessage(Object.assign({},request,{nonce:'\(nonce)'}));
   });
   // The vendor instance may still finish asynchronous driver selection.
   // Replace it so that it cannot restore its browser-database methods later.
   window.localforage=facade;
  };
  window.__GameShelfPrepareSharedExit=async function(){
   const scene=window.SceneManager,wasStopped=scene&&scene._stopped;
   if(scene&&typeof scene.stop==='function')scene.stop();
   try{await window.GameShelfSharedWebStorage.flush();}
   catch(error){if(scene&&!wasStopped&&typeof scene.resume==='function')scene.resume();throw error;}
  };
  """
  super.init()
 }
 func accepts(_ url:URL)->Bool {
  url.scheme==entryURL.scheme && url.host==entryURL.host && url.port==entryURL.port &&
   url.path.hasPrefix(entryURL.deletingLastPathComponent().path+"/") && url.user==nil && url.password==nil
 }
 func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage,replyHandler:@escaping(Any?,String?)->Void) {
  guard message.name==Self.handlerName,message.webView === webView,message.frameInfo.isMainFrame,
        let source=message.frameInfo.request.url,accepts(source),
        let body=message.body as? [String:Any],body["nonce"] as? String==nonce,
        let request=Request(body) else{replyHandler(nil,"Invalid shared-save request.");return}
  let cost=request.cost
  lock.lock();let allowed=accepting && pending<32 && cost<=4*1024*1024+2048 && pendingBytes<=8*1024*1024-cost
  if allowed {
   pending+=1;pendingBytes+=cost
   queue.async {
    defer{self.lock.lock();self.pending-=1;self.pendingBytes-=cost;self.lock.unlock()}
    do {
     let value:Any
     switch request {
     case .get(let key):value=try self.store.get(key) as Any? ?? NSNull()
     case .set(let key,let text):try self.store.set(key,value:text);value=text
     case .remove(let key):try self.store.remove(key);value=NSNull()
     case .keys:value=try self.store.keys()
     case .clear:try self.store.clear();value=NSNull()
     }
     DispatchQueue.main.async{replyHandler(["value":value],nil)}
    }catch{DispatchQueue.main.async{replyHandler(nil,"个人存档读写失败，请检查连接后重试。")}}
   }
  }
  lock.unlock()
  if !allowed{replyHandler(nil,"Shared-save session is closing or busy; please retry.")}
 }
 /// Lock ordering ensures every accepted write is ahead of this drain barrier.
 func closeAndFlush(_ completion:@escaping()->Void) {
  lock.lock();accepting=false
  queue.async{DispatchQueue.main.async(execute:completion)}
  lock.unlock()
 }
}
