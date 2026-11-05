import AppKit

final class AdministratorSetupWindowController:NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
 private struct ServerInfo:Decodable {let serverID:String;let setupRequired:Bool?}
 private let invitation:AdministratorSetupInvitation
 private let completion:(SharedLoginResponse)->Void
 private let username=NSTextField(string:"")
 private let password=NSSecureTextField(string:"")
 private let confirmation=NSSecureTextField(string:"")
 private let feedback=NSTextField(labelWithString:"")
 private let spinner=NSProgressIndicator()
 private var submitButton:NSButton!
 private var api:SharedAPI?
 private var serverID:String?
 private var operation=UUID()
 private var closed=false
 private var loading=false
 private var started=false
 init(invitation:AdministratorSetupInvitation,completion:@escaping(SharedLoginResponse)->Void) {
  self.invitation=invitation;self.completion=completion
  let window=OnboardingWindowStyle.window("创建共享库")
  super.init(window:window);window.delegate=self
  let form=OnboardingWindowStyle.form(in:window)
  func add(_ view:NSView){OnboardingWindowStyle.add(view,to:form)}
  add(OnboardingWindowStyle.label("创建管理员",size:25,weight:.semibold))
  if let name=invitation.name{add(OnboardingWindowStyle.label(name,size:13))}
  for (title,input) in [("账号",username),("密码",password),("确认密码",confirmation)] {
   input.placeholderString=title;input.delegate=self
   let box=SharedLoginInput(field:input)
   let group=OnboardingWindowStyle.stack([OnboardingWindowStyle.label(title,size:12,weight:.medium),box],spacing:7)
   box.widthAnchor.constraint(equalTo:group.widthAnchor).isActive=true;add(group)
  }
  submitButton=SharedLoginPrimary("创建管理员"){[weak self] in self?.submit()}
  submitButton.isBordered=false;submitButton.keyEquivalent="\r";submitButton.heightAnchor.constraint(equalToConstant:44).isActive=true;add(submitButton)
  feedback.font = .systemFont(ofSize:12);feedback.textColor = .secondaryLabelColor;feedback.maximumNumberOfLines=3;feedback.lineBreakMode = .byWordWrapping;add(feedback)
  spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped=false;form.addArrangedSubview(spinner)
  update();window.center()
 }
 required init?(coder:NSCoder){fatalError()}
 override func showWindow(_ sender:Any?) {
  super.showWindow(sender)
  guard !started,!closed else{return};started=true;loadServer()
 }
 func windowWillClose(_ notification:Notification){closed=true;operation=UUID();clearPasswords();api=nil}
 func controlTextDidBeginEditing(_ obj:Notification){((obj.object as? NSTextField)?.superview as? SharedLoginInput)?.focus(true)}
 func controlTextDidEndEditing(_ obj:Notification){((obj.object as? NSTextField)?.superview as? SharedLoginInput)?.focus(false)}
 private func clearPasswords(){password.stringValue="";confirmation.stringValue=""}
 private func update(){
  [username,password,confirmation].forEach{$0.isEnabled = !loading && serverID != nil && !closed}
  submitButton.title=serverID==nil && !loading ? "重试连接":"创建管理员"
  submitButton.isEnabled = !loading && !closed;submitButton.needsDisplay=true
  if loading{spinner.startAnimation(nil)}else{spinner.stopAnimation(nil)}
 }
 private func status(_ text:String,error:Bool=false){feedback.stringValue=text;feedback.textColor=error ? .systemRed:.secondaryLabelColor;update()}
 private func loadServer(){
  loading=true;status("正在连接…")
  let request=UUID();operation=request
  do {
   let client=try SharedAPI(address:invitation.address,certificateSHA256:invitation.certificateSHA256);api=client
   client.request("/api/server-info"){[weak self] (result:Result<ServerInfo,Error>) in DispatchQueue.main.async {
    guard let self,!self.closed,self.operation==request else{return}
    self.loading=false
    switch result {
    case .success(let info):
     guard !info.serverID.isEmpty,info.serverID.utf8.count<=128,info.setupRequired==true else{self.status("此服务器不需要或不支持管理员初始化。",error:true);return}
     self.serverID=info.serverID;self.status("");self.window?.makeFirstResponder(self.username)
    case .failure:self.status("无法连接服务器。",error:true)
    }
   }}
  }catch{loading=false;status("服务器连接设置无效。",error:true)}
 }
 private func submit(){
  guard !loading,!closed else{return}
  guard let serverID,let api else{loadServer();return}
  let name=username.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),secret=password.stringValue,confirmed=confirmation.stringValue
  clearPasswords()
  do{try AdministratorSetupValidation.credentials(username:name,password:secret,confirmation:confirmed)}catch{status(error.localizedDescription,error:true);return}
  loading=true;status("正在创建…")
  let request=UUID();operation=request
  api.request("/api/setup",method:"POST",body:["setupToken":invitation.setupToken,"username":name,"password":secret]){[weak self] (result:Result<SharedLoginResponse,Error>) in DispatchQueue.main.async {
   guard let self,!self.closed,self.operation==request else{return}
   self.loading=false;self.clearPasswords()
   switch result {
   case .success(let response):
    do{try AdministratorSetupValidation.response(response,expectedServerID:serverID)}catch{self.serverID=nil;self.status(error.localizedDescription,error:true);return}
    self.close();self.completion(response)
   case .failure(let error):
    let status=(error as? SharedRequestError)?.statusCode
    if status==409{self.serverID=nil;self.status("服务器已完成初始化。",error:true)}
    else{self.status(status==401 || status==403 ? "管理员邀请无效或已失效。":"创建失败，请检查连接后重试。",error:true)}
   }
  }}
 }
}
