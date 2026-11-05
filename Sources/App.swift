import AppKit
import WebKit
import UniformTypeIdentifiers

class ActionButton:NSButton {
 var actionBlock:(()->Void)?
 var menuProvider:(()->NSMenu?)?
 var opensMenuOnClick=false
 convenience init(_ text:String,_ action:@escaping ()->Void){self.init(title:text,target:nil,action:nil);self.actionBlock=action;target=self;self.action=#selector(invoke);bezelStyle = .rounded}
 @objc func invoke(){if opensMenuOnClick,let menu=menuProvider?(){menu.popUp(positioning:nil,at:NSPoint(x:0,y:bounds.height),in:self)}else{actionBlock?()}}
 override func menu(for event:NSEvent)->NSMenu?{menuProvider?() ?? super.menu(for:event)}
}
final class ActionMenuItem:NSMenuItem {
 var actionBlock:(()->Void)?
 init(_ text:String,_ action:@escaping()->Void){super.init(title:text,action:nil,keyEquivalent:"");actionBlock=action;target=self;self.action=#selector(invoke)}
 required init(coder:NSCoder){fatalError()}
 @objc func invoke(){actionBlock?()}
}
final class NavigationButton:ActionButton {
 var symbol="square.grid.2x2"
 var selected=false
 override func draw(_ dirtyRect:NSRect){
  if selected {NSColor(calibratedWhite:0.86,alpha:1).setFill();NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:9,yRadius:9).fill()}
  let image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:17,weight:.regular))
  image?.draw(in:NSRect(x:15,y:(bounds.height-20)/2,width:20,height:20))
  let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14,weight:selected ? .semibold:.regular),.foregroundColor:NSColor.labelColor]
  (title as NSString).draw(at:NSPoint(x:47,y:(bounds.height-18)/2),withAttributes:attrs)
 }
}
final class CoverButton:ActionButton {
 var game:Game!
 var coverImage:NSImage?
 override func draw(_ dirtyRect:NSRect){
  let r=bounds.insetBy(dx:1,dy:1)
  let p=NSBezierPath(roundedRect:r,xRadius:9,yRadius:9)
  NSGraphicsContext.saveGraphicsState();p.addClip()
  if let coverImage,coverImage.size.width>0,coverImage.size.height>0 {
   // Official artwork often uses landscape banners. Fit the whole image so
   // titles and logos remain readable instead of cropping it into a portrait.
   NSColor(calibratedWhite:0.94,alpha:1).setFill();p.fill()
   let scale=min(r.width/coverImage.size.width,r.height/coverImage.size.height)
   let target=NSRect(x:r.midX-coverImage.size.width*scale/2,y:r.midY-coverImage.size.height*scale/2,width:coverImage.size.width*scale,height:coverImage.size.height*scale)
   coverImage.draw(in:target,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
  }
  else {
   let n=game.title.unicodeScalars.reduce(0){($0+Int($1.value))%360}
   NSGradient(starting:NSColor(calibratedHue:CGFloat(n)/360,saturation:0.21,brightness:0.7,alpha:1),ending:NSColor(calibratedHue:CGFloat(n)/360,saturation:0.36,brightness:0.28,alpha:1))?.draw(in:r,angle:270)
   let style=NSMutableParagraphStyle();style.alignment = .center
   let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:23,weight:.medium),.foregroundColor:NSColor.white,.paragraphStyle:style]
   let text=NSAttributedString(string:game.title,attributes:attrs)
   let rect=NSRect(x:16,y:r.midY-40,width:r.width-32,height:100)
   text.draw(with:rect,options:[.usesLineFragmentOrigin,.truncatesLastVisibleLine])
  }
  NSGraphicsContext.restoreGraphicsState()
 }
 override var acceptsFirstResponder:Bool{true}
 override func keyDown(with event:NSEvent){if event.keyCode==36 || event.keyCode==49 {actionBlock?()} else {super.keyDown(with:event)}}
}
final class FlippedView:NSView { override var isFlipped:Bool{true} }
final class ShelfView:NSView {
 var dropped:(([URL])->Void)?
 override init(frame:NSRect){super.init(frame:frame);registerForDraggedTypes([.fileURL])}
 required init?(coder:NSCoder){fatalError()}
 override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation{.copy}
 override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
  let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
  if urls.isEmpty{return false};dropped?(urls);return true
 }
}
final class App:NSObject,NSApplicationDelegate,NSSearchFieldDelegate,WKNavigationDelegate,WKUIDelegate,WKScriptMessageHandler {
 var propertyWindows:[UUID:GamePropertiesController]=[:]
 var settingsWindow:SettingsWindowController?
 var discoveryWindow:DiscoveryWindowController?
 var sharedLibraryWindow:SharedLibraryWindowController?
 var sharedSessions:[UUID:SharedRunningSession]=[:]
 var sharedAccessTokens=SharedSessionTokens()
 var saveMigrationPlans:[UUID:MZSaveArchive]=[:]
 var sharedWebKitSession:SharedWebKitSession?
 var leavingWebGame=false
 var window:NSWindow!
 var store:LibraryStore!
 var playtime:PlaytimeStore?
 var playtimeRecorder:PlaytimeRecorder?
 var pendingPlaytimeError:String?
 var playtimeTimer:Timer?
 var personalLibraryTimer:Timer?
 var personalSyncing=false
 var onboardingWindow:OnboardingWindowController?
 var playtimeLabels:[UUID:NSTextField]=[:]
 var playtimeReportedFailure=false
 var container:NSView!
 var toolbar:NSStackView!
 var content:NSView!
 var status:NSTextField!
 var statusMessage=""
 var statusHeight:NSLayoutConstraint?
 var statusSpinner:NSProgressIndicator?
 var busySince:Date?
 var statusTimer:Timer?
 var search=NSSearchField()
 var filter="all"
 var collapsedCollections=Set(UserDefaults.standard.stringArray(forKey:"CollapsedCollections") ?? [])
 var web:WKWebView?
 var gameResourceServer:GameResourceServer?
 var pendingWebLaunch:UUID?
 var active:Game?
 var coverRequests:Set<UUID>=[]
 var quitPromptOpen=false
 var deferredPreparations:[()->Void]=[]
 var quitting=false
 var busy=false
 var running:[UUID:Process]=[:]
 var wineSessions:Set<UUID>=[]
 var nativeRunning:[UUID:Process]=[:]
 var nativeApplications:[UUID:NSRunningApplication]=[:]
 var nativeLaunching:Set<UUID>=[]
 var runtimeRoot:URL {
  if let path=UserDefaults.standard.string(forKey:"RuntimeDataRoot"){return URL(fileURLWithPath:path)}
  return root
 }
 var root:URL {
  if let i=CommandLine.arguments.firstIndex(of:"--data-dir"),CommandLine.arguments.indices.contains(i+1){return URL(fileURLWithPath:CommandLine.arguments[i+1])}
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GameShelf")
 }
 func applicationDidFinishLaunching(_ notification:Notification){
  if let icon=Bundle.main.url(forResource:"AppIcon",withExtension:"icns").flatMap({NSImage(contentsOf:$0)}){NSApp.applicationIconImage=icon}
  do{store=try LibraryStore(root:root)}catch{errorAlert(error);NSApp.terminate(nil);return}
  if !FileManager.default.fileExists(atPath:root.appendingPathComponent("collections.json").path){
   do{for name in ["SLG","RPG","视觉小说"]{_ = try store.createCollection(name:name)}}catch{errorAlert(error)}
  }
  var playtimeError:Error?
  do{let history=try PlaytimeStore(root:root);playtime=history;playtimeRecorder=PlaytimeRecorder(store:history)}catch{playtimeError=error}
  setupMenu()
  window=NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  window.title="游戏库";window.appearance=NSAppearance(named:.aqua);window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.minSize=NSSize(width:780,height:520);window.center()
  window.setFrameAutosaveName("GameShelfMain")
  showLibrary();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
  if let error=playtimeError{showStatus("时长记录暂不可用，已有数据保留："+error.localizedDescription)}
  let timer=Timer(timeInterval:15,repeats:true){[weak self] _ in self?.checkpointPlaytime()}
  playtimeTimer=timer;RunLoop.main.add(timer,forMode:.common)
  let profileTimer=Timer(timeInterval:60,repeats:true){[weak self] _ in self?.syncPersonalLibrary()}
  personalLibraryTimer=profileTimer;RunLoop.main.add(profileTimer,forMode:.common)
  syncPersonalLibrary()
  let workspace=NSWorkspace.shared.notificationCenter
  workspace.addObserver(self,selector:#selector(playtimeWillSleep),name:NSWorkspace.willSleepNotification,object:nil)
  workspace.addObserver(self,selector:#selector(playtimeDidWake),name:NSWorkspace.didWakeNotification,object:nil)
  workspace.addObserver(self,selector:#selector(playtimeApplicationEnded(_:)),name:NSWorkspace.didTerminateApplicationNotification,object:nil)
  if let i=CommandLine.arguments.firstIndex(of:"--open-game"),CommandLine.arguments.indices.contains(i+1){importURLs([URL(fileURLWithPath:CommandLine.arguments[i+1])])}
  else{showOnboardingIfNeeded()}
 }
 func setupMenu(){
  let menu=NSMenu();NSApp.mainMenu=menu
  let appItem=NSMenuItem();menu.addItem(appItem);let a=NSMenu();appItem.submenu=a
  a.addItem(withTitle:"关于 游戏库",action:#selector(about),keyEquivalent:"").target=self
  a.addItem(withTitle:"设置…",action:#selector(settings),keyEquivalent:",").target=self
  a.addItem(.separator());a.addItem(withTitle:"退出 游戏库",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
  let file=NSMenuItem();menu.addItem(file);let f=NSMenu(title:"文件");file.submenu=f
  f.addItem(withTitle:"扫描游戏…",action:#selector(showDiscovery),keyEquivalent:"o").target=self
  f.addItem(withTitle:"连接共享游戏库…",action:#selector(showSharedLibrary),keyEquivalent:"k").target=self
  f.addItem(.separator())
  f.addItem(withTitle:"手动添加游戏…",action:#selector(importPanel),keyEquivalent:"").target=self
  let edit=NSMenuItem();menu.addItem(edit);let e=NSMenu(title:"编辑");edit.submenu=e
  for (title,action,key) in [("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")]{e.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)}
  let view=NSMenuItem();menu.addItem(view);let v=NSMenu(title:"显示");view.submenu=v
  v.addItem(withTitle:"切换全屏",action:#selector(NSWindow.toggleFullScreen(_:)),keyEquivalent:"f").keyEquivalentModifierMask=[.command,.control]
 }
 func label(_ text:String,size:CGFloat=14,weight:NSFont.Weight = .regular)->NSTextField{let l=NSTextField(labelWithString:text);l.font=NSFont.systemFont(ofSize:size,weight:weight);return l}
 func stack(_ views:[NSView],vertical:Bool=false,spacing:CGFloat=10)->NSStackView{let s=NSStackView(views:views);s.orientation=vertical ? .vertical:.horizontal;s.spacing=spacing;s.alignment=vertical ? .leading:.centerY;return s}
 func pin(_ view:NSView,to parent:NSView,inset:CGFloat=0){view.translatesAutoresizingMaskIntoConstraints=false;parent.addSubview(view);NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),view.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])}
 func showLibrary(){
  guard active==nil else{return}
  window.title="游戏库"
  let shell=ShelfView();shell.dropped={[weak self] urls in
   guard let self else{return}
   if urls.allSatisfy({$0.pathExtension.lowercased() != "exe"}){self.showDiscovery();self.discoveryWindow?.addDirectories(urls)}else{self.importURLs(urls)}
  }
  window.contentView=shell
  let side=NSView();side.wantsLayer=true;side.layer?.backgroundColor=NSColor(calibratedWhite:0.935,alpha:1).cgColor
  side.widthAnchor.constraint(equalToConstant:240).isActive=true
  let brandIcon=NSImageView(image:NSImage(systemSymbolName:"gamecontroller",accessibilityDescription:nil)!)
  brandIcon.widthAnchor.constraint(equalToConstant:24).isActive=true
  let brand=stack([brandIcon,label("游戏库",size:18,weight:.semibold)],spacing:10)
  let nav=stack([],vertical:true,spacing:2)
  let brandWrap=NSView();pin(brand,to:brandWrap,inset:12);brandWrap.heightAnchor.constraint(equalToConstant:56).isActive=true
  nav.addArrangedSubview(brandWrap)
  for (key,name,symbol) in [("all","所有游戏","square.grid.2x2"),("recent","最近游玩","clock"),("favorite","收藏","heart")]{
   let button=NavigationButton(name){[weak self] in self?.filter=key;self?.showLibrary()}
   button.symbol=symbol;button.selected=filter==key;button.isBordered=false
   button.widthAnchor.constraint(equalToConstant:216).isActive=true;button.heightAnchor.constraint(equalToConstant:34).isActive=true;nav.addArrangedSubview(button)
  }
  nav.translatesAutoresizingMaskIntoConstraints=false;side.addSubview(nav)
  NSLayoutConstraint.activate([nav.leadingAnchor.constraint(equalTo:side.leadingAnchor,constant:12),nav.trailingAnchor.constraint(equalTo:side.trailingAnchor,constant:-12),nav.topAnchor.constraint(equalTo:side.topAnchor,constant:6)])
  let settings=NavigationButton("设置"){[weak self] in self?.settings()};settings.symbol="gearshape";settings.isBordered=false
  settings.translatesAutoresizingMaskIntoConstraints=false;side.addSubview(settings)
  NSLayoutConstraint.activate([settings.leadingAnchor.constraint(equalTo:side.leadingAnchor,constant:12),settings.trailingAnchor.constraint(equalTo:side.trailingAnchor,constant:-12),settings.bottomAnchor.constraint(equalTo:side.bottomAnchor,constant:-12),settings.heightAnchor.constraint(equalToConstant:36)])
  let heading=label("分类",size:12,weight:.semibold);heading.textColor = .secondaryLabelColor
  let plus=ActionButton(""){[weak self] in self?.createCollection()};plus.image=NSImage(systemSymbolName:"plus",accessibilityDescription:"新建分类");plus.setAccessibilityLabel("新建分类");plus.isBordered=false;plus.widthAnchor.constraint(equalToConstant:24).isActive=true
  let categoryHeader=stack([heading,NSView(),plus],spacing:6);categoryHeader.translatesAutoresizingMaskIntoConstraints=false;side.addSubview(categoryHeader)
  NSLayoutConstraint.activate([categoryHeader.leadingAnchor.constraint(equalTo:side.leadingAnchor,constant:22),categoryHeader.trailingAnchor.constraint(equalTo:side.trailingAnchor,constant:-16),categoryHeader.topAnchor.constraint(equalTo:nav.bottomAnchor,constant:16),categoryHeader.heightAnchor.constraint(equalToConstant:24)])
  let categoryScroll=NSScrollView();categoryScroll.drawsBackground=false;categoryScroll.hasVerticalScroller=true;categoryScroll.autohidesScrollers=true;categoryScroll.translatesAutoresizingMaskIntoConstraints=false;side.addSubview(categoryScroll)
  NSLayoutConstraint.activate([categoryScroll.leadingAnchor.constraint(equalTo:side.leadingAnchor,constant:10),categoryScroll.trailingAnchor.constraint(equalTo:side.trailingAnchor,constant:-10),categoryScroll.topAnchor.constraint(equalTo:categoryHeader.bottomAnchor,constant:4),categoryScroll.bottomAnchor.constraint(equalTo:settings.topAnchor,constant:-12)])
  let tree=FlippedView();categoryScroll.documentView=tree;tree.translatesAutoresizingMaskIntoConstraints=false
  NSLayoutConstraint.activate([tree.widthAnchor.constraint(equalTo:categoryScroll.contentView.widthAnchor),tree.leadingAnchor.constraint(equalTo:categoryScroll.contentView.leadingAnchor),tree.topAnchor.constraint(equalTo:categoryScroll.contentView.topAnchor)])
  let groups=stack([],vertical:true,spacing:3);pin(groups,to:tree)
  for collection in store.collections{appendCollectionRow(id:collection.id.uuidString,name:collection.name,games:store.games(inCollection:collection.id),to:groups)}
  appendCollectionRow(id:"uncategorized",name:"未分类",games:store.uncategorizedGames,to:groups)
  let main=NSView();main.wantsLayer=true;main.layer?.backgroundColor=NSColor.white.cgColor
  let all=stack([side,main],spacing:0);all.alignment = .top;pin(all,to:shell)
  main.widthAnchor.constraint(equalTo:shell.widthAnchor,constant:-240).isActive=true
  side.heightAnchor.constraint(equalTo:all.heightAnchor).isActive=true;main.heightAnchor.constraint(equalTo:all.heightAnchor).isActive=true
  let title=label(currentFilterTitle(),size:14,weight:.semibold)
  search.placeholderString="搜索游戏";search.delegate=self;search.widthAnchor.constraint(equalToConstant:190).isActive=true;search.focusRingType = .none
  let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
  let importButton=ActionButton("添加游戏库"){[weak self] in self?.showDiscovery()};importButton.image=NSImage(systemSymbolName:"folder.badge.plus",accessibilityDescription:nil);importButton.imagePosition = .imageLeading;importButton.controlSize = .large
  let sharedButton=ActionButton("共享库"){[weak self] in self?.showSharedLibrary()};sharedButton.image=NSImage(systemSymbolName:"network",accessibilityDescription:nil);sharedButton.imagePosition = .imageLeading
  let top=stack(filter=="all" ? [title,spacer,search,sharedButton,importButton]:[title,spacer,search],spacing:18)
  let topWrap=NSView();pin(top,to:topWrap,inset:22);topWrap.heightAnchor.constraint(equalToConstant:70).isActive=true
  let line=NSBox();line.boxType = .separator
  let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false
  let scrollWrap=NSView();pin(scroll,to:scrollWrap,inset:30)
  status=label(statusMessage,size:13);status.textColor = .labelColor;status.lineBreakMode = .byTruncatingMiddle
  status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
  let spinner=NSProgressIndicator();spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false
  spinner.widthAnchor.constraint(equalToConstant:16).isActive=true;spinner.heightAnchor.constraint(equalToConstant:16).isActive=true;statusSpinner=spinner
  let statusRow=stack([spinner,status,NSView()],spacing:10)
  let statusWrap=NSView();statusWrap.wantsLayer=true;statusWrap.layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor
  statusRow.translatesAutoresizingMaskIntoConstraints=false;statusWrap.addSubview(statusRow)
  NSLayoutConstraint.activate([statusRow.leadingAnchor.constraint(equalTo:statusWrap.leadingAnchor,constant:22),statusRow.trailingAnchor.constraint(equalTo:statusWrap.trailingAnchor,constant:-22),statusRow.centerYAnchor.constraint(equalTo:statusWrap.centerYAnchor)])
  statusHeight=statusWrap.heightAnchor.constraint(equalToConstant:0);statusHeight?.isActive=true
  let layout=stack([topWrap,line,statusWrap,scrollWrap],vertical:true,spacing:0);pin(layout,to:main)
  for v in [topWrap,line,statusWrap,scrollWrap] {v.widthAnchor.constraint(equalTo:layout.widthAnchor).isActive=true}
  refreshStatus()
  content=scroll
  renderCards()
 }
 func currentFilterTitle()->String {
  if let title=["all":"所有游戏","recent":"最近游玩","favorite":"收藏","uncategorized":"未分类"][filter]{return title}
  if let id=UUID(uuidString:filter),let group=store.collections.first(where:{$0.id==id}){return group.name}
  if filter.hasPrefix("game:"),let id=UUID(uuidString:String(filter.dropFirst(5))),let game=store.games.first(where:{$0.id==id}){return game.title}
  return "所有游戏"
 }
 func appendCollectionRow(id:String,name:String,games:[Game],to groups:NSStackView){
  let collapsed=collapsedCollections.contains(id)
  let arrow=ActionButton(""){[weak self] in
   guard let self else{return};if self.collapsedCollections.contains(id){self.collapsedCollections.remove(id)}else{self.collapsedCollections.insert(id)}
   UserDefaults.standard.set(Array(self.collapsedCollections),forKey:"CollapsedCollections");self.showLibrary()
  }
  arrow.image=NSImage(systemSymbolName:collapsed ? "chevron.right":"chevron.down",accessibilityDescription:nil);arrow.setAccessibilityLabel((collapsed ? "展开 ":"折叠 ")+name);arrow.isBordered=false;arrow.widthAnchor.constraint(equalToConstant:18).isActive=true
  let select=ActionButton(name+"  ("+String(games.count)+")"){[weak self] in self?.filter=id;self?.search.stringValue="";self?.showLibrary()};select.font = .systemFont(ofSize:12,weight:.semibold);select.lineBreakMode = .byTruncatingTail;select.toolTip=name;select.alignment = .left;select.isBordered=false;select.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
  if filter==id{select.contentTintColor = .controlAccentColor}
  var pieces:[NSView]=[arrow,select,NSView()]
  if let uuid=UUID(uuidString:id){let more=ActionButton("⋯"){[weak self] in self?.manageCollection(uuid)};more.isBordered=false;more.widthAnchor.constraint(equalToConstant:22).isActive=true;more.setAccessibilityLabel("管理分类 "+name);pieces.append(more)}
  let header=stack(pieces,spacing:2);header.heightAnchor.constraint(equalToConstant:29).isActive=true;groups.addArrangedSubview(header);header.widthAnchor.constraint(equalTo:groups.widthAnchor).isActive=true
  guard !collapsed else{return}
  for game in games.sorted(by:{$0.title.localizedStandardCompare($1.title) == .orderedAscending}) {
   let button=ActionButton(game.title){[weak self] in self?.filter="game:"+game.id.uuidString;self?.search.stringValue="";self?.showLibrary()}
   button.menuProvider={[weak self] in self?.gameMenu(game.id)}
   button.isBordered=false;button.font = .systemFont(ofSize:12);button.alignment = .left;button.lineBreakMode = .byTruncatingTail;button.imagePosition = .imageLeading;button.imageHugsTitle=true
   let icon=game.cover.flatMap{NSImage(contentsOfFile:$0)} ?? NSImage(systemSymbolName:"gamecontroller",accessibilityDescription:nil)
   icon?.size=NSSize(width:18,height:18);button.image=icon;button.toolTip=game.title;button.setAccessibilityLabel("选择游戏 "+game.title)
   if filter=="game:"+game.id.uuidString{button.contentTintColor = .controlAccentColor}
   let indent=NSView();indent.widthAnchor.constraint(equalToConstant:24).isActive=true
   let row=stack([indent,button],spacing:3);row.heightAnchor.constraint(equalToConstant:26).isActive=true;groups.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:groups.widthAnchor).isActive=true
  }
 }
 func gameMenu(_ id:UUID)->NSMenu? {
  guard let game=store.games.first(where:{$0.id==id}) else{return nil}
  let menu=NSMenu();menu.autoenablesItems=false
  func item(_ title:String,_ action:@escaping()->Void)->ActionMenuItem{let i=ActionMenuItem(title,action);i.isEnabled = !busy;return i}
  menu.addItem(item("开始游戏"){[weak self] in self?.launch(game)})
  menu.addItem(item(game.favorite ? "取消收藏":"添加至收藏"){[weak self] in guard let self,!self.busy else{return};var updated=game;updated.favorite.toggle();do{try self.store.update(updated);self.showLibrary()}catch{self.errorAlert(error)}})
  menu.addItem(.separator())
  let selected=store.collectionIDs(for:id)
  let add=NSMenuItem(title:"添加至",action:nil,keyEquivalent:"");let addMenu=NSMenu();addMenu.autoenablesItems=false;add.isEnabled = !busy
  for group in store.collections {
   let i=item(group.name){[weak self] in self?.changeMembership(id,collection:group.id,adding:true)}
   i.isEnabled = !busy && !selected.contains(group.id);if selected.contains(group.id){i.state = .on};addMenu.addItem(i)
  }
  if !store.collections.isEmpty{addMenu.addItem(.separator())}
  addMenu.addItem(item("新建分类…"){[weak self] in self?.createCollection(assignTo:id)})
  add.submenu=addMenu;menu.addItem(add)
  let remove=NSMenuItem(title:"移除出分类",action:nil,keyEquivalent:"");let removeMenu=NSMenu();removeMenu.autoenablesItems=false
  for group in store.collections where selected.contains(group.id){removeMenu.addItem(item(group.name){[weak self] in self?.changeMembership(id,collection:group.id,adding:false)})}
  remove.submenu=removeMenu;remove.isEnabled = !busy && !selected.isEmpty;menu.addItem(remove)
  menu.addItem(item("管理分类…"){[weak self] in self?.manageGameCollections(game)})
  menu.addItem(.separator())
  menu.addItem(item("在 Finder 中显示"){NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:game.folder)})
  menu.addItem(item("属性…"){[weak self] in self?.details(game)})
  return menu
 }
 func changeMembership(_ id:UUID,collection:UUID,adding:Bool){
  guard !busy else{return};var selected=store.collectionIDs(for:id)
  if adding{selected.insert(collection)}else{selected.remove(collection)}
  do{try store.setCollections(for:id,ids:selected);showLibrary()}catch{errorAlert(error)}
 }
 func createCollection(assignTo gameID:UUID?=nil){
  guard !busy else{return}
  let a=NSAlert();a.messageText="新建分类";let field=NSTextField(string:"");field.placeholderString="例如：SLG、东方、待游玩";field.frame=NSRect(x:0,y:0,width:320,height:26);a.accessoryView=field;a.addButton(withTitle:"创建");a.addButton(withTitle:"取消")
  guard a.runModal() == .alertFirstButtonReturn else{return}
  do{let group=try store.createCollection(name:field.stringValue);if let gameID{try store.setCollections(for:gameID,ids:store.collectionIDs(for:gameID).union([group.id]))};filter=group.id.uuidString;showLibrary()}catch{errorAlert(error)}
 }
 func manageCollection(_ id:UUID){
  guard !busy,let group=store.collections.first(where:{$0.id==id}) else{return}
  let a=NSAlert();a.messageText="管理分类";a.informativeText="移除分类会保留游戏及其存档。";let field=NSTextField(string:group.name);field.frame=NSRect(x:0,y:0,width:320,height:26);a.accessoryView=field;a.addButton(withTitle:"重命名");a.addButton(withTitle:"移除分类");a.addButton(withTitle:"取消")
  let answer=a.runModal()
  do{
   if answer == .alertFirstButtonReturn{try store.renameCollection(id,name:field.stringValue)}
   else if answer == .alertSecondButtonReturn{try store.removeCollection(id);if filter==id.uuidString{filter="all"}}
   else{return};showLibrary()
  }catch{errorAlert(error)}
 }
 func manageGameCollections(_ game:Game,pending:Set<UUID>?=nil){
  guard !busy else{return}
  let a=NSAlert();a.messageText="分类："+game.title;a.informativeText="可以加入多个分类。取消全部勾选会放入「未分类」。"
  let selected=pending ?? store.collectionIDs(for:game.id)
  let checks=store.collections.map{group->NSButton in let b=NSButton(checkboxWithTitle:group.name,target:nil,action:nil);b.state=selected.contains(group.id) ? .on:.off;return b}
  let list=stack(checks,vertical:true,spacing:8);list.frame=NSRect(x:0,y:0,width:320,height:max(30,checks.count*26));a.accessoryView=list
  a.addButton(withTitle:"保存");a.addButton(withTitle:"新建分类…");a.addButton(withTitle:"取消")
  let answer=a.runModal()
  if answer == .alertSecondButtonReturn{let draft=Set(zip(store.collections,checks).filter{$0.1.state == .on}.map{$0.0.id});createCollection();manageGameCollections(game,pending:draft);return}
  guard answer == .alertFirstButtonReturn else{return}
  let ids=Set(zip(store.collections,checks).filter{$0.1.state == .on}.map{$0.0.id})
  do{try store.setCollections(for:game.id,ids:ids);showLibrary()}catch{errorAlert(error)}
 }
 func controlTextDidChange(_ obj:Notification){renderCards()}
 func renderCards(){
  guard let scroll=content as? NSScrollView else{return}
  playtimeLabels.removeAll()
  let query=search.stringValue
  let collectionID=UUID(uuidString:filter)
  let members=collectionID.map{Set(store.games(inCollection:$0).map{$0.id})}
  let singleID=filter.hasPrefix("game:") ? UUID(uuidString:String(filter.dropFirst(5))):nil
  let unclassified=Set(store.uncategorizedGames.map{$0.id})
  var games=store.games.filter{(members==nil || members!.contains($0.id)) && (singleID==nil || singleID==$0.id) && (filter != "uncategorized" || unclassified.contains($0.id)) && (filter != "favorite" || $0.favorite)&&(filter != "recent" || $0.lastPlayed != nil)&&(query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))}
  if filter=="recent"{games.sort{($0.lastPlayed ?? .distantPast)>($1.lastPlayed ?? .distantPast)}}else{games.sort{$0.title.localizedStandardCompare($1.title) == .orderedAscending}}
  let doc=FlippedView();scroll.documentView=doc;doc.translatesAutoresizingMaskIntoConstraints=false
  NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),doc.topAnchor.constraint(equalTo:scroll.contentView.topAnchor),doc.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor)])
  if games.isEmpty{
   let searching = !query.isEmpty
   let welcome = filter=="all" && store.games.isEmpty && !searching
   let symbol = searching ? "magnifyingglass" : filter=="recent" ? "clock" : filter=="favorite" ? "heart" : "square.stack.3d.up"
   let image=NSImageView(image:NSImage(systemSymbolName:symbol,accessibilityDescription:nil)!)
   image.contentTintColor=NSColor(calibratedWhite:0.68,alpha:1);image.symbolConfiguration = .init(pointSize:44,weight:.ultraLight)
   image.heightAnchor.constraint(equalToConstant:60).isActive=true
   let message = searching ? "没有匹配的游戏" : filter=="recent" ? "暂无游玩记录" : filter=="favorite" ? "暂无收藏" : filter=="all" ? "暂无游戏" : "分类为空"
   let title=label(message,size:23,weight:.semibold)
   var elements:[NSView]=[image,title]
   if welcome {
    let action=ActionButton("添加游戏库文件夹"){[weak self] in self?.showDiscovery()};action.controlSize = .large;elements.append(action)
   }else if !searching {
    let hint=label(filter=="recent" ? "从「所有游戏」启动游戏后，会显示在这里。":filter=="favorite" ? "在游戏的「⋯」菜单中选择收藏。":"在游戏的「⋯」菜单中选择「管理分类」。",size:13);hint.textColor = .secondaryLabelColor;elements.append(hint)
   }
   let s=stack(elements,vertical:true,spacing:22);s.alignment = .centerX
   doc.addSubview(s);s.translatesAutoresizingMaskIntoConstraints=false
   NSLayoutConstraint.activate([doc.heightAnchor.constraint(equalTo:scroll.contentView.heightAnchor),s.centerXAnchor.constraint(equalTo:doc.centerXAnchor),s.centerYAnchor.constraint(equalTo:doc.centerYAnchor,constant:-35)])
   return
  }

  let rows=stack([],vertical:true,spacing:28);pin(rows,to:doc)
  for start in stride(from:0,to:games.count,by:3){
   let row=stack([],spacing:22);row.distribution = .fillEqually;row.alignment = .top
   rows.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:rows.widthAnchor).isActive=true
   for offset in 0..<3 {
    guard start+offset<games.count else{row.addArrangedSubview(NSView());continue}
    let game=games[start+offset]
    let cover=CoverButton(""){[weak self] in self?.launch(game)};cover.game=game;cover.isBordered=false;cover.toolTip="启动 "+game.title;cover.setAccessibilityLabel("启动 "+game.title)
    cover.menuProvider={[weak self] in self?.gameMenu(game.id)}
    if let path=game.cover {cover.coverImage=NSImage(contentsOfFile:path)}
    cover.heightAnchor.constraint(equalTo:cover.widthAnchor,multiplier:1.32).isActive=true
    let name=label(game.title,size:14,weight:.semibold);name.lineBreakMode = .byTruncatingTail
    let more=ActionButton("⋯"){};more.menuProvider={[weak self] in self?.gameMenu(game.id)};more.opensMenuOnClick=true;more.setAccessibilityLabel("游戏菜单 "+game.title);more.bezelStyle = .recessed;more.widthAnchor.constraint(equalToConstant:28).isActive=true
    let play=ActionButton("启动"){[weak self] in self?.launch(game)};play.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:nil);play.imagePosition = .imageLeading;play.toolTip="启动 "+game.title;play.setAccessibilityLabel("启动游戏 "+game.title)
    let names=stack([name,NSView(),play,more],spacing:6);name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    let time=label(playtimeText(game.id),size:11);time.textColor = .secondaryLabelColor;time.setAccessibilityLabel("游玩时长 "+game.title);playtimeLabels[game.id]=time
    let card=stack([cover,names,time],vertical:true,spacing:8);cover.widthAnchor.constraint(equalTo:card.widthAnchor).isActive=true;names.widthAnchor.constraint(equalTo:card.widthAnchor).isActive=true;time.widthAnchor.constraint(equalTo:card.widthAnchor).isActive=true
    row.addArrangedSubview(card)
   }
  }
 }
 @objc func importPanel(){
  guard !busy,active==nil else{return}
  let panel=NSOpenPanel();panel.title="选择游戏文件夹或可执行文件";panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=true
  panel.beginSheetModal(for:window){[weak self] result in if result == .OK {self?.importURLs(panel.urls)}}
 }
 func importURLs(_ urls:[URL],progress:ImportProgress?=nil){
  guard !busy,active==nil,let url=urls.first else{return}
  let current=progress ?? ImportProgress(total:urls.count)
  setBusy(true,current.checking(url.lastPathComponent))
  DispatchQueue.global(qos:.userInitiated).async {
   do {
    let isExe=url.pathExtension.lowercased()=="exe"
    let source=isExe ? url.deletingLastPathComponent():url
    var candidates=try Scan.candidates(at:source)
    if isExe{candidates=candidates.filter{$0.path==url.lastPathComponent}}
    self.preparationReady {
     var next=current
     if candidates.isEmpty {
      self.errorAlert(LibraryError("没有找到可启动入口。请选择含游戏 EXE、macOS .app 或浏览器导出 index.html 的目录；压缩包请先解压。"));next.record(.failed)
     }else if candidates.count==1 {
      next.record(self.add(source,candidates[0]))
     }else {
      self.showStatus("正在导入 \(current.processed+1)/\(current.total)：等待选择「\(source.lastPathComponent)」的启动入口…")
      let alert=NSAlert();alert.messageText="选择此游戏的启动入口";alert.informativeText="请选择平时使用的入口；带中文或汉化标记的入口会优先列出。此后会自动使用所选入口。\n识别引擎："+Array(Set(candidates.map{$0.engine})).sorted().joined(separator:"、")
      let popup=NSPopUpButton(frame:NSRect(x:0,y:0,width:400,height:28));popup.addItems(withTitles:candidates.map{$0.path});alert.accessoryView=popup;alert.addButton(withTitle:"添加");alert.addButton(withTitle:"取消")
      if alert.runModal() == .alertFirstButtonReturn{next.record(self.add(source,candidates[popup.indexOfSelectedItem]))}else{next.record(.cancelled)}
     }
     self.advanceImport(urls,progress:next)
    }
   }catch{self.preparationReady {
    var next=current;next.record(.failed);self.errorAlert(error);self.advanceImport(urls,progress:next)
   }}
  }
 }
 func advanceImport(_ urls:[URL],progress:ImportProgress){
  let remaining=Array(urls.dropFirst())
  if !remaining.isEmpty{setBusy(false,"");importURLs(remaining,progress:progress)}
  else{setBusy(false,progress.summary)}
 }
 @discardableResult func add(_ source:URL,_ candidate:Candidate)->ImportProgress.Outcome{do{
  showStatus("正在登记「\(source.lastPathComponent)」到游戏库…")
  let existingIDs=Set(store.games.map{$0.id})
  let game=try store.add(source:source,candidate:candidate)
  filter="all";search.stringValue="";showLibrary()
  if game.cover==nil,UserDefaults.standard.object(forKey:"AutoOnlineCover") as? Bool != false{findCover(game,automatic:true)}
  return existingIDs.contains(game.id) ? .existing:.added
 }catch{errorAlert(error);return .failed}}
 func preparationReady(_ action:@escaping()->Void){
  DispatchQueue.main.async {
   if self.quitting{return}
   if self.quitPromptOpen{self.deferredPreparations.append(action)}else{action()}
  }
 }
 func showStatus(_ message:String){statusMessage=message;refreshStatus()}
 func refreshStatus(){
  let elapsed=busySince.map{Int(Date().timeIntervalSince($0))} ?? 0
  status?.stringValue=statusMessage+(busy && elapsed>=3 ? "（已用时 \(elapsed) 秒）":"")
  status?.isHidden=statusMessage.isEmpty
  statusHeight?.constant=statusMessage.isEmpty ? 0:44
  if busy{statusSpinner?.startAnimation(nil)}else{statusSpinner?.stopAnimation(nil)}
 }
 func setBusy(_ value:Bool,_ message:String){
  if value && !busy{busySince=Date()}
  busy=value;statusMessage=message
  statusTimer?.invalidate();statusTimer=nil
  if value{let timer=Timer(timeInterval:1,repeats:true){[weak self] _ in self?.refreshStatus()};statusTimer=timer;RunLoop.main.add(timer,forMode:.common)}else{busySince=nil}
  refreshStatus()
  if !value{flushPlaytimeError()}
 }
 func errorAlert(_ error:Error){guard !quitting else{return};let a=NSAlert();a.messageText="无法完成操作";a.informativeText=error.localizedDescription;a.alertStyle = .warning;a.runModal()}
 func playtimeText(_ gameID:UUID)->String {
  guard let playtime else{return "时长记录暂不可用"}
  let seconds=playtime.totalSeconds(gameID:gameID)
  return playtime.records(gameID:gameID).isEmpty ? "尚无游玩记录":"已游玩 "+Self.playtimeDuration(seconds)
 }
 static func playtimeDuration(_ seconds:TimeInterval)->String {
  guard seconds.isFinite,seconds>=60 else{return "不足 1 分钟"}
  let minutes=Int(min(seconds/60,Double(Int.max/60)))
  return minutes>=60 ? "\(minutes/60) 小时 \(minutes%60) 分钟":"\(minutes) 分钟"
 }
 func playtimeOperation(_ action:(PlaytimeRecorder)throws->Void){
  guard let playtimeRecorder else{return}
  do{try action(playtimeRecorder);refreshPlaytimeLabels()}
  catch{
   if !playtimeReportedFailure{pendingPlaytimeError="时长暂未保存，稍后会重试；请检查应用数据目录："+error.localizedDescription}
   flushPlaytimeError()
  }
 }
 func flushPlaytimeError(){
  guard !busy,!quitting,!playtimeReportedFailure,let message=pendingPlaytimeError else{return}
  showStatus(message);pendingPlaytimeError=nil;playtimeReportedFailure=true
 }
 func beginPlaytime(_ id:UUID){playtimeOperation{try $0.begin(gameID:id)}}
 func endPlaytime(_ id:UUID,at:Date=Date(),uptime:TimeInterval=ProcessInfo.processInfo.systemUptime){playtimeOperation{try $0.end(gameID:id,at:at,uptime:uptime)}}
 func refreshPlaytimeLabels(){for(id,label) in playtimeLabels{label.stringValue=playtimeText(id)}}
 func checkpointPlaytime(){
  let ended=nativeApplications.filter{$0.value.isTerminated}.map{$0.key}
  for id in ended{endPlaytime(id);nativeApplications.removeValue(forKey:id);releaseShared(id)}
  playtimeOperation{try $0.checkpoint()};flushPlaytimeError()
 }
 @objc func playtimeWillSleep(){playtimeOperation{try $0.pause()}}
 @objc func playtimeDidWake(){playtimeOperation{try $0.resume()}}
 @objc func playtimeApplicationEnded(_ notification:Notification){
  guard let ended=notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else{return}
  let ids=nativeApplications.filter{$0.value.processIdentifier==ended.processIdentifier}.map{$0.key}
  for id in ids{endPlaytime(id);nativeApplications.removeValue(forKey:id);releaseShared(id)}
 }
 func markPlayed(_ game:Game){guard store.games.contains(where:{$0.id==game.id}) else{return};do{try store.recordPlayed(game.id)}catch{errorAlert(error)}}
 func launch(_ game:Game){
  guard !busy,active==nil else{return}
  if game.shared != nil,let session=sharedSessions[game.id],session.closing || session.unmounted {
   showStatus("上一次共享会话正在关闭，请稍后再启动。");return
  }
  if game.shared != nil,sharedSessions[game.id]==nil {launchShared(game);return}
  if game.shared != nil,[Backend.rpgmz,.web].contains(game.entry.backend) {prepareSharedWeb(game);return}
  let folder=URL(fileURLWithPath:game.folder),entry=URL(fileURLWithPath:game.folder).appendingPathComponent(game.entry.path)
  if game.entry.backend == .rpgmz{prepareMZ(game,entry:entry,folder:folder);return}
  guard FileManager.default.fileExists(atPath:entry.path) else{errorAlert(LibraryError("找不到游戏文件。请确认游戏目录或磁盘可访问；位置：\(game.folder)"));return}
  switch game.entry.backend {
  case .renpy:
   if nativeRenpyRoot(game) != nil {startRenpy(game)} else {prepareWine(game)}
  case .web: playWeb(game,entry:entry,folder:folder)
  case .rpgmz: prepareMZ(game,entry:entry,folder:folder)
  case .native:
   startNativeApplication(game)
  case .wine:
   if game.entry.engine=="Ren’Py",nativeRenpyRoot(game) != nil {startRenpy(game);return}
   prepareWine(game)
  }
 }
 func startNativeApplication(_ game:Game){
  if nativeLaunching.contains(game.id){showStatus("macOS 正在启动或验证此游戏，请勿重复开启。");return}
  if let app=nativeApplications[game.id],!app.isTerminated{app.activate(options:[.activateAllWindows]);return}
  let cachedApp=root.appendingPathComponent("NativeApps/"+game.id.uuidString+".app")
  let sourceApp=URL(fileURLWithPath:game.folder).appendingPathComponent(game.entry.path)
  if let existing=NativeAppIdentity.runningApplication(at:cachedApp) ?? NativeAppIdentity.runningApplication(at:sourceApp) {
   // Games can outlive the library process. Adopt the actual app rather than
   // replacing its runtime or launching a second copy after a client restart.
   nativeApplications[game.id]=existing;beginPlaytime(game.id);markPlayed(game)
   existing.activate(options:[.activateAllWindows]);showStatus("游戏已在运行。");return
  }
  setBusy(true,"正在准备运行环境…")
  let localRoot=root
  DispatchQueue.global(qos:.userInitiated).async {
   do {
    let managedRoot=try self.saveDataRoot(for:game)
    if game.shared != nil {
     let sourceApp=URL(fileURLWithPath:game.folder).appendingPathComponent(game.entry.path)
     guard FileManager.default.fileExists(atPath:sourceApp.appendingPathComponent("Contents/Resources/autorun/renpy/vc_version.py").path) else{throw LibraryError("此原生游戏的账号存档位置尚未适配。请使用已提供的 Windows 入口，或先添加该引擎的存档适配；未在公共用户目录启动。")}
    }
    let plan=try NativeAppCache.prepare(game:game,root:localRoot)
    let storageID=try NativeGameSaves.storageID(game:game,localRoot:localRoot)
    let autorun=plan.app.appendingPathComponent("Contents/Resources/autorun")
    var arguments:[String]=[],environment=plan.environment
    if FileManager.default.fileExists(atPath:autorun.appendingPathComponent("renpy/vc_version.py").path){
     guard FileManager.default.fileExists(atPath:managedRoot.path) else{throw LibraryError("存档运行目录不可用，请确认其磁盘或共享目录可访问。")}
     let saves=managedRoot.appendingPathComponent("Saves/NativeApps/"+storageID.uuidString),logs=managedRoot.appendingPathComponent("Logs/"+game.id.uuidString)
     try FileManager.default.createDirectory(at:saves,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
     arguments=["--savedir",saves.path];environment["RENPY_LOG_BASE"]=logs.path;environment["PYTHONDONTWRITEBYTECODE"]="1"
     if let language=game.nativeLanguage,!language.isEmpty{environment["RENPY_LANGUAGE"]=language}
    }else if let data=try? Data(contentsOf:plan.app.appendingPathComponent("Contents/Info.plist")),let info=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],info["CFBundleExecutable"] as? String=="Phoenixes" {
     try NativeGameSaves.preparePhoenixes(game:game,managedRoot:managedRoot,localRoot:localRoot)
     arguments=["--language","zh_CN"]
    }
    self.preparationReady {
     let config=NSWorkspace.OpenConfiguration();config.createsNewApplicationInstance=true;config.arguments=arguments;config.environment=environment
     self.nativeLaunching.insert(game.id);self.setBusy(false,"正在启动游戏…")
     NSWorkspace.shared.openApplication(at:plan.app,configuration:config){app,error in DispatchQueue.main.async {
      self.nativeLaunching.remove(game.id);guard !self.quitting else{return};self.setBusy(false,"")
      if let error{self.errorAlert(error)}else if let app{self.nativeApplications[game.id]=app;self.beginPlaytime(game.id);self.markPlayed(game);self.showStatus("已启动「\(game.title)」")}
     }}
    }
   }catch{self.preparationReady{self.setBusy(false,"");self.errorAlert(error)}}
  }
 }
 func prepareWine(_ game:Game){
   if wineSessions.contains(game.id) {errorAlert(LibraryError("此游戏仍在运行，请回到游戏窗口。"));return}
   setBusy(true,"正在准备运行环境…")
   let source=URL(fileURLWithPath:UserDefaults.standard.string(forKey:"WineSource") ?? Wrapper.defaultSource.path)
   let dataRoot=runtimeDataRoot(for:game)
   guard FileManager.default.fileExists(atPath:dataRoot.path) else{setBusy(false,"");errorAlert(LibraryError("运行数据位置不可用，请确认磁盘或共享目录可访问，或在设置中重新选择。"));return}
   let destination=dataRoot.appendingPathComponent("Runtimes/"+game.id.uuidString+".app")
   DispatchQueue.global(qos:.userInitiated).async{
    do {
     // Shared resources already have a private server view. Local game-specific
     // adapters must not silently substitute an unscoped source directory.
     let cursorGame=game.shared == nil ? try UnityCursorAdapter.prepareIfEnabled(game:game,dataRoot:dataRoot):game
     let launchGame=game.shared == nil ? try RPGDictionary.prepareIfNeeded(game:cursorGame,dataRoot:dataRoot,tools:Bundle.main.resourceURL!.appendingPathComponent("Tools")):cursorGame
     self.preparationReady{self.showStatus("正在检查运行环境…")}
     let app=try Wrapper.prepare(game:launchGame,source:source,destination:destination,shareEngine:true,freshPrefix:game.shared != nil)
     try SharedWineBootstrap.prepare(game:launchGame,runtime:app)
     self.preparationReady{self.showStatus("正在检查运行组件…")}
     try RTP.register(game:launchGame,runtime:app,root:self.runtimeRoot.appendingPathComponent("Dependencies"))
     self.preparationReady {
      guard !self.quitting else{return}
      self.startWine(game,runtime:app,launchGame:launchGame)

     }
    }catch{self.preparationReady{self.setBusy(false,"");self.errorAlert(error)}}
   }
 }

 func nativeRenpyRoot(_ game:Game)->URL? {
  let engineRoots=[Bundle.main.resourceURL!.appendingPathComponent("Engines"),root.appendingPathComponent("Engines"),FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GameShelf/Engines"),runtimeRoot.appendingPathComponent("Engines")]
  return NativeEngines.availableRenpyRoot(folder:URL(fileURLWithPath:game.folder),roots:engineRoots)
 }
 func startRenpy(_ game:Game){
  if let app=nativeRunning[game.id],app.isRunning {NSRunningApplication(processIdentifier:app.processIdentifier)?.activate(options:[]);return}
  setBusy(true,"正在加载游戏资源…")

  let data:URL
  do{data=try saveDataRoot(for:game)}catch{setBusy(false,"");errorAlert(error);return}
  DispatchQueue.global(qos:.userInitiated).async {
   do {
    guard FileManager.default.fileExists(atPath:data.path) else{throw LibraryError("运行数据目录不可用，请确认磁盘或共享目录可访问。")}
    guard let engineRoot=self.nativeRenpyRoot(game) else{throw LibraryError("尚未安装此游戏精确版本的原生 Ren’Py 引擎。请在运行数据目录的 Engines 中放置对应官方 SDK。")}
    let spec=try NativeEngines.renpySpec(game:game,engines:engineRoot,data:data)
    self.preparationReady {
     guard !self.quitting else{return}
     do {
      let log=data.appendingPathComponent("Logs/"+game.id.uuidString+"/launcher-"+String(Int(Date().timeIntervalSince1970))+".log")
      FileManager.default.createFile(atPath:log.path,contents:nil)
      let output=try FileHandle(forWritingTo:log)
      let process=Process();process.executableURL=spec.executable;process.arguments=spec.arguments;process.currentDirectoryURL=spec.directory;process.environment=spec.environment;process.standardOutput=output;process.standardError=output
      process.terminationHandler={p in
       let endedAt=Date(),endedUptime=ProcessInfo.processInfo.systemUptime
       try? output.close()
       DispatchQueue.main.async { self.endPlaytime(game.id,at:endedAt,uptime:endedUptime) }
       self.preparationReady {
        self.nativeRunning.removeValue(forKey:game.id)
        self.releaseShared(game.id)
        if !self.busy{self.showStatus("游戏进程已结束。")}
        if p.terminationStatus != 0 {self.errorAlert(LibraryError("原生游戏已退出，代码 \(p.terminationStatus)。日志：\(log.path)"))}
       }
      }
      do{try process.run()}catch{try? output.close();throw error}
      self.nativeRunning[game.id]=process;self.beginPlaytime(game.id);self.markPlayed(game);self.setBusy(false,"正在启动原生游戏窗口…")
     }catch{self.setBusy(false,"");self.errorAlert(error)}
    }
   }catch{self.preparationReady{self.setBusy(false,"");self.errorAlert(error)}}
  }
 }
 func startWine(_ game:Game,runtime:URL,launchGame:Game?=nil){
  do {
   if wineSessions.contains(game.id) {setBusy(false,"");throw LibraryError("此游戏仍在运行，请先回到游戏窗口或退出后重试。")}
   let spec=try Wrapper.launchSpec(game:launchGame ?? game,runtime:runtime)
   let wait=try Wrapper.waitSpec(game:game,runtime:runtime)
   let logs=runtime.appendingPathComponent("Contents/SharedSupport/Logs")
   try FileManager.default.createDirectory(at:logs,withIntermediateDirectories:true)
   let log=logs.appendingPathComponent("GameShelf-"+String(Int(Date().timeIntervalSince1970))+".log")
   FileManager.default.createFile(atPath:log.path,contents:nil)
   let handle=try FileHandle(forWritingTo:log)
   let p=Process();p.executableURL=spec.executable;p.arguments=spec.arguments;p.currentDirectoryURL=spec.directory;p.environment=spec.environment;p.standardOutput=handle;p.standardError=handle
   p.terminationHandler={process in
    let status=process.terminationStatus
    DispatchQueue.global(qos:.utility).async {
     do {
      let waiter=Process();waiter.executableURL=wait.executable;waiter.arguments=wait.arguments;waiter.currentDirectoryURL=wait.directory;waiter.environment=wait.environment;waiter.standardOutput=handle;waiter.standardError=handle
      try waiter.run();waiter.waitUntilExit()
      guard waiter.terminationStatus==0 else{throw LibraryError("无法确认游戏子进程是否已结束，请先在游戏窗口内退出。")}
      let endedAt=Date(),endedUptime=ProcessInfo.processInfo.systemUptime
      try? handle.close()
      DispatchQueue.main.async {
       self.endPlaytime(game.id,at:endedAt,uptime:endedUptime);self.running.removeValue(forKey:game.id);self.wineSessions.remove(game.id)
       self.releaseShared(game.id)
       if !self.busy{self.showStatus("游戏进程已结束。")}
       if status != 0 {self.errorAlert(LibraryError("\(game.title) 已退出，代码 \(status)。请通过游戏菜单查看日志：\(log.lastPathComponent)"))}
      }
     }catch{try? handle.close();DispatchQueue.main.async{self.errorAlert(error)}}
    }
   }
   do{try p.run()}catch{try? handle.close();throw error}
   running[game.id]=p;wineSessions.insert(game.id);beginPlaytime(game.id);markPlayed(game);setBusy(false,"游戏已启动。")
  }catch{setBusy(false,"");errorAlert(error)}
 }
 func prepareMZ(_ game:Game,entry:URL,folder:URL){
  let request=UUID();pendingWebLaunch=request;setBusy(true,"正在读取游戏资源并检查旧存档…")
  let bundleID=Bundle.main.bundleIdentifier ?? "local.gameshelf.app",localRoot=root
  DispatchQueue.global(qos:.userInitiated).async {
   let result:Result<(GameResourceServer,URL,UUID,MZSaveArchive?),Error>=Result {
    try EntryPolicy.validate(game.entry)
    guard FileManager.default.fileExists(atPath:entry.path) else{throw LibraryError("找不到游戏入口，请确认 NAS 已连接。")}
    guard MZWebProfile.matches(at:folder) else{throw LibraryError("游戏的启动脚本或插件配置已改变，原生适配未验证此版本。已有文件和存档已保留。")}
    let storageID=try WebSaveBindings(root:localRoot).resolve(source:game.originalFolder,initial:game.id)
    let key="GameResourcePort."+storageID.uuidString
    let saved=UserDefaults.standard.integer(forKey:key)
    guard let preferred=UInt16(exactly:saved) else{throw LibraryError("本机端口记录无效，已停止启动以保留原存档位置。")}
    let previous=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/"+bundleID+"/WebsiteDataStore/"+storageID.uuidString.lowercased())
    let archive=try MZSaveArchive.prepare(folder:folder,storageID:storageID,root:localRoot,webKitDirectory:previous)
    let server=try GameResourceServer(root:folder,preferredPort:preferred)
    return (server,try server.entryURL(relativePath:"index.html"),storageID,archive)
   }
   self.preparationReady {
    guard self.pendingWebLaunch==request else{if case .success(let value)=result{value.0.stop()};return}
    self.pendingWebLaunch=nil;self.setBusy(false,"")
    switch result {
    case .success(let value):
     self.gameResourceServer=value.0;UserDefaults.standard.set(Int(value.0.port),forKey:"GameResourcePort."+value.2.uuidString)
     self.playWeb(game,entry:entry,folder:folder,hostedEntry:value.1,storageID:value.2,migration:value.3)
    case .failure(let error):self.errorAlert(error)
    }
   }
  }
 }
 func playWeb(_ game:Game,entry:URL,folder:URL,hostedEntry:URL?=nil,storageID:UUID?=nil,migration:MZSaveArchive?=nil,sharedSession:SharedWebKitSession?=nil){
  active=game;window.title=game.title
  let cfg=WKWebViewConfiguration();cfg.websiteDataStore=sharedSession == nil ? WKWebsiteDataStore(forIdentifier:storageID ?? game.id):WKWebsiteDataStore.nonPersistent();cfg.mediaTypesRequiringUserActionForPlayback=[]
  if let sharedSession {
   cfg.userContentController.addScriptMessageHandler(sharedSession,contentWorld:.page,name:SharedWebKitSession.handlerName)
   cfg.userContentController.addUserScript(WKUserScript(source:sharedSession.documentScript,injectionTime:.atDocumentStart,forMainFrameOnly:true))
  }
  if hostedEntry != nil {
   // A desktop MZ package defaults to unscaled 1280 CSS pixels in browser mode.
   // Fit once after engine initialization; preserve subsequent F3/fullscreen input.
   let sizing="""
   (()=>{let attempts=0;const timer=setInterval(()=>{attempts++;if(typeof Graphics!=='undefined'&&Graphics.width>0&&Graphics.height>0&&Graphics._canvas){if(Graphics._stretchEnabled===false&&typeof Graphics._switchStretchMode==='function')Graphics._switchStretchMode();clearInterval(timer);}else if(attempts>=200)clearInterval(timer);},250);})();
   """
   cfg.userContentController.addUserScript(WKUserScript(source:sizing,injectionTime:.atDocumentStart,forMainFrameOnly:true))
  }
  if let migration {
   guard let tool=Bundle.main.url(forResource:"migrate_mz_saves",withExtension:"js",subdirectory:"Tools"),let library=try? String(contentsOf:tool,encoding:.utf8) else{active=nil;gameResourceServer?.stop();gameResourceServer=nil;errorAlert(LibraryError("缺少旧存档恢复组件，未启动空存档游戏。"));return}
   saveMigrationPlans[game.id]=migration
   cfg.userContentController.add(self,name:"mzSaveMigration")
   let script="(function(module,define){\n"+library+"\n})(undefined,undefined);\n"+mzMigrationScript(game:game,archive:migration)
   cfg.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
  }
  let web=WKWebView(frame:.zero,configuration:cfg);web.navigationDelegate=self;web.uiDelegate=self;self.web=web
  sharedSession?.webView=web
  let back=ActionButton("退出游戏"){[weak self] in self?.leaveGame()}
  let title=label(game.title,size:13,weight:.medium)
  let row=stack([back,title,NSView(),ActionButton("全屏"){[weak self] in self?.window.toggleFullScreen(nil)}],spacing:15)
  let top=NSView();pin(row,to:top,inset:8);top.heightAnchor.constraint(equalToConstant:44).isActive=true
  let body=stack([top,web],vertical:true,spacing:0);body.alignment = .leading
  top.widthAnchor.constraint(equalTo:body.widthAnchor).isActive=true;web.widthAnchor.constraint(equalTo:body.widthAnchor).isActive=true
  window.contentView=NSView();pin(body,to:window.contentView!)
  if let hostedEntry{web.load(URLRequest(url:hostedEntry))}else{web.loadFileURL(entry,allowingReadAccessTo:folder)}
  window.makeFirstResponder(web)
 }
 func mzMigrationScript(game:Game,archive:MZSaveArchive)->String {
  return """
  (()=>{
   const payload="\(archive.payload)",fingerprint="\(archive.fingerprint)",entry="\(game.id.uuidString)";
   const notify=(result)=>window.webkit.messageHandlers.mzSaveMigration.postMessage(Object.assign({entry,fingerprint},result));
   let attempts=0;const poll=setInterval(()=>{
    if(typeof DataManager==='undefined'||typeof StorageManager==='undefined'||typeof localforage==='undefined'||typeof JsonEx==='undefined'){if(++attempts>18000){clearInterval(poll);notify({error:'等待游戏存储组件超时，原存档未修改。'});}return;}
    clearInterval(poll);
    const original=DataManager.isGlobalInfoLoaded;let finished=false;
    DataManager.isGlobalInfoLoaded=function(){return finished&&original.call(this);};
    (async()=>{
     let loaded=0;while(!original.call(DataManager)||!window.$dataSystem){if(++loaded>1800)throw Error('等待存档索引超时');await new Promise(r=>setTimeout(r,100));}
     const bytes=Uint8Array.from(atob(payload),c=>c.charCodeAt(0));const plan=JSON.parse(new TextDecoder().decode(bytes));
     const prefix=StorageManager.forageKey('');
     const io={gameId:$dataSystem.advanced.gameId,
      read:n=>localforage.getItem(StorageManager.forageKey(n)),
      write:(n,z)=>localforage.setItem(StorageManager.forageKey(n),z),
      remove:n=>localforage.removeItem(StorageManager.forageKey(n)),
      names:async()=> (await localforage.keys()).filter(k=>k.startsWith(prefix)).map(k=>k.slice(prefix.length)).filter(n=>/^(global|config|titleInfo|file(?:0|[1-9][0-9]{0,2}))$/.test(n)),
      unzip:async z=>JsonEx.parse(await StorageManager.zipToJson(z)),
      zip:async obj=>StorageManager.jsonToZip(JsonEx.stringify(obj))};
     const result=await GameShelfMZSaveMigration.migrate(plan,io);
     await StorageManager.updateForageKeys();DataManager._globalInfo=await StorageManager.loadObject('global');
     finished=true;notify({imported:result.imported,reused:result.reused,mappings:result.mappings});
    })().catch(e=>notify({error:String(e.message||e)}));
   },10);
  })();
  """
 }
 func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){
  guard message.name=="mzSaveMigration",message.webView === web,message.frameInfo.isMainFrame,let body=message.body as? [String:Any],let idText=body["entry"] as? String,let id=UUID(uuidString:idText),active?.id==id,let plan=saveMigrationPlans[id],body["fingerprint"] as? String==plan.fingerprint else{return}
  if let error=body["error"] as? String {
   let alert=NSAlert();alert.messageText="旧存档恢复未完成";alert.informativeText=String(error.prefix(800))+"\n游戏尚未继续，备份位于："+plan.backup.path;alert.addButton(withTitle:"重试恢复");alert.addButton(withTitle:"退出游戏")
   if alert.runModal() == .alertFirstButtonReturn{web?.reload()}else{leaveGame(skipSavePrompt:true)};return
  }
  saveMigrationPlans.removeValue(forKey:id)
  guard let imported=body["imported"] as? Int,imported>=0,imported<=1000 else{return}
  do{try plan.markCompleted(imported:imported);showStatus("已恢复 \(imported) 个旧存档，原件与备份保留。")}
  catch{errorAlert(LibraryError("旧存档已恢复，但恢复记录保存失败："+error.localizedDescription))}
 }
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){if let game=active{beginPlaytime(game.id);markPlayed(game)}}
 func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error){errorAlert(error)}
 func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error){errorAlert(error)}
 func webViewWebContentProcessDidTerminate(_ webView:WKWebView){if let id=active?.id{endPlaytime(id)};errorAlert(LibraryError("游戏网页进程已退出。请退出后重新打开，未保存的进度可能丢失。"))}
 func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
  guard let u=navigationAction.request.url else{decisionHandler(.cancel);return}
  if let session=sharedWebKitSession,navigationAction.targetFrame?.isMainFrame != false,!session.accepts(u) {
   decisionHandler(.cancel)
   if navigationAction.navigationType == .linkActivated,["https","http"].contains(u.scheme ?? ""){NSWorkspace.shared.open(u)}
   return
  }
  if navigationAction.navigationType == .linkActivated, !u.isFileURL {decisionHandler(.cancel);NSWorkspace.shared.open(u);return}
  decisionHandler(.allow)
 }
 func webView(_ webView:WKWebView,runJavaScriptAlertPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping()->Void){let a=NSAlert();a.messageText=active?.title ?? "游戏";a.informativeText=message;a.runModal();completionHandler()}
 func webView(_ webView:WKWebView,runJavaScriptConfirmPanelWithMessage message:String,initiatedByFrame frame:WKFrameInfo,completionHandler:@escaping(Bool)->Void){let a=NSAlert();a.messageText=message;a.addButton(withTitle:"确定");a.addButton(withTitle:"取消");completionHandler(a.runModal() == .alertFirstButtonReturn)}
 func leaveGame(skipSavePrompt:Bool=false){
  guard !leavingWebGame else{return}
  if !skipSavePrompt {
  let a=NSAlert();a.messageText="退出游戏？";a.informativeText="请先使用游戏内的存档功能；此应用不会保存即时快照。";a.addButton(withTitle:"退出游戏");a.addButton(withTitle:"继续游戏")
  guard a.runModal() == .alertFirstButtonReturn else{return}
  }
  if let session=sharedWebKitSession {
   leavingWebGame=true;setBusy(true,"正在确认存档写入…")
   let finish={session.closeAndFlush{[weak self] in self?.finishLeavingWebGame()}}
   guard let web else{finish();return}
   web.callAsyncJavaScript("await window.__GameShelfPrepareSharedExit(); return true;",arguments:[:],in:nil,in:.page){[weak self] result in
    guard let self else{return}
    if case .failure = result {
     let alert=NSAlert();alert.messageText="存档写入尚未确认";alert.informativeText="请检查网络后在游戏中重试保存。";alert.addButton(withTitle:"返回游戏");alert.addButton(withTitle:"仍然退出")
     if alert.runModal() != .alertSecondButtonReturn{self.leavingWebGame=false;self.setBusy(false,"存档尚未确认。");return}
    }
    finish()
   }
   return
  }
  finishLeavingWebGame()
 }
 func finishLeavingWebGame(){
  let id=active?.id
  if let id{endPlaytime(id);saveMigrationPlans.removeValue(forKey:id)}
  web?.configuration.userContentController.removeScriptMessageHandler(forName:"mzSaveMigration")
  web?.configuration.userContentController.removeScriptMessageHandler(forName:SharedWebKitSession.handlerName,contentWorld:.page)
  web?.stopLoading();web?.navigationDelegate=nil;web?.uiDelegate=nil;web=nil
  gameResourceServer?.stop();gameResourceServer=nil;sharedWebKitSession=nil;leavingWebGame=false;active=nil
  setBusy(false,"");showLibrary();if let id{releaseShared(id)}
 }
 func applicationWillTerminate(_ notification:Notification){playtimeTimer?.invalidate();playtimeOperation{try $0.endAll()};NSWorkspace.shared.notificationCenter.removeObserver(self);quitting=true;statusTimer?.invalidate();PreparationTasks.shared.cancel();pendingWebLaunch=nil;gameResourceServer?.stop();gameResourceServer=nil}
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
  if !sharedSessions.isEmpty {
   for id in sharedSessions.keys{releaseShared(id)}
   let alert=NSAlert();alert.messageText="共享游戏会话尚未关闭";alert.informativeText="请先在游戏内保存退出。GameShelf 会刷新网络写入并关闭个人会话后再退出，避免存档写入中断。";alert.addButton(withTitle:"返回游戏库");alert.runModal();return .terminateCancel
  }
  if pendingWebLaunch != nil{pendingWebLaunch=nil;busy=false;return .terminateNow}
  if busy {
   let a=NSAlert();a.messageText="停止准备并退出？";a.informativeText="当前任务：\(status?.stringValue ?? "后台准备")\n\n退出会停止未完成的准备或复制。原游戏和已有存档保留；未完成的临时副本不会加入游戏库。"
   a.addButton(withTitle:"停止并退出");a.addButton(withTitle:"继续等待")
   quitPromptOpen=true
   let answer=a.runModal();quitPromptOpen=false
   guard answer == .alertFirstButtonReturn else{
    let completions=deferredPreparations;deferredPreparations=[]
    for completion in completions{completion()}
    return .terminateCancel
   }
   quitting=true;deferredPreparations=[];pendingWebLaunch=nil;busy=false;PreparationTasks.shared.cancel()
   return .terminateNow
  }
  if active != nil{leaveGame();return active==nil ? .terminateNow:.terminateCancel}
  if !wineSessions.isEmpty || nativeRunning.values.contains(where:{$0.isRunning}) || nativeApplications.values.contains(where:{!$0.isTerminated}) || !nativeLaunching.isEmpty{let a=NSAlert();a.messageText="游戏仍在运行";a.informativeText="退出游戏库不会关闭已运行的游戏，也不会取消已交给 macOS 的启动或验证。请在各自窗口保存退出，或在系统验证窗口停止。";a.addButton(withTitle:"退出游戏库");a.addButton(withTitle:"取消");return a.runModal() == .alertFirstButtonReturn ? .terminateNow:.terminateCancel}
  return .terminateNow
 }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
 func showGameLogs(_ game:Game){
  let root=runtimeDataRoot(for:game)
  let logs=(game.entry.backend == .native || game.entry.backend == .renpy) ? root.appendingPathComponent("Logs/"+game.id.uuidString) : root.appendingPathComponent("Runtimes/"+game.id.uuidString+".app/Contents/SharedSupport/Logs")
  DispatchQueue.global(qos:.userInitiated).async {
   let exists=FileManager.default.fileExists(atPath:logs.path)
   DispatchQueue.main.async{if exists{NSWorkspace.shared.open(logs)}else{self.errorAlert(LibraryError("此游戏尚未生成运行日志。"))}}
  }
 }
 func details(_ game:Game){guard !busy else{return};presentProperties(game)}
 func download(_ game:Game){
  guard game.shared==nil else{errorAlert(LibraryError("共享游戏按网络资源运行，此入口不会下载整款游戏。"));return}
  if wineSessions.contains(game.id) || (nativeRunning[game.id].map{$0.isRunning} ?? false) || (nativeApplications[game.id].map{!$0.isTerminated} ?? false) || nativeLaunching.contains(game.id){errorAlert(LibraryError("请先退出游戏，再复制到本地。"));return}
  let a=NSAlert();a.messageText="下载到本地？";a.informativeText="将完整复制游戏到 Mac，并切换到本地副本运行。NAS 原文件不变。请先退出此游戏，以免复制到正在写入的存档。复制所需空间与游戏大小相当。";a.addButton(withTitle:"下载");a.addButton(withTitle:"取消")
  guard a.runModal() == .alertFirstButtonReturn else{return}
  setBusy(true,"正在复制游戏，完成前请保持 NAS 连接…")
  DispatchQueue.global(qos:.userInitiated).async{
   do{let result=try self.store.download(game);self.preparationReady{guard !self.quitting else{return};do{try self.store.update(result);self.setBusy(false,"本地副本已就绪。");self.renderCards()}catch{self.setBusy(false,"");self.errorAlert(error)}}}
   catch{self.preparationReady{self.setBusy(false,"");self.errorAlert(error)}}
  }
 }
 func findCover(_ game:Game,automatic:Bool){
  guard !coverRequests.contains(game.id) else{return}
  var search=CoverArt.query(game.title)
  if !automatic {
   let alert=NSAlert();alert.messageText="联网查找封面";alert.informativeText="按游戏名查询 VNDB 和 Steam，仅下载封面缩略图。可去掉目录中的版本号或汉化标签。"
   let field=NSTextField(string:search);field.frame=NSRect(x:0,y:0,width:380,height:26);alert.accessoryView=field;alert.addButton(withTitle:"查找");alert.addButton(withTitle:"取消")
   guard alert.runModal() == .alertFirstButtonReturn else{return};search=field.stringValue
  }
  guard search.count>=2 else{return}
  coverRequests.insert(game.id)
  let requested=search,coverRoot=store.root
  Task {
   do {
    let matches=try await CoverArt.search(requested)
    let selection:(match:CoverMatch,prior:String?)? = await MainActor.run {
     guard let current=self.store.games.first(where:{$0.id==game.id}) else{return nil}
     if automatic{return CoverArt.exact(matches,query:CoverArt.query(requested)).map{($0,current.cover)}}
     guard !matches.isEmpty else{self.errorAlert(LibraryError("未找到封面。可修改搜索名称，或使用「选择封面」添加本地图片。"));return nil}
     let a=NSAlert();a.messageText="选择封面对应的游戏";a.informativeText="选择正确条目后下载封面；原有封面可以随时更换。"
     let popup=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28));popup.addItems(withTitles:matches.map{$0.title+" · "+$0.source});a.accessoryView=popup;a.addButton(withTitle:"使用封面");a.addButton(withTitle:"取消")
     return a.runModal() == .alertFirstButtonReturn ? (matches[popup.indexOfSelectedItem],current.cover):nil
    }
    if let selection {
     let path=try await CoverArt.save(selection.match,to:coverRoot,id:game.id)
     await MainActor.run {
      guard var current=self.store.games.first(where:{$0.id==game.id}),current.cover==selection.prior,(!automatic || current.cover==nil) else{return}
      current.cover=path;current.coverOrigin=nil;current.defaultCoverSHA256=nil
      do{try self.store.update(current);self.renderCards()}catch{if !automatic{self.errorAlert(error)}}
     }
    }
   }catch{if !automatic{await MainActor.run{self.errorAlert(error)}}}
   await MainActor.run{_ = self.coverRequests.remove(game.id)}
  }
 }
 func chooseCover(_ game:Game){
  let p=NSOpenPanel();p.title="选择封面";p.canChooseDirectories=false;p.allowedContentTypes=[.png,.jpeg,.webP,.heic]
  p.beginSheetModal(for:window){result in
   guard result == .OK,let u=p.url else{return}
   do{let dir=self.store.root.appendingPathComponent("Covers");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
    let target=dir.appendingPathComponent(game.id.uuidString+"-"+UUID().uuidString+"."+u.pathExtension)
    try Data(contentsOf:u).write(to:target,options:.atomic)
    var updated=game;updated.cover=target.path;updated.coverOrigin=nil;updated.defaultCoverSHA256=nil;try self.store.update(updated);self.renderCards()
   }catch{self.errorAlert(error)}
  }
 }
 func relocate(_ game:Game){
  guard game.shared==nil else{errorAlert(LibraryError("共享游戏位置由服务器管理。请在共享库中重新连接原服务器和账号。"));return}
  let p=NSOpenPanel();p.title="重新定位游戏文件夹";p.canChooseFiles=false;p.canChooseDirectories=true;p.treatsFilePackagesAsDirectories=true
  p.beginSheetModal(for:window){result in
   guard result == .OK,let u=p.url else{return}
   guard FileManager.default.fileExists(atPath:u.appendingPathComponent(game.entry.path).path) else{self.errorAlert(LibraryError("新目录中没有原启动入口：\(game.entry.path)"));return}
   var updated=game;updated.folder=u.path
   do{try self.store.update(updated);self.renderCards()}catch{self.errorAlert(error)}
  }
 }
 @objc func settings(){
  if let existing=settingsWindow {
   existing.showWindow(nil);existing.window?.makeKeyAndOrderFront(nil)
  }else {
   let controller=SettingsWindowController(app:self);settingsWindow=controller
   controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil)
  }
  NSApp.activate(ignoringOtherApps:true)
 }
 @objc func about(){let a=NSAlert();a.messageText="GameShelf for Mac";a.informativeText="macOS 游戏兼容与管理客户端 · 本地与网络卷原位置导入\n\n网页导出游戏可内嵌运行。Windows / macOS 程序在各自窗口运行。引擎识别不等于兼容认证，应用不提供即时快照。\n\n不包含商业游戏或第三方运行环境；Wine / Wineskin 沿用本机已有安装及其许可证。";a.runModal()}
}

@main struct Bootstrap {
 static func main(){
  let app=NSApplication.shared
  let delegate=App()
  app.delegate=delegate
  app.setActivationPolicy(.regular)
  withExtendedLifetime(delegate){app.run()}
 }
}
