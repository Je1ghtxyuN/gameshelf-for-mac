import AppKit

extension App {
 func prepareRosetta(for game:Game){
  guard !quitting else{return}
  let alert=NSAlert()
  alert.messageText="安装 Rosetta 2"
  alert.informativeText="此 Wine 运行环境需要 Apple 的 Rosetta 2。选择「同意并安装」即同意 Apple 软件许可协议，安装完成后将继续准备游戏。"
  let license=ActionButton("查看 Apple 软件许可协议"){
   NSWorkspace.shared.open(URL(string:"https://www.apple.com/legal/sla/")!)
  }
  license.sizeToFit();alert.accessoryView=license
  alert.addButton(withTitle:"同意并安装");alert.addButton(withTitle:"取消")
  guard alert.runModal() == .alertFirstButtonReturn else{releaseShared(game.id);return}
  setBusy(true,"正在安装 Rosetta 2…")
  DispatchQueue.global(qos:.userInitiated).async {
   do {
    try RosettaPreparation.prepare()
    self.preparationReady{self.setBusy(false,"");self.prepareWine(game)}
   }catch{self.preparationReady{self.setBusy(false,"");self.releaseShared(game.id);self.errorAlert(error)}}
  }
 }
}
