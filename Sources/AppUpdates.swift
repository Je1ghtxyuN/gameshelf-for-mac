import AppKit
import Sparkle

/// Sparkle owns downloading and verified installation. The app owns game lifetime.
final class AppUpdates:NSObject,SPUUpdaterDelegate {
 private weak var app:App?
 private var controller:SPUStandardUpdaterController!
 private var deferredInstall:(()->Void)?
 private var idleTimer:Timer?
 private(set) var installationRequested=false
 init(app:App,startUpdater:Bool=true){
  self.app=app
  super.init()
  controller=SPUStandardUpdaterController(startingUpdater:startUpdater,updaterDelegate:self,userDriverDelegate:nil)
 }
 deinit{idleTimer?.invalidate()}
 func check(){controller.checkForUpdates(nil)}
 func updater(_ updater:SPUUpdater,mayPerform updateCheck:SPUUpdateCheck)throws {
  guard app?.updateActivity.canInstall==true else {
   throw NSError(domain:"GameShelf.Updates",code:1,userInfo:[NSLocalizedDescriptionKey:"请先保存并退出游戏，待当前任务完成后再检查更新。"])
  }
 }
 func updater(_ updater:SPUUpdater,shouldPostponeRelaunchForUpdate item:SUAppcastItem,untilInvokingBlock installHandler:@escaping()->Void)->Bool {
  installationRequested=true
  guard app?.updateActivity.canInstall==true else {
   deferredInstall=installHandler
   app?.showStatus("更新已准备好，退出游戏后继续安装。")
   idleTimer?.invalidate()
   let timer=Timer(timeInterval:1,repeats:true){[weak self] _ in self?.resumeWhenIdle()}
   idleTimer=timer;RunLoop.main.add(timer,forMode:.common)
   return true
  }
  return false
 }
 private func resumeWhenIdle(){
  guard let app,!app.quitting,app.updateActivity.canInstall,let install=deferredInstall else{return}
  idleTimer?.invalidate();idleTimer=nil;deferredInstall=nil
  install()
 }
 // Do not veto here: Sparkle checks this before its postponement callback.
 // Activity is handled by postponement plus the app termination guard.
 func updaterShouldRelaunchApplication(_ updater:SPUUpdater)->Bool{true}
 func updater(_ updater:SPUUpdater,userDidMake choice:SPUUserUpdateChoice,forUpdate item:SUAppcastItem,state:SPUUserUpdateState){
  installationRequested = choice == .install || (choice == .dismiss && state.stage == .installing)
 }
 func updater(_ updater:SPUUpdater,willInstallUpdate item:SUAppcastItem){installationRequested=true}
 private func clearInstallationRequest(){
  installationRequested=false;deferredInstall=nil;idleTimer?.invalidate();idleTimer=nil
 }
 func userDidCancelDownload(_ updater:SPUUpdater){clearInstallationRequest()}
 func updater(_ updater:SPUUpdater,didAbortWithError error:Error){clearInstallationRequest()}
 func updater(_ updater:SPUUpdater,didFinishUpdateCycleFor updateCheck:SPUUpdateCheck,error:Error?){
  // A nil completion can leave a verified installation scheduled on quit.
  // Download cancellation has its own callback; do not clear pending installs.
  if error != nil{clearInstallationRequest()}
 }
}

extension App {
 var updateActivity:UpdateActivity {
  UpdateActivity(preparing:busy || quitting || quitPromptOpen,
    gameProcesses:running.values.filter{$0.isRunning}.count + wineSessions.count + nativeRunning.values.filter{$0.isRunning}.count + nativeApplications.values.filter{!$0.isTerminated}.count,
    webActive:active != nil || leavingWebGame,
    pendingLaunches:nativeLaunching.count + (pendingWebLaunch == nil ? 0:1),sharedSessions:sharedSessions.count)
 }
 @objc func checkForUpdates(){updates?.check()}
}
