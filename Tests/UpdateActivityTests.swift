import Foundation
@main struct UpdateActivityTests {
 static func main(){
  func state(_ preparing:Bool=false,_ processes:Int=0,_ web:Bool=false,_ pending:Int=0,_ shares:Int=0)->UpdateActivity{UpdateActivity(preparing:preparing,gameProcesses:processes,webActive:web,pendingLaunches:pending,sharedSessions:shares)}
  precondition(state().canInstall)
  for value in [state(true),state(false,1),state(false,0,true),state(false,0,false,1),state(false,0,false,0,1)]{precondition(!value.canInstall,"updating must not interrupt preparation, games, pending launches or shared save flush")}
  print("PASS update activity: idle allowed; preparation, Wine/native, web, pending launches and shared leases block install")
 }
}
