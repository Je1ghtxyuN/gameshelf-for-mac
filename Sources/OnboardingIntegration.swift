import AppKit

extension App {
 func showOnboardingIfNeeded(){
  do{
   let state=try OnboardingState(root:root)
   guard state.needsPresentation(existingGameCount:store.games.count),(try SharedConnectionStore(root:root)).connections.isEmpty else{return}
   onboardingWindow=OnboardingWindowController{[weak self] choice in
    guard let self else{return}
    do{try state.complete(choice:choice)}catch{self.errorAlert(error);return}
    self.onboardingWindow?.close();self.onboardingWindow=nil
    switch choice {
    case .local:self.window.makeKeyAndOrderFront(nil)
    case .connect:self.showSharedLibrary()
    case .create:self.showSharedLibrary();self.sharedLibraryWindow?.beginAdministratorSetup()
    }
   }
   onboardingWindow?.showWindow(nil);onboardingWindow?.window?.makeKeyAndOrderFront(nil)
  }catch{showStatus(error.localizedDescription)}
 }
}
