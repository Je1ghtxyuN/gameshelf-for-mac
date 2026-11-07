import AppKit
import Sparkle

// No games, accounts, network, or user data. Exercise the actual delegate against
// Sparkle with startup disabled, while activity is supplied by this host fixture.
final class App:NSObject {
 var busy=false,quitting=false,quitPromptOpen=false,leavingWebGame=false
 var running:[UUID:Process]=[:],nativeRunning:[UUID:Process]=[:]
 var wineSessions=Set<UUID>(),nativeLaunching=Set<UUID>()
 var nativeApplications:[UUID:NSRunningApplication]=[:]
 var active:String?,pendingWebLaunch:UUID?
 var sharedSessions:[UUID:Bool]=[:]
 var updates:AppUpdates?
 func showStatus(_ text:String){}
}
@main struct AppUpdatesTests {
 static func main(){
  let app=App()
  let controller=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
  let updater=controller.updater
  let subject=AppUpdates(app:app,startUpdater:false)
  let item=SUAppcastItem(dictionary:["title":"Test","sparkle:version":"43","enclosure":["url":"https://example.org/test.zip","sparkle:version":"43"]])!
  subject.updater(updater,willInstallUpdate:item)
  precondition(subject.installationRequested)
  subject.userDidCancelDownload(updater)
  precondition(!subject.installationRequested,"cancel download must unlock launch even if cycle completes without error")
  subject.updater(updater,willInstallUpdate:item)
  subject.updater(updater,didFinishUpdateCycleFor:.updates,error:nil)
  precondition(subject.installationRequested,"nil completion can leave install scheduled on quit")
  subject.updater(updater,didFinishUpdateCycleFor:.updates,error:NSError(domain:"fixture",code:1))
  precondition(!subject.installationRequested)
  app.busy=true
  precondition(subject.updaterShouldRelaunchApplication(updater),"must reach postponement callback rather than abort before it")
  var installed=0
  precondition(subject.updater(updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{installed+=1}))
  RunLoop.main.run(until:Date().addingTimeInterval(1.1));precondition(installed==0)
  app.busy=false
  RunLoop.main.run(until:Date().addingTimeInterval(1.1));precondition(installed==1)
  RunLoop.main.run(until:Date().addingTimeInterval(1.1));precondition(installed==1,"resume exactly once")
  subject.userDidCancelDownload(updater)
  app.busy=true
  _ = subject.updater(updater,shouldPostponeRelaunchForUpdate:item,untilInvokingBlock:{installed+=1})
  subject.userDidCancelDownload(updater);app.busy=false
  RunLoop.main.run(until:Date().addingTimeInterval(1.1));precondition(installed==1,"canceled deferred closure must not install")
  print("PASS actual Sparkle delegate: download cancellation, nil/error completion, busy postponement, idle resume once and cancellation of deferred install")
 }
}
