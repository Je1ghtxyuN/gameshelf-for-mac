import AppKit
@main struct LibraryGridGeometryTests {
 static func main() {
  _ = NSApplication.shared
  func controls()->(NSButton,NSTextField,NSButton,NSButton,NSTextField) {
   let cover=NSButton(title:"",target:nil,action:nil);cover.isBordered=false
   let name=NSTextField(labelWithString:"合成 Game with a long title");name.font = .systemFont(ofSize:14,weight:.semibold);name.lineBreakMode = .byTruncatingTail
   let play=NSButton(title:"启动",target:nil,action:nil);play.bezelStyle = .rounded;play.image=NSImage(systemSymbolName:"play.fill",accessibilityDescription:nil);play.imagePosition = .imageLeading
   let more=NSButton(title:"⋯",target:nil,action:nil);more.bezelStyle = .recessed
   let time=NSTextField(labelWithString:"时长记录暂不可用");time.font = .systemFont(ofSize:11)
   return (cover,name,play,more,time)
  }
  func stack(_ views:[NSView],vertical:Bool=false,spacing:CGFloat)->NSStackView {
   let s=NSStackView(views:views);s.orientation=vertical ? .vertical:.horizontal;s.alignment=vertical ? .leading:.centerY;s.spacing=spacing;return s
  }
  let (cover,name,play,more,time)=controls()
  more.widthAnchor.constraint(equalToConstant:28).isActive=true
  name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
  let names=stack([name,NSView(),play,more],spacing:6)
  let old=stack([cover,names,time],vertical:true,spacing:8)
  cover.heightAnchor.constraint(equalTo:cover.widthAnchor,multiplier:1.32).isActive=true
  for view in [cover,names,time]{view.widthAnchor.constraint(equalTo:old.widthAnchor).isActive=true}
  old.widthAnchor.constraint(equalToConstant:278).isActive=true
  let oldSize=old.fittingSize
  let (c,n,p,m,t)=controls();let new=LibraryCardView(cover:c,name:n,play:p,more:m,time:t)
  print("old card fitting=\(oldSize) new height=\(new.height(for:278)) old row=\(names.fittingSize) old time=\(time.fittingSize)");fflush(stdout)
  precondition(abs(oldSize.height-new.height(for:278))<0.5,"card height changed")
  print("PASS card dimensions match former stack layout")
 }
}
