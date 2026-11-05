import AppKit

final class SharedAdministrationWindowController:NSWindowController,NSWindowDelegate {
 private weak var app:App?
 private let connection:SharedConnection
 private let changed:()->Void
 private let onClose:()->Void
 private var roots:[SharedAdminRoot]=[],candidates:[SharedAdminCandidate]=[],users:[SharedAdminUser]=[],games:[SharedCatalogGame]=[],grants:[SharedAdminGrant]=[]
 private var page=0,closed=false,busy=false,feedback=""
 private var operation=UUID()
 private var task:Task<Void,Never>?
 private let body=NSView(),navigation=NSStackView(),message=NSTextField(labelWithString:"")
 private let spinner=NSProgressIndicator()
 private var controls:[NSControl]=[],checks:[(String,NSButton)]=[]
 private let rootPicker=NSPopUpButton(),userPicker=NSPopUpButton(),gamePicker=NSPopUpButton()
 private let ownAccess=NSButton(checkboxWithTitle:"允许当前账号游玩",target:nil,action:nil)
 private let newName=NSTextField(),newPassword=NSSecureTextField()
 private var selectedRoot:String?
 private var saveRules:[String:[SharedAdminSaveRule]]=[:]

 init(app:App,connection:SharedConnection,showGames:Bool,changed:@escaping()->Void,onClose:@escaping()->Void)throws {
  guard connection.isAdministrator else{throw LibraryError("需要管理员账号。")}
  self.app=app;self.connection=connection;self.changed=changed;self.onClose=onClose
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  super.init(window:window);window.title="服务器管理";window.appearance=NSAppearance(named:.aqua);window.isReleasedWhenClosed=false;window.delegate=self;window.minSize=NSSize(width:850,height:560)
  ownAccess.state = .on;newName.placeholderString="用户名";newPassword.placeholderString="密码（至少 12 位）"
  build();render();window.center();refresh()
 }
 required init?(coder:NSCoder){fatalError()}
 func windowWillClose(_ notification:Notification){closed=true;operation=UUID();task?.cancel();newPassword.stringValue="";onClose()}
 private func text(_ value:String,_ size:CGFloat=14,_ weight:NSFont.Weight = .regular)->NSTextField {
  let v=NSTextField(labelWithString:value);v.font = .systemFont(ofSize:size,weight:weight);v.lineBreakMode = .byTruncatingTail;v.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);return v
 }
 private func stack(_ views:[NSView],vertical:Bool=false,spacing:CGFloat=12)->NSStackView {
  let v=NSStackView(views:views);v.orientation=vertical ? .vertical:.horizontal;v.alignment=vertical ? .leading:.centerY;v.spacing=spacing;return v
 }
 private func button(_ title:String,_ work:@escaping()->Void)->NSButton {
  let b=ActionButton(title,work);b.bezelStyle = .rounded;controls.append(b);return b
 }
 private func pin(_ view:NSView,_ parent:NSView,_ inset:CGFloat=0){
  view.translatesAutoresizingMaskIntoConstraints=false;parent.addSubview(view)
  NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),view.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])
 }
 private func build(){
  guard let root=window?.contentView else{return};root.wantsLayer=true;root.layer?.backgroundColor=NSColor.white.cgColor
  let side=NSView();side.wantsLayer=true;side.layer?.backgroundColor=NSColor(calibratedWhite:0.95,alpha:1).cgColor
  navigation.orientation = .vertical;navigation.alignment = .leading;navigation.spacing=10
  let icon=NSImageView(image:NSApp.applicationIconImage);icon.widthAnchor.constraint(equalToConstant:42).isActive=true;icon.heightAnchor.constraint(equalToConstant:42).isActive=true
  navigation.addArrangedSubview(stack([icon,text("服务器管理",18,.semibold)]));navigation.addArrangedSubview(text(connection.name,13))
  for (index,title) in ["游戏","账号","授权"].enumerated(){let b=ActionButton(title){[weak self] in guard let self,!self.busy else{return};self.page=index;self.render()};b.alignment = .left;b.isBordered=false;b.heightAnchor.constraint(equalToConstant:38).isActive=true;b.widthAnchor.constraint(equalToConstant:170).isActive=true;b.font = .systemFont(ofSize:14);b.tag=index;navigation.addArrangedSubview(b)}
  let filler=NSView();navigation.addArrangedSubview(filler);filler.setContentHuggingPriority(.defaultLow,for:.vertical);pin(navigation,side,20)
  let layout=stack([side,body],spacing:0);pin(layout,root);side.widthAnchor.constraint(equalToConstant:210).isActive=true
  body.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-210).isActive=true
  side.heightAnchor.constraint(equalTo:layout.heightAnchor).isActive=true;body.heightAnchor.constraint(equalTo:layout.heightAnchor).isActive=true
 }
 private func render(){
  guard !closed else{return};body.subviews.forEach{$0.removeFromSuperview()};controls=[];checks=[]
  for b in navigation.arrangedSubviews.compactMap({$0 as? NSButton}){b.contentTintColor=b.tag==page ? .controlAccentColor:.labelColor;b.font = .systemFont(ofSize:14,weight:b.tag==page ? .semibold:.regular);b.isEnabled = !busy;b.setAccessibilityValue(b.tag==page ? "已选择":"")}
  let refreshButton=button("刷新"){[weak self] in self?.refresh()}
  let heading=stack([text(["游戏","账号","授权"][page],26,.bold),NSView(),refreshButton])
  let content=stack([heading],vertical:true,spacing:18);pin(content,body,26);heading.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
  let list=stack([],vertical:true,spacing:12)
  let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false
  let document=FlippedView();document.translatesAutoresizingMaskIntoConstraints=false;scroll.documentView=document;pin(list,document,4)
  NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),document.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),document.topAnchor.constraint(equalTo:scroll.contentView.topAnchor)])
  func add(_ v:NSView){list.addArrangedSubview(v);v.widthAnchor.constraint(equalTo:list.widthAnchor).isActive=true}
  switch page {
  case 0:
   rootPicker.removeAllItems();rootPicker.addItems(withTitles:roots.map{$0.title});if let index=roots.firstIndex(where:{$0.id==selectedRoot}){rootPicker.selectItem(at:index)}
   controls.append(rootPicker);rootPicker.isEnabled = !roots.isEmpty;rootPicker.target=self;rootPicker.action=#selector(rootChanged)
   let scan=button("扫描游戏"){[weak self] in self?.scan()};scan.isEnabled = !roots.isEmpty
   let source=stack([rootPicker,scan]);content.addArrangedSubview(source);source.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
   rootPicker.setContentHuggingPriority(.defaultLow,for:.horizontal)
   if roots.isEmpty{add(text("尚未设置游戏库目录",16,.medium));add(button("设置游戏库目录…"){[weak self] in self?.addRoot()})}
   else if candidates.isEmpty{add(text("暂无扫描结果",16,.medium))}
   for candidate in candidates where candidate.rootID==(selectedRoot ?? roots.first?.id) {
    let check=NSButton(checkboxWithTitle:candidate.title,target:nil,action:nil);check.font = .systemFont(ofSize:15,weight:.medium);check.isEnabled=candidate.available;check.lineBreakMode = .byTruncatingTail;checks.append((candidate.id,check));controls.append(check)
    let relative=text(candidate.relative,12);relative.textColor = .secondaryLabelColor;relative.toolTip=candidate.relative
    let platforms=Set(candidate.entries.map{DiscoveryPresentation.platform(entry:$0)}).sorted().joined(separator:" · ")
    let saves=button("存档设置…"){[weak self] in self?.editSaves(candidate)}
    let row=stack([stack([check,relative],vertical:true,spacing:4),NSView(),text(platforms,12),saves])
    row.heightAnchor.constraint(greaterThanOrEqualToConstant:58).isActive=true;add(row)
   }
   content.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
   controls.append(ownAccess);ownAccess.isEnabled=true;content.addArrangedSubview(ownAccess)
   let publish=button("发布所选游戏"){[weak self] in self?.publish()}
   let footer=stack([text("已发布 \(games.count) 款",12),NSView(),publish]);content.addArrangedSubview(footer);footer.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
  case 1:
   let create=button("创建账号"){[weak self] in self?.createUser()};newName.isEnabled=true;newPassword.isEnabled=true;controls += [newName,newPassword]
   let form=stack([newName,newPassword,create]);content.addArrangedSubview(form);form.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
   for user in users {
    let info=text(user.username+(user.admin ? " · 管理员":"")+(user.disabled ? " · 已停用":""),15,.medium)
    var views:[NSView]=[info,NSView()]
    if !user.disabled && user.id != connection.accountID {views.append(button("停用"){[weak self] in self?.disable(user)})}
    let row=stack(views);row.heightAnchor.constraint(greaterThanOrEqualToConstant:42).isActive=true;add(row)
   }
   content.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
  default:
   let active=users.filter{!$0.disabled};userPicker.removeAllItems();userPicker.addItems(withTitles:active.map{$0.username});gamePicker.removeAllItems();gamePicker.addItems(withTitles:games.map{$0.title});userPicker.isEnabled = !active.isEmpty;gamePicker.isEnabled = !games.isEmpty;controls += [userPicker,gamePicker]
   let grant=button("授权"){[weak self] in self?.changeGrant(true)}
   let revoke=button("撤销"){[weak self] in self?.changeGrant(false)}
   let form=stack([userPicker,gamePicker,grant,revoke]);content.addArrangedSubview(form);form.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
   userPicker.setAccessibilityLabel("账号");gamePicker.setAccessibilityLabel("游戏")
   for item in grants {
    let name=users.first{$0.id==item.userID}?.username ?? item.userID
    let game=games.first{$0.id==item.gameID}?.title ?? item.gameID
    add(text(name+"  →  "+game,14))
   }
   if grants.isEmpty{add(text("暂无游戏授权",16,.medium))}
   content.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
  }
  spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false
  message.stringValue=feedback;message.maximumNumberOfLines=2;message.font = .systemFont(ofSize:12);message.textColor = .secondaryLabelColor
  let status=stack([spinner,message]);content.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:content.widthAnchor).isActive=true
  scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive=true;scroll.setContentHuggingPriority(.defaultLow,for:.vertical)
  if busy{controls.forEach{$0.isEnabled=false};spinner.startAnimation(nil)}else{spinner.stopAnimation(nil)}
 }
 @objc private func rootChanged(){if roots.indices.contains(rootPicker.indexOfSelectedItem){selectedRoot=roots[rootPicker.indexOfSelectedItem].id;render()}}
 private func client()throws->(SharedAPI,String){
  guard let app,let token=try app.sharedToken(for:connection) else{throw LibraryError("登录已过期，请重新登录共享库。")}
  return (try SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256),token)
 }
 private func perform(_ title:String,_ work:@escaping(SharedAPI,String)async throws->String){
  guard !closed,!busy else{return}
  do{
   let (api,token)=try client();busy=true;feedback=title;operation=UUID();let id=operation;render()
   task=Task{@MainActor [weak self] in
    do{let result=try await work(api,token);guard let self,!self.closed,self.operation==id else{return};self.busy=false;self.feedback=result;self.changed();self.refresh(success:result)}
    catch{guard let self,!self.closed,self.operation==id else{return};self.busy=false;self.feedback=self.friendly(error);self.render()}
   }
  }catch{feedback=friendly(error);render()}
 }
 private func friendly(_ error:Error)->String {
  if let e=error as? SharedRequestError {
   switch e.statusCode{case 401:return "登录已过期，请重新登录共享库。";case 403:return "当前账号没有管理员权限。";case 409:return "服务器正在处理其他操作，或游戏版本已变化，请刷新后重试。";case 400:return "操作未通过检查，请核对输入内容。";default:break}
  }
  return error.localizedDescription
 }
 private func refresh(success:String?=nil){
  guard !closed,!busy else{return}
  do{
   let (api,token)=try client();busy=true;operation=UUID();let id=operation;feedback=success ?? "正在加载…";render()
   task=Task{@MainActor [weak self] in
    do{
     let r:SharedAdminRoots=try await api.value("/api/admin/roots",token:token)
     let c:SharedAdminCandidates=try await api.value("/api/admin/candidates",token:token)
     let u:SharedAdminUsers=try await api.value("/api/admin/users",token:token)
     let g:SharedCatalog=try await api.value("/api/admin/games",token:token)
     let a:SharedAdminGrants=try await api.value("/api/admin/grants",token:token)
     guard let self,!self.closed,self.operation==id else{return}
     self.roots=r.roots;self.candidates=c.candidates;self.users=u.users;self.games=g.games;self.grants=a.grants
     if !self.roots.contains(where:{$0.id==self.selectedRoot}){self.selectedRoot=self.roots.first?.id}
     self.busy=false;self.feedback=success ?? "";self.render()
    }catch{guard let self,!self.closed,self.operation==id else{return};self.busy=false;self.feedback=self.friendly(error);self.render()}
   }
  }catch{feedback=friendly(error);render()}
 }
 private func scan(){
  guard let id=selectedRoot ?? roots.first?.id else{return}
  perform("正在扫描游戏…"){api,token in
   let result:SharedAdminScan=try await api.value(SharedAdminPath.scan(id),method:"POST",token:token,body:[:])
   return "扫描完成：\(result.discovered) 款候选游戏"+(result.complete ? "":"，部分目录未能读取")
  }
 }
 private func publish(){
  let ids=checks.filter{$0.1.state == .on}.map{$0.0};guard !ids.isEmpty else{feedback="请先勾选游戏。";message.stringValue=feedback;return}
  let review=NSAlert();review.messageText="发布 \(ids.count) 款游戏？"
  review.informativeText=candidates.filter{ids.contains($0.id)}.map{"\($0.title)：排除 \($0.detectedSavePaths.count) 项已有存档路径，补充 \(saveRules[$0.id]?.count ?? 0) 项"}.joined(separator:"\n")
  review.addButton(withTitle:"发布");review.addButton(withTitle:"取消");guard review.runModal() == .alertFirstButtonReturn else{return}
  let grantSelf=ownAccess.state == .on,account=connection.accountID
  let rules=saveRules
  // Capture only confirmed title aliases and bounded artwork before entering the task.
  let catalog=app.map{GameMetadataCatalog(root:$0.store.root)}
  var metadata:[String:(title:String,cover:LibraryCoverPayload?)]=[:]
  for candidate in candidates where ids.contains(candidate.id){
   if let record=catalog?.match(candidate.title){
    let cover=catalog?.coverURL(record).flatMap{try? LibraryCoverPayload.thumbnail(at:$0)}
    metadata[candidate.id]=(record.title,cover)
   }
  }
  perform("正在发布游戏…"){api,token in
   var count=0,metadataFailures=0
   for id in ids {
    try Task.checkCancellation()
    let additional=(rules[id] ?? []).map{["path":$0.path,"kind":$0.kind]}
    let game:SharedCatalogGame=try await api.value(SharedAdminPath.publish(id),method:"POST",token:token,body:["savePaths":additional])
    try Task.checkCancellation()
    if grantSelf{let _:SharedAdminOK=try await api.value("/api/admin/grants",method:"POST",token:token,body:["userID":account,"gameID":game.id,"allowed":true])}
    if let known=metadata[id]{
     do{
      let _:SharedAdminOK=try await api.value("/api/admin/games/"+game.id+"/metadata",method:"POST",token:token,body:["title":known.title])
      if let cover=known.cover{let _:LibraryCoverPayload=try await api.value("/api/admin/games/"+game.id+"/cover",method:"POST",token:token,body:["data":cover.data])}
     }catch{metadataFailures+=1}
    }
    count+=1
   }
   return "已发布 \(count) 款游戏"+(metadataFailures>0 ? " · \(metadataFailures) 项名称或封面暂未更新":"")
  }
 }
 private func editSaves(_ candidate:SharedAdminCandidate){
  let alert=NSAlert();alert.messageText=candidate.title+" · 存档设置"
  let detected=candidate.detectedSavePaths.map{$0.path+($0.kind=="directory" ? "/":"")}.joined(separator:"\n")
  let files=NSTextView(),directories=NSTextView(),detectedView=NSTextView();detectedView.string=detected.isEmpty ? "无":detected;detectedView.isEditable=false
  files.string=(saveRules[candidate.id] ?? []).filter{$0.kind=="file"}.map{$0.path}.joined(separator:"\n")
  directories.string=(saveRules[candidate.id] ?? []).filter{$0.kind=="directory"}.map{$0.path}.joined(separator:"\n")
  func editor(_ view:NSTextView)->NSView{let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;view.isRichText=false;view.font = .systemFont(ofSize:13);view.frame=NSRect(x:0,y:0,width:460,height:75);view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true;scroll.documentView=view;scroll.heightAnchor.constraint(equalToConstant:75).isActive=true;return scroll}
  let form=stack([text("已检测的存档路径",13,.medium),editor(detectedView),text("补充文件路径（每行一项）",13,.medium),editor(files),text("补充文件夹路径（每行一项）",13,.medium),editor(directories)],vertical:true,spacing:8)
  form.frame=NSRect(x:0,y:0,width:470,height:350);form.widthAnchor.constraint(equalToConstant:470).isActive=true
  for view in form.arrangedSubviews{view.widthAnchor.constraint(equalTo:form.widthAnchor).isActive=true}
  alert.accessoryView=form;alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
  guard alert.runModal() == .alertFirstButtonReturn else{return}
  do{saveRules[candidate.id]=try SharedAdminSaveRule.parse(files:files.string,directories:directories.string)}catch{message.stringValue=error.localizedDescription}
 }
 private func createUser(){
  let name=newName.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),password=newPassword.stringValue
  guard !name.isEmpty,password.count>=12 else{message.stringValue="请输入用户名和至少 12 位的密码。";return}
  newPassword.stringValue=""
  perform("正在创建账号…"){api,token in let _:SharedAdminOK=try await api.value("/api/admin/users",method:"POST",token:token,body:["username":name,"password":password,"admin":false]);return "账号已创建"}
 }
 private func disable(_ user:SharedAdminUser){
  let alert=NSAlert();alert.messageText="停用账号「"+user.username+"」？";alert.addButton(withTitle:"停用");alert.addButton(withTitle:"取消")
  guard alert.runModal() == .alertFirstButtonReturn else{return}
  perform("正在停用账号…"){api,token in let _:SharedAdminOK=try await api.value(SharedAdminPath.disable(user.id),method:"POST",token:token,body:[:]);return "账号已停用"}
 }
 private func changeGrant(_ allowed:Bool){
  let active=users.filter{!$0.disabled};guard active.indices.contains(userPicker.indexOfSelectedItem),games.indices.contains(gamePicker.indexOfSelectedItem) else{message.stringValue="请选择账号和已发布的游戏。";return}
  let user=active[userPicker.indexOfSelectedItem].id,game=games[gamePicker.indexOfSelectedItem].id
  perform("正在更新授权…"){api,token in let _:SharedAdminOK=try await api.value("/api/admin/grants",method:"POST",token:token,body:["userID":user,"gameID":game,"allowed":allowed]);return allowed ? "已授权":"已撤销授权"}
 }
 private func addRoot(){
  let alert=NSAlert();alert.messageText="添加游戏库目录";let name=NSTextField(string:""),path=NSTextField(string:"");name.placeholderString="名称";path.placeholderString="服务器内的游戏目录";let form=stack([name,path],vertical:true);form.frame=NSRect(x:0,y:0,width:420,height:75);alert.accessoryView=form;alert.addButton(withTitle:"添加");alert.addButton(withTitle:"取消")
  guard alert.runModal() == .alertFirstButtonReturn else{return}
  let title=name.stringValue,location=path.stringValue
  perform("正在添加目录…"){api,token in let _:SharedAdminOK=try await api.value("/api/admin/roots",method:"POST",token:token,body:["title":title,"path":location]);return "游戏库目录已添加"}
 }
}
