import Foundation

struct PlaySession: Codable, Identifiable {
 var id: UUID
 var gameID: UUID
 var startedAt: Date
 var endedAt: Date?
 var durationSeconds: TimeInterval
 var interrupted: Bool
}

/// Local snapshots, serialized within one store instance. The owner must keep a
/// single instance per root; coordination between processes is not provided.
/// Getters never advance clocks. Checkpoint periodically and pause before sleep.
final class PlaytimeStore {
 private struct Entry: Codable {
  var session: PlaySession
  var checkpointAt: Date
 }
 private struct Snapshot: Codable {
  var version = 1
  var entries: [Entry] = []
 }
 private enum StoreError: Error {
  case invalidTime, invalidSnapshot, unsupportedVersion, durationOverflow
 }
 private let file: URL
 private let lock = NSLock()
 private var snapshot = Snapshot()
 private var anchors: [UUID: TimeInterval] = [:]
 private var paused = false
 private var snapshotRevision = 0

 var revision: Int { synchronized { snapshotRevision } }

 init(root: URL) throws {
  file = root.appendingPathComponent("playtime.json")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let bytes: Data
  do { bytes = try Data(contentsOf: file) }
  catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
   return
  }
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .secondsSince1970
  var loaded = try decoder.decode(Snapshot.self, from: bytes)
  try Self.validate(loaded)
  var recovered = false
  for index in loaded.entries.indices where loaded.entries[index].session.endedAt == nil {
   loaded.entries[index].session.endedAt = loaded.entries[index].checkpointAt
   loaded.entries[index].session.interrupted = true
   recovered = true
  }
  if recovered {
   // No current date/uptime is consulted during crash recovery. If persisting
   // recovery fails, initialization throws and the original bytes stay intact.
   try persist(loaded)
   snapshotRevision = 1
  }
  snapshot = loaded
 }

 func begin(gameID: UUID, at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try synchronized {
   try Self.validate(at: at, uptime: uptime)
   guard !snapshot.entries.contains(where: { $0.session.gameID == gameID && $0.session.endedAt == nil }) else { return }
   var next = try advanced(at: at, uptime: uptime)
   next.entries.append(Entry(session: PlaySession(id: UUID(), gameID: gameID, startedAt: at,
                                                 endedAt: nil, durationSeconds: 0, interrupted: false), checkpointAt: at))
   try commit(next, uptime: uptime, paused: paused)
  }
 }

 func end(gameID: UUID, at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try synchronized {
   try Self.validate(at: at, uptime: uptime)
   guard let index = snapshot.entries.firstIndex(where: { $0.session.gameID == gameID && $0.session.endedAt == nil }) else { return }
   var next = try advanced(at: at, uptime: uptime)
   next.entries[index].session.endedAt = at
   next.entries[index].checkpointAt = at
   try commit(next, uptime: uptime, paused: paused)
  }
 }

 func checkpoint(at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try synchronized {
   try Self.validate(at: at, uptime: uptime)
   guard hasActiveSessions else { return }
   try commit(advanced(at: at, uptime: uptime), uptime: uptime, paused: paused)
  }
 }

 func pause(at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try synchronized {
   try Self.validate(at: at, uptime: uptime)
   guard !paused else { return }
   // Commit even when idle so a failed write cannot silently change pause state.
   try commit(advanced(at: at, uptime: uptime), uptime: uptime, paused: true)
  }
 }

 /// Idempotent; invalid uptime is ignored because this API is nonthrowing.
 /// This changes only live anchors, not the persisted snapshot/revision.
 func resume(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
  synchronized {
   guard paused, uptime.isFinite, uptime >= 0 else { return }
   anchors = Dictionary(uniqueKeysWithValues: snapshot.entries.filter { $0.session.endedAt == nil }.map { ($0.session.gameID, uptime) })
   paused = false
  }
 }

 func endAll(at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try synchronized {
   try Self.validate(at: at, uptime: uptime)
   guard hasActiveSessions else { return }
   var next = try advanced(at: at, uptime: uptime)
   for index in next.entries.indices where next.entries[index].session.endedAt == nil {
    next.entries[index].session.endedAt = at
    next.entries[index].checkpointAt = at
   }
   try commit(next, uptime: uptime, paused: paused)
  }
 }

 func totalSeconds(gameID: UUID) -> TimeInterval {
  synchronized {
   snapshot.entries.filter { $0.session.gameID == gameID }.reduce(0) { $0 + $1.session.durationSeconds }
  }
 }

 /// Distribute the measured duration proportionally across the stored wall-time
 /// interval (including paused gaps). A zero/backwards wall interval is treated
 /// as a point at its last checkpoint, conserving duration without division by 0.
 func recentSeconds(gameID: UUID, since: Date) -> TimeInterval {
  synchronized {
   let boundary = since.timeIntervalSince1970
   guard boundary.isFinite else { return 0 }
   return snapshot.entries.filter { $0.session.gameID == gameID }.reduce(0) { sum, entry in
    let start = entry.session.startedAt.timeIntervalSince1970
    let end = (entry.session.endedAt ?? entry.checkpointAt).timeIntervalSince1970
    let duration = entry.session.durationSeconds
    let contribution: TimeInterval
    if end <= start { contribution = boundary <= end ? duration : 0 }
    else if boundary <= start { contribution = duration }
    else if boundary >= end { contribution = 0 }
    else {
     // Halve before subtraction so finite extreme Dates cannot overflow.
     let fraction = (end / 2 - boundary / 2) / (end / 2 - start / 2)
     contribution = duration * min(1, max(0, fraction))
    }
    return sum + contribution
   }
  }
 }

 func records(gameID: UUID) -> [PlaySession] {
  synchronized { snapshot.entries.filter { $0.session.gameID == gameID }.map { $0.session } }
 }

 private var hasActiveSessions: Bool { snapshot.entries.contains { $0.session.endedAt == nil } }

 private func advanced(at: Date, uptime: TimeInterval) throws -> Snapshot {
  var next = snapshot
  guard !paused else { return next }
  for index in next.entries.indices where next.entries[index].session.endedAt == nil {
   let gameID = next.entries[index].session.gameID
   guard let anchor = anchors[gameID] else { throw StoreError.invalidSnapshot }
   // A decreasing injected uptime never subtracts playtime. Successful writes
   // rebase anchors to the new uptime so later positive deltas still count.
   let delta = max(0, uptime - anchor)
   let duration = next.entries[index].session.durationSeconds + delta
   guard duration.isFinite else { throw StoreError.durationOverflow }
   next.entries[index].session.durationSeconds = duration
   next.entries[index].checkpointAt = at
  }
  return next
 }

 private func commit(_ next: Snapshot, uptime: TimeInterval, paused nextPaused: Bool) throws {
  try Self.validate(next)
  try persist(next)
  snapshot = next
  paused = nextPaused
  anchors = nextPaused ? [:] : Dictionary(uniqueKeysWithValues: next.entries.filter { $0.session.endedAt == nil }.map { ($0.session.gameID, uptime) })
  snapshotRevision += 1
 }

 private func persist(_ next: Snapshot) throws {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .secondsSince1970
  encoder.outputFormatting = [.sortedKeys]
  let bytes = try encoder.encode(next)
  try bytes.write(to: file, options: .atomic)
 }

 private static func validate(at: Date, uptime: TimeInterval) throws {
  guard at.timeIntervalSince1970.isFinite, uptime.isFinite, uptime >= 0 else { throw StoreError.invalidTime }
 }

 private static func validate(_ value: Snapshot) throws {
  guard value.version == 1 else { throw StoreError.unsupportedVersion }
  var identifiers: Set<UUID> = [], activeGames: Set<UUID> = []
  var total: TimeInterval = 0
  for entry in value.entries {
   let session = entry.session
   guard identifiers.insert(session.id).inserted,
         session.startedAt.timeIntervalSince1970.isFinite,
         entry.checkpointAt.timeIntervalSince1970.isFinite,
         session.durationSeconds.isFinite, session.durationSeconds >= 0 else { throw StoreError.invalidSnapshot }
   if let ended = session.endedAt {
    guard ended.timeIntervalSince1970.isFinite, ended == entry.checkpointAt else { throw StoreError.invalidSnapshot }
   } else {
    guard !session.interrupted, activeGames.insert(session.gameID).inserted else { throw StoreError.invalidSnapshot }
   }
   total += session.durationSeconds
   guard total.isFinite else { throw StoreError.durationOverflow }
  }
 }

 private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
  lock.lock()
  defer { lock.unlock() }
  return try body()
 }
}
