import Foundation

@main struct PlaytimeStoreTests {
 struct Failure: Error { let message: String }
 static func main() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("PlaytimeStoreTests-" + UUID().uuidString)
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  var passed = 0, failed = 0
  func check(_ condition: Bool, _ message: String) throws {
   if !condition { throw Failure(message: message) }
  }
  func near(_ actual: Double, _ expected: Double, _ message: String) throws {
   try check(actual.isFinite && abs(actual - expected) < 0.000001, message + ": \(actual) != \(expected)")
  }
  func reject(_ message: String, _ operation: () throws -> Void) throws {
   do { try operation() } catch { return }
   throw Failure(message: message)
  }
  func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
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

  test("multiple games count independently and duplicate begin/end are idempotent") { folder in
   let store = try PlaytimeStore(root: folder), a = UUID(), b = UUID()
   try store.begin(gameID: a, at: date(100), uptime: 10)
   let firstID = store.records(gameID: a).first?.id
   let revision = store.revision
   try store.begin(gameID: a, at: date(105), uptime: 15)
   try check(store.revision == revision, "duplicate begin changed revision")
   try store.begin(gameID: b, at: date(110), uptime: 20)
   try store.end(gameID: a, at: date(130), uptime: 40)
   try store.end(gameID: b, at: date(140), uptime: 50)
   let endedRevision = store.revision
   try store.end(gameID: a, at: date(200), uptime: 100)
   try near(store.totalSeconds(gameID: a), 30, "first game duration")
   try near(store.totalSeconds(gameID: b), 30, "background second game duration")
   try check(store.records(gameID: a).count == 1 && store.records(gameID: a).first?.id == firstID, "duplicate changed session identity")
   try check(store.revision == endedRevision, "duplicate end changed revision")
   try store.begin(gameID: a, at: date(200), uptime: 100)
   try store.endAll(at: date(207), uptime: 107)
   try check(store.records(gameID: a).count == 2, "second launch did not create a new session")
   try near(try PlaytimeStore(root: folder).totalSeconds(gameID: a), 37, "closed sessions did not persist")
  }
  test("checkpoint is the persisted snapshot and recovery stops at that checkpoint") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   try store.begin(gameID: id, at: date(100), uptime: 5)
   try near(store.totalSeconds(gameID: id), 0, "getter invented live time")
   try store.checkpoint(at: date(112), uptime: 17)
   try near(store.totalSeconds(gameID: id), 12, "checkpoint omitted elapsed uptime")
   try check(store.records(gameID: id).first?.endedAt == nil, "live snapshot was prematurely ended")
   let recovered = try PlaytimeStore(root: folder)
   let record = recovered.records(gameID: id).first
   try check(record?.endedAt == date(112) && record?.interrupted == true, "crash recovery did not close at last checkpoint")
   try near(recovered.totalSeconds(gameID: id), 12, "recovery invented offline hours")
   let again = try PlaytimeStore(root: folder)
   try check(again.records(gameID: id).first?.id == record?.id && again.records(gameID: id).first?.interrupted == true, "recovery did not persist")
   try near(again.totalSeconds(gameID: id), 12, "recovery repeated duration")
  }
  test("wall clock rollback preserves monotonic duration and recent conservation") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   try store.begin(gameID: id, at: date(1000), uptime: 100)
   try store.end(gameID: id, at: date(900), uptime: 160)
   try near(store.totalSeconds(gameID: id), 60, "wall clock changed duration")
   try near(store.recentSeconds(gameID: id, since: date(0)), 60, "rollback lost recent duration")
   try near(store.recentSeconds(gameID: id, since: date(901)), 0, "rollback fallback included a future checkpoint")
   try near(store.recentSeconds(gameID: id, since: date(900)), 60, "rollback boundary lost duration")
  }
  test("pause/resume excludes sleep and repeated pause/resume cannot reset the anchor") { folder in
   let store = try PlaytimeStore(root: folder), a = UUID(), b = UUID()
   try store.begin(gameID: a, at: date(100), uptime: 10)
   try store.pause(at: date(120), uptime: 30)
   try store.pause(at: date(130), uptime: 40)
   try store.begin(gameID: b, at: date(150), uptime: 60)
   try store.checkpoint(at: date(1000), uptime: 910)
   try near(store.totalSeconds(gameID: a), 20, "paused checkpoint counted sleep")
   store.resume(uptime: 1010)
   store.resume(uptime: 1015)
   try store.endAll(at: date(1120), uptime: 1030)
   try near(store.totalSeconds(gameID: a), 40, "sleep or duplicate resume changed elapsed time")
   try near(store.totalSeconds(gameID: b), 20, "game begun paused counted sleep")
   try check(store.records(gameID: a).first?.interrupted == false, "normal end marked interrupted")
  }
  test("last fourteen days prorates a boundary crossing session") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   let boundary = 2000000.0, day = 86400.0
   try store.begin(gameID: id, at: date(boundary - day), uptime: 0)
   try store.end(gameID: id, at: date(boundary + day), uptime: 200)
   try store.begin(gameID: id, at: date(boundary + 13 * day), uptime: 300)
   try store.end(gameID: id, at: date(boundary + 14 * day), uptime: 320)
   try near(store.recentSeconds(gameID: id, since: date(boundary)), 120, "boundary overlap was not proportional")
   try near(store.totalSeconds(gameID: id), 220, "proration mutated total")
   try near(store.recentSeconds(gameID: id, since: date(boundary + 15 * day)), 0, "future query included old duration")
  }
  test("zero wall interval conserves duration at its checkpoint") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   try store.begin(gameID: id, at: date(100), uptime: 1)
   try store.end(gameID: id, at: date(100), uptime: 31)
   try near(store.recentSeconds(gameID: id, since: date(100)), 30, "zero wall span lost duration")
   try near(store.recentSeconds(gameID: id, since: date(101)), 0, "zero wall span leaked into future")
  }
  test("all snapshot write failures roll back durations sessions revision and pause state") { folder in
   let store = try PlaytimeStore(root: folder), a = UUID(), b = UUID()
   try store.begin(gameID: a, at: date(100), uptime: 10)
   let revision = store.revision
   let file = folder.appendingPathComponent("playtime.json")
   let backup = try Data(contentsOf: file)
   try fm.removeItem(at: file)
   try fm.createDirectory(at: file, withIntermediateDirectories: false)
   try Data("keep".utf8).write(to: file.appendingPathComponent("sentinel"))
   try reject("checkpoint write failure accepted") { try store.checkpoint(at: date(110), uptime: 20) }
   try reject("begin write failure accepted") { try store.begin(gameID: b, at: date(110), uptime: 20) }
   try reject("end write failure accepted") { try store.end(gameID: a, at: date(110), uptime: 20) }
   try reject("pause write failure accepted") { try store.pause(at: date(110), uptime: 20) }
   try reject("endAll write failure accepted") { try store.endAll(at: date(110), uptime: 20) }
   try check(store.revision == revision && store.records(gameID: b).isEmpty && store.records(gameID: a).first?.endedAt == nil, "failed save mutated model")
   try near(store.totalSeconds(gameID: a), 0, "failed save mutated elapsed time")
   try check(try Data(contentsOf: file.appendingPathComponent("sentinel")) == Data("keep".utf8), "failed save damaged target")
   try fm.removeItem(at: file)
   try backup.write(to: file)
   try store.end(gameID: a, at: date(130), uptime: 40)
   try near(store.totalSeconds(gameID: a), 30, "failed operations advanced uptime or paused state")
  }
  test("malformed existing bytes throw without replacement") { folder in
   try fm.createDirectory(at: folder, withIntermediateDirectories: true)
   let file = folder.appendingPathComponent("playtime.json"), bad = Data("{broken JSON".utf8)
   try bad.write(to: file)
   try reject("corrupt file silently reset") { _ = try PlaytimeStore(root: folder) }
   try check(try Data(contentsOf: file) == bad, "corrupt bytes replaced")
  }
  test("nonfinite date and negative or nonfinite uptime cannot poison state") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   for uptime in [-1.0, Double.nan, Double.infinity] {
    try reject("invalid uptime accepted") { try store.begin(gameID: id, at: date(100), uptime: uptime) }
   }
   try reject("nonfinite date accepted") { try store.begin(gameID: id, at: date(.nan), uptime: 0) }
   try store.begin(gameID: id, at: date(100), uptime: 0)
   let revision = store.revision
   try reject("invalid checkpoint accepted") { try store.checkpoint(at: date(101), uptime: .nan) }
   try reject("invalid end date accepted") { try store.end(gameID: id, at: date(.infinity), uptime: 10) }
   try reject("invalid pause accepted") { try store.pause(at: date(101), uptime: -1) }
   store.resume(uptime: .nan)
   try check(store.revision == revision, "invalid inputs wrote snapshot")
   try store.end(gameID: id, at: date(110), uptime: 10)
   try near(store.totalSeconds(gameID: id), 10, "invalid inputs altered anchor")
   try near(store.recentSeconds(gameID: id, since: date(.nan)), 0, "invalid recent query escaped finite bounds")
  }
  test("uptime rollback never subtracts time and resumes from new baseline") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   try store.begin(gameID: id, at: date(0), uptime: 100)
   try store.checkpoint(at: date(10), uptime: 110)
   try store.checkpoint(at: date(20), uptime: 1)
   try store.end(gameID: id, at: date(25), uptime: 6)
   try near(store.totalSeconds(gameID: id), 15, "uptime rollback produced negative or inflated duration")
  }
  test("semantic corrupt snapshots throw and are preserved") { folder in
   try fm.createDirectory(at: folder, withIntermediateDirectories: true)
   let file = folder.appendingPathComponent("playtime.json"), id = UUID().uuidString, game = UUID().uuidString
   let good: [String: Any] = ["session": ["id": id, "gameID": game, "startedAt": 100, "endedAt": 110, "durationSeconds": 10, "interrupted": false], "checkpointAt": 110]
   var negative = good
   var badSession = good["session"] as! [String: Any]
   badSession["durationSeconds"] = -1
   negative["session"] = badSession
   var active = good
   badSession = good["session"] as! [String: Any]
   badSession.removeValue(forKey: "endedAt")
   active["session"] = badSession
   for object: [String: Any] in [
    ["version": 1, "entries": [negative]],
    ["version": 1, "entries": [good, good]],
    ["version": 1, "entries": [active, active]],
    ["version": 99, "entries": []]
   ] {
    let bytes = try JSONSerialization.data(withJSONObject: object)
    try bytes.write(to: file)
    try reject("invalid snapshot accepted") { _ = try PlaytimeStore(root: folder) }
    try check(try Data(contentsOf: file) == bytes, "invalid snapshot overwritten")
   }
  }
  test("huge finite elapsed overflow fails transactionally") { folder in
   let store = try PlaytimeStore(root: folder), id = UUID()
   try store.begin(gameID: id, at: date(0), uptime: 0)
   try store.checkpoint(at: date(1), uptime: Double.greatestFiniteMagnitude)
   let revision = store.revision
   try store.checkpoint(at: date(2), uptime: 0)
   let before = store.revision
   try reject("overflow duration accepted") { try store.checkpoint(at: date(3), uptime: Double.greatestFiniteMagnitude) }
   try check(store.revision == before && before >= revision, "overflow changed snapshot")
   try check(store.totalSeconds(gameID: id).isFinite, "overflow contaminated total")
  }
  print("PlaytimeStore: \(passed) passed; \(failed) failed")
  if failed != 0 { exit(1) }
 }
}
