import Foundation

struct SharedPublicationBatch {
 struct Failure{let index:Int;let error:Error}
 var completed:[Int]=[]
 var failures:[Failure]=[]
 var stopped=false
 @MainActor static func run<Item>(_ items:[Item],continueWhile:()->Bool={true},stopOn:(Error)->Bool,perform:(Item,Int)async throws->Void)async->Self {
  var report=Self()
  for (index,item) in items.enumerated(){
   guard continueWhile() else{report.stopped=true;break}
   do{try await perform(item,index);report.completed.append(index)}
   catch{report.failures.append(Failure(index:index,error:error));if stopOn(error){report.stopped=true;break}}
  }
  return report
 }
}
