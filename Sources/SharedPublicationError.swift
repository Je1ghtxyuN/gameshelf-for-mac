import Foundation

/// Only fixed local wording is displayed; arbitrary remote/local error text stays private.
enum SharedPublicationError {
 /// Global authority/transport failures stop remaining items, regardless of phase.
 static func shouldStopBatch(_ error:Error)->Bool {
  if let request=error as? SharedRequestError{return request.statusCode==401 || request.statusCode==403}
  return error is CancellationError || error is PinnedHTTPError || (error as NSError).domain==NSURLErrorDomain
 }
 static func isMappingFailure(_ error:Error)->Bool {
  if let local=error as? LibraryError{return local.message=="所选游戏不在对应目录中。"}
  guard let error=error as? SharedRequestError,let reason=error.reason else{return false}
  switch reason {
  case .folderMissing,.pathMismatch,.entryNotRecognized,.fingerprintMismatch:return true
  default:return false
  }
 }
 static func message(_ error:Error)->String {
  if error is CancellationError{return "共享操作已取消。"}
  if let pinned=error as? PinnedHTTPError {
   switch pinned {
   case .timeout:return "连接超时，请检查网络和共享服务后重试。"
   case .connectionFailed:return "无法连接共享服务，请检查网络后重试。"
   case .untrustedCertificate,.invalidPin:return "TLS 验证失败，请核对服务器地址和可信证书配置。"
   case .invalidRequest:return "HTTPS 请求未通过安全校验，请核对连接配置。"
   case .invalidResponse:return "服务器 HTTPS 响应格式无效，请检查共享服务。"
   case .tooLarge:return "HTTPS 请求或响应超过大小限制，已停止本批共享。"
   }
  }
  if let local=error as? LibraryError,["请先更新共享服务，再共享此游戏。","服务器返回的游戏入口不匹配。","所选游戏不在对应目录中。","无法核对共享游戏入口。","共享入口不能使用符号链接。","游戏入口超过核对大小限制。","游戏入口正在变化，请稍后重试。"].contains(local.message){return local.message}
  let cocoa=error as NSError
  if cocoa.domain==NSCocoaErrorDomain,[NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(cocoa.code){return "找不到本机游戏入口，请确认网络目录已连接。"}
  if let request=error as? SharedRequestError {
   if let reason=request.reason {
    switch reason {
    case .scanBusy:return "服务器正在扫描，请稍后重试。"
    case .unicodePathAmbiguous:return "服务器目录存在 Unicode 等价的重名项目，无法唯一确定游戏路径，请管理员处理名称冲突。"
    case .rulesReview:return "存档隔离规则需要管理员审核，未创建新版本。"
    case .sourceChanged:return "服务器游戏版本已变化，请重新扫描并核对。"
    case .rootChanged:return "服务器目录配置已变化，请刷新后重试。"
    case .folderMissing:return "服务器上找不到所选游戏目录，请核对对应目录。"
    case .pathMismatch:return "所选游戏路径不在对应服务器目录内，请重新选择对应目录。"
    case .entryNotRecognized:return "服务器未识别所选启动入口，请核对入口及对应目录。"
    case .fingerprintMismatch:return "本机与服务器的启动入口指纹不同，请核对版本和对应目录。"
    case .entryChanged:return "核对期间启动入口发生变化，请稍后重新核对。"
    case .entryUnsupported:return "启动入口不是可安全读取的普通文件，或超过核对大小限制。"
    case .reservedProfile:return "游戏源包含保留的账号目录，需管理员检查后再共享。"
    case .tooManyEntries:return "游戏目录条目过多，服务器无法完成核对。"
    case .candidateMissing:return "服务器候选记录已失效，请重新扫描或登记。"
    case .rootMissing:return "服务器游戏库目录配置不存在，请刷新共享位置。"
    case .coverMissing:return "服务器封面记录不存在，请重试封面更新。"
    case .invalidTitle:return "游戏名称未通过服务器校验，请检查名称。"
    case .invalidCover:return "封面未通过服务器校验，请更换有效图片。"
    case .coverTooLarge:return "封面超过服务器 256 KiB 限制，请缩小图片后重试。"
    case .writeLease:return "此账号的游戏写入会话尚未结束，请保存退出后重试。"
    case .provisioning:return "服务器正在准备个人游戏空间，请稍后重试。"
    case .passwordGameRunning:return "请先保存并退出此账号正在运行的游戏，再修改密码。"
    case .sourceUnavailable:return "服务器暂时无法读取游戏源，请检查挂载后重试。"
    case .serviceUnavailable:return "共享服务暂时不可用，请稍后重试。"
    }
   }
   switch request.statusCode {
   case 401:return "登录已失效，请重新登录。"
   case 403:return "当前账号没有执行此操作的权限。"
   case 400:return "服务器未接受此请求，请核对所选项目。"
   case 404:return "服务器资源或接口不存在，请刷新并核对服务版本。"
   case 409:return "服务器状态冲突，请刷新后重试。"
   case 412:return "服务器未通过一致性核对，请重新核对。"
   case 413:return "请求超过服务器大小限制，请减少每批共享数量。"
   case 429:return "请求过于频繁，请稍后重试。"
   case 503:return "共享服务或游戏源暂时不可用，请稍后重试。"
   default:return "共享请求失败（\(request.statusCode)）。"
   }
  }
  if let url=error as? URLError {
   switch url.code {
   case .timedOut:return "连接超时，请检查网络和共享服务后重试。"
   case .cancelled:return "共享操作已取消。"
   case .secureConnectionFailed,.serverCertificateUntrusted,.serverCertificateHasBadDate,.serverCertificateHasUnknownRoot,.serverCertificateNotYetValid:return "TLS 验证失败，请核对服务器地址和可信证书配置。"
   default:return "无法连接共享服务，请检查网络后重试。"
   }
  }
  return "共享操作未完成，请核对所选项目和连接后重试。"
 }
}
