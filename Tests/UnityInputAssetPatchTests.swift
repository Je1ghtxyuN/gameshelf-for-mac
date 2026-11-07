import Foundation
@main struct UnityInputAssetPatchTests {
 static func main()throws {
  let input=Data([1,2,3,4,5]),output=Data([1,9,3,7,8,4,5])
  let spec=UnityInputAssetPatch.Spec(sourceSHA256:UnityInputAssetPatch.digest(input),sourceLength:5,outputSHA256:UnityInputAssetPatch.digest(output),outputLength:7,splices:[.init(start:1,end:2,bytes:Data([9])),.init(start:3,end:3,bytes:Data([7,8]))])
  guard try UnityInputAssetPatch.apply(input,spec:spec)==output else{throw LibraryError("delta applied incorrectly")}
  func rejects(_ label:String,_ body:()throws->Void)throws {do{try body()}catch{return};throw LibraryError("accepted "+label)}
  try rejects("unknown source") {_ = try UnityInputAssetPatch.apply(Data([5,4,3,2,1]),spec:spec)}
  try rejects("repeated patch") {_ = try UnityInputAssetPatch.apply(output,spec:spec)}
  let corrupt=UnityInputAssetPatch.Spec(sourceSHA256:spec.sourceSHA256,sourceLength:5,outputSHA256:spec.outputSHA256,outputLength:7,splices:[])
  try rejects("corrupt delta") {_ = try UnityInputAssetPatch.apply(input,spec:corrupt)}
  let overlaps=UnityInputAssetPatch.Spec(sourceSHA256:spec.sourceSHA256,sourceLength:5,outputSHA256:spec.outputSHA256,outputLength:7,splices:[.init(start:2,end:4,bytes:Data()),.init(start:3,end:5,bytes:Data())])
  try rejects("overlapping delta") {_ = try UnityInputAssetPatch.apply(input,spec:overlaps)}
  if let path=ProcessInfo.processInfo.environment["GAMESHELF_UNITY_INPUT_SOURCE"] {
   let bytes=try Data(contentsOf:URL(fileURLWithPath:path))
   let patched=try UnityInputAssetPatch.apply(bytes)
   guard UnityInputAssetPatch.digest(patched)==UnityInputAssetPatch.cyanbrain.outputSHA256 else {throw LibraryError("real asset output differs")}
  }
  print("PASS UnityInputAssetPatch: exact delta, input/output integrity, wrong/repeated version, overlap and corruption rejection")
 }
}
