import Foundation

extension Game {
 func applyingKnownMetadata(_ catalog:GameMetadataCatalog)->Game {
  guard let record=catalog.match(title) else{return self}
  var updated=self
  // Exact, explicitly confirmed aliases only: retain custom names and artwork.
  if titleIsCustom != true{updated.title=record.title}
  if updated.cover==nil,let url=catalog.coverURL(record){updated.cover=url.path;updated.coverOrigin="catalog";updated.defaultCoverSHA256=nil}
  return updated
 }
}
