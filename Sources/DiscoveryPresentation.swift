import Foundation

enum DiscoveryPresentation {
 static func platform(entry:Candidate)->String {
  switch entry.backend {case .native:return "macOS";case .web:return "HTML";case .wine,.renpy,.rpgmz:return "Windows"}
 }
 static func language(entry:Candidate,relativePath:String)->String {
  let stem=(entry.path as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping.lowercased()
  let location=relativePath.precomposedStringWithCanonicalMapping.lowercased()
  if ["中文","汉化","漢化","简体","簡體","繁体","繁體"].contains(where:{stem.contains($0) || location.contains($0)}){return "中文标记"}
  if stem.range(of:#"(?:^|[\s_.-])(?:cn|chs|cht|sc|zh(?:_cn|_tw)?)(?:$|[\s_.-])"#,options:.regularExpression) != nil{return "中文标记"}
  if stem.range(of:#"(?:^|[\s_.-])(?:en|eng|english)(?:$|[\s_.-])"#,options:.regularExpression) != nil{return "英文标记"}
  if stem.range(of:#"(?:^|[\s_.-])(?:jp|ja|jpn)(?:$|[\s_.-])"#,options:.regularExpression) != nil{return "日文标记"}
  return "未知"
 }
 static func version(relativePath:String)->String {
  let expression=try! NSRegularExpression(pattern:#"(?:^|[\s_.-])v?([0-9]{1,3}\.[0-9]+(?:\.[0-9]+){0,2})(?=$|[\s_.-])"#,options:.caseInsensitive)
  for component in relativePath.split(separator:"/").reversed() {
   let text=String(component) as NSString
   if let match=expression.firstMatch(in:text as String,range:NSRange(location:0,length:text.length)){return text.substring(with:match.range(at:1))+"（目录标记）"}
  }
  return "未知"
 }
}
