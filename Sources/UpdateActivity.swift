import Foundation

struct UpdateActivity {
 let preparing:Bool
 let gameProcesses:Int
 let webActive:Bool
 let pendingLaunches:Int
 let sharedSessions:Int
 var canInstall:Bool{!preparing && gameProcesses==0 && !webActive && pendingLaunches==0 && sharedSessions==0}
}
