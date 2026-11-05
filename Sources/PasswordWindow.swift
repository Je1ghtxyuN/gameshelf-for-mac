import AppKit

final class PasswordWindowController:NSWindowController,NSWindowDelegate {
 private let current=NSSecureTextField(),password=NSSecureTextField(),confirmation=NSSecureTextField()
 private let message=NSTextField(labelWithString:"")
 private let save=NSButton(title:"保存",target:nil,action:nil),cancel=NSButton(title:"取消",target:nil,action:nil)
 private let requiresCurrent:Bool
 private let submit:(String?,String)async throws->Void
 private let succeeded:()->Void
 private let dismissed:()->Void
 private var task:Task<Void,Never>?,closed=false
 init(title:String,requiresCurrent:Bool,submit:@escaping(String?,String)async throws->Void,succeeded:@escaping()->Void,dismissed:@escaping()->Void){
  self.requiresCurrent=requiresCurrent;self.submit=submit;self.succeeded=succeeded;self.dismissed=dismissed
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:460,height:requiresCurrent ? 400:320),styleMask:[.titled,.closable],backing:.buffered,defer:false)
  super.init(window:window);window.title=title;window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.aqua);window.delegate=self
  let root=window.contentView!;root.wantsLayer=true;root.layer?.backgroundColor=NSColor.white.cgColor
  let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:26)])
  let heading=NSTextField(labelWithString:title);heading.font = .systemFont(ofSize:22,weight:.semibold);stack.addArrangedSubview(heading)
  var fields:[(String,NSSecureTextField)]=[];if requiresCurrent{fields.append(("当前密码",current))};fields += [("新密码",password),("确认新密码",confirmation)]
  for (title,field) in fields{let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:13,weight:.medium);stack.addArrangedSubview(label);field.placeholderString=title;field.setAccessibilityLabel(title);let box=SharedLoginInput(field:field);stack.addArrangedSubview(box);box.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
  message.maximumNumberOfLines=2;message.textColor = .systemRed;message.font = .systemFont(ofSize:12);stack.addArrangedSubview(message);message.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
  save.target=self;save.action=#selector(savePassword);save.bezelStyle = .rounded;save.keyEquivalent="\r";cancel.target=self;cancel.action=#selector(cancelPassword);cancel.bezelStyle = .rounded;cancel.keyEquivalent="\u{1b}"
  let footer=NSStackView(views:[NSView(),cancel,save]);footer.spacing=10;stack.addArrangedSubview(footer);footer.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
  window.center();window.makeFirstResponder(requiresCurrent ? current:password)
 }
 required init?(coder:NSCoder){fatalError()}
 func windowWillClose(_ notification:Notification){closed=true;current.stringValue="";password.stringValue="";confirmation.stringValue="";dismissed()}
 @objc private func cancelPassword(){close()}
 @objc private func savePassword(){
  let old=requiresCurrent ? current.stringValue:nil,new=password.stringValue
  guard (!requiresCurrent || !(old ?? "").isEmpty),new.count>=12,new.utf8.count<=1024 else{message.stringValue="请输入当前密码及至少 12 位的新密码。";return}
  guard new==confirmation.stringValue else{message.stringValue="两次输入的新密码不一致。";return}
  current.stringValue="";password.stringValue="";confirmation.stringValue="";save.isEnabled=false;cancel.isEnabled=false;message.stringValue="正在保存…"
  task=Task{@MainActor [weak self] in
   guard let self else{return}
   do{try await self.submit(old,new);self.succeeded();if !self.closed{self.close()}}
   catch{if !self.closed{self.save.isEnabled=true;self.cancel.isEnabled=true;let e=error as? SharedRequestError;self.message.stringValue=e?.statusCode==401 ? "当前密码不正确，或登录已过期。":e?.statusCode==409 ? "请先保存并退出此账号正在运行的游戏。":"密码未修改，请检查连接和输入后重试。"}}
  }
 }
}
