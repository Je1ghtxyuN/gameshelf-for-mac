import AppKit

private final class DiscoveryCancellation {
 private let lock=NSLock()
 private var stopped=false
 func cancel(){lock.lock();stopped=true;lock.unlock()}
 var cancelled:Bool{lock.lock();defer{lock.unlock()};return stopped}
}

final class DiscoveryWindowController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
 private weak var app:App?
 private let store:DiscoveryStore
 private let sources=NSPopUpButton()
 private let modes=NSSegmentedControl(labels:["全部","已加入","已忽略"],trackingMode:.selectOne,target:nil,action:nil)
 private let table=NSTableView()
 private let status=NSTextField(labelWithString:"")
 private let spinner=NSProgressIndicator()
 private let selectedCount=NSTextField(labelWithString:"")
 private var records:[DiscoveryRecord]=[]
 private var checked=Set<String>()
 private var controls:[NSButton]=[]
 private var cancellation:DiscoveryCancellation?
 private var operation=UUID()
 private var scanning=false
 private var closed=false
 private var addAction:NSButton?
 private var ignoreAction:NSButton?
 private var shareAction:NSButton?
 private var sharing=false
 private var cancelAction:NSButton?

 init(app:App)throws {
  self.app=app;store=try DiscoveryStore(root:app.root)
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:610),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  super.init(window:window);window.title="扫描游戏";window.minSize=NSSize(width:860,height:480);window.isReleasedWhenClosed=false;window.delegate=self;window.appearance=NSAppearance(named:.aqua)
  build();reloadSources();window.center()
 }
 required init?(coder:NSCoder){fatalError()}
 func windowWillClose(_ notification:Notification){closed=true;operation=UUID();cancellation?.cancel();app?.discoveryWindow=nil}
 private func button(_ title:String,_ action:@escaping()->Void)->NSButton{let b=ActionButton(title,action);controls.append(b);return b}
 private func build(){
  guard let app,let content=window?.contentView else{return}
  let title=app.label("扫描游戏",size:24,weight:.semibold)
  let add=button("添加目录…"){[weak self] in self?.chooseSource()}
  let scan=button("扫描"){[weak self] in self?.scan()}
  let cancel=ActionButton("停止"){[weak self] in self?.cancellation?.cancel();self?.status.stringValue="正在停止…"}
  cancelAction=cancel;cancel.isEnabled=false
  sources.target=self;sources.action=#selector(sourceChanged);sources.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
  let sourceRow=app.stack([sources,add,scan,cancel],spacing:10)
  modes.selectedSegment=0;modes.target=self;modes.action=#selector(filterChanged)
  spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false
  status.maximumNumberOfLines=2;status.lineBreakMode = .byWordWrapping;status.textColor = .secondaryLabelColor;status.font = .systemFont(ofSize:12)
  let progress=app.stack([spinner,status],spacing:8)
  let filterRow=app.stack([modes,NSView(),progress],spacing:16)
  let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false;scroll.borderType = .noBorder;scroll.documentView=table
  table.delegate=self;table.dataSource=self;table.rowHeight=43;table.usesAlternatingRowBackgroundColors=true;table.selectionHighlightStyle = .none;table.intercellSpacing=NSSize(width:10,height:0);table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
  for (id,name,width) in [("check","",28.0),("title","游戏",220.0),("version","版本",115.0),("platform","平台",85.0),("language","语言",85.0),("entry","启动入口",300.0)] {
   let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=name;column.width=width;column.minWidth=id=="check" ? 28:65
   column.resizingMask=id=="entry" ? [.autoresizingMask,.userResizingMask]:id=="check" ? []:[.userResizingMask]
   table.addTableColumn(column)
  }
  let ignore=button("忽略所选"){[weak self] in self?.ignoreSelected()}
  let addSelected=button("加入本机游戏库"){[weak self] in self?.addSelected()}
  ignoreAction=ignore;addAction=addSelected
  selectedCount.font = .systemFont(ofSize:12);selectedCount.textColor = .secondaryLabelColor
  let share=button("共享所选"){[weak self] in self?.shareSelected()};shareAction=share
  let footer=app.stack([selectedCount,NSView(),ignore,share,addSelected],spacing:10)
  let layout=app.stack([title,sourceRow,filterRow,scroll,footer],vertical:true,spacing:18);app.pin(layout,to:content,inset:26)
  for view in [sourceRow,filterRow,scroll,footer]{view.widthAnchor.constraint(equalTo:layout.widthAnchor).isActive=true}
  scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true;scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
 }
 private var source:LibrarySource? {let index=sources.indexOfSelectedItem;return store.sources.indices.contains(index) ? store.sources[index]:nil}
 private var state:DiscoveryStatus {modes.selectedSegment==1 ? .added:modes.selectedSegment==2 ? .ignored:.pending}
 private func reloadSources(select id:UUID?=nil){
  let selected=id ?? source?.id;sources.removeAllItems()
  let names=Dictionary(grouping:store.sources,by:\.title)
  sources.addItems(withTitles:store.sources.map{(names[$0.title]?.count ?? 0)>1 ? $0.title+" · "+URL(fileURLWithPath:$0.path).deletingLastPathComponent().lastPathComponent:$0.title})
  if let selected,let index=store.sources.firstIndex(where:{$0.id==selected}){sources.selectItem(at:index)}
  sources.toolTip=source?.path;reloadRows()
 }
 @objc private func sourceChanged(){checked=[];status.stringValue="";sources.toolTip=source?.path;reloadRows()}
 @objc private func filterChanged(){checked=[];reloadRows()}
 private func chooseSource(){
  guard !scanning,let window else{return}
  let panel=NSOpenPanel();panel.title="选择游戏库目录";panel.prompt="选择";panel.canChooseDirectories=true;panel.canChooseFiles=false
  panel.beginSheetModal(for:window){[weak self] response in
   guard let self,!self.closed,response == .OK,let url=panel.url else{return}
   do{let source=try self.store.register(path:url);self.reloadSources(select:source.id);self.scan()}catch{self.status.stringValue=error.localizedDescription}
  }
 }
 func addDirectories(_ urls:[URL]){
  guard !scanning,!closed else{return}
  do{var first:UUID?;for url in urls{let value=try store.register(path:url);if first==nil{first=value.id}};reloadSources(select:first);scan()}catch{status.stringValue=error.localizedDescription}
 }
 private func setScanning(_ value:Bool){
  scanning=value;controls.forEach{$0.isEnabled = !value};cancelAction?.isEnabled=value;sources.isEnabled = !value;modes.isEnabled = !value
  if value{spinner.startAnimation(nil)}else{spinner.stopAnimation(nil)}
  table.reloadData();updateSelection()
 }
 private func scan(){
  guard !scanning,let source else{status.stringValue="请选择目录";return}
  let cancellation=DiscoveryCancellation();self.cancellation=cancellation;operation=UUID();let id=operation
  setScanning(true);status.stringValue="正在扫描…"
  DispatchQueue.global(qos:.userInitiated).async { [weak self] in
   let result=LibraryDiscovery.scan(source:source,cancelled:{cancellation.cancelled}){progress in
    if progress.visitedDirectories==1 || progress.visitedDirectories%10==0 {
     DispatchQueue.main.async{guard let self,!self.closed,self.operation==id else{return};self.status.stringValue="已扫描 \(progress.visitedDirectories) 个目录 · \(progress.foundGames) 款游戏";self.status.toolTip=progress.relativePath}
    }
   }
   let canonicalRoot=URL(fileURLWithPath:source.path).resolvingSymlinksInPath().standardizedFileURL
   DispatchQueue.main.async {
    guard let self,!self.closed,self.operation==id else{return}
    self.setScanning(false);self.cancellation=nil
    do {
     try self.store.apply(result,sourceID:source.id)
     if let app=self.app{try DiscoveryBinding.reconcile(discovery:self.store,source:source,canonicalRoot:canonicalRoot,games:app.store.games)}
     self.reloadRows()
     let detail=result.issues.prefix(1).map(\.message).joined()
     self.status.stringValue=(result.cancelled ? "已停止":result.completed ? "扫描完成":"扫描未完成")+" · \(result.games.count) 款游戏"+(detail.isEmpty ? "":" · "+detail)
    }catch{self.status.stringValue=error.localizedDescription}
   }
  }
 }
 private func reloadRows(){
  records=source.map{store.records(sourceID:$0.id).filter{state == .pending ? $0.status != .ignored:$0.status==state}.compactMap{record in
   var row=record;row.game.entries=row.game.entries.filter(SharedScanSelection.launchable)
   guard !row.game.entries.isEmpty else{return nil}
   if let selected=row.selectedEntry,!row.game.entries.contains(where:{$0.path==selected.path && $0.backend==selected.backend}){row.selectedEntry=nil}
   return row
  }.sorted{$0.game.relativePath.localizedStandardCompare($1.game.relativePath) == .orderedAscending}} ?? []
  checked.formIntersection(Set(records.map{$0.game.id}));table.reloadData();updateSelection()
 }
 private func selectionPolicy(_ record:DiscoveryRecord)->DiscoverySelectionPolicy{DiscoverySelectionPolicy(status:record.status,available:record.available,view:state,scanning:scanning,sharing:sharing)}
 private func updateSelection(){
  selectedCount.stringValue=checked.isEmpty ? "\(records.count) 项":"已选择 \(checked.count) 项"
  let selected=records.filter{checked.contains($0.game.id)}
  shareAction?.isEnabled = selected.contains{selectionPolicy($0).shareable}
  addAction?.isEnabled = selected.contains{selectionPolicy($0).importable}
  ignoreAction?.isEnabled = selected.contains{selectionPolicy($0).ignorable || selectionPolicy($0).restorable}
  ignoreAction?.title=state == .ignored ? "恢复所选":"忽略所选"
 }
 func numberOfRows(in tableView:NSTableView)->Int{records.count}
 private func entry(_ record:DiscoveryRecord)->Candidate {
  if let selected=record.selectedEntry,let current=record.game.entries.first(where:{$0.path==selected.path && $0.backend==selected.backend}){return current}
  return record.game.entries[0]
 }
 private func entryName(_ entry:Candidate,game:DiscoveredGame)->String{entry.path=="." ? game.title+".app":entry.path}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
  guard records.indices.contains(row),let column=tableColumn?.identifier.rawValue else{return nil}
  let record=records[row],chosen=entry(record)
  if column=="check" {
   let checkbox=NSButton(checkboxWithTitle:"",target:self,action:#selector(checkedChanged(_:)));checkbox.identifier=NSUserInterfaceItemIdentifier(record.game.id);checkbox.setAccessibilityLabel("选择 "+record.game.title);checkbox.state=checked.contains(record.game.id) ? .on:.off;checkbox.isEnabled = selectionPolicy(record).selectable;return checkbox
  }
  if column=="entry",record.game.entries.count>1 {
   let popup=NSPopUpButton();popup.identifier=NSUserInterfaceItemIdentifier(record.game.id);popup.addItems(withTitles:record.game.entries.map{entryName($0,game:record.game)})
   popup.selectItem(at:record.game.entries.firstIndex(of:chosen) ?? 0);popup.target=self;popup.action=#selector(entrySelected(_:));popup.isEnabled = selectionPolicy(record).shareable;return popup
  }
  let value:String
  switch column {
  case "title":value=record.game.title+(record.available ? "":" · 不可用")
  case "version":value=DiscoveryPresentation.version(relativePath:record.game.relativePath).replacingOccurrences(of:"（目录标记）",with:"").replacingOccurrences(of:"未知",with:"—")
  case "platform":value=DiscoveryPresentation.platform(entry:chosen)
  case "language":value=DiscoveryPresentation.language(entry:chosen,relativePath:record.game.relativePath).replacingOccurrences(of:"标记",with:"").replacingOccurrences(of:"未知",with:"—")
  case "entry":value=entryName(chosen,game:record.game)
  default:value=""
  }
  let text=NSTextField(labelWithString:value);text.font = .systemFont(ofSize:13,weight:column=="title" ? .medium:.regular);text.lineBreakMode = .byTruncatingMiddle;text.toolTip=record.game.relativePath;text.textColor=record.available ? .labelColor:.secondaryLabelColor;return text
 }
 @objc private func checkedChanged(_ button:NSButton){guard let id=button.identifier?.rawValue,let record=records.first(where:{$0.game.id==id}),selectionPolicy(record).selectable else{return};if button.state == .on{checked.insert(id)}else{checked.remove(id)};updateSelection()}
 @objc private func entrySelected(_ popup:NSPopUpButton){
  guard !scanning,let id=popup.identifier?.rawValue,let record=records.first(where:{$0.game.id==id}),record.game.entries.indices.contains(popup.indexOfSelectedItem),selectionPolicy(record).shareable else{return}
  do{try store.select(id,entry:record.game.entries[popup.indexOfSelectedItem]);reloadRows()}catch{status.stringValue=error.localizedDescription}
 }
 private func addSelected(){
  guard let app,let source,!scanning,!app.busy,state == .pending else{return}
  var count=0,errors:[String]=[],added:[Game]=[],previous=Set(app.store.games.map(\.id))
  for record in records where checked.contains(record.game.id) && selectionPolicy(record).importable {
   do{
    let chosen=entry(record),folder=URL(fileURLWithPath:source.path).appendingPathComponent(record.game.relativePath)
    var game=try app.store.add(source:folder,candidate:chosen)
    if !previous.contains(game.id),game.title != record.game.title{game.title=record.game.title;try app.store.update(game)}
    game=try app.applyKnownMetadata(game)
    previous.insert(game.id);try store.markAdded(record.game.id,entry:chosen,gameID:game.id);count+=1;added.append(game)
   }catch{errors.append(error.localizedDescription)}
  }
  checked=[];reloadRows();app.showLibrary();status.stringValue="已添加 \(count) 款游戏"+(errors.first.map{" · "+$0} ?? "")
  if UserDefaults.standard.object(forKey:"AutoOnlineCover") as? Bool != false{for game in added where game.cover==nil{app.findCover(game,automatic:true)}}
 }
 private func shareSelected(){
  guard !scanning,!sharing,let app,!app.busy,let source else{return}
  let selected=records.filter{checked.contains($0.game.id) && selectionPolicy($0).shareable}
  guard !selected.isEmpty else{return};sharing=true;table.reloadData();updateSelection();status.stringValue="正在准备共享…"
  app.shareScanned(selected,source:source){[weak self] message in guard let self,!self.closed else{return};self.sharing=false;self.table.reloadData();self.status.stringValue=message;self.updateSelection()}
 }
 private func ignoreSelected(){
  guard !scanning else{return}
  do{
   for record in records where checked.contains(record.game.id) && (selectionPolicy(record).ignorable || selectionPolicy(record).restorable){if state == .ignored{try store.restore(record.game.id)}else{try store.ignore(record.game.id)}}
   checked=[];reloadRows();status.stringValue=state == .ignored ? "已恢复所选项目":"已忽略所选项目"
  }catch{status.stringValue=error.localizedDescription}
 }
}
