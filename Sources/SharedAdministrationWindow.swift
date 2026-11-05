import AppKit

/// Account management only. Scanning and playing have their own existing surfaces.
final class SharedAdministrationWindowController:NSWindowController,NSWindowDelegate {
 private weak var app:App?
 private let connection:SharedConnection,changed:()->Void,onClose:()->Void,signedOut:()->Void
 private var users:[SharedAdminUser]=[],games:[SharedCatalogGame]=[],grants:[SharedAdminGrant]=[]
 private var selectedID:String?,closed=false,busy=false,feedback=""
 private let sidebar=NSStackView(),body=NSView(),message=NSTextField(labelWithString:"")
 private let newName=NSTextField(),newPassword=NSSecureTextField()
 private var controls:[NSControl]=[],passwordWindow:PasswordWindowController?
 private var task:Task<Void,Never>?
 init(app:App,connection:SharedConnection,changed:@escaping()->Void,onClose:@escaping()->Void,signedOut:@escaping()->Void={})throws{
  guard connection.isAdministrator else{throw LibraryError("需要管理员账号。")}
  self.app=app;self.connection=connection;self.changed=changed;self.onClose=onClose;self.signedOut=signedOut;selectedID=connection.accountID
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
  super.init(window:window);window.title="账号管理";window.minSize=NSSize(width:790,height:530);window.isReleasedWhenClosed=false;window.delegate=self;window.appearance=NSAppearance(named:.aqua)
  build();render();window.center();refresh()
 }
 required init?(coder:NSCoder){fatalError()}
 func windowWillClose(_ notification:Notification){closed=true;newPassword.stringValue="";passwordWindow?.close();onClose()}
 private func label(_ title:String,_ size:CGFloat=14,_ weight:NSFont.Weight = .regular)->NSTextField{let t=NSTextField(labelWithString:title);t.font = .systemFont(ofSize:size,weight:weight);t.lineBreakMode = .byTruncatingTail;return t}
 private func stack(_ views:[NSView],vertical:Bool=false,spacing:CGFloat=12)->NSStackView{let s=NSStackView(views:views);s.orientation=vertical ? .vertical:.horizontal;s.alignment=vertical ? .leading:.centerY;s.spacing=spacing;return s}
 private func button(_ title:String,_ action:@escaping()->Void)->NSButton{let b=ActionButton(title,action);b.bezelStyle = .rounded;controls.append(b);return b}
 private func pin(_ view:NSView,to parent:NSView,inset:CGFloat=0){view.translatesAutoresizingMaskIntoConstraints=false;parent.addSubview(view);NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),view.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])}
 private func build(){
  let root=window!.contentView!;root.wantsLayer=true;root.layer?.backgroundColor=NSColor.white.cgColor
  let side=NSView();side.wantsLayer=true;side.layer?.backgroundColor=NSColor(calibratedWhite:0.95,alpha:1).cgColor;sidebar.orientation = .vertical;sidebar.alignment = .leading;sidebar.spacing=10;pin(sidebar,to:side,inset:20)
  side.translatesAutoresizingMaskIntoConstraints=false;body.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(side);root.addSubview(body)
  NSLayoutConstraint.activate([side.leadingAnchor.constraint(equalTo:root.leadingAnchor),side.topAnchor.constraint(equalTo:root.topAnchor),side.bottomAnchor.constraint(equalTo:root.bottomAnchor),side.widthAnchor.constraint(equalToConstant:220),body.leadingAnchor.constraint(equalTo:side.trailingAnchor),body.trailingAnchor.constraint(equalTo:root.trailingAnchor),body.topAnchor.constraint(equalTo:root.topAnchor),body.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
 }
 private func render(){
  guard !closed else{return};body.subviews.forEach{$0.removeFromSuperview()};sidebar.arrangedSubviews.forEach{sidebar.removeArrangedSubview($0);$0.removeFromSuperview()};controls=[]
  sidebar.addArrangedSubview(label("账号管理",21,.semibold));sidebar.addArrangedSubview(button("创建账号"){[weak self] in self?.selectedID=nil;self?.render()})
  for user in users{let b=button(user.username+(user.admin ? " · 管理员":"")+(user.disabled ? " · 已停用":"")){[weak self] in self?.selectedID=user.id;self?.render()};b.isBordered=false;b.alignment = .left;b.contentTintColor=selectedID==user.id ? .controlAccentColor:.labelColor;sidebar.addArrangedSubview(b);b.widthAnchor.constraint(equalTo:sidebar.widthAnchor).isActive=true;b.heightAnchor.constraint(equalToConstant:36).isActive=true}
  sidebar.addArrangedSubview(NSView())
  let content=stack([],vertical:true,spacing:20);pin(content,to:body,inset:28)
  func add(_ v:NSView){content.addArrangedSubview(v);v.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true}
  if let user=users.first(where:{$0.id==selectedID}){
   add(label(user.username,26,.semibold))
   var actions:[NSView]=[button(user.id==connection.accountID ? "修改密码":"重置密码"){[weak self] in self?.editPassword(user)}]
   if user.id != connection.accountID && !user.disabled{actions.append(button("停用账号"){[weak self] in self?.disable(user)})}
   actions.append(NSView());add(stack(actions));add(label("可玩的游戏",16,.semibold))
   let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false;let doc=FlippedView();doc.translatesAutoresizingMaskIntoConstraints=false;scroll.documentView=doc
   let list=stack([],vertical:true);pin(list,to:doc,inset:4);NSLayoutConstraint.activate([doc.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),doc.topAnchor.constraint(equalTo:scroll.contentView.topAnchor),doc.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor)])
   for game in games{let checked=grants.contains{$0.userID==user.id && $0.gameID==game.id};let check=NSButton(checkboxWithTitle:game.title,target:nil,action:nil);check.state=checked ? .on:.off;check.setAccessibilityLabel("可玩游戏 "+game.title);check.target=self;check.action=#selector(accessClicked(_:));check.identifier=NSUserInterfaceItemIdentifier(user.id+":"+game.id);controls.append(check);let row=stack([check,NSView()]);list.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:list.widthAnchor).isActive=true;row.heightAnchor.constraint(equalToConstant:36).isActive=true}
   if games.isEmpty{list.addArrangedSubview(label("暂无已共享游戏"))}
   add(scroll);scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive=true;scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
  }else{
   add(label("创建账号",26,.semibold));newName.placeholderString="用户名";newPassword.placeholderString="密码（至少 12 位）";controls += [newName,newPassword]
   add(label("用户名",13,.medium));add(SharedLoginInput(field:newName));add(label("密码",13,.medium));add(SharedLoginInput(field:newPassword));add(stack([NSView(),button("创建"){[weak self] in self?.createUser()}]));add(NSView())
  }
  message.stringValue=feedback;message.maximumNumberOfLines=2;message.font = .systemFont(ofSize:12);message.textColor = .secondaryLabelColor;add(message);controls.forEach{$0.isEnabled = !busy}
 }
 @objc private func accessClicked(_ b:NSButton){guard let raw=b.identifier?.rawValue else{return};let p=raw.split(separator:":").map(String.init);guard p.count==2,let u=users.first(where:{$0.id==p[0]}),let g=games.first(where:{$0.id==p[1]}) else{return};setAccess(u,game:g,allowed:b.state == .on)}
 private func client()throws->(SharedAPI,String){guard let app,let token=try app.sharedToken(for:connection) else{throw LibraryError("请重新登录共享库。")};return(try SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256),token)}
 private func perform(_ work:@escaping(SharedAPI,String)async throws->Void){
  guard !busy,!closed else{return}
  do{let (api,token)=try client();busy=true;feedback="正在保存…";render();task=Task{@MainActor[weak self] in do{try await work(api,token);guard let self,!self.closed else{return};self.busy=false;self.changed();self.refresh()}catch{guard let self,!self.closed else{return};self.busy=false;self.feedback=(error as? SharedRequestError)?.statusCode==409 ? "请先退出这个账号正在运行的游戏。":"操作未完成，请检查连接和输入。";self.render()}}}catch{feedback=error.localizedDescription;render()}
 }
 private func refresh(){
  guard !busy,!closed else{return}
  do{let (api,token)=try client();busy=true;render();task=Task{@MainActor[weak self] in
   do{let u:SharedAdminUsers=try await api.value("/api/admin/users",token:token),g:SharedCatalog=try await api.value("/api/admin/games",token:token),a:SharedAdminGrants=try await api.value("/api/admin/grants",token:token);guard let self,!self.closed else{return};self.users=u.users;self.games=g.games;self.grants=a.grants;self.busy=false;self.feedback="";self.render()}
   catch{guard let self,!self.closed else{return};self.busy=false;self.feedback="无法加载账号，请检查登录和连接。";self.render()}
  }}catch{feedback=error.localizedDescription;render()}
 }
 private func createUser(){let name=newName.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),password=newPassword.stringValue;guard !name.isEmpty,password.count>=12 else{feedback="请输入用户名及至少 12 位的密码。";render();return};newPassword.stringValue="";perform{[weak self] api,token in let result:SharedAdminUserCreated=try await api.value("/api/admin/users",method:"POST",token:token,body:["username":name,"password":password,"admin":false]);await MainActor.run{self?.selectedID=result.id;self?.newName.stringValue=""}}}
 private func setAccess(_ user:SharedAdminUser,game:SharedCatalogGame,allowed:Bool){perform{api,token in let _:SharedAdminOK=try await api.value("/api/admin/grants",method:"POST",token:token,body:["userID":user.id,"gameID":game.id,"allowed":allowed])}}
 private func disable(_ user:SharedAdminUser){let alert=NSAlert();alert.messageText="停用账号「"+user.username+"」？";alert.addButton(withTitle:"停用");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return};perform{api,token in let _:SharedAdminOK=try await api.value(SharedAdminPath.disable(user.id),method:"POST",token:token,body:[:])}}
 private func editPassword(_ user:SharedAdminUser){
  do{let(api,token)=try client();let own=user.id==connection.accountID
   passwordWindow=PasswordWindowController(title:own ? "修改密码":"重置 "+user.username+" 的密码",requiresCurrent:own,submit:{old,new in let path=own ? "/api/account/password":"/api/admin/users/"+user.id+"/password";let body:[String:Any]=own ? ["oldPassword":old ?? "","newPassword":new]:["password":new];let _:SharedAdminOK=try await api.value(path,method:"POST",token:token,body:body)},succeeded:{[weak self] in guard let self else{return};if own{self.app?.clearSharedLogin(self.connection);self.signedOut();self.close()}else{self.feedback="密码已重置";self.render()}},dismissed:{[weak self] in self?.passwordWindow=nil})
   passwordWindow?.showWindow(nil);passwordWindow?.window?.makeKeyAndOrderFront(nil)
  }catch{feedback=error.localizedDescription;render()}
 }
}
private struct SharedAdminUserCreated:Decodable{let id:String}
