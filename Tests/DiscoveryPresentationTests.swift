import Foundation
@main struct DiscoveryPresentationTests {
 static func main()throws {
  struct Failure:Error{let message:String}
  func check(_ value:Bool,_ message:String)throws{if !value{throw Failure(message:message)}}
  let plain=Candidate(path:"Game.exe",backend:.wine,engine:"Windows")
  try check(DiscoveryPresentation.language(entry:plain,relativePath:"English Game") == "未知","English title was treated as language evidence")
  try check(DiscoveryPresentation.language(entry:Candidate(path:"Game_cn.exe",backend:.wine,engine:"QLIE"),relativePath:"Story")=="中文标记","Chinese launcher marker lost")
  try check(DiscoveryPresentation.language(entry:plain,relativePath:"Story 汉化版")=="中文标记","Chinese directory marker lost")
  try check(DiscoveryPresentation.version(relativePath:"SLG/Story-0.26.10-installed/Story.app")=="0.26.10（目录标记）","directory edition marker lost")
  try check(DiscoveryPresentation.version(relativePath:"Story/Chapter 17")=="未知","chapter number treated as version")
  try check(DiscoveryPresentation.platform(entry:Candidate(path:"Story.app",backend:.native,engine:"macOS"))=="macOS","native platform")
  print("PASS DiscoveryPresentation: platform and explicit language/version markers; unknowns remain unknown")
 }
}
