import Foundation

enum SharedScanSelection {
 static func relative(folder:String,localRoot:String)throws->String {
  guard [localRoot,folder].allSatisfy({$0.hasPrefix("/") && !$0.split(separator:"/").contains("..")}) else{throw LibraryError("所选游戏不在对应目录中。")}
  let root=URL(fileURLWithPath:localRoot).standardizedFileURL.resolvingSymlinksInPath().path
  let path=URL(fileURLWithPath:folder).standardizedFileURL.resolvingSymlinksInPath().path
  guard root != "/",path==root || path.hasPrefix(root+"/") else{throw LibraryError("所选游戏不在对应目录中。")}
  let relative=path==root ? ".":String(path.dropFirst(root.count+1))
  guard !relative.contains("\\"),!relative.contains(":"),!relative.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw LibraryError("游戏路径无法共享。")}
  return relative
 }
 static func suggestedRoot(source:String,title:String)->String? {
  var url=URL(fileURLWithPath:source)
  while url.path != "/"{if url.lastPathComponent.caseInsensitiveCompare(title) == .orderedSame{return url.path};url.deleteLastPathComponent()}
  return nil
 }
 static func launchable(_ entry:Candidate)->Bool{!VisualNovelProbe.isAuxiliaryExecutable(URL(fileURLWithPath:entry.path).lastPathComponent)}
}
