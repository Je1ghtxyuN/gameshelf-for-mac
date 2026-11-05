import AppKit

enum OnboardingWindowStyle {
 static func window(_ title:String)->NSWindow {
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:550),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
  window.title=title;window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.aqua)
  return window
 }
 static func label(_ title:String,size:CGFloat=14,weight:NSFont.Weight = .regular)->NSTextField {
  let result=NSTextField(labelWithString:title);result.font = .systemFont(ofSize:size,weight:weight);return result
 }
 static func stack(_ views:[NSView],spacing:CGFloat=16)->NSStackView {
  let result=NSStackView(views:views);result.orientation = .vertical;result.alignment = .leading;result.spacing=spacing;return result
 }
 static func form(in window:NSWindow)->NSStackView {
  let root=window.contentView!;root.wantsLayer=true;root.layer?.backgroundColor=NSColor.white.cgColor
  let art=SharedLoginArtwork(),panel=NSView(),form=stack([])
  for view in [art,panel] {view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
  form.translatesAutoresizingMaskIntoConstraints=false;panel.addSubview(form)
  NSLayoutConstraint.activate([
   art.leadingAnchor.constraint(equalTo:root.leadingAnchor),art.topAnchor.constraint(equalTo:root.topAnchor),art.bottomAnchor.constraint(equalTo:root.bottomAnchor),art.widthAnchor.constraint(equalToConstant:235),
   panel.leadingAnchor.constraint(equalTo:art.trailingAnchor),panel.trailingAnchor.constraint(equalTo:root.trailingAnchor),panel.topAnchor.constraint(equalTo:root.topAnchor),panel.bottomAnchor.constraint(equalTo:root.bottomAnchor),
   form.widthAnchor.constraint(equalToConstant:355),form.centerXAnchor.constraint(equalTo:panel.centerXAnchor),form.centerYAnchor.constraint(equalTo:panel.centerYAnchor),form.topAnchor.constraint(greaterThanOrEqualTo:panel.topAnchor,constant:24),form.bottomAnchor.constraint(lessThanOrEqualTo:panel.bottomAnchor,constant:-24)
  ])
  return form
 }
 static func add(_ view:NSView,to form:NSStackView){form.addArrangedSubview(view);view.widthAnchor.constraint(equalTo:form.widthAnchor).isActive=true}
}

final class OnboardingWindowController:NSWindowController {
 private let onSelect:(OnboardingChoice)->Void
 private var selected=false
 init(onSelect:@escaping(OnboardingChoice)->Void) {
  self.onSelect=onSelect
  let window=OnboardingWindowStyle.window("GameShelf")
  super.init(window:window)
  let form=OnboardingWindowStyle.form(in:window)
  OnboardingWindowStyle.add(OnboardingWindowStyle.label("欢迎使用 GameShelf",size:25,weight:.semibold),to:form)
  for (title,choice) in [("本地使用",OnboardingChoice.local),("连接共享库",.connect),("创建共享库",.create)] {
   let action={ [weak self] in self?.choose(choice) }
   let button:ActionButton = choice == .local ? SharedLoginPrimary(title,{action()}):ActionButton(title,{action()})
   button.font = .systemFont(ofSize:14,weight:.medium);button.heightAnchor.constraint(equalToConstant:44).isActive=true
   if choice == .local{button.isBordered=false;button.keyEquivalent="\r"}
   OnboardingWindowStyle.add(button,to:form)
  }
  window.center()
 }
 required init?(coder:NSCoder){fatalError()}
 private func choose(_ choice:OnboardingChoice){guard !selected else{return};selected=true;close();onSelect(choice)}
}
