import Foundation
@main struct PureOnyxDisplaySettingsTests {
 static func main(){
  let old="[General]\r\nLanguage = ChineseSimplified\r\n[Screen]\r\nFullscreen = True\r\nResolution = 1470 x 956\r\nReflectionsEnabled = True\r\n[Bindings]\r\n20 = <Keyboard>/z\r\n"
  let window=PureOnyxDisplaySettings.updating(old,fullscreen:false)
  precondition(window.contains("Fullscreen = False\r\nResolution = 1280 x 720\r\n"))
  precondition(window.contains("Language = ChineseSimplified") && window.contains("20 = <Keyboard>/z") && window.contains("ReflectionsEnabled = True"))
  precondition(PureOnyxDisplaySettings.updating(window,fullscreen:false)==window)
  precondition(PureOnyxDisplaySettings.updating(window,fullscreen:true).contains("Fullscreen = True"))
  precondition(PureOnyxDisplaySettings.updating("",fullscreen:false)=="[Screen]\nFullscreen = False\nResolution = 1280 x 720\n")
  print("PASS PURE ONYX display INI: window/fullscreen, first launch, CRLF, idempotence; language/bindings/other graphics preserved")
 }
}
