import Foundation
@main struct RosettaPreparationTests {
 static func main()throws {
  var installs=0
  try RosettaPreparation.prepare(available:{true},install:{installs+=1})
  precondition(installs==0,"Existing Rosetta must not be reinstalled")
  var available=false
  try RosettaPreparation.prepare(available:{available},install:{installs+=1;available=true})
  precondition(installs==1 && available,"Missing Rosetta must be installed before retry")
  do{try RosettaPreparation.prepare(available:{false},install:{});fatalError("Successful command without available Rosetta accepted")}catch{}
  enum Failure:Error{case rejected}
  do{try RosettaPreparation.prepare(available:{false},install:{throw Failure.rejected});fatalError("Installer failure ignored")}catch Failure.rejected{}catch{fatalError("Original installer failure lost")}
  print("PASS Rosetta preparation: reuse, install and verify, unavailable result and installer failure")
 }
}
