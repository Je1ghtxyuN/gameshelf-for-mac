import Foundation

enum SharedNavigation {
 enum Destination {case login,catalog,account}
 static func preferred(connections:[SharedConnection],boundID:UUID?)->SharedConnection? {
  if let boundID{return connections.first{$0.id==boundID}}
  return connections.count==1 ? connections.first:nil
 }
 static func destination(accountRequested:Bool,authenticated:Bool)->Destination {
  authenticated ? (accountRequested ? .account:.catalog):.login
 }
}
