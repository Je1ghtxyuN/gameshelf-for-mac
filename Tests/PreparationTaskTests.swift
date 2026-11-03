import Foundation
@main struct PreparationTaskTests {
 static func main()throws {
  let tasks=PreparationTaskGroup()
  let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/sleep");p.arguments=["30"]
  try tasks.run(p);precondition(p.isRunning)
  tasks.cancel();p.waitUntilExit();precondition(!p.isRunning)
  tasks.finish(p)
  let never=Process();never.executableURL=URL(fileURLWithPath:"/bin/sleep");never.arguments=["30"]
  do{try tasks.run(never);fatalError("Cancelled work started")}catch{precondition(!never.isRunning)}
  let blocked=PreparationTaskGroup(),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
  let late=Process();late.executableURL=URL(fileURLWithPath:"/bin/sleep");late.arguments=["30"]
  DispatchQueue.global().async {
   defer{finished.signal()}
   do{try blocked.run(late){p in entered.signal();release.wait();try p.run()};fatalError("Late spawn accepted")}catch{}
  }
  precondition(entered.wait(timeout:.now()+3) == .success)
  let start=Date();blocked.cancel();precondition(Date().timeIntervalSince(start)<0.25)
  release.signal();precondition(finished.wait(timeout:.now()+3) == .success)
  if late.isRunning{late.waitUntilExit()};precondition(!late.isRunning)
  print("PASS preparation cancellation stops owned helper and prevents late launch")
 }
}
