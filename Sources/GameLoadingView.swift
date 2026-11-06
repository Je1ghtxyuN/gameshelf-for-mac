import AppKit
import QuartzCore

final class GameLoadingView:NSView {
 let gameID:UUID
 private let state=NSTextField(labelWithString:"")
 init(game:Game){
  gameID=game.id;super.init(frame:.zero)
  wantsLayer=true;layer?.backgroundColor=NSColor.black.cgColor
  let ring=NSView();ring.wantsLayer=true
  ring.translatesAutoresizingMaskIntoConstraints=false;addSubview(ring)
  NSLayoutConstraint.activate([ring.widthAnchor.constraint(equalToConstant:96),ring.heightAnchor.constraint(equalToConstant:96),ring.centerXAnchor.constraint(equalTo:centerXAnchor),ring.centerYAnchor.constraint(equalTo:centerYAnchor)])
  let path=CGPath(ellipseIn:CGRect(x:7,y:7,width:82,height:82),transform:nil)
  let track=CAShapeLayer();track.path=path;track.fillColor=nil;track.strokeColor=NSColor(white:0.16,alpha:1).cgColor;track.lineWidth=10
  let arc=CAShapeLayer();arc.path=path;arc.fillColor=nil;arc.strokeColor=NSColor(white:0.62,alpha:1).cgColor;arc.lineWidth=10;arc.strokeEnd=0.28
  arc.frame=CGRect(x:0,y:0,width:96,height:96)
  let rotation=CABasicAnimation(keyPath:"transform.rotation.z");rotation.fromValue=0;rotation.toValue=Double.pi*2;rotation.duration=1;rotation.repeatCount = .infinity
  arc.add(rotation,forKey:"loading")
  ring.layer?.addSublayer(track);ring.layer?.addSublayer(arc)
  let title=NSTextField(labelWithString:game.title);title.font = .systemFont(ofSize:22,weight:.semibold);title.textColor = .white
  title.alignment = .center;title.lineBreakMode = .byTruncatingTail
  title.translatesAutoresizingMaskIntoConstraints=false;addSubview(title)
  state.font = .systemFont(ofSize:14);state.textColor=NSColor(white:0.65,alpha:1);state.alignment = .center;state.lineBreakMode = .byTruncatingMiddle
  state.translatesAutoresizingMaskIntoConstraints=false;addSubview(state)
  NSLayoutConstraint.activate([title.centerXAnchor.constraint(equalTo:centerXAnchor),title.bottomAnchor.constraint(equalTo:ring.topAnchor,constant:-28),title.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-64),state.centerXAnchor.constraint(equalTo:centerXAnchor),state.topAnchor.constraint(equalTo:ring.bottomAnchor,constant:24),state.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-64)])
  setAccessibilityLabel("正在启动 "+game.title)
 }
 required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
 override func hitTest(_ point:NSPoint)->NSView?{bounds.contains(point) ? self:nil}
 func update(_ message:String){state.stringValue=message}
}

extension App {
 func beginGameLoading(_ game:Game){
  guard let host=window?.contentView else{return}
  if launchLoading?.gameID==game.id,launchLoading?.superview===host{return}
  finishGameLoading()
  let overlay=GameLoadingView(game:game);overlay.translatesAutoresizingMaskIntoConstraints=false
  host.addSubview(overlay,positioned:.above,relativeTo:nil)
  NSLayoutConstraint.activate([overlay.leadingAnchor.constraint(equalTo:host.leadingAnchor),overlay.trailingAnchor.constraint(equalTo:host.trailingAnchor),overlay.topAnchor.constraint(equalTo:host.topAnchor),overlay.bottomAnchor.constraint(equalTo:host.bottomAnchor)])
  launchLoading=overlay;overlay.update("正在准备游戏…")
 }
 func finishGameLoading(){launchLoading?.removeFromSuperview();launchLoading=nil}
}
