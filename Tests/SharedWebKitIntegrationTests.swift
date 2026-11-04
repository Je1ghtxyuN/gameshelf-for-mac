import AppKit
import WebKit

private final class PageDelegate:NSObject,WKNavigationDelegate {
 var loaded=false
 var error:Error?
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){loaded=true}
 func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error){self.error=error}
 func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error){self.error=error}
}
@main struct SharedWebKitIntegrationTests {
 static func check(_ value:Bool,_ message:String)throws{if !value{throw LibraryError("WebKit acceptance: "+message)}}
 static func wait(_ predicate:()->Bool)throws {
  let deadline=Date().addingTimeInterval(25)
  while !predicate() && Date()<deadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.02)) }
  try check(predicate(),"timed out")
 }
 static func js(_ web:WKWebView,_ body:String)throws->Any {
  var result:Result<Any,Error>?
  web.callAsyncJavaScript(body,arguments:[:],in:nil,in:.page){result=$0}
  try wait{result != nil};return try result!.get()
 }
 static func main()throws {
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.finishLaunching()
  let fm=FileManager.default,root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("SharedWebKit-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
  let assets=root.appendingPathComponent("assets")
  try fm.createDirectory(at:assets.appendingPathComponent("js/libs"),withIntermediateDirectories:true)
  let args=CommandLine.arguments
  func option(_ name:String)->String? {guard let index=args.firstIndex(of:name),args.indices.contains(index+1) else{return nil};return args[index+1]}
  let vendorForage=option("--vendor-forage"),vendorManagers=option("--vendor-managers")
  let original=try vendorForage.map{try String(contentsOfFile:$0,encoding:.utf8)} ?? "window.localforage={getItem(){throw Error('original local database used')},setItem(){throw Error('original local database used')}};"
  try Data(original.utf8).write(to:assets.appendingPathComponent(SharedWebKitSession.adapterPath))
  var managersHTML=""
  if let vendorManagers {
   let managers=try Data(contentsOf:URL(fileURLWithPath:vendorManagers));try managers.write(to:assets.appendingPathComponent("js/rmmz_managers.js"))
   managersHTML="<script>window.Utils={isNwjs:function(){return false}};window.$dataSystem={advanced:{gameId:12345}};</script><script src='js/rmmz_managers.js'></script><script>window.$dataSystem={advanced:{gameId:12345}};</script>"
  }
  try Data(("<html><head><script src='js/libs/localforage.min.js'></script>"+managersHTML+"</head><body>synthetic storage</body></html>").utf8).write(to:assets.appendingPathComponent("index.html"))
  let library=try String(contentsOf:URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("Tools/shared_web_storage.js"),encoding:.utf8)
  var live:[(WKWebView,PageDelegate,SharedWebKitSession,GameResourceServer)]=[]
  defer {
   for (web,_,session,server) in live {
    web.configuration.userContentController.removeScriptMessageHandler(forName:SharedWebKitSession.handlerName,contentWorld:.page)
    web.stopLoading();var drained=false;session.closeAndFlush{drained=true};try? wait{drained};server.stop()
   }
  }
  func page(_ account:String)throws->WKWebView {
   let profile=root.appendingPathComponent(account);try fm.createDirectory(at:profile,withIntermediateDirectories:true)
   let store=try SharedWebSaveStore(profileRoot:profile,identity:account)
   let server=try GameResourceServer(root:assets,scriptSuffixes:[SharedWebKitSession.adapterPath:SharedWebKitSession.resourceSuffix,SharedWebKitSession.managerPath:SharedWebKitSession.managerSuffix])
   let entry=try server.entryURL(relativePath:"index.html"),session=SharedWebKitSession(store:store,entryURL:entry,library:library)
   let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
   config.userContentController.addScriptMessageHandler(session,contentWorld:.page,name:SharedWebKitSession.handlerName)
   config.userContentController.addUserScript(WKUserScript(source:session.documentScript,injectionTime:.atDocumentStart,forMainFrameOnly:true))
   let web=WKWebView(frame:NSRect(x:0,y:0,width:640,height:480),configuration:config),delegate=PageDelegate()
   web.navigationDelegate=delegate;session.webView=web;live.append((web,delegate,session,server))
   web.load(URLRequest(url:entry));try wait{delegate.loaded || delegate.error != nil};if let error=delegate.error{throw error}
   try check(session.accepts(entry),"own origin rejected")
   try check(!session.accepts(URL(string:"https://example.invalid/index.html")!),"external origin accepted")
   return web
  }
  let alice=try page("alice"),bob=try page("bob")
  let validation=try page("validation")
  // Authenticate raw requests independently of the JS facade's own validation.
  // The nonce is already present in this page's injected connector function.
  _ = try js(validation,"""
  const match=window.__GameShelfConnectSharedStorage.toString().match(/nonce:'([^']+)'/);
  if(!match)throw Error('fixture nonce unavailable');
  window.sendValidationRequest=body=>window.webkit.messageHandlers.gameshelfSharedSave.postMessage(Object.assign({nonce:match[1]},body));
  await sendValidationRequest({op:'set',key:'sentinel',value:'keep'});return true;
  """)
  let validationFile=root.appendingPathComponent("validation/WebKitMZ/store.json")
  let validationBytes=try Data(contentsOf:validationFile)
  let validationInode=try fm.attributesOfItem(atPath:validationFile.path)[.systemFileNumber] as? NSNumber
  let rejected=try js(validation,"""
  const bad=[
   ['get with oversized nested value',{op:'get',key:'sentinel',value:Array(64).fill('x'.repeat(16384))}],
   ['clear extra value',{op:'clear',value:'must not clear'}],
   ['keys extra key',{op:'keys',key:'sentinel'}],
   ['get extra string value',{op:'get',key:'sentinel',value:'unused'}],
   ['remove extra value',{op:'remove',key:'sentinel',value:null}],
   ['set missing value',{op:'set',key:'sentinel'}],
   ['set array value',{op:'set',key:'sentinel',value:['not a string']}],
   ['set dictionary value',{op:'set',key:'sentinel',value:{nested:'not a string'}}],
   ['set numeric value',{op:'set',key:'sentinel',value:1}],
   ['set null value',{op:'set',key:'sentinel',value:null}],
   ['set missing key',{op:'set',value:'x'}],
   ['get numeric key',{op:'get',key:1}],
   ['get array key',{op:'get',key:['sentinel']}],
   ['remove dictionary key',{op:'remove',key:{name:'sentinel'}}],
   ['remove missing key',{op:'remove'}],
   ['keys null key',{op:'keys',key:null}],
   ['unknown field',{op:'clear',unexpected:true}],
   ['unknown operation',{op:'unknown'}],
   ['nonstring operation',{op:1}],
   ['oversized UTF8 key',{op:'set',key:'é'.repeat(513),value:'x'}],
   ['oversized UTF8 value',{op:'set',key:'sentinel',value:'😀'.repeat(1048576)+'a'}]
  ];
  for(const [label,body] of bad){
   let rejected=false;
   try{await sendValidationRequest(body);}catch(error){
    if(!String(error).includes('Invalid shared-save request.'))throw Error(label+': reached queue/store instead of strict validation: '+error);
    rejected=true;
   }
   if(!rejected)throw Error(label+': malformed request accepted');
  }
  return bad.length;
  """) as? Int
  try check(rejected==21,"not all malformed raw requests were rejected before queue/store work")
  try check(try Data(contentsOf:validationFile)==validationBytes,"rejected raw requests modified persisted bytes")
  try check(try fm.attributesOfItem(atPath:validationFile.path)[.systemFileNumber] as? NSNumber==validationInode,"rejected raw requests republished the snapshot")
  try check(try js(validation,"""
  if((await sendValidationRequest({op:'get',key:'sentinel'})).value!=='keep')throw Error('sentinel changed');
  const key='é'.repeat(512),value='😀'.repeat(1048576);
  await sendValidationRequest({op:'set',key,value});
  if((await sendValidationRequest({op:'get',key})).value!==value)throw Error('exact UTF8 limits rejected or damaged');
  await sendValidationRequest({op:'remove',key});
  await sendValidationRequest({op:'set',key:'',value:''});
  if((await sendValidationRequest({op:'get',key:''})).value!=='')throw Error('empty strings rejected');
  if(!(await sendValidationRequest({op:'keys'})).value.includes('sentinel'))throw Error('valid keys rejected');
  await sendValidationRequest({op:'clear'});
  return (await sendValidationRequest({op:'keys'})).value.length===0;
  """) as? Bool==true,"strict validation rejected valid op shapes or exact byte boundaries")
  print("PASS strict native bridge: 21 malformed authenticated requests rejected; bytes/inode preserved; all valid operations, empty strings and exact UTF8 limits accepted")
  if vendorManagers != nil {
   try check(try js(alice,"await StorageManager.saveZip('engine-slot','MZ-alice'); await GameShelfSharedWebStorage.flush(); return await StorageManager.loadZip('engine-slot');") as? String=="MZ-alice","actual MZ StorageManager did not use acknowledged network adapter")
   try check(try js(bob,"try { return await StorageManager.loadZip('engine-slot'); } catch (_) { return null; }") is NSNull,"MZ StorageManager crossed accounts")
   try check(try js(alice,"let settled=false;const saving=StorageManager.saveZip('inflight-slot','complete-chain');saving.then(()=>{settled=true;});await GameShelfSharedWebStorage.flush();if(!settled)throw Error('flush ended before engine save');await saving;return await StorageManager.loadZip('inflight-slot');") as? String=="complete-chain","exit flush did not include the complete actual MZ save chain")
  }
  try check(try js(alice,"await localforage.setItem('file1','alice 中文'); await GameShelfSharedWebStorage.flush(); return await localforage.getItem('file1');") as? String=="alice 中文","Alice bridge write/read")
  try check(try js(bob,"return await localforage.getItem('file1');") is NSNull,"Bob inherited Alice progress")
  try check(try js(bob,"await localforage.setItem('file1','bob'); await GameShelfSharedWebStorage.flush(); return await localforage.getItem('file1');") as? String=="bob","Bob bridge write/read")
  try check(try js(alice,"return await localforage.getItem('file1');") as? String=="alice 中文","Alice changed after Bob save")
  _ = try js(alice,"localStorage.setItem('ephemeral','not-roaming'); return true;")
  let reopened=try page("alice")
  try check(try js(reopened,"return await localforage.getItem('file1');") as? String=="alice 中文","private save did not reopen")
  try check(try js(reopened,"return localStorage.getItem('ephemeral');") is NSNull,"browser-local state unexpectedly shared")
  try check(try String(contentsOf:assets.appendingPathComponent(SharedWebKitSession.adapterPath),encoding:.utf8)==original,"script source changed")
  try check(try js(alice,"try { await window.webkit.messageHandlers.gameshelfSharedSave.postMessage({nonce:'wrong',op:'clear'}); return false; } catch (_) { return true; }") as? Bool==true,"invalid bridge nonce accepted")
  _ = try js(alice,"window.SceneManager={_stopped:false,stop(){this._stopped=true},resume(){this._stopped=false}}; await window.__GameShelfPrepareSharedExit(); return true;")
  try check(try js(alice,"return SceneManager._stopped;") as? Bool==true,"exit did not stop new scene writes")
  _ = try js(alice,"SceneManager.resume(); return true;")
  let persisted=root.appendingPathComponent("alice/WebKitMZ/store.json"),beforeFailure=try Data(contentsOf:persisted)
  try Data("corrupt fixture".utf8).write(to:persisted)
  try check(try js(alice,"try { await localforage.setItem('retry','value'); return false; } catch (_) { return true; }") as? Bool==true,"native write failure was hidden")
  try check(try js(alice,"try { await window.__GameShelfPrepareSharedExit(); return false; } catch (_) { return !SceneManager._stopped; }") as? Bool==true,"failed write was silently accepted by flush")
  try check(try Data(contentsOf:persisted)==Data("corrupt fixture".utf8),"failed operation reset stored data")
  try beforeFailure.write(to:persisted,options:.atomic)
  try check(try js(alice,"await localforage.setItem('retry','recovered'); await GameShelfSharedWebStorage.flush(); return true;") as? Bool==true,"successful retry did not clear write failure")
  let session=live.first{$0.0 === alice}!.2;var closed=false;session.closeAndFlush{closed=true};try wait{closed}
  try check(try js(alice,"try { await localforage.setItem('after-close','rejected'); return false; } catch (_) { return true; }") as? Bool==true,"closed bridge accepted another save")
  print("PASS real hidden WebKit: adapted script, native reply ACK, two account saves, reopening and nonpersistent browser state; source unchanged")
 }
}
