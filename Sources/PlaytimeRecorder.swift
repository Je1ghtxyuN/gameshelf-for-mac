import Foundation

/// FIFO lifecycle recording over a single PlaytimeStore. Every event captures
/// its clocks at the call site; retries never substitute the recovery time.
/// Route all store mutations through this facade so nothing advances past a
/// failed event. Snapshot getters can continue to use the underlying store.
///
/// Pending events exist only in memory: if the process crashes while storage is
/// unavailable, they are lost. The store can recover only its last durable
/// checkpoint. Non-checkpoint lifecycle events are never dropped or coalesced.
final class PlaytimeRecorder {
 private enum Event {
  case begin(UUID, Date, TimeInterval)
  case end(UUID, Date, TimeInterval)
  case checkpoint(Date, TimeInterval)
  case pause(Date, TimeInterval)
  case resume(TimeInterval)
  case endAll(Date, TimeInterval)

  var isCheckpoint: Bool {
   if case .checkpoint = self { return true }
   return false
  }
 }

 private let store: PlaytimeStore
 private let lock = NSLock()
 private var pending: [Event] = []

 init(store: PlaytimeStore) { self.store = store }

 func begin(gameID: UUID, at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try enqueue(.begin(gameID, at, uptime))
 }

 func end(gameID: UUID, at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try enqueue(.end(gameID, at, uptime))
 }

 func checkpoint(at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try enqueue(.checkpoint(at, uptime))
 }

 func pause(at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try enqueue(.pause(at, uptime))
 }

 func resume(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try enqueue(.resume(uptime))
 }

 func endAll(at: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
  try enqueue(.endAll(at, uptime))
 }

 private func enqueue(_ event: Event) throws {
  lock.lock()
  defer { lock.unlock() }
  // Index zero is a previously failed head and must retain its original clocks.
  // Only consecutive checkpoints behind that head may collapse to the latest.
  if event.isCheckpoint, pending.count > 1, pending.last?.isCheckpoint == true {
   pending[pending.count - 1] = event
  } else {
   pending.append(event)
  }
  while let first = pending.first {
   // Removing only after success preserves the failing event and its successors.
   try apply(first)
   pending.removeFirst()
  }
 }

 private func apply(_ event: Event) throws {
  switch event {
  case let .begin(id, at, uptime): try store.begin(gameID: id, at: at, uptime: uptime)
  case let .end(id, at, uptime): try store.end(gameID: id, at: at, uptime: uptime)
  case let .checkpoint(at, uptime): try store.checkpoint(at: at, uptime: uptime)
  case let .pause(at, uptime): try store.pause(at: at, uptime: uptime)
  case let .resume(uptime): store.resume(uptime: uptime)
  case let .endAll(at, uptime): try store.endAll(at: at, uptime: uptime)
  }
 }
}
