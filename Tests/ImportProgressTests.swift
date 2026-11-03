import Foundation
@main struct ImportProgressTests {
 static func main(){
  var p=ImportProgress(total:4)
  precondition(p.checking("樱御前").contains("1/4"))
  p.record(.added);p.record(.failed);p.record(.cancelled);p.record(.existing)
  precondition(p.processed==4 && p.existing==1 && p.added==1 && p.failed==1 && p.cancelled==1)
  precondition(p.summary.contains("已添加 1") && p.summary.contains("已在库中 1") && p.summary.contains("失败 1") && p.summary.contains("取消 1"))
  var good=ImportProgress(total:1);good.record(.added)
  precondition(good.summary.contains("导入完成"))
  print("PASS import progress counts success/failure/cancellation independently")
 }
}
