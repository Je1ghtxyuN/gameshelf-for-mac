import Foundation

/// `.pending` is the All page; per-record status controls destructive actions.
struct DiscoverySelectionPolicy {
 let selectable:Bool
 let shareable:Bool
 let importable:Bool
 let ignorable:Bool
 let restorable:Bool
 init(status:DiscoveryStatus,available:Bool,view:DiscoveryStatus,scanning:Bool=false,sharing:Bool=false){
  let visible=view == .pending ? status != .ignored:status == view
  selectable = !scanning && !sharing && visible && (available || status == .ignored)
  shareable = selectable && status != .ignored
  importable = selectable && status == .pending
  ignorable = selectable && status == .pending
  restorable = selectable && status == .ignored
 }
}
