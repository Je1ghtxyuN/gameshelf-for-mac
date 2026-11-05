import Foundation

struct SharedPublishSelection {
 let folder:String
 let entry:Candidate
 let title:String
 let gameID:UUID?
 init(game:Game)throws {
  guard game.shared==nil,game.originalFolder.hasPrefix("/"),SharedScanSelection.launchable(game.entry) else{throw LibraryError("此游戏无法再次共享。")}
  try EntryPolicy.validate(game.entry)
  folder=game.originalFolder;entry=game.entry;title=game.title;gameID=game.id
 }
 init(record:DiscoveryRecord,source:LibrarySource)throws {
  guard record.available,record.status != .ignored else{throw LibraryError("所选游戏不可用。")}
  let chosen=record.selectedEntry.flatMap{selected in record.game.entries.first{$0.path==selected.path && $0.backend==selected.backend && SharedScanSelection.launchable($0)}} ?? record.game.entries.first(where:SharedScanSelection.launchable)
  guard let chosen else{throw LibraryError("所选项目没有有效的游戏入口。")}
  try EntryPolicy.validate(chosen)
  let url=URL(fileURLWithPath:source.path).appendingPathComponent(record.game.relativePath).standardizedFileURL
  _ = try SharedScanSelection.relative(folder:url.path,localRoot:source.path)
  folder=url.path;entry=chosen;title=record.game.title;gameID=record.addedGameID
 }
}
