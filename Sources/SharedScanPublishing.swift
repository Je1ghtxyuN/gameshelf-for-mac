import AppKit

private struct SharedScanLocation:Codable{var serverID:String;var rootID:String;var localPath:String}
extension App {
 func clearSharedLogin(_ connection:SharedConnection){
  if let saved=try? SharedConnectionStore(root:root){for item in saved.connections where item.serverID==connection.serverID && item.accountID==connection.accountID{sharedAccessTokens.removeValue(forKey:item.id)}}
 }
 func scanSharingConnection()->SharedConnection?{
  if let current=sharedLibraryWindow?.sharingConnection{return current}
  guard let saved=try? SharedConnectionStore(root:root) else{return nil}
  let bound=(try? PersonalLibraryBindingStore(root:root))?.binding?.connectionID
  let rows=saved.connections.filter{$0.isAdministrator && sharedAccessTokens[$0.id] != nil}
  if let bound,let result=rows.first(where:{$0.id==bound}){return result}
  return rows.count==1 ? rows[0]:nil
 }
 func shareScanned(_ records:[DiscoveryRecord],source:LibrarySource,finished:@escaping(String)->Void){
  guard !busy,!records.isEmpty else{return}
  guard let connection=scanSharingConnection(),let token=sharedAccessTokens[connection.id] else{showSharedLibrary();finished("请先登录管理员账号，再共享所选游戏。");return}
  guard records.count<=200 else{finished("每次最多共享 200 款游戏。");return}
  do{
   let api=try SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256)
   setBusy(true,"正在读取共享游戏库…")
   Task{@MainActor [weak self] in
    guard let self else{return};var published=0
    var mappingRootID:String?;var mappingConfirmed=false
    do{
     let roots:SharedAdminRoots=try await api.value("/api/admin/roots",token:token)
     guard !self.quitting else{return}
     guard !roots.roots.isEmpty else{throw LibraryError("服务器尚未配置游戏目录。")}
     let locationsFile=self.root.appendingPathComponent("shared-scan-locations.json")
     var locations=(try? JSONDecoder().decode([SharedScanLocation].self,from:Data(contentsOf:locationsFile))) ?? []
     let alert=NSAlert();alert.messageText="共享 \(records.count) 款游戏";alert.addButton(withTitle:"共享");alert.addButton(withTitle:"取消")
     let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:410,height:28));picker.addItems(withTitles:roots.roots.map(\.title))
     let row=NSStackView(views:[NSTextField(labelWithString:"共享位置"),picker]);row.spacing=12;row.frame=NSRect(x:0,y:0,width:480,height:32);alert.accessoryView=row
     guard alert.runModal() == .alertFirstButtonReturn else{self.setBusy(false,"");finished("");return}
     let remoteRoot=roots.roots[picker.indexOfSelectedItem]
     mappingRootID=remoteRoot.id
     var localRoot=locations.first(where:{$0.serverID==connection.serverID && $0.rootID==remoteRoot.id})?.localPath
     if localRoot==nil{
      let panel=NSOpenPanel();panel.title="选择「"+remoteRoot.title+"」在本机的对应目录";panel.prompt="使用此目录";panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.directoryURL=URL(fileURLWithPath:SharedScanSelection.suggestedRoot(source:source.path,title:remoteRoot.title) ?? source.path)
      guard panel.runModal() == .OK,let url=panel.url else{self.setBusy(false,"");finished("");return};localRoot=url.path
     }
     guard let localRoot else{throw LibraryError("未选择对应目录。")}
     var choices:[String:Candidate]=[:]
     let rows=try records.map{record->[String:String] in
      let selected=record.selectedEntry.flatMap{e in record.game.entries.first{$0.path==e.path && $0.backend==e.backend && SharedScanSelection.launchable($0)}} ?? record.game.entries.first(where:SharedScanSelection.launchable)
      guard let entry=selected else{throw LibraryError("所选项目没有有效的游戏入口。")}
      let folder=URL(fileURLWithPath:source.path).appendingPathComponent(record.game.relativePath).standardizedFileURL.path
      let relative=try SharedScanSelection.relative(folder:folder,localRoot:localRoot);choices[relative]=entry
      return ["relative":relative,"entryPath":entry.path]
     }
     self.showStatus("正在核对所选游戏…")
     let result:SharedAdminCandidates=try await api.value("/api/admin/roots/"+remoteRoot.id+"/candidates",method:"POST",token:token,body:["games":rows])
     guard !self.quitting else{return}
     guard result.candidates.count==rows.count,result.candidates.allSatisfy({candidate in choices[candidate.relative].map{wanted in candidate.entries.contains{$0.path==wanted.path && $0.backend==wanted.backend}}==true}) else{throw LibraryError("服务器目录与所选游戏不匹配，未进行共享。")}
     mappingConfirmed=true
     locations.removeAll{$0.serverID==connection.serverID && $0.rootID==remoteRoot.id};locations.append(SharedScanLocation(serverID:connection.serverID,rootID:remoteRoot.id,localPath:localRoot))
     try JSONEncoder().encode(locations).write(to:locationsFile,options:.atomic)
     for candidate in result.candidates{
      guard !self.quitting else{return}
      self.showStatus("正在共享 \(published+1)/\(rows.count)："+candidate.title)
      let game:SharedCatalogGame=try await api.value(SharedAdminPath.publish(candidate.id),method:"POST",token:token,body:["savePaths":[]])
      let _:SharedAdminOK=try await api.value("/api/admin/grants",method:"POST",token:token,body:["userID":connection.accountID,"gameID":game.id,"allowed":true]);published+=1
      if let known=GameMetadataCatalog(root:self.root).match(candidate.title){
       let _:SharedAdminOK=try await api.value("/api/admin/games/"+game.id+"/metadata",method:"POST",token:token,body:["title":known.title])
       if let image=GameMetadataCatalog(root:self.root).coverURL(known),let cover=try? LibraryCoverPayload.thumbnail(at:image){let _:LibraryCoverPayload=try await api.value("/api/admin/games/"+game.id+"/cover",method:"POST",token:token,body:["data":cover.data])}
      }
     }
     self.setBusy(false,"");finished("已共享 \(published) 款游戏");self.sharedLibraryWindow?.reloadSharedGames()
    }catch{
     guard !self.quitting else{return};self.setBusy(false,"")
     let request=error as? SharedRequestError
     if !mappingConfirmed,let rootID=mappingRootID,(request?.statusCode==400 || request?.statusCode==404 || error is LibraryError){
      let file=self.root.appendingPathComponent("shared-scan-locations.json")
      if var locations=try? JSONDecoder().decode([SharedScanLocation].self,from:Data(contentsOf:file)){
       locations.removeAll{$0.serverID==connection.serverID && $0.rootID==rootID}
       try? JSONEncoder().encode(locations).write(to:file,options:.atomic)
      }
     }
     finished((published>0 ? "已共享 \(published) 款；":"")+(request?.statusCode==400 || request?.statusCode==404 ? "对应目录或游戏入口不匹配，请重新选择目录。":request?.statusCode==401 ? "登录已过期，请重新登录。":error.localizedDescription))
    }
   }
  }catch{setBusy(false,"");finished(error.localizedDescription)}
 }
}
