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
  do{try shareSelections(records.map{try SharedPublishSelection(record:$0,source:source)},finished:finished)}catch{finished(error.localizedDescription)}
 }
 func shareLibraryGame(_ game:Game){
  do{try shareSelections([SharedPublishSelection(game:game)]){[weak self] message in self?.showStatus(message)}}catch{errorAlert(error)}
 }
 private func shareSelections(_ selections:[SharedPublishSelection],finished:@escaping(String)->Void)throws{
  guard !busy,!selections.isEmpty else{finished("");return}
  guard let connection=scanSharingConnection(),let token=sharedAccessTokens[connection.id] else{showSharedLibrary();finished("请先登录管理员账号，再共享所选游戏。");return}
  guard selections.count<=200 else{finished("每次最多共享 200 款游戏。");return}
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
     let alert=NSAlert();alert.messageText=selections.count==1 ? "共享「"+selections[0].title+"」":"共享 \(selections.count) 款游戏";alert.addButton(withTitle:"共享");alert.addButton(withTitle:"取消")
     let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:410,height:28));picker.addItems(withTitles:roots.roots.map(\.title))
     let row=NSStackView(views:[NSTextField(labelWithString:"共享位置"),picker]);row.spacing=12;row.frame=NSRect(x:0,y:0,width:480,height:32);if roots.roots.count>1{alert.accessoryView=row}
     guard alert.runModal() == .alertFirstButtonReturn else{self.setBusy(false,"");finished("");return}
     let remoteRoot=roots.roots[picker.indexOfSelectedItem]
     mappingRootID=remoteRoot.id
     var localRoot=locations.first(where:{$0.serverID==connection.serverID && $0.rootID==remoteRoot.id})?.localPath
     if localRoot==nil,!self.rejectedSharedMappingGuesses.contains(connection.serverID+":"+remoteRoot.id),let suggested=SharedScanSelection.suggestedRoot(source:selections[0].folder,title:remoteRoot.title),selections.allSatisfy({(try? SharedScanSelection.relative(folder:$0.folder,localRoot:suggested)) != nil}){localRoot=suggested}
     if localRoot==nil{
      let panel=NSOpenPanel();panel.title="选择「"+remoteRoot.title+"」在本机的对应目录";panel.prompt="使用此目录";panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.directoryURL=URL(fileURLWithPath:selections[0].folder)
      guard panel.runModal() == .OK,let url=panel.url else{self.setBusy(false,"");finished("");return};localRoot=url.path
     }
     guard let localRoot else{throw LibraryError("未选择对应目录。")}
     var metadataWarnings:[String]=[]
     var metadataStopError:Error?
     let report=await SharedPublicationBatch.run(selections,continueWhile:{metadataStopError==nil},stopOn:SharedPublicationError.shouldStopBatch){selected,index in
      guard !self.quitting else{throw CancellationError()}
      self.showStatus("正在共享 \(index+1)/\(selections.count)："+selected.title)
      let row=try await Task.detached(priority:.userInitiated){
       let relative=try SharedScanSelection.relative(folder:selected.folder,localRoot:localRoot)
       return ["relative":relative,"entryPath":selected.entry.path,"entrySHA256":try SharedEntryFingerprint.hash(folder:URL(fileURLWithPath:selected.folder),entry:selected.entry)]
      }.value
      let result:SharedAdminCandidates=try await api.value("/api/admin/roots/"+remoteRoot.id+"/candidates",method:"POST",token:token,body:["games":[row]])
      guard !self.quitting else{throw CancellationError()}
      guard result.entryFingerprintsVerified==true else{throw LibraryError("请先更新共享服务，再共享此游戏。")}
      guard result.candidates.count==1,let candidate=result.candidates.first,candidate.relative==row["relative"],candidate.entries.contains(where:{$0.path==selected.entry.path && $0.backend==selected.entry.backend}) else{throw LibraryError("服务器返回的游戏入口不匹配。")}
      if !mappingConfirmed{
       mappingConfirmed=true
       locations.removeAll{$0.serverID==connection.serverID && $0.rootID==remoteRoot.id};locations.append(SharedScanLocation(serverID:connection.serverID,rootID:remoteRoot.id,localPath:localRoot))
       try? JSONEncoder().encode(locations).write(to:locationsFile,options:.atomic)
      }
      let game:SharedCatalogGame=try await api.value(SharedAdminPath.publish(candidate.id),method:"POST",token:token,body:["savePaths":[]])
      let _:SharedAdminOK=try await api.value("/api/admin/grants",method:"POST",token:token,body:["userID":connection.accountID,"gameID":game.id,"allowed":true]);published+=1
      do{
       let local=selected.gameID.flatMap{id in self.store.games.first{$0.id==id}}
       let catalog=GameMetadataCatalog(root:self.root),known=catalog.match(candidate.title)
       if let title=local?.title ?? known?.title{
        let _:SharedAdminOK=try await api.value("/api/admin/games/"+game.id+"/metadata",method:"POST",token:token,body:["title":title])
       }
       let image=local?.cover.map{URL(fileURLWithPath:$0)} ?? known.flatMap{catalog.coverURL($0)}
       if let image,let cover=try? LibraryCoverPayload.thumbnail(at:image){let _:LibraryCoverPayload=try await api.value("/api/admin/games/"+game.id+"/cover",method:"POST",token:token,body:["data":cover.data])}
      }catch{
       metadataWarnings.append(selected.title+"：已共享，名称或封面待同步（"+SharedPublicationError.message(error)+"）")
       if SharedPublicationError.shouldStopBatch(error){metadataStopError=error}
      }
     }
     guard !self.quitting else{return}
     if !mappingConfirmed,report.failures.contains(where:{SharedPublicationError.isMappingFailure($0.error)}){
      self.rejectedSharedMappingGuesses.insert(connection.serverID+":"+remoteRoot.id)
      locations.removeAll{$0.serverID==connection.serverID && $0.rootID==remoteRoot.id};try? JSONEncoder().encode(locations).write(to:locationsFile,options:.atomic)
     }
     if report.failures.contains(where:{($0.error as? SharedRequestError)?.statusCode==401}) || (metadataStopError as? SharedRequestError)?.statusCode==401{self.clearSharedLogin(connection)}
     let remaining=selections.count-report.completed.count-report.failures.count
     let summary="已共享 \(published) 款游戏"+(report.failures.isEmpty ? "":"，\(report.failures.count) 款失败")+(remaining>0 ? "，\(remaining) 款未处理":"")
     let failures=report.failures.map{selections[$0.index].title+"："+SharedPublicationError.message($0.error)}
     let details=failures+metadataWarnings
     self.setBusy(false,"");finished(summary);self.sharedLibraryWindow?.reloadSharedGames()
     if !details.isEmpty{
      let alert=NSAlert();alert.messageText=summary;alert.informativeText=details.prefix(8).joined(separator:"\n")+(details.count>8 ? "\n另有 \(details.count-8) 项详情已保存在运行日志。":"");alert.addButton(withTitle:"好")
      let log=self.root.appendingPathComponent("Logs/Sharing");try? FileManager.default.createDirectory(at:log,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
      if let data=try? JSONSerialization.data(withJSONObject:["completed":report.completed.map{selections[$0].title},"failures":failures,"metadataWarnings":metadataWarnings],options:[.prettyPrinted,.sortedKeys]){try? data.write(to:log.appendingPathComponent("latest.json"),options:.atomic)}
      alert.runModal()
     }

    }catch{
     guard !self.quitting else{return};self.setBusy(false,"")
     let request=error as? SharedRequestError
     if !mappingConfirmed,let rootID=mappingRootID,SharedPublicationError.isMappingFailure(error){
      self.rejectedSharedMappingGuesses.insert(connection.serverID+":"+rootID)
      let file=self.root.appendingPathComponent("shared-scan-locations.json")
      if var locations=try? JSONDecoder().decode([SharedScanLocation].self,from:Data(contentsOf:file)){
       locations.removeAll{$0.serverID==connection.serverID && $0.rootID==rootID}
       try? JSONEncoder().encode(locations).write(to:file,options:.atomic)
      }
     }
     if request?.statusCode==401{self.clearSharedLogin(connection)}
     finished(SharedPublicationError.message(error))
    }
   }
  }catch{setBusy(false,"");finished(error.localizedDescription)}
 }
}
