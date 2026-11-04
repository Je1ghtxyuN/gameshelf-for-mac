import AppKit

final class SharedLoginArtwork:NSView {
 override func draw(_ dirtyRect:NSRect){
  NSGradient(colors:[NSColor(calibratedRed:0.12,green:0.20,blue:0.43,alpha:1),NSColor(calibratedRed:0.24,green:0.36,blue:0.69,alpha:1)])?.draw(in:bounds,angle:70)
  NSColor.white.withAlphaComponent(0.035).setFill()
  NSBezierPath(ovalIn:NSRect(x:-140,y:bounds.height-300,width:450,height:450)).fill()
  NSBezierPath(ovalIn:NSRect(x:bounds.width-150,y:-80,width:320,height:320)).fill()
  let size:CGFloat=90
  NSApp.applicationIconImage?.draw(in:NSRect(x:(bounds.width-size)/2,y:bounds.height*0.56,width:size,height:size))
  func text(_ value:String,y:CGFloat,size:CGFloat,weight:NSFont.Weight,alpha:CGFloat=1){
   let style=NSMutableParagraphStyle();style.alignment = .center
   (value as NSString).draw(in:NSRect(x:16,y:y,width:bounds.width-32,height:42),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:NSColor.white.withAlphaComponent(alpha),.paragraphStyle:style])
  }
  text("GameShelf",y:bounds.height*0.45,size:26,weight:.semibold)
  text("共享游戏库",y:bounds.height*0.38,size:14,weight:.regular,alpha:0.8)
 }
}

final class SharedLoginInput:NSView {
 init(field:NSTextField){
  super.init(frame:.zero);wantsLayer=true;layer?.cornerRadius=9;layer?.borderWidth=1;layer?.borderColor=NSColor(calibratedWhite:0.86,alpha:1).cgColor;layer?.backgroundColor=NSColor(calibratedWhite:0.975,alpha:1).cgColor
  field.isBordered=false;field.drawsBackground=false;field.focusRingType = .none;field.font = .systemFont(ofSize:15);field.maximumNumberOfLines=1;field.cell?.isScrollable=true
  field.translatesAutoresizingMaskIntoConstraints=false;addSubview(field)
  NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant:44),field.leadingAnchor.constraint(equalTo:leadingAnchor,constant:13),field.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-13),field.centerYAnchor.constraint(equalTo:centerYAnchor),field.heightAnchor.constraint(equalToConstant:23)])
 }
 required init?(coder:NSCoder){fatalError()}
 func focus(_ active:Bool){layer?.borderColor=(active ? NSColor.controlAccentColor:NSColor(calibratedWhite:0.86,alpha:1)).cgColor;layer?.borderWidth=active ? 1.5:1}
}

final class SharedLoginPrimary:ActionButton {
 override func draw(_ dirtyRect:NSRect){
  let rect=bounds.insetBy(dx:1,dy:1)
  (isEnabled ? (isHighlighted ? NSColor(calibratedRed:0.12,green:0.30,blue:0.66,alpha:1):NSColor(calibratedRed:0.19,green:0.39,blue:0.81,alpha:1)):NSColor(calibratedWhite:0.85,alpha:1)).setFill()
  NSBezierPath(roundedRect:rect,xRadius:9,yRadius:9).fill()
  let text=title as NSString,attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:isEnabled ? NSColor.white:NSColor.secondaryLabelColor]
  let size=text.size(withAttributes:attributes);text.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attributes)
 }
}
