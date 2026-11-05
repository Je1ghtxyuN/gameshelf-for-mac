import Foundation
@main struct SharedPublicationBatchTests {
 enum Failure:Error{case missing,expired}
 @MainActor static func main()async {
  var seen:[Int]=[]
  let batch=await SharedPublicationBatch.run([0,1,2],stopOn:{_ in false}){value,_ in
   seen.append(value);if value==1{throw Failure.missing}
  }
  precondition(seen==[0,1,2] && batch.completed==[0,2] && batch.failures.map(\.index)==[1] && !batch.stopped)
  seen=[]
  let expired=await SharedPublicationBatch.run([0,1,2],stopOn:{$0 is Failure}){value,_ in
   seen.append(value);if value==1{throw Failure.expired}
  }
  precondition(seen==[0,1] && expired.completed==[0] && expired.failures.map(\.index)==[1] && expired.stopped)
  let empty=await SharedPublicationBatch.run([Int](),stopOn:{_ in false}){_,_ in fatalError("empty batch invoked")}
  precondition(empty.completed.isEmpty && empty.failures.isEmpty)
  var continueBatch=true;seen=[]
  let metadataStopped=await SharedPublicationBatch.run([0,1,2],continueWhile:{continueBatch},stopOn:{_ in false}){value,_ in
   seen.append(value);if value==0{continueBatch=false}
  }
  precondition(seen==[0] && metadataStopped.completed==[0] && metadataStopped.failures.isEmpty && metadataStopped.stopped)
  print("PASS batch publication: item failures preserve successes and continue; expired authority stops remaining items")
 }
}
