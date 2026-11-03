import Foundation

@main struct PlaytimeRecorderTests {
 struct Failure: Error { let message: String }
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("PlaytimeRecorderTests-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  var passed = 0, failed = 0
  func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
  func check(_ condition: Bool, _ message: String) throws {
   if !condition { throw Failure(message: message) }
  }
  func near(_ value: Double, _ expected: Double, _ message: String) throws {
   try check(value.isFinite && abs(value - expected) < 0.000001, "\(message): \(value) != \(expected)")
  }
  func reject(_ message: String, _ action: () throws -> Void) throws {
   do { try action() } catch { return }
   throw Failure(message: message)
  }
  func test(_ name: String, _ body: (URL) throws -> Void) {
   do {
    let folder = root.appendingPathComponent(UUID().uuidString)
    try body(folder)
    passed += 1
    print("PASS \(name)")
   } catch {
    failed += 1
    print("FAIL \(name): \(error)")
   }
  }
  // A nonempty directory at the snapshot path reliably rejects atomic writes,
  // without permission assumptions, mocks, or touching any real user data.
  func block(_ folder: URL) throws -> Data? {
   let file = folder.appendingPathComponent("playtime.json")
   let backup = try? Data(contentsOf: file)
   if backup != nil { try fm.removeItem(at: file) }
   try fm.createDirectory(at: file, withIntermediateDirectories: false)
   try Data("keep".utf8).write(to: file.appendingPathComponent("sentinel"))
   return backup
  }
  func unblock(_ folder: URL, _ backup: Data?) throws {
   let file = folder.appendingPathComponent("playtime.json")
   try check(try Data(contentsOf: file.appendingPathComponent("sentinel")) == Data("keep".utf8), "failed recording damaged target")
   try fm.removeItem(at: file)
   if let backup { try backup.write(to: file) }
  }

  test("failed begin and queued end replay their original timestamps") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   let recorder = PlaytimeRecorder(store: store)
   let backup = try block(folder)
   try reject("begin did not report write failure") { try recorder.begin(gameID: id, at: date(100), uptime: 10) }
   try reject("end bypassed failed begin") { try recorder.end(gameID: id, at: date(130), uptime: 40) }
   try check(store.records(gameID: id).isEmpty && store.revision == 0, "failed begin advanced store")
   try unblock(folder, backup)
   try recorder.checkpoint(at: date(10000), uptime: 9910)
   try near(store.totalSeconds(gameID: id), 30, "retry counted time after game exit")
   let records = store.records(gameID: id)
   try check(records.count == 1 && records[0].startedAt == date(100) && records[0].endedAt == date(130), "retry changed captured dates or duplicated session")
   try near(try PlaytimeStore(root: folder).totalSeconds(gameID: id), 30, "replayed session was not persisted")
  }
  test("failed end blocks later checkpoints and does not accrue recovery delay") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   let recorder = PlaytimeRecorder(store: store)
   try recorder.begin(gameID: id, at: date(100), uptime: 10)
   let before = store.revision, backup = try block(folder)
   try reject("end did not fail") { try recorder.end(gameID: id, at: date(120), uptime: 30) }
   for offset in 0..<50 {
    try reject("checkpoint bypassed failed end") { try recorder.checkpoint(at: date(1000 + Double(offset)), uptime: 910 + Double(offset)) }
   }
   try check(store.revision == before && store.records(gameID: id).first?.endedAt == nil, "failed end advanced clock")
   try unblock(folder, backup)
   try recorder.checkpoint(at: date(5000), uptime: 4910)
   try near(store.totalSeconds(gameID: id), 20, "failed end counted recovery delay")
   try check(store.records(gameID: id).first?.endedAt == date(120), "failed end timestamp was replaced")
  }
  test("failed pause queues resume and end so sleep is excluded") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   let recorder = PlaytimeRecorder(store: store)
   try recorder.begin(gameID: id, at: date(100), uptime: 10)
   let before = store.revision, backup = try block(folder)
   try reject("pause did not fail") { try recorder.pause(at: date(120), uptime: 30) }
   try reject("resume bypassed failed pause") { try recorder.resume(uptime: 1030) }
   try reject("end bypassed failed pause") { try recorder.end(gameID: id, at: date(1140), uptime: 1050) }
   try check(store.revision == before, "queued resume changed persisted clock")
   try unblock(folder, backup)
   try recorder.checkpoint(at: date(2000), uptime: 1910)
   try near(store.totalSeconds(gameID: id), 40, "queued resume lost original wake anchor or counted sleep")
   try check(store.records(gameID: id).first?.endedAt == date(1140), "end date changed on replay")
  }
  test("checkpoint coalescing cannot cross a pause resume or game event") { folder in
   let store = try PlaytimeStore(root: folder), a = UUID(), b = UUID()
   let recorder = PlaytimeRecorder(store: store)
   try recorder.begin(gameID: a, at: date(100), uptime: 10)
   let backup = try block(folder)
   try reject("head checkpoint did not fail") { try recorder.checkpoint(at: date(110), uptime: 20) }
   try reject("second checkpoint did not fail") { try recorder.checkpoint(at: date(120), uptime: 30) }
   try reject("pause bypassed checkpoint") { try recorder.pause(at: date(130), uptime: 40) }
   try reject("paused checkpoint bypassed head") { try recorder.checkpoint(at: date(500), uptime: 410) }
   try reject("resume bypassed head") { try recorder.resume(uptime: 1010) }
   try reject("begin bypassed head") { try recorder.begin(gameID: b, at: date(1100), uptime: 1010) }
   try reject("end bypassed head") { try recorder.end(gameID: a, at: date(1120), uptime: 1030) }
   try reject("endAll bypassed head") { try recorder.endAll(at: date(1130), uptime: 1040) }
   try unblock(folder, backup)
   try recorder.checkpoint(at: date(5000), uptime: 4910)
   try near(store.totalSeconds(gameID: a), 50, "FIFO crossed sleep or game boundary")
   try near(store.totalSeconds(gameID: b), 30, "endAll lost its captured time")
   try check(store.records(gameID: a).first?.endedAt == date(1120) && store.records(gameID: b).first?.endedAt == date(1130), "queued end boundaries reordered")
  }
  test("a failed head checkpoint is retained while only adjacent tail checkpoints coalesce") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   let recorder = PlaytimeRecorder(store: store)
   try recorder.begin(gameID: id, at: date(100), uptime: 100)
   let backup = try block(folder)
   try reject("head checkpoint did not fail") { try recorder.checkpoint(at: date(120), uptime: 120) }
   // Deliberate backwards uptime makes deleting the head observable: the head
   // contributes 20 seconds before rebasing, the tail contributes zero.
   try reject("tail checkpoint did not fail") { try recorder.checkpoint(at: date(130), uptime: 0) }
   try reject("tail replacement did not fail") { try recorder.checkpoint(at: date(140), uptime: 1) }
   try unblock(folder, backup)
   try recorder.end(gameID: id, at: date(150), uptime: 11)
   try near(store.totalSeconds(gameID: id), 30, "failed head discarded or stale adjacent tail replayed")
  }
  test("successful recorder preserves duplicate semantics and normal pause resume") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   let recorder = PlaytimeRecorder(store: store)
   try recorder.begin(gameID: id, at: date(100), uptime: 10)
   try recorder.begin(gameID: id, at: date(105), uptime: 15)
   try recorder.pause(at: date(120), uptime: 30)
   try recorder.resume(uptime: 1030)
   try recorder.checkpoint(at: date(1130), uptime: 1040)
   try recorder.endAll(at: date(1140), uptime: 1050)
   let revision = store.revision
   try recorder.end(gameID: id, at: date(2000), uptime: 1910)
   try near(store.totalSeconds(gameID: id), 40, "normal forwarding changed elapsed time")
   try check(store.records(gameID: id).count == 1 && store.revision == revision, "duplicates changed persisted state")
  }
  print("PlaytimeRecorder: \(passed) passed; \(failed) failed")
  if failed != 0 { exit(1) }
 }
}
