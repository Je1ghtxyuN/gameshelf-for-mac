import AppKit
import UniformTypeIdentifiers

final class SharedLibraryWindowController:NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
 private enum Page {case servers,address,login,catalog,retry,account}
 private weak var app:App?
 private let store:SharedConnectionStore
 private var page:Page = .address
 private var selected:SharedConnection? {
  didSet{if oldValue != selected{administrationWindow?.close();administrationWindow=nil}}
 }
 private var server:SharedServerInfo?
 private let address=NSTextField(string:"")
 private let username=NSTextField(string:"")
 private let password=NSSecureTextField(string:"")
 private let remember=NSButton(checkboxWithTitle:"保持登录",target:nil,action:nil)
 private var pin:String?
 private var invitationName:String?
 private var api:SharedAPI?
 private var operation=UUID()
 private var closed=false
 private var loading=false
 private var feedback=""
 private var feedbackIsError=false
 private var controls:[NSControl]=[]
 private var message:NSTextField?
 private var spinner:NSProgressIndicator?
 private var addButton:NSButton?
 private var selectionLabel:NSTextField?
 private var rows:[(SharedCatalogGame,NSButton,NSPopUpButton)]=[]
 private var games:[SharedCatalogGame]=[]
 private var administratorSetupWindow:AdministratorSetupWindowController?
 private var administrationWindow:SharedAdministrationWindowController?
 private var accountRequested=false

 func openLibrary(){
  accountRequested=false
  let binding=app.flatMap{try? PersonalLibraryBindingStore(root:$0.root)}?.binding
  if let connection=SharedNavigation.preferred(connections:store.connections,boundID:binding?.connectionID){choose(connection)}
  else{showServers()}
 }
 func openAccount(connectionID:UUID){
  accountRequested=true
  guard let connection=store.connections.first(where:{$0.id==connectionID}) else{showServers();return}
  choose(connection)
 }

 init(app:App)throws {
  self.app=app;store=try SharedConnectionStore(root:app.root)
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:550),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
  super.init(window:window)
  window.title="共享游戏库";window.isReleasedWhenClosed=false;window.delegate=self;window.appearance=NSAppearance(named:.aqua)
  address.placeholderString="服务器地址";username.placeholderString="账号";password.placeholderString="密码"
  address.delegate=self;username.delegate=self;password.delegate=self;remember.state = .on
  page=store.connections.isEmpty ? .address:.servers
  render();window.center()
 }
 required init?(coder:NSCoder){fatalError()}
 func windowWillClose(_ notification:Notification){closed=true;operation=UUID();password.stringValue="";administrationWindow?.close();app?.sharedLibraryWindow=nil}
 func controlTextDidBeginEditing(_ obj:Notification){(obj.object as? NSTextField)?.superview.flatMap{$0 as? SharedLoginInput}?.focus(true)}
 func controlTextDidEndEditing(_ obj:Notification){(obj.object as? NSTextField)?.superview.flatMap{$0 as? SharedLoginInput}?.focus(false)}
 private func label(_ value:String,size:CGFloat=14,weight:NSFont.Weight = .regular,secondary:Bool=false)->NSTextField {
  let label=NSTextField(labelWithString:value);label.font = .systemFont(ofSize:size,weight:weight);label.textColor=secondary ? .secondaryLabelColor:.labelColor;return label
 }
 private func stack(_ views:[NSView],vertical:Bool=true,spacing:CGFloat=12)->NSStackView {
  let result=NSStackView(views:views);result.orientation=vertical ? .vertical:.horizontal;result.spacing=spacing;result.alignment=vertical ? .leading:.centerY;return result
 }
 private func action(_ title:String,primary:Bool=false,_ block:@escaping()->Void)->NSButton {
  let button:ActionButton=primary ? SharedLoginPrimary(title,block):ActionButton(title,block)
  button.font = .systemFont(ofSize:13,weight:primary ? .semibold:.regular)
  if primary{button.isBordered=false;button.heightAnchor.constraint(equalToConstant:44).isActive=true;button.keyEquivalent="\r"}
  controls.append(button);return button
 }
 private func link(_ title:String,_ block:@escaping()->Void)->NSButton {
  let button=action(title,block);button.isBordered=false;button.contentTintColor = .controlAccentColor;button.alignment = .left;return button
 }
 private func field(_ title:String,_ input:NSTextField)->NSView {
  let box=SharedLoginInput(field:input),group=stack([label(title,size:12,weight:.medium),box],spacing:7)
  box.widthAnchor.constraint(equalTo:group.widthAnchor).isActive=true
  return group
 }
 private func render(){
  guard let window,let root=window.contentView else{return}
  root.subviews.forEach{$0.removeFromSuperview()};controls=[];message=nil;spinner=nil;addButton=nil
  root.wantsLayer=true;root.layer?.backgroundColor=NSColor.white.cgColor
  if page == .catalog{renderCatalog(root);return}
  if page == .account{renderAccount(root);return}
  window.title="共享游戏库"
  window.styleMask.remove(.resizable)
  window.minSize=NSSize(width:800,height:578)
  let art=SharedLoginArtwork();art.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(art)
  let panel=NSView();panel.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(panel)
  NSLayoutConstraint.activate([art.leadingAnchor.constraint(equalTo:root.leadingAnchor),art.topAnchor.constraint(equalTo:root.topAnchor),art.bottomAnchor.constraint(equalTo:root.bottomAnchor),art.widthAnchor.constraint(equalToConstant:235),panel.leadingAnchor.constraint(equalTo:art.trailingAnchor),panel.trailingAnchor.constraint(equalTo:root.trailingAnchor),panel.topAnchor.constraint(equalTo:root.topAnchor),panel.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
  let form=stack([],spacing:16);form.translatesAutoresizingMaskIntoConstraints=false;panel.addSubview(form)
  NSLayoutConstraint.activate([form.widthAnchor.constraint(equalToConstant:355),form.centerXAnchor.constraint(equalTo:panel.centerXAnchor),form.centerYAnchor.constraint(equalTo:panel.centerYAnchor),form.topAnchor.constraint(greaterThanOrEqualTo:panel.topAnchor,constant:24),form.bottomAnchor.constraint(lessThanOrEqualTo:panel.bottomAnchor,constant:-24)])
  func add(_ view:NSView){form.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:form.widthAnchor).isActive=true}
  switch page {
  case .servers:
   add(label("选择服务器",size:25,weight:.semibold))
   let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true
   let document=FlippedView();document.translatesAutoresizingMaskIntoConstraints=false;scroll.documentView=document
   let list=stack([],spacing:9);app?.pin(list,to:document,inset:1)
   NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),document.topAnchor.constraint(equalTo:scroll.contentView.topAnchor),document.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),scroll.heightAnchor.constraint(equalToConstant:min(195,CGFloat(store.connections.count)*66))])
   for connection in store.connections {
    let button=action(connection.name){[weak self] in self?.choose(connection)}
    let title=NSMutableAttributedString(string:connection.name+"\n",attributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:NSColor.labelColor])
    title.append(NSAttributedString(string:host(connection.address)+" · "+connection.username,attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.secondaryLabelColor]))
    button.attributedTitle=title;button.alignment = .left;button.isBordered=false;button.wantsLayer=true;button.layer?.cornerRadius=9;button.layer?.backgroundColor=NSColor(calibratedWhite:0.96,alpha:1).cgColor
    button.image=NSImage(systemSymbolName:"server.rack",accessibilityDescription:nil);button.imagePosition = .imageLeading
    list.addArrangedSubview(button);button.widthAnchor.constraint(equalTo:list.widthAnchor).isActive=true;button.heightAnchor.constraint(equalToConstant:58).isActive=true
   }
   add(scroll)
   add(action("添加服务器",primary:true){[weak self] in self?.newServer()})
   add(link("使用邀请文件…"){[weak self] in self?.importInvitation()})
  case .address:
   add(label("连接游戏库",size:25,weight:.semibold))
   add(field("服务器地址",address));controls.append(address)
   add(action("继续",primary:true){[weak self] in self?.connect()})
   let options=stack([link("使用邀请文件…"){[weak self] in self?.importInvitation()},NSView(),link("高级设置"){[weak self] in self?.advanced()}],vertical:false,spacing:8)
   add(options)
   add(link("创建共享库…"){[weak self] in self?.beginAdministratorSetup()})
   if !store.connections.isEmpty{add(link("返回已连接的服务器"){[weak self] in self?.showServers()})}
  case .login:
   add(label("欢迎回来",size:25,weight:.semibold))
   let icon=NSImageView(image:NSImage(systemSymbolName:"server.rack",accessibilityDescription:nil)!)
   let serverName=label(server?.name ?? "共享游戏库",size:13,weight:.medium)
   let change=link("切换服务器"){[weak self] in self?.showServers()}
   add(stack([icon,serverName,NSView(),change],vertical:false,spacing:8))
   add(field("账号",username));add(field("密码",password));controls += [username,password]
   remember.font = .systemFont(ofSize:12);remember.state=(selected?.rememberLogin ?? true) ? .on:.off
   controls.append(remember);add(remember)
   add(action("登录",primary:true){[weak self] in self?.login()})
  case .retry:
   add(label("暂时无法连接",size:24,weight:.semibold))
   add(label(selected?.name ?? server?.name ?? "共享游戏库",size:14,secondary:true))
   add(action("重试连接",primary:true){[weak self] in self?.loadCatalog()})
   add(link("检查连接设置"){[weak self] in self?.page = .address;self?.feedback="";self?.render()})
   add(link("选择其他服务器"){[weak self] in self?.showServers()})
  case .catalog,.account:break
  }
  let progress=NSProgressIndicator();progress.style = .spinning;progress.controlSize = .small;progress.isDisplayedWhenStopped=false
  let text=label(feedback,size:12,secondary:!feedbackIsError);text.maximumNumberOfLines=3;text.lineBreakMode = .byWordWrapping
  let status=stack([progress,text],vertical:false,spacing:7);add(status);message=text;spinner=progress
  window.setContentSize(NSSize(width:800,height:550));applyLoading()
  if !loading{window.makeFirstResponder(page == .login ? (username.stringValue.isEmpty ? username:password):page == .address ? address:nil)}
 }
 private func renderCatalog(_ root:NSView){
  guard let app,let window,let connection=selected else{return}
  window.styleMask.insert(.resizable);window.minSize=NSSize(width:850,height:560);window.title=connection.name+" · 共享游戏库"
  let title=stack([label(connection.name,size:24,weight:.semibold),label(host(connection.address),size:12,secondary:true)],spacing:5)
  let refresh=action(""){[weak self] in self?.loadCatalog()}
  refresh.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"刷新游戏");refresh.toolTip="刷新游戏";refresh.isBordered=false
  let account=action("账号"){[weak self] in self?.openAccount(connectionID:connection.id)}
  account.image=NSImage(systemSymbolName:"person.crop.circle",accessibilityDescription:nil);account.imagePosition = .imageLeading
  let change=action("切换服务器"){[weak self] in self?.showServers()}
  var headerViews:[NSView]=[title,NSView(),refresh,change,account]
  if connection.isAdministrator{headerViews.append(action("添加游戏"){[weak self] in self?.openAdministration()})}
  if connection.isAdministrator{headerViews.append(action("服务器管理"){[weak self] in self?.openAdministration()})}
  let header=stack(headerViews,vertical:false,spacing:12)
  let text=label(feedback,size:12,secondary:!feedbackIsError);text.maximumNumberOfLines=2;message=text
  let progress=NSProgressIndicator();progress.style = .spinning;progress.controlSize = .small;progress.isDisplayedWhenStopped=false;spinner=progress
  let status=stack([progress,text],vertical:false,spacing:8)
  let separator=NSBox();separator.boxType = .separator
  let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false
  let document=FlippedView();document.translatesAutoresizingMaskIntoConstraints=false;scroll.documentView=document
  NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),document.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),document.topAnchor.constraint(equalTo:scroll.contentView.topAnchor)])
  let list=stack([],spacing:14);app.pin(list,to:document,inset:8);rows=[]
  for game in games where !game.entries.isEmpty {
   let checkbox=NSButton(checkboxWithTitle:game.title,target:self,action:#selector(selectionChanged));checkbox.font = .systemFont(ofSize:15,weight:.medium);checkbox.lineBreakMode = .byTruncatingTail;checkbox.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
   let popup=NSPopUpButton();popup.addItems(withTitles:game.entries.map{$0.path+" · "+DiscoveryPresentation.platform(entry:$0)});popup.widthAnchor.constraint(equalToConstant:300).isActive=true
   let row=stack([checkbox,NSView(),popup],vertical:false,spacing:14);list.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:list.widthAnchor).isActive=true;row.heightAnchor.constraint(greaterThanOrEqualToConstant:38).isActive=true;rows.append((game,checkbox,popup))
  }
  if rows.isEmpty{list.addArrangedSubview(label("暂无可用游戏",size:14,secondary:true))}
  let selectedCount=label("\(rows.count) 款游戏",size:12,secondary:true);selectionLabel=selectedCount
  let add=action("添加到游戏库",primary:true){[weak self] in self?.addSelected()};add.widthAnchor.constraint(equalToConstant:155).isActive=true;addButton=add
  let footer=stack([selectedCount,NSView(),add],vertical:false,spacing:12)
  let layout=stack([header,status,separator,scroll,footer],spacing:18);app.pin(layout,to:root,inset:28)
  for view in [header,status,separator,scroll,footer]{view.widthAnchor.constraint(equalTo:layout.widthAnchor).isActive=true}
  scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive=true;scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
  window.setContentSize(NSSize(width:940,height:620));applyLoading();selectionChanged()
 }
 private func renderAccount(_ root:NSView){
  guard let app,let window,let connection=selected else{return}
  window.title="账号";window.styleMask.remove(.resizable);window.minSize=NSSize(width:680,height:550)
  root.layer?.backgroundColor=NSColor(calibratedWhite:0.98,alpha:1).cgColor
  let back=action("返回共享库"){[weak self] in self?.accountRequested=false;self?.page = .catalog;self?.render();self?.loadCatalog()}
  back.image=NSImage(systemSymbolName:"chevron.left",accessibilityDescription:nil);back.imagePosition = .imageLeading
  let heading=stack([label("账号",size:27,weight:.bold),NSView(),back],vertical:false)
  let form=stack([heading],spacing:22);app.pin(form,to:root,inset:32);heading.widthAnchor.constraint(equalTo:form.widthAnchor).isActive=true
  func card(_ heading:String,_ contents:[NSView]){
   let box=NSView();box.wantsLayer=true;box.layer?.backgroundColor=NSColor.white.cgColor;box.layer?.cornerRadius=12;box.layer?.borderWidth=1;box.layer?.borderColor=NSColor.separatorColor.withAlphaComponent(0.45).cgColor
   let group=stack([label(heading,size:13,weight:.semibold)]+contents,spacing:12);app.pin(group,to:box,inset:20)
   form.addArrangedSubview(box);box.widthAnchor.constraint(equalTo:form.widthAnchor).isActive=true
  }
  let identity=stack([label(connection.username,size:25,weight:.semibold),NSView(),label(connection.isAdministrator ? "管理员":"普通账号",size:13,secondary:true)],vertical:false)
  card("当前账号",[identity,label(connection.name,size:14),label(host(connection.address),size:13,secondary:true)])
  let bound=(try? PersonalLibraryBindingStore(root:app.root))?.binding
  let isBound=bound?.connectionID==connection.id && bound?.serverID==connection.serverID && bound?.accountID==connection.accountID
  let sync=action(isBound ? "同步资料":"绑定游戏库资料…"){[weak self] in
   if isBound{self?.app?.syncPersonalLibrary(force:true)}else{self?.bindPersonalLibrary()}
  }
  card("个人游戏库",[label(isBound ? "已绑定 · \(app.store.games.count) 款游戏":"未绑定",size:15),stack([sync,NSView()],vertical:false)])
  var footer:[NSView]=[action("切换服务器"){[weak self] in self?.accountRequested=false;self?.showServers()}]
  if connection.isAdministrator{footer.append(action("服务器管理"){[weak self] in self?.openAdministration()})}
  footer += [NSView(),action("退出登录"){[weak self] in self?.logout()}]
  let progress=NSProgressIndicator();progress.style = .spinning;progress.controlSize = .small;progress.isDisplayedWhenStopped=false;spinner=progress
  let text=label(feedback,size:12,secondary:!feedbackIsError);text.maximumNumberOfLines=2;message=text
  form.addArrangedSubview(stack([progress,text],vertical:false));form.addArrangedSubview(NSView())
  let actions=stack(footer,vertical:false);form.addArrangedSubview(actions);actions.widthAnchor.constraint(equalTo:form.widthAnchor).isActive=true
  window.setContentSize(NSSize(width:680,height:550));applyLoading()
 }
 private func host(_ value:String)->String{URL(string:value)?.host ?? value}
 private func applyLoading(){
  controls.forEach{$0.isEnabled = !loading}
  if loading{spinner?.startAnimation(nil)}else{spinner?.stopAnimation(nil)}
  message?.stringValue=feedback;message?.textColor=feedbackIsError ? .systemRed:.secondaryLabelColor
  controls.compactMap{$0 as? SharedLoginPrimary}.forEach{$0.needsDisplay=true}
  if page == .catalog{selectionChanged()}
 }
 private func status(_ value:String,error:Bool=false){feedback=value;feedbackIsError=error;applyLoading()}
 private func start(_ value:String){loading=true;feedback=value;feedbackIsError=false;applyLoading()}
 private func finish(_ value:String="",error:Bool=false){loading=false;status(value,error:error)}
 private func friendly(_ error:Error)->String{
  let ns=error as NSError
  if ns.domain==NSURLErrorDomain {
   if [-1200,-1201,-1202,-1203,-1204].contains(ns.code){return "无法验证服务器身份。请使用管理员提供的邀请文件，或检查高级连接设置。"}
   return "连接不上服务器，请检查地址和网络后重试。"
  }
  return error.localizedDescription
 }
 private func showServers(){
  operation=UUID();loading=false;password.stringValue="";selected=nil;server=nil;games=[];pin=nil;invitationName=nil;feedback="";feedbackIsError=false
  page=store.connections.isEmpty ? .address:.servers;render()
 }
 private func newServer(){showServers();address.stringValue="";page = .address;render()}
 private func choose(_ connection:SharedConnection){
  loading=false
  operation=UUID();selected=connection;server=SharedServerInfo(name:connection.name,serverID:connection.serverID,version:"");address.stringValue=connection.address;username.stringValue=connection.username;password.stringValue="";pin=connection.certificateSHA256;feedback="";feedbackIsError=false
  let authenticated=(try? app?.sharedToken(for:connection)) != nil
  switch SharedNavigation.destination(accountRequested:accountRequested,authenticated:authenticated){
  case .account:page = .account;loading=false;render();loadCatalog()
  case .catalog:page = .retry;render();loadCatalog()
  case .login:page = .login;render()
  }
 }
 private func connect(){
  do {
   let normalized=try SharedServerAddress.userInput(address.stringValue)
   let client=try SharedAPI(address:normalized.absoluteString,certificateSHA256:pin);api=client;address.stringValue=normalized.absoluteString
   operation=UUID();let id=operation;start("正在连接服务器…")
   client.request("/api/server-info"){[weak self] (result:Result<SharedServerInfo,Error>) in DispatchQueue.main.async {
    guard let self,!self.closed,self.operation==id else{return}
    self.loading=false
    do{
     var info=try result.get()
     guard !info.serverID.isEmpty,info.serverID.count<=128 else{throw LibraryError("此服务器的身份信息无效。")}
     if let old=self.selected,old.serverID != info.serverID{throw LibraryError("服务器身份发生变化，请确认地址后添加为新的服务器。")}
     let name=info.name.trimmingCharacters(in:.whitespacesAndNewlines);info.name=name.isEmpty || name.count>80 ? self.host(self.address.stringValue):name
     self.server=info
     if info.setupRequired==true{self.page = .address;self.feedback="等待管理员初始化";self.feedbackIsError=false;self.render();self.beginAdministratorSetup();return}
     self.page = .login;self.feedback="";self.feedbackIsError=false;self.render()
    }catch{self.finish(self.friendly(error),error:true)}
   }}
  }catch{finish(friendly(error),error:true)}
 }
 private func login(){
  guard let info=server,let app else{return}
  guard !username.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!password.stringValue.isEmpty else{status("请输入账号和密码。",error:true);return}
  do {
   let client=try SharedAPI(address:address.stringValue,certificateSHA256:pin);api=client;operation=UUID();let id=operation
   let keep=remember.state == .on;start("正在登录…")
   client.login(username:username.stringValue,password:password.stringValue){[weak self] result in DispatchQueue.main.async {
    guard let self,!self.closed,self.operation==id else{return}
    do {
     let response=try result.get()
     guard response.serverID==info.serverID else{throw LibraryError("服务器身份不匹配，请重新选择服务器。")}
     var connection=SharedConnection(name:info.name,address:client.address.absoluteString,serverID:response.serverID,accountID:response.user.id,username:response.user.username,isAdministrator:response.user.admin,certificateSHA256:self.pin,rememberLogin:keep)
     if let existing=self.store.connections.first(where:{$0.serverID==connection.serverID && $0.accountID==connection.accountID}){connection.id=existing.id}
     if keep{try SharedCredentialStore.save(token:response.token,connectionID:connection.id)}
     else{try SharedCredentialStore.delete(connectionID:connection.id)}
     try self.store.save(connection);app.sharedAccessTokens[connection.id]=response.token
     self.password.stringValue="";self.selected=connection;self.loading=false;self.games=[];self.page = self.accountRequested ? .account:.catalog;self.render();if !self.accountRequested{self.loadCatalog()}
    }catch{
     let message=(error as? SharedRequestError)?.statusCode==401 ? "账号或密码不正确，请重试。":self.friendly(error)
     self.finish(message,error:true)
    }
   }}
  }catch{finish(friendly(error),error:true)}
 }
 private func loadCatalog(){
  guard let connection=selected,let app else{return}
  do {
   guard let token=try app.sharedToken(for:connection) else{page = .login;loading=false;feedback="";render();return}
   let client=try SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256);api=client;operation=UUID();let id=operation
   start("正在加载游戏库…")
   client.catalog(token:token){[weak self] result in DispatchQueue.main.async {
    guard let self,!self.closed,self.operation==id else{return}
    self.loading=false
    do{
     self.games=try result.get().games;self.page = self.accountRequested ? .account:.catalog;self.feedback="";self.feedbackIsError=false;self.render()
     for remote in self.games {
      if let game=app.store.games.first(where:{$0.shared?.serverID==connection.serverID && $0.shared?.accountID==connection.accountID && $0.shared?.gameID==remote.id}){app.fetchSharedDefaultCover(remote,connection:connection,game:game)}
     }
    }
    catch{
     if (error as? SharedRequestError)?.statusCode==401{self.page = .login;self.feedback="登录已过期"}
     else{self.page = .retry;self.feedback=self.friendly(error)}
     self.feedbackIsError=true;self.render()
    }
   }}
  }catch{loading=false;page = .login;feedback="请重新登录以继续。";feedbackIsError=true;render()}
 }
 @objc private func selectionChanged(){
  let count=rows.filter{$0.1.state == .on}.count
  selectionLabel?.stringValue=count==0 ? "\(rows.count) 款游戏":"已选择 \(count) 款游戏"
  addButton?.isEnabled = !loading && count>0;addButton?.needsDisplay=true
 }
 private func addSelected(){
  guard let app,let connection=selected,!app.busy else{return}
  do{
   var count=0
   for (game,checkbox,popup) in rows where checkbox.state == .on {
    guard game.entries.indices.contains(popup.indexOfSelectedItem) else{continue}
    let added=try app.store.addShared(game,entry:game.entries[popup.indexOfSelectedItem],connection:connection,mountRoot:app.root);app.fetchSharedDefaultCover(game,connection:connection,game:added);checkbox.state = .off;count+=1
   }
   app.showLibrary();finish("已添加 \(count) 款游戏。");selectionChanged()
  }catch{finish(friendly(error),error:true)}
 }
 private func advanced(){
  guard !loading else{return}
  let alert=NSAlert();alert.messageText="高级连接设置"
  let field=NSTextField(string:pin ?? "");field.placeholderString="SHA-256 证书指纹（可选）";field.frame=NSRect(x:0,y:0,width:420,height:26);alert.accessoryView=field;alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
  if alert.runModal() == .alertFirstButtonReturn {do{pin=try SharedServerAddress.certificatePin(field.stringValue);status(pin==nil ? "":"已应用管理员提供的连接设置。")}catch{status(friendly(error),error:true)}}
 }
 func beginAdministratorSetup(){importInvitation(administratorOnly:true)}
 private func importInvitation(administratorOnly:Bool=false){
  guard let window,!loading else{return}
  let panel=NSOpenPanel();panel.title="选择邀请文件";panel.prompt="导入";panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
  panel.beginSheetModal(for:window){[weak self] response in
   guard let self,!self.closed,response == .OK,let url=panel.url else{return}
   do{
    let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
    let data=try handle.read(upToCount:4097) ?? Data()
    if administratorOnly || (try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["kind"] as? String=="administrator-setup" {
     let invitation=try AdministratorSetupInvitation.read(data)
     self.administratorSetupWindow=AdministratorSetupWindowController(invitation:invitation){[weak self] response in
      guard let self,let app=self.app else{return}
      do{
       var connection=SharedConnection(name:invitation.name ?? "GameShelf",address:invitation.address,serverID:response.serverID,accountID:response.user.id,username:response.user.username,isAdministrator:response.user.admin,certificateSHA256:invitation.certificateSHA256,rememberLogin:true)
       if let existing=self.store.connections.first(where:{$0.serverID==connection.serverID && $0.accountID==connection.accountID}){connection.id=existing.id}
       try SharedCredentialStore.save(token:response.token,connectionID:connection.id);try self.store.save(connection);app.sharedAccessTokens[connection.id]=response.token
       self.selected=connection;self.loading=false;self.page = .catalog;self.render();self.loadCatalog()
      }catch{self.finish(error.localizedDescription,error:true)}
     }
     self.administratorSetupWindow?.showWindow(nil);self.administratorSetupWindow?.window?.makeKeyAndOrderFront(nil);return
    }
    let invitation=try SharedServerInvitation.read(data)
    self.operation=UUID();self.selected=nil;self.server=nil;self.password.stringValue="";self.pin=invitation.certificateSHA256;self.invitationName=invitation.name;self.address.stringValue=invitation.address;self.page = .address;self.feedback=invitation.name.map{"邀请已载入 · "+$0} ?? "邀请已载入";self.feedbackIsError=false;self.render()
   }catch{self.finish("无法读取这个邀请文件，请向管理员确认。",error:true)}
  }
 }
 private func openAdministration(){
  guard let connection=selected,connection.isAdministrator,let app else{return}
  do{
   if administrationWindow==nil{administrationWindow=try SharedAdministrationWindowController(app:app,connection:connection,showGames:true,changed:{[weak self] in
    guard let self,!self.closed,self.selected?.id==connection.id else{return};self.loadCatalog()
   },onClose:{[weak self] in self?.administrationWindow=nil})}
   administrationWindow?.showWindow(nil);administrationWindow?.window?.makeKeyAndOrderFront(nil)
  }catch{status(error.localizedDescription,error:true)}
 }
 private func bindPersonalLibrary(){
  guard let connection=selected,let app else{return}
  let alert=NSAlert();alert.messageText="绑定到 "+connection.username+"？"
  alert.informativeText="游戏名称、封面、分类、收藏和时长将保存到「"+connection.name+"」的个人账号。游戏文件与存档位置保留。"
  alert.addButton(withTitle:"绑定");alert.addButton(withTitle:"取消")
  if alert.runModal() == .alertFirstButtonReturn{app.bindPersonalLibrary(to:connection);if page == .account{render()}}
 }
 private func logout(){
  guard let connection=selected,let app else{return}
  guard app.sharedSessions.isEmpty else{status("请先保存并退出正在运行的共享游戏。",error:true);return}
  do{
   if let token=try app.sharedToken(for:connection),let client=try? SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256){api=client;client.request("/api/logout",method:"POST",token:token){(_:Result<SharedOK,Error>) in}}
   try SharedCredentialStore.delete(connectionID:connection.id);app.sharedAccessTokens.removeValue(forKey:connection.id)
   password.stringValue="";games=[];page = .login;feedback="";feedbackIsError=false;render()
  }catch{status(friendly(error),error:true)}
 }
}
struct SharedOK:Codable {var ok:Bool?=nil}
