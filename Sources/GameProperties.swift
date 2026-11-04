import AppKit

/// One retained, independent properties window per library ID. All writes start
/// with a fresh record; switching pages never keeps a mutable Game snapshot.
final class GamePropertiesController: NSWindowController, NSWindowDelegate {
 weak var app: App?
 let gameID: UUID
 private var selectedPage = 0
 private var navigation: [NSButton] = []
 private let form = NSStackView()
 private let scroll = NSScrollView()
 private var nameField: NSTextField?
 private var feedback: NSTextField?
 private var refreshTimer: Timer?
 private var lastState = ""

 init(app: App, gameID: UUID) {
  self.app = app
  self.gameID = gameID
  let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
  super.init(window: panel)
  panel.delegate = self
  panel.isReleasedWhenClosed = false
  panel.appearance = NSAppearance(named: .aqua)
  panel.minSize = NSSize(width: 720, height: 480)
  panel.center()
  buildLayout()
  refresh()
  // Existing cover/download/relocate flows do not expose completion callbacks.
  // Observe only in-memory state, never walk a game directory or NAS here.
  refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
   self?.refreshIfChanged()
  }
 }
 required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
 deinit { refreshTimer?.invalidate() }

 private var game: Game? { app?.store.games.first { $0.id == gameID } }
 private var running: Bool {
  guard let app else { return false }
  return app.nativeLaunching.contains(gameID) || app.active?.id == gameID || app.wineSessions.contains(gameID) || (app.nativeRunning[gameID]?.isRunning ?? false) || (app.nativeApplications[gameID].map{!$0.isTerminated} ?? false)
 }
 private var blocked: Bool {
  guard let app else { return true }
  return app.busy || app.window?.attachedSheet != nil
 }
 private func stateKey(_ game: Game) -> String {
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
  let record = (try? encoder.encode(game))?.base64EncodedString() ?? ""
  let groups = app?.store.collections.filter { $0.gameIDs.contains(gameID) }.map { $0.name }.joined(separator: "\n") ?? ""
  return record + groups + "\(blocked)|\(running)|\(app?.coverRequests.contains(gameID) ?? false)" + (selectedPage == 4 ? "|\(app?.playtime?.revision ?? 0)" : "")
 }
 private func refreshIfChanged() {
  guard let game else { close(); return }
  window?.title = game.title + " — 属性"
  if stateKey(game) != lastState {
   // Keep a typed display-name draft while asynchronous operations complete.
   let draft = nameField?.stringValue
   refresh()
   if let draft { nameField?.stringValue = draft }
  }
 }
 func windowDidBecomeKey(_ notification: Notification) { refreshIfChanged() }
 func windowWillClose(_ notification: Notification) {
  refreshTimer?.invalidate()
  refreshTimer = nil
  if app?.propertyWindows[gameID] === self { app?.propertyWindows.removeValue(forKey: gameID) }
 }

 private func buildLayout() {
  guard let root = window?.contentView else { return }
  root.wantsLayer = true
  root.layer?.backgroundColor = NSColor.white.cgColor
  let sidebar = NSView()
  sidebar.wantsLayer = true
  sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
  sidebar.translatesAutoresizingMaskIntoConstraints = false
  root.addSubview(sidebar)
  let items = NSStackView()
  items.orientation = .vertical
  items.alignment = .leading
  items.spacing = 6
  items.translatesAutoresizingMaskIntoConstraints = false
  sidebar.addSubview(items)
  let heading = text("游戏属性", size: 12, secondary: true)
  items.addArrangedSubview(heading)
  for (index, item) in [("通用", "slider.horizontal.3"), ("运行", "play.circle"), ("文件", "folder"), ("封面与分类", "photo.on.rectangle"), ("游玩记录", "clock")].enumerated() {
   let button = ActionButton(item.0) { [weak self] in
    self?.window?.makeFirstResponder(nil)
    self?.selectedPage = index
    self?.refresh()
   }
   button.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
   button.imagePosition = .imageLeading
   button.alignment = .left
   button.bezelStyle = .recessed
   button.setButtonType(.pushOnPushOff)
   button.widthAnchor.constraint(equalToConstant: 136).isActive = true
   button.heightAnchor.constraint(equalToConstant: 36).isActive = true
   items.addArrangedSubview(button)
   navigation.append(button)
  }
  scroll.translatesAutoresizingMaskIntoConstraints = false
  scroll.hasVerticalScroller = true
  scroll.autohidesScrollers = true
  scroll.drawsBackground = false
  root.addSubview(scroll)
  let document = FlippedView()
  document.translatesAutoresizingMaskIntoConstraints = false
  scroll.documentView = document
  form.orientation = .vertical
  form.alignment = .leading
  form.spacing = 16
  form.translatesAutoresizingMaskIntoConstraints = false
  document.addSubview(form)
  NSLayoutConstraint.activate([
   sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
   sidebar.topAnchor.constraint(equalTo: root.topAnchor),
   sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
   sidebar.widthAnchor.constraint(equalToConstant: 160),
   items.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
   items.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
   scroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
   scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
   scroll.topAnchor.constraint(equalTo: root.topAnchor),
   scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
   document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
   document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
   document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
   form.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
   form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
   form.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
   form.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
  ])
 }
 private func text(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
  let field = NSTextField(wrappingLabelWithString: value)
  field.font = .systemFont(ofSize: size)
  field.textColor = secondary ? .secondaryLabelColor : .labelColor
  field.isSelectable = true
  field.lineBreakMode = .byWordWrapping
  field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  return field
 }
 private func add(_ view: NSView, fullWidth: Bool = true) {
  form.addArrangedSubview(view)
  if fullWidth { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
 }
 private func section(_ title: String, value: String) {
  let label = text(title, size: 12, secondary: true)
  let value = text(value)
  let group = NSStackView(views: [label, value])
  group.orientation = .vertical
  group.alignment = .leading
  group.spacing = 5
  add(group)
  value.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
 }
 @discardableResult private func button(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSButton {
  let control = ActionButton(title, action)
  control.isEnabled = enabled
  add(control, fullWidth: false)
  return control
 }
 private func checkbox(_ title: String, on: Bool, action: @escaping (Bool) -> Void) {
  let control = ActionButton(title) {}
  control.setButtonType(.switch)
  control.state = on ? .on : .off
  control.isEnabled = !blocked
  control.actionBlock = { [weak control] in action(control?.state == .on) }
  add(control)
 }
 private func refresh() {
  guard let app, let game else { close(); return }
  window?.title = game.title + " — 属性"
  lastState = stateKey(game)
  nameField = nil
  feedback = nil
  for view in form.arrangedSubviews { form.removeArrangedSubview(view); view.removeFromSuperview() }
  for (index, button) in navigation.enumerated() { button.state = index == selectedPage ? .on : .off }
  let titles = ["通用", "运行", "文件", "封面与分类", "游玩记录"]
  let title = text(titles[selectedPage], size: 24)
  title.font = .systemFont(ofSize: 24, weight: .semibold)
  add(title)
  if blocked { add(text("正在处理游戏或文件选择，请完成后再修改属性。", secondary: true)) }
  switch selectedPage {
  case 0:
   add(text("显示名称", size: 12, secondary: true))
   let field = NSTextField(string: game.title)
   field.placeholderString = "输入游戏显示名称"
   field.setAccessibilityLabel("游戏显示名称")
   field.isEnabled = !blocked
   nameField = field
   add(field)
   add(text("只修改游戏库中的显示名称，不会重命名磁盘目录。支持 1–160 个字符，允许与其他游戏同名。", secondary: true))
   button("保存名称", enabled: !blocked) { [weak self] in self?.saveName() }
   let status = text("", secondary: true)
   feedback = status
   add(status)
   checkbox("收藏此游戏", on: game.favorite) { [weak self] value in self?.update { $0.favorite = value } }
   if let shared=game.shared {
    section("游戏来源",value:"共享游戏库")
    if let connection=try? SharedConnectionStore(root:app.root).connections.first(where:{$0.id==shared.connectionID}){section("服务器与账号",value:connection.name+" · "+connection.username)}
    add(text("游戏资源通过网络读取，存档与配置使用此账号的独立空间。",secondary:true))
   }
   let separator = NSBox(); separator.boxType = .separator; add(separator)
   add(text("从游戏库移除后，原游戏、本地副本、运行环境与存档均保留。", secondary: true))
   button("从游戏库移除…", enabled: !blocked) { [weak self] in self?.removeEntry() }
  case 1:
   let renpy = game.entry.backend == .renpy || (game.entry.backend == .wine && game.entry.engine == "Ren’Py")
   let nativeRenpy = renpy && app.nativeRenpyRoot(game) != nil
   let usesWine = ((game.entry.backend == .wine || game.entry.backend == .renpy) && !nativeRenpy) || (game.shared != nil && game.entry.backend == .rpgmz)
   let modes: [Backend: String] = [.wine: "Wine / Wineskin · 独立窗口", .native: "macOS · 独立窗口", .renpy: "原生 Ren’Py · 独立窗口", .web: "WebKit · 内嵌画面", .rpgmz: "原生 RPG Maker MZ · 内嵌画面"]
   section("运行方式", value: modes[usesWine ? .wine : (nativeRenpy ? .renpy : game.entry.backend)] ?? game.entry.backend.rawValue)
   section("引擎", value: game.entry.engine)
   section("启动入口", value: game.entry.path)
   button("查看运行日志", enabled: !blocked) { [weak self] in self?.perform { $0.showGameLogs($1) } }
   if let language=game.nativeLanguage{section("启动语言",value:"简体中文（"+language+"）")}
   if usesWine {
    section("此游戏的运行环境位置", value: app.runtimeDataRoot(for:game).appendingPathComponent("Runtimes/" + gameID.uuidString + ".app").path)
    section("Wine 环境来源", value: UserDefaults.standard.string(forKey: "WineSource") ?? Wrapper.defaultSource.path)
    add(text("以下设置在下次启动时生效。游戏运行时，请先在游戏内保存并退出，再更改设置。", secondary: true))
    if running { add(text("游戏仍在运行，请先退出游戏。", secondary: true)) }
    checkbox("使用 1280×720 虚拟桌面", on: game.windowSize != nil) { [weak self] value in
     self?.update(launchSetting: true) { $0.windowSize = value ? "1280x720" : nil }
    }
    checkbox("显示性能 HUD（帧率统计）", on: game.showPerformanceHUD == true) { [weak self] value in
     self?.update(launchSetting: true) { $0.showPerformanceHUD = value }
    }
   }
  case 2:
   section("原始位置（NAS 或导入目录）", value: game.originalFolder)
   section(game.entry.backend == .native ? "游戏资源位置":"当前运行位置", value: game.folder)
   if game.entry.backend == .native {
    section("本地原生运行库缓存", value: app.root.appendingPathComponent("NativeApps/"+gameID.uuidString+".app").path)
    add(text("已识别的 Ren’Py / Godot 只缓存程序和运行库，game / PCK 游戏资源通过链接读取原目录。", secondary:true))
   }
   let local = app.store.root.appendingPathComponent("Games").appendingPathComponent(gameID.uuidString).standardizedFileURL.path
   if game.shared == nil {
    section("本地副本位置", value: local)
    add(text(game.folder == local ? "当前使用本地副本。" : "当前引用游戏目录；下载会复制到本地并切换运行位置，保留原件。", secondary: true))
   }else{add(text("游戏在启动时挂载到此位置。大资源保留在服务器；个人写入由服务器独立保存。",secondary:true))}
   button("在 Finder 中显示当前目录") { [weak self] in
    guard let game = self?.game else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.folder)])
   }
   button("显示原始目录", enabled:game.shared==nil) { [weak self] in
    guard let game = self?.game else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.originalFolder)])
   }
   button("重新定位文件夹…", enabled: !blocked && game.shared==nil) { [weak self] in self?.perform(requireStopped: true) { $0.relocate($1) } }
   button("下载到本地…", enabled: !blocked && game.shared==nil && game.folder != local) { [weak self] in self?.perform(requireStopped: true) { $0.download($1) } }
  case 3:
   if let cover = game.cover, let image = NSImage(contentsOfFile: cover) {
    let preview = NSImageView(image: image)
    preview.imageScaling = .scaleProportionallyUpOrDown
    preview.setAccessibilityLabel("当前游戏封面")
    preview.heightAnchor.constraint(equalToConstant: 180).isActive = true
    add(preview)
   } else { add(text("尚未设置封面。", secondary: true)) }
   button("选择本地封面…", enabled: !blocked) { [weak self] in self?.perform { $0.chooseCover($1) } }
   let searching = app.coverRequests.contains(gameID)
   button(searching ? "正在联网查找封面…" : "联网查找封面…", enabled: !blocked && !searching) { [weak self] in self?.perform { $0.findCover($1, automatic: false) } }
   let groups = app.store.collections.filter { $0.gameIDs.contains(gameID) }.map { $0.name }
   section("所属分类", value: groups.isEmpty ? "未分类" : groups.joined(separator: "、"))
   button("管理分类…", enabled: !blocked) { [weak self] in self?.perform { $0.manageGameCollections($1) } }
  default:
   guard let history = app.playtime else {
    add(text("时长记录暂不可用。已有记录文件会保留，请检查应用数据目录。", secondary: true)); return
   }
   let since = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
   let summary = NSStackView()
   summary.orientation = .horizontal
   summary.distribution = .fillEqually
   summary.spacing = 14
   for (heading, seconds) in [("累计游玩", history.totalSeconds(gameID: gameID)), ("最近两周（约）", history.recentSeconds(gameID: gameID, since: since))] {
    let value = text(App.playtimeDuration(seconds), size: 21)
    value.font = .systemFont(ofSize: 21, weight: .semibold)
    let group = NSStackView(views: [text(heading, size: 12, secondary: true), value])
    group.orientation = .vertical; group.alignment = .leading; group.spacing = 10
    group.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
    group.wantsLayer = true; group.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor; group.layer?.cornerRadius = 10
    summary.addArrangedSubview(group)
   }
   add(summary)
   add(text("从启用此功能后开始记录。GameShelf 运行期间统计游戏会话，包含切到后台的时间；电脑睡眠时暂停。退出客户端后不继续计时。", size: 12, secondary: true))
   let records = history.records(gameID: gameID).sorted { $0.startedAt > $1.startedAt }
   let heading = text(records.isEmpty ? "还没有游玩记录" : "最近游玩", size: 16)
   heading.font = .systemFont(ofSize: 16, weight: .semibold); add(heading)
   let dates = DateFormatter(); dates.locale = Locale(identifier: "zh_CN"); dates.dateFormat = "yyyy年M月d日 HH:mm"
   let times = DateFormatter(); times.dateFormat = "HH:mm"
   for record in records.prefix(20) {
    let end = record.endedAt.map { times.string(from: $0) } ?? "运行中"
    section(dates.string(from: record.startedAt) + " — " + end,
            value: App.playtimeDuration(record.durationSeconds) + (record.interrupted ? " · 上次异常退出，已保留最近记录" : ""))
   }
   if records.isEmpty { add(text("从游戏库启动一次游戏后，时长和游玩记录会显示在这里。历史游玩时间不会自动补算。", secondary: true)) }
  }
 }
 private func report(_ error: Error) {
  guard let window else { return }
  let alert = NSAlert(error: error)
  alert.beginSheetModal(for: window)
 }
 private func saveName() {
  guard !blocked, let app, game != nil, let field = nameField else { return }
  let raw = field.stringValue
  let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !name.isEmpty, name.count <= 160 else {
   report(LibraryError("显示名称须为 1–160 个字符，不能包含控制字符。")); return
  }
  do {
   try app.store.renameGame(gameID, name: name)
   app.showLibrary()
   refresh()
   feedback?.stringValue = "显示名称已保存。"
  } catch { report(error) }
 }
 private func update(launchSetting: Bool = false, _ mutation: (inout Game) -> Void) {
  guard !blocked, let app, var current = game else { refresh(); return }
  if launchSetting && running {
   refresh()
   report(LibraryError("请先在游戏内保存并退出，再更改启动设置。")); return
  }
  do {
   mutation(&current)
   try app.store.update(current)
   app.showLibrary()
   let draft = nameField?.stringValue
   refresh()
   if let draft { nameField?.stringValue = draft }
  } catch { refresh(); report(error) }
 }
 private func perform(requireStopped: Bool = false, _ action: (App, Game) -> Void) {
  guard !blocked, let app, let current = game else { return }
  guard !requireStopped || !running else {
   report(LibraryError("请先在游戏内保存并退出，再操作游戏文件。")); return
  }
  action(app, current)
  refreshIfChanged()
 }
 private func removeEntry() {
  guard !blocked, let current = game, let window else { return }
  let alert = NSAlert()
  alert.messageText = "从游戏库移除「\(current.title)」？"
  alert.informativeText = "仅移除游戏库条目。原游戏文件、本地副本、运行环境及存档全部保留，不会删除磁盘目录。"
  alert.addButton(withTitle: "移除条目")
  alert.addButton(withTitle: "取消")
  alert.buttons.first?.hasDestructiveAction = true
  alert.beginSheetModal(for: window) { [weak self] answer in
   guard answer == .alertFirstButtonReturn, let self, let app = self.app, !self.blocked, self.game != nil else { return }
   do {
    try app.store.remove(self.gameID)
    if app.filter == "game:" + self.gameID.uuidString { app.filter = "all" }
    app.showLibrary()
    self.close()
   } catch { self.report(error) }
  }
 }
}

extension App {
 func presentProperties(_ game: Game) {
  if let existing = propertyWindows[game.id] {
   existing.showWindow(nil)
   existing.window?.makeKeyAndOrderFront(nil)
  } else {
   guard store.games.contains(where: { $0.id == game.id }) else { return }
   let controller = GamePropertiesController(app: self, gameID: game.id)
   propertyWindows[game.id] = controller
   controller.showWindow(nil)
   controller.window?.makeKeyAndOrderFront(nil)
  }
  NSApp.activate(ignoringOtherApps: true)
 }
}
