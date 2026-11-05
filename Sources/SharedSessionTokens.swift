import Foundation

/// Login tokens live only in this App instance. No disk or credential APIs.
struct SharedSessionTokens {
 private var tokens:[UUID:String]=[:]
 subscript(connection:UUID)->String? {
  get{tokens[connection]}
  set{if let value=newValue,!value.isEmpty{tokens[connection]=value}else{tokens.removeValue(forKey:connection)}}
 }
 @discardableResult mutating func removeValue(forKey connection:UUID)->String?{tokens.removeValue(forKey:connection)}
}
