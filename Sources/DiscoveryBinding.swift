import Foundation

/// Reconcile legacy manual imports without modifying the library or overriding
/// an explicit pending choice. canonicalRoot is resolved by the scan worker.
enum DiscoveryBinding {
 static func reconcile(discovery:DiscoveryStore,source:LibrarySource,canonicalRoot:URL,games:[Game])throws {
  for record in discovery.records(sourceID:source.id) where record.status == .pending && record.available && record.selectedEntry==nil && record.addedGameID==nil {
   let folder=canonicalRoot.appendingPathComponent(record.game.relativePath).standardizedFileURL.path
   guard let existing=games.first(where:{$0.shared==nil && $0.originalFolder==folder}),
         let entry=record.game.entries.first(where:{$0.path==existing.entry.path && $0.backend==existing.entry.backend}) else{continue}
   try discovery.markAdded(record.game.id,entry:entry,gameID:existing.id)
  }
 }
}
