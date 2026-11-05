import Foundation
@main struct DiscoverySelectionPolicyTests {
 static func main() {
  func policy(_ status:DiscoveryStatus,_ view:DiscoveryStatus,available:Bool=true,scanning:Bool=false,sharing:Bool=false)->DiscoverySelectionPolicy {
   DiscoverySelectionPolicy(status:status,available:available,view:view,scanning:scanning,sharing:sharing)
  }
  for view:DiscoveryStatus in [.pending,.added] {
   let added=policy(.added,view)
   precondition(added.selectable && added.shareable,"Added games must be selectable for sharing on All and Added pages")
   precondition(!added.importable && !added.ignorable && !added.restorable,"Added games cannot be imported or ignored again")
  }
  let pending=policy(.pending,.pending)
  precondition(pending.selectable && pending.shareable && pending.importable && pending.ignorable && !pending.restorable)
  let ignored=policy(.ignored,.ignored,available:false)
  precondition(ignored.selectable && ignored.restorable && !ignored.shareable && !ignored.importable && !ignored.ignorable)
  for status:DiscoveryStatus in [.pending,.added,.ignored] {
   for view:DiscoveryStatus in [.pending,.added,.ignored] {
    for busy in [policy(status,view,scanning:true),policy(status,view,sharing:true)] {
     precondition(!busy.selectable && !busy.shareable && !busy.importable && !busy.ignorable && !busy.restorable)
    }
   }
  }
  for status:DiscoveryStatus in [.pending,.added] {
   let unavailable=policy(status,.pending,available:false)
   precondition(!unavailable.selectable && !unavailable.shareable && !unavailable.importable && !unavailable.ignorable)
  }
  for invisible in [policy(.ignored,.pending),policy(.pending,.added),policy(.added,.ignored)] {
   precondition(!invisible.selectable && !invisible.shareable && !invisible.importable && !invisible.ignorable && !invisible.restorable)
  }
  // Mixed checked rows on All: only the pending record may be imported/ignored.
  let mixed=[policy(.pending,.pending),policy(.added,.pending)]
  precondition(mixed.filter(\.shareable).count==2 && mixed.filter(\.importable).count==1 && mixed.filter(\.ignorable).count==1)
  print("PASS discovery selection: added sharing, no duplicate import/ignore, mixed selections, unavailable/ignored/busy guards")
 }
}
