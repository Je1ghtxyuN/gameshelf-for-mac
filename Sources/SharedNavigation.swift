import Foundation

enum SharedNavigation {
 enum Destination {case login,catalog,account}
 static func preferred(connections:[SharedConnection],boundID:UUID?,activeID:UUID?=nil)->SharedConnection? {
  if let activeID,let active=connections.first(where:{$0.id==activeID}){return active}
  if let boundID{return connections.first{$0.id==boundID}}
  return connections.count==1 ? connections.first:nil
 }
 static func loginUsername(connection:SharedConnection,authenticated:Bool)->String {
  authenticated ? connection.username:""
 }
 static func destination(accountRequested:Bool,authenticated:Bool)->Destination {
  authenticated ? (accountRequested ? .account:.catalog):.login
 }
}
