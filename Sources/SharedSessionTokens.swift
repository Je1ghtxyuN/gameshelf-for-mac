import Foundation

/// Login tokens live only in this App instance. No disk or credential APIs.
struct SharedSessionTokens {
 private(set) var activeConnectionID:UUID?
 private var tokens:[UUID:String]=[:]
 subscript(connection:UUID)->String? {
  get{tokens[connection]}
  set{if let value=newValue,!value.isEmpty{tokens[connection]=value;activeConnectionID=connection}else{removeValue(forKey:connection)}}
 }
 @discardableResult mutating func removeValue(forKey connection:UUID)->String?{
  if activeConnectionID==connection{activeConnectionID=nil}
  return tokens.removeValue(forKey:connection)
 }
}
