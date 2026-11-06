import AppKit
import Darwin

/// Opt-in AppKit event-loop regression test using the product App.showLibrary.
/// Compile with App.swift's Bootstrap removed in a temporary source copy.
@main struct LibraryGridPerformanceTests {
 static func main() {
  let application=NSApplication.shared
  let delegate=LayoutProbe()
  application.setActivationPolicy(.accessory);application.delegate=delegate
  withExtendedLifetime(delegate){application.run()}
 }
}
final class LayoutProbe:NSObject,NSApplicationDelegate {
 var shelf:App!
 var heartbeat:Timer?
 var ticks=0
 var last=Date()
 var maxGap:Double=0
 var stage=0
 let started=Date()
 var watchdog:DispatchSourceTimer?
 var fixtureRoot:URL!
 func log(_ message:String){print(message);fflush(stdout)}
 func applicationDidFinishLaunching(_ notification:Notification) {
  let timer=DispatchSource.makeTimerSource(queue:.global())
  timer.schedule(deadline:.now()+20);timer.setEventHandler{fputs("FAIL main event loop blocked: 20s watchdog\n",stderr);fflush(stderr);_exit(124)};timer.resume();watchdog=timer
  do {
   let args=CommandLine.arguments
   guard let i=args.firstIndex(of:"--data-dir"),args.indices.contains(i+1) else{fatalError("--data-dir required")}
   let root=URL(fileURLWithPath:args[i+1]).standardizedFileURL
   let allowed=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/validation/library-layout").path
   precondition(root.path.hasPrefix(allowed+"/") && !FileManager.default.fileExists(atPath:root.path))
   fixtureRoot=root
   let count=args.last.flatMap(Int.init) ?? 26
   try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
   let games=(0..<count).map{n in Game(title:String(format:"合成 Game %03d with a long title",n),folder:root.appendingPathComponent("inert-\(n)").path,originalFolder:"synthetic",entry:Candidate(path:"not-a-real-game.exe",backend:.wine,engine:"Windows"),favorite:n%2==0,lastPlayed:Date(timeIntervalSince1970:Double(n)))}
   try JSONEncoder().encode(games).write(to:root.appendingPathComponent("library.json"))
   let collections=(0..<3).map{n in GameCollection(name:"分类 \(n)",gameIDs:games.filter{n==0 || $0.favorite==(n==1)}.map(\.id))}
   try JSONEncoder().encode(collections).write(to:root.appendingPathComponent("collections.json"))
   shelf=App();shelf.store=try LibraryStore(root:root);shelf.collapsedCollections=[]
   shelf.window=NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
   shelf.window.isReleasedWhenClosed=false;shelf.window.minSize=NSSize(width:780,height:520)
   log("BEGIN product showLibrary cards=\(count)")
   shelf.showLibrary();shelf.window.ignoresMouseEvents=true;shelf.window.orderFront(nil)
   // Do not capture the user's keyboard during parallel work. Window min/max
   // queries below exercise the tiling-size calculation directly.
   log("STARTUP showLibrary returned \(Date().timeIntervalSince(started))s")
   last=Date()
   heartbeat=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in self?.step()}
   RunLoop.main.add(heartbeat!,forMode:.common)
  }catch{log("FAIL \(error)");_exit(1)}
 }
 func step() {
  let now=Date();maxGap=max(maxGap,now.timeIntervalSince(last));last=now;ticks+=1
  guard ticks%3==0 else{return}
  let start=Date();stage+=1
  log("BEGIN stage=\(stage)")
  switch stage {
  case 1:
   shelf.window.contentView?.layoutSubtreeIfNeeded()
   verifyGrid()
   if let view=shelf.window.contentView,let image=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
    view.cacheDisplay(in:view.bounds,to:image)
    try! image.representation(using:.png,properties:[:])!.write(to:fixtureRoot.appendingPathComponent("first-frame.png"))
   }
   log("WINDOW minFullscreen=\(shelf.window.minFullScreenContentSize) maxFullscreen=\(shelf.window.maxFullScreenContentSize)")
  case 2:
   NSApp.deactivate();shelf.window.resignKey()
  case 3...7:
   let sizes=[NSSize(width:780,height:520),NSSize(width:1600,height:1000),NSSize(width:940,height:650),NSSize(width:1180,height:780),NSSize(width:800,height:540)]
   shelf.window.setContentSize(sizes[stage-3]);shelf.window.contentView?.layoutSubtreeIfNeeded()
   _ = shelf.window.minFullScreenContentSize;_ = shelf.window.maxFullScreenContentSize
   verifyGrid()
  case 8:
   shelf.search.stringValue="Game 000";shelf.renderCards();shelf.window.contentView?.layoutSubtreeIfNeeded()
   precondition(shelf.playtimeLabels.count==1,"search changed")
  case 9:
   shelf.search.stringValue="";shelf.filter="recent";shelf.showLibrary();shelf.window.contentView?.layoutSubtreeIfNeeded()
  case 10:
   shelf.filter="favorite";shelf.showLibrary();shelf.window.contentView?.layoutSubtreeIfNeeded()
   precondition(shelf.playtimeLabels.count==shelf.store.games.filter(\.favorite).count)
  case 11:
   shelf.filter="all";shelf.showLibrary();shelf.window.contentView?.layoutSubtreeIfNeeded()
   _ = shelf.window.minFullScreenContentSize;_ = shelf.window.maxFullScreenContentSize
  case 12:
   shelf.window.close();heartbeat?.invalidate();watchdog?.cancel()
   precondition(maxGap<1.5,"event loop stalled")
   log("PASS cards=\(shelf.store.games.count) heartbeatTicks=\(ticks) maxGap=\(maxGap)s total=\(Date().timeIntervalSince(started))s startup/deactivation/min-max/resize/search/filter/close")
   _exit(0)
  default:break
  }
  log("END stage=\(stage) duration=\(Date().timeIntervalSince(start))s")
 }
 func check(_ ok:Bool,_ message:String){if !ok{log("FAIL "+message);_exit(1)}}
 func verifyGrid() {
  guard CommandLine.arguments.contains("--expect-frame-layout") else{return}
  guard let scroll=shelf.content as? NSScrollView,let grid=scroll.documentView as? LibraryGridView else{fatalError("Frame grid missing")}
  log("GEOMETRY viewport=\(scroll.contentSize) grid=\(grid.frame) first=\(grid.cards.prefix(3).map{$0.frame}) cover=\(grid.cards.first?.cover.frame ?? .zero)")
  check(grid.cards.count==shelf.playtimeLabels.count,"card count")
  check(abs(grid.frame.width-scroll.contentSize.width)<1,"grid must follow resized viewport")
  if grid.cards.count>=3 {
   check(abs(grid.cards[2].frame.maxX-(grid.bounds.width-24))<1,"24pt scroller gutter changed")
  }
  for card in grid.cards {
   check(card.frame.width>0 && abs(card.cover.frame.height-card.frame.width*1.32)<1,"cover ratio")
   let playRect=card.play.alignmentRect(forFrame:card.play.frame)
   let moreRect=card.more.alignmentRect(forFrame:card.more.frame)
   let nameRect=card.name.alignmentRect(forFrame:card.name.frame)
   check(playRect.maxX<=moreRect.minX && nameRect.maxX<=playRect.minX,"control alignment overlap")
   check(card.subviews.allSatisfy{$0.translatesAutoresizingMaskIntoConstraints},"card descendants must use frames")
  }
  func visit(_ view:NSView) {
   if let list=view as? LibrarySidebarView {
    for row in list.subviews {check(row.frame.width==list.frame.width && row.frame.height>0,"sidebar row geometry")}
   }
   view.subviews.forEach(visit)
  }
  if let view=shelf.window.contentView{visit(view)}
 }

}
