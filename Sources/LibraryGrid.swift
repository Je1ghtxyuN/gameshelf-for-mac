import AppKit

/// Library content deliberately uses frames: its size must not become part of
/// NSWindow's fullscreen-tiling min/max Auto Layout optimization. Only the small
/// fixed chrome around the scroll views participates in that constraint graph.
final class LibraryCardView:NSView {
 let cover:NSView
 let name:NSTextField
 let play:NSButton
 let more:NSButton
 let time:NSTextField
 private let nameHeight:CGFloat
 private let timeHeight:CGFloat
 init(cover:NSView,name:NSTextField,play:NSButton,more:NSButton,time:NSTextField) {
  self.cover=cover;self.name=name;self.play=play;self.more=more;self.time=time
  nameHeight=max(play.intrinsicContentSize.height,more.intrinsicContentSize.height,name.intrinsicContentSize.height)
  timeHeight=time.intrinsicContentSize.height
  super.init(frame:.zero)
  for view in [cover,name,play,more,time] {view.translatesAutoresizingMaskIntoConstraints=true;addSubview(view)}
 }
 required init?(coder:NSCoder){fatalError()}
 override var isFlipped:Bool{true}
 func height(for width:CGFloat)->CGFloat {width*1.32+8+nameHeight+8+timeHeight}
 override func setFrameSize(_ newSize:NSSize){super.setFrameSize(newSize);arrange()}
 private func arrange() {
  let width=bounds.width,coverHeight=width*1.32,y=coverHeight+8
  let moreWidth:CGFloat=28,playWidth=play.intrinsicContentSize.width
  cover.frame=NSRect(x:0,y:0,width:width,height:coverHeight)
  // Auto Layout previously positioned alignment rects. Preserve AppKit's
  // bezel/text outsets while arranging the same rects without constraints.
  let playX=max(0,width-moreWidth-6-playWidth)
  func place(_ view:NSView,_ x:CGFloat,_ width:CGFloat,_ height:CGFloat) {
   view.frame=view.frame(forAlignmentRect:NSRect(x:x,y:y+(nameHeight-height)/2,width:width,height:height))
  }
  place(more,max(0,width-moreWidth),moreWidth,more.intrinsicContentSize.height)
  place(play,playX,playWidth,play.intrinsicContentSize.height)
  place(name,0,max(0,playX-12),name.intrinsicContentSize.height)
  time.frame=time.frame(forAlignmentRect:NSRect(x:0,y:y+nameHeight+8,width:width,height:timeHeight))
 }
}

final class LibraryGridView:NSView {
 static let columns=3
 static let gutter:CGFloat=24
 static let columnSpacing:CGFloat=22
 static let rowSpacing:CGFloat=28
 let cards:[LibraryCardView]
 init(cards:[LibraryCardView],width:CGFloat) {
  self.cards=cards
  super.init(frame:NSRect(x:0,y:0,width:width,height:0))
  autoresizingMask=[.width]
  for card in cards{addSubview(card)}
  arrange()
 }
 required init?(coder:NSCoder){fatalError()}
 override var isFlipped:Bool{true}
 override func setFrameSize(_ newSize:NSSize){super.setFrameSize(newSize);arrange()}
 private func arrange() {
  let width=max(0,(bounds.width-Self.gutter-CGFloat(Self.columns-1)*Self.columnSpacing)/CGFloat(Self.columns))
  let height=cards.first?.height(for:width) ?? 0
  for (index,card) in cards.enumerated() {
   card.frame=NSRect(x:CGFloat(index%Self.columns)*(width+Self.columnSpacing),y:CGFloat(index/Self.columns)*(height+Self.rowSpacing),width:width,height:height)
  }
  let rows=(cards.count+Self.columns-1)/Self.columns
  let total=CGFloat(rows)*height+CGFloat(max(0,rows-1))*Self.rowSpacing
  if frame.height != total{super.setFrameSize(NSSize(width:frame.width,height:total))}
 }
}

/// A frame-based scrolling list keeps an expanded sidebar independent of the
/// number of games/collections when AppKit asks the window for its minimum size.
final class LibrarySidebarView:NSView {
 private var rows:[(view:NSView,height:CGFloat)]=[]
 override var isFlipped:Bool{true}
 override init(frame:NSRect){super.init(frame:frame);autoresizingMask=[.width]}
 required init?(coder:NSCoder){fatalError()}
 func appendRow(_ view:NSView,height:CGFloat) {
  rows.append((view,height));addSubview(view)
  let y=frame.height+(rows.count==1 ? 0:3)
  view.frame=NSRect(x:0,y:y,width:bounds.width,height:height)
  super.setFrameSize(NSSize(width:frame.width,height:y+height))
 }
 override func setFrameSize(_ newSize:NSSize) {
  super.setFrameSize(NSSize(width:newSize.width,height:frame.height))
  for row in rows{row.view.setFrameSize(NSSize(width:newSize.width,height:row.height))}
 }
}

final class LibrarySidebarRowView:NSView {
 let leading:NSView?
 let body:NSView
 let trailing:NSView?
 let indent:CGFloat
 init(leading:NSView?=nil,body:NSView,trailing:NSView?=nil,indent:CGFloat=0) {
  self.leading=leading;self.body=body;self.trailing=trailing;self.indent=indent
  super.init(frame:.zero)
  for view in [leading,body,trailing].compactMap({$0}) {view.translatesAutoresizingMaskIntoConstraints=true;addSubview(view)}
 }
 required init?(coder:NSCoder){fatalError()}
 override var isFlipped:Bool{true}
 override func setFrameSize(_ newSize:NSSize) {
  super.setFrameSize(newSize)
  leading?.frame=NSRect(x:0,y:0,width:18,height:bounds.height)
  trailing?.frame=NSRect(x:max(0,bounds.width-22),y:0,width:22,height:bounds.height)
  let x=leading==nil ? indent:20
  body.frame=NSRect(x:x,y:0,width:max(0,bounds.width-x-(trailing==nil ? 0:24)),height:bounds.height)
 }
}
