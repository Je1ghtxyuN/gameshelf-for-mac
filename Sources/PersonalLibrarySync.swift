import AppKit

extension App {
 func bindPersonalLibrary(to connection:SharedConnection){
  guard !personalSyncing else{showStatus("个人游戏库正在同步，请稍后再试。");return}
  do{_ = try PersonalLibraryBindingStore(root:root).bind(to:connection);syncPersonalLibrary(force:true)}catch{errorAlert(error)}
 }
 func syncPersonalLibrary(force:Bool=false){
  guard !quitting,!personalSyncing else{return}
  do{
   let bindingStore=try PersonalLibraryBindingStore(root:root)
   guard let identity=bindingStore.binding else{return}
   let connections=try SharedConnectionStore(root:root)
   guard let connection=connections.connections.first(where:{$0.id==identity.connectionID && $0.serverID==identity.serverID && $0.accountID==identity.accountID}) else{return}
   guard let token=sharedAccessTokens[connection.id] else{if force{showStatus("请登录已绑定的个人账号后同步。")};return}
   let snapshot=try PersonalLibrarySnapshot.make(games:store.games,collections:store.collections,serverID:identity.serverID,accountID:identity.accountID,playtime:{self.playtime?.totalSeconds(gameID:$0) ?? 0})
   let fingerprint=try snapshot.fingerprint(),coverPaths=Dictionary(uniqueKeysWithValues:store.games.filter{game in snapshot.games.contains{$0.id==game.id}}.compactMap{game in game.cover.map{(game.id,$0)}})
   let api=try SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256),profileRoot=root
   personalSyncing=true
   if force{showStatus("正在绑定个人游戏库…")}
   Task.detached(priority:.utility){
    do{
     let path="/api/personal-library/"+identity.deviceID.uuidString
     var revision=identity.revision
     if identity.fingerprint != fingerprint || force {
      let body=try JSONSerialization.jsonObject(with:snapshot.encoded()) as! [String:Any]
      let document:PersonalLibraryDocument
      do{document=try await api.value(path,method:"POST",token:token,body:["expectedRevision":identity.revision,"snapshot":body])}
      catch let error as SharedRequestError where error.statusCode==409 {
       let existing:PersonalLibraryDocument=try await api.value(path,token:token)
       guard existing.deviceID==identity.deviceID,try existing.snapshot.fingerprint()==fingerprint else{throw LibraryError("服务器个人资料已有其他修改，本机资料已保留，未覆盖。")}
       document=existing
      }
      guard document.deviceID==identity.deviceID,document.revision>=identity.revision,try document.snapshot.fingerprint()==fingerprint else{throw LibraryError("个人资料同步返回的身份或内容不匹配。")}
      revision=document.revision
     }
     let gameIDs=Set(snapshot.games.map{$0.id.uuidString})
     var coverHashes=identity.coverHashes.filter{gameIDs.contains($0.key)}
     // Commit the metadata ACK before independent thumbnail work. Otherwise a
     // failed image followed by a playtime change strands the old revision.
     let metadataState=try PersonalLibraryBindingStore(root:profileRoot)
     try metadataState.acknowledge(identity:identity,revision:revision,fingerprint:fingerprint,coverHashes:coverHashes)
     guard var acknowledged=metadataState.binding else{throw LibraryError("个人账号绑定已更改。")}
     var coverFailures=0
     for (id,pathValue) in coverPaths {
      do{
       let payload=try LibraryCoverPayload.thumbnail(at:URL(fileURLWithPath:pathValue))
       guard let digest=payload.sha256 else{continue}
       if coverHashes[id.uuidString]==digest{continue}
       let response:LibraryCoverPayload=try await api.value(path+"/covers/"+id.uuidString,method:"POST",token:token,body:["data":payload.data])
       _ = try response.checkedBytes(expectedHash:digest);coverHashes[id.uuidString]=digest
       let coverState=try PersonalLibraryBindingStore(root:profileRoot)
       try coverState.acknowledge(identity:acknowledged,revision:revision,fingerprint:fingerprint,coverHashes:coverHashes)
       if let saved=coverState.binding{acknowledged=saved}
      }catch{coverFailures+=1}
     }
     if coverFailures>0{throw LibraryError("资料已同步，\(coverFailures) 张封面将在连接恢复后重试。")}
     await MainActor.run{
      self.personalSyncing=false
      if force && !self.quitting{self.showStatus("个人游戏库已绑定到 "+connection.username+"，已同步 \(snapshot.games.count) 款游戏资料。")}
     }
    }catch{await MainActor.run{self.personalSyncing=false;if !self.quitting{self.showStatus("个人资料尚未同步："+error.localizedDescription)}}}
   }
  }catch{if force{errorAlert(error)}}
 }
 func fetchSharedDefaultCover(_ remote:SharedCatalogGame,connection:SharedConnection,game:Game){
  guard let digest=remote.coverSHA256,digest.count==64,digest.allSatisfy({"0123456789abcdef".contains($0)}),remote.id.count==32,remote.id.allSatisfy({"0123456789abcdef".contains($0)}),game.cover==nil || game.coverOrigin=="shared-default" || game.coverOrigin=="catalog",!coverRequests.contains(game.id) else{return}
  if game.coverOrigin=="shared-default",game.defaultCoverSHA256==digest,game.cover.map({FileManager.default.fileExists(atPath:$0)})==true{return}
  do{
   guard let token=try sharedToken(for:connection) else{return}
   let client=try SharedAPI(address:connection.address,certificateSHA256:connection.certificateSHA256),destination=root.appendingPathComponent("Covers/"+game.id.uuidString+"-shared-default.jpg")
   coverRequests.insert(game.id)
   Task.detached(priority:.utility){
    do{
     let payload:LibraryCoverPayload=try await client.value("/api/games/"+remote.id+"/cover",token:token)
     let bytes=try payload.checkedBytes(expectedHash:digest)
     try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
     try bytes.write(to:destination,options:[.atomic])
     await MainActor.run{
      defer{self.coverRequests.remove(game.id)}
      guard !self.quitting,var current=self.store.games.first(where:{$0.id==game.id}),current.cover==game.cover,current.coverOrigin==game.coverOrigin else{return}
      current.cover=destination.path;current.coverOrigin="shared-default";current.defaultCoverSHA256=digest
      do{try self.store.update(current);self.renderCards()}catch{self.showStatus("封面暂未更新。")}
     }
    }catch{await MainActor.run{_ = self.coverRequests.remove(game.id)}}
   }
  }catch{}
 }
}
