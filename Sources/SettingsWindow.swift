import AppKit
import UniformTypeIdentifiers

/// A retained settings window. Filesystem work is deliberately confined to
/// explicit background probes and validation of a user-selected destination.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
 private weak var app: App?
 private let form = NSStackView()
 private let scroll = NSScrollView()
 private var navigation: [SettingsActionButton] = []
 private var selectedPage = 0
 private var timer: Timer?
 private var closed = false
 private var changeButtons: [NSButton] = []
 private var restriction: NSTextField?
 private var libraryCount: NSTextField?
 private var observedPaths = ""
 private var volumeCache: [String: SettingsVolumeInfo] = [:]
 private var probing: Set<String> = []
 private var volumeViews: [String: [(NSTextField, NSProgressIndicator)]] = [:]
 private var volumeGeneration = 0
 private var validating = false
 private var validationID = UUID()
 private let probeQueue = DispatchQueue(label: "GameShelf.settings.volumes", qos: .utility, attributes: .concurrent)
 private let validationQueue = DispatchQueue(label: "GameShelf.settings.validation", qos: .userInitiated)
 private let titles = ["通用", "库与封面", "存储空间", "运行环境", "关于"]

 init(app: App) {
  self.app = app
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 650),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
  super.init(window: window)
  window.title = "GameShelf 设置"
  window.minSize = NSSize(width: 800, height: 540)
  window.contentMinSize = NSSize(width: 800, height: 540)
  window.appearance = NSAppearance(named: .aqua)
  window.isReleasedWhenClosed = false
  window.delegate = self
  buildLayout()
  observedPaths = pathSignature
  renderPage()
  // A scroll view has no intrinsic content height. Establish the viewport
  // after installing constraints so window fitting cannot collapse it.
  window.setContentSize(NSSize(width: 940, height: 650))
  window.center()
  timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshActivity() }
  if let timer { RunLoop.main.add(timer, forMode: .common) }
 }
 required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
 deinit { timer?.invalidate() }

 func windowWillClose(_ notification: Notification) {
  closed = true
  validationID = UUID()
  timer?.invalidate()
  timer = nil
  if let window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
  if app?.settingsWindow === self { app?.settingsWindow = nil }
 }
 func windowDidBecomeKey(_ notification: Notification) { refreshActivity() }

 private var activity: SettingsActivity {
  SettingsActivity(preparing: app?.busy ?? true,
                   wineSessions: app?.wineSessions.count ?? 0,
                   nativeProcesses: app?.nativeRunning.values.filter { $0.isRunning }.count ?? 0,
                   nativeApplications: app?.nativeApplications.values.filter { !$0.isTerminated }.count ?? 0,
                   pendingNative: app?.nativeLaunching.count ?? 0,
                   webActive: app?.active != nil,
                   pendingWeb: app?.pendingWebLaunch != nil)
 }
 private var pathSignature: String {
  [app?.root.path ?? "", app?.runtimeRoot.path ?? "", wineSource.path].joined(separator: "\n")
 }
 private var wineSource: URL {
  let configured=URL(fileURLWithPath: UserDefaults.standard.string(forKey: "WineSource") ?? Wrapper.defaultSource.path)
  if FileManager.default.fileExists(atPath:configured.appendingPathComponent("Contents/MacOS/wineskinlauncher").path) || Wrapper.isManagedSource(source:configured){return configured}
  if let app,let cached=ManagedWine.displaySource(root:app.root.appendingPathComponent("Engines")){return cached}
  return configured
 }
 private var mayChange: Bool { !closed && app != nil && app?.quitting == false && activity.canChangeLocations }
 private func refreshActivity() {
  guard !closed else { return }
  if observedPaths != pathSignature {
   observedPaths = pathSignature
   volumeCache.removeAll()
   volumeGeneration += 1
   renderPage()
  }
  let enabled = mayChange && !validating && window?.attachedSheet == nil
  changeButtons.forEach { $0.isEnabled = enabled }
  restriction?.stringValue = validating ? "正在验证所选位置…" : (activity.restrictionText ?? (app?.quitting == true ? "正在退出 GameShelf。" : "游戏运行或准备期间，位置与环境来源暂时不可更改。"))
  restriction?.isHidden = !validating && mayChange
  libraryCount?.stringValue = "\(app?.store.games.count ?? 0) 款游戏"
 }

 private func buildLayout() {
  guard let root = window?.contentView else { return }
  root.wantsLayer = true
  root.layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1).cgColor
  let sidebar = NSView()
  sidebar.wantsLayer = true
  sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.95, alpha: 1).cgColor
  sidebar.translatesAutoresizingMaskIntoConstraints = false
  root.addSubview(sidebar)
  let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 40, height: 40)))
  icon.imageScaling = .scaleProportionallyUpOrDown
  icon.widthAnchor.constraint(equalToConstant: 38).isActive = true
  icon.heightAnchor.constraint(equalToConstant: 38).isActive = true
  let brand = vertical([label("GameShelf", size: 17, weight: .semibold), label("设置", size: 11, secondary: true)], spacing: 2)
  let identity = NSStackView(views: [icon, brand])
  identity.spacing = 10
  identity.alignment = .centerY
  let items = vertical([identity], spacing: 5)
  items.setCustomSpacing(25, after: identity)
  items.translatesAutoresizingMaskIntoConstraints = false
  sidebar.addSubview(items)
  let symbols = ["slider.horizontal.3", "photo.on.rectangle", "internaldrive", "shippingbox", "info.circle"]
  for index in titles.indices {
   let button = SettingsActionButton(titles[index], padded: true) { [weak self] in
    guard let self else { return }
    self.window?.makeFirstResponder(nil)
    self.selectedPage = index
    self.renderPage()
    self.scroll.contentView.scroll(to: .zero)
    self.scroll.reflectScrolledClipView(self.scroll.contentView)
   }
   button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
   button.imagePosition = .imageLeading
   button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
   button.alignment = .left
   button.isBordered = false
   button.wantsLayer = true
   button.layer?.cornerRadius = 8
   button.heightAnchor.constraint(equalToConstant: 40).isActive = true
   items.addArrangedSubview(button)
   button.widthAnchor.constraint(equalTo: items.widthAnchor).isActive = true
   navigation.append(button)
  }
  let divider = NSBox()
  divider.boxType = .separator
  divider.translatesAutoresizingMaskIntoConstraints = false
  root.addSubview(divider)
  scroll.translatesAutoresizingMaskIntoConstraints = false
  scroll.hasVerticalScroller = true
  scroll.autohidesScrollers = true
  scroll.drawsBackground = false
  root.addSubview(scroll)
  let document = SettingsFlippedView()
  document.translatesAutoresizingMaskIntoConstraints = false
  scroll.documentView = document
  form.orientation = .vertical
  form.alignment = .leading
  form.spacing = 18
  form.translatesAutoresizingMaskIntoConstraints = false
  document.addSubview(form)
  NSLayoutConstraint.activate([
   root.widthAnchor.constraint(greaterThanOrEqualToConstant: 800),
   root.heightAnchor.constraint(greaterThanOrEqualToConstant: 540),
   sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor),
   sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 200),
   items.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
   items.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
   items.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 26),
   divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
   divider.topAnchor.constraint(equalTo: root.topAnchor), divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
   scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
   scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
   document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
   document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
   form.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 30),
   form.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -30),
   form.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
   form.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
  ])
 }

 private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
  let field = NSTextField(wrappingLabelWithString: text)
  field.font = .systemFont(ofSize: size, weight: weight)
  field.textColor = secondary ? .secondaryLabelColor : .labelColor
  field.isSelectable = true
  field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  return field
 }
 private func vertical(_ views: [NSView], spacing: CGFloat = 9) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = spacing
  for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
  return stack
 }
 private func add(_ view: NSView) {
  form.addArrangedSubview(view)
  view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
 }
 private func card(_ title: String, detail: String? = nil, views: [NSView] = []) {
  var contents: [NSView] = [label(title, size: 14, weight: .semibold)]
  contents.append(contentsOf: views)
  let stack = vertical(contents, spacing: 11)
  let box = NSView()
  box.toolTip = detail
  box.wantsLayer = true
  box.layer?.cornerRadius = 12
  box.layer?.backgroundColor = NSColor.white.cgColor
  box.layer?.borderColor = NSColor(calibratedWhite: 0.87, alpha: 1).cgColor
  box.layer?.borderWidth = 0.5
  stack.translatesAutoresizingMaskIntoConstraints = false
  box.addSubview(stack)
  NSLayoutConstraint.activate([
   stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
   stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
   stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
   stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -18)
  ])
  add(box)
 }
 private func button(_ title: String, changesLocation: Bool = false, action: @escaping () -> Void) -> NSButton {
  let button = SettingsActionButton(title, action: action)
  button.bezelStyle = .rounded
  button.controlSize = .regular
  button.setContentHuggingPriority(.required, for: .horizontal)
  if changesLocation { changeButtons.append(button) }
  return button
 }
 private func actions(_ views: [NSView]) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .horizontal
  stack.spacing = 10
  stack.alignment = .centerY
  stack.addArrangedSubview(NSView())
  return stack
 }
 private func path(_ url: URL) -> NSTextField {
  let field = label(url.path, size: 12, secondary: true)
  field.lineBreakMode = .byCharWrapping
  field.cell?.wraps = true
  field.cell?.isScrollable = false
  field.setAccessibilityLabel("文件位置：" + url.path)
  return field
 }
 private func finder(_ url: URL) -> NSButton {
  button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
 }
 private func renderPage() {
  guard !closed, let app else { return }
  changeButtons.removeAll()
  volumeViews.removeAll()
  restriction = nil
  libraryCount = nil
  for view in form.arrangedSubviews { form.removeArrangedSubview(view); view.removeFromSuperview() }
  for (index, button) in navigation.enumerated() {
   let selected = index == selectedPage
   button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor : NSColor.clear.cgColor
   button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
   button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
   button.setAccessibilityValue(selected ? "已选择" : "")
  }
  add(label(titles[selectedPage], size: 28, weight: .bold))
  if selectedPage == 2 || selectedPage == 3 {
   let notice = label("", size: 12, secondary: true)
   restriction = notice
   add(notice)
  }
  switch selectedPage {
  case 0:
   let count = label("\(app.store.games.count) 款游戏", size: 30, weight: .semibold)
   libraryCount = count
   card("我的游戏库", detail: "已加入 GameShelf 的游戏", views: [count])
   if let binding=(try? PersonalLibraryBindingStore(root:app.root))?.binding,
      let connection=(try? SharedConnectionStore(root:app.root))?.connections.first(where:{$0.serverID==binding.serverID && $0.accountID==binding.accountID}) {
    let name=connection.username+(connection.isAdministrator ? " · 管理员":"")
    card("个人账号",views:[label(name,size:16,weight:.medium),actions([button("管理账号"){[weak app] in app?.showSharedAccount(connectionID:connection.id)},button("同步资料"){[weak app] in app?.syncPersonalLibrary(force:true)}])])
   }
  case 1:
   let checkbox = SettingsActionButton("导入时自动联网匹配封面") {}
   checkbox.setButtonType(.switch)
   checkbox.state = UserDefaults.standard.object(forKey: "AutoOnlineCover") as? Bool == false ? .off : .on
   checkbox.actionBlock = { [weak self, weak checkbox] in
    guard self?.closed == false, let checkbox else { return }
    UserDefaults.standard.set(checkbox.state == .on, forKey: "AutoOnlineCover")
   }
   card("自动封面", detail: "仅使用游戏名称向 VNDB / Steam 查询封面，不上传游戏文件。更改后立即保存。", views: [checkbox])
   let covers = app.root.appendingPathComponent("Covers")
   card("封面文件", detail: "游戏库使用的封面保存在此处。", views: [path(covers), actions([finder(covers)])])
  case 2:
   storageCard("本地应用数据", detail: "游戏库记录、封面与下载到本地的游戏。", url: app.root, runtime: false)
   storageCard("运行环境与日志", detail: "独立运行环境、日志和使用此位置的托管存档。部分内嵌游戏的存档仍保存在本机。", url: app.runtimeRoot, runtime: true)
   let native = app.root.appendingPathComponent("NativeApps")
   card("本地原生运行库", detail: "运行程序与组件缓存在本机，游戏素材仍可从 NAS 读取。此目录不是完整离线副本，也不随运行数据位置切换。", views: [path(native), actions([finder(native)])])
   add(actions([button("刷新磁盘信息") { [weak self] in self?.refreshVolumes() }]))
  case 3:
   let source=wineSource
   let available=Wrapper.isManagedSource(source:source) || FileManager.default.fileExists(atPath:source.appendingPathComponent("Contents/MacOS/wineskinlauncher").path)
   var views:[NSView]=[label(available ? (Wrapper.isManagedSource(source:source) ? "已安装":"自定义环境"):"自动管理")]
   if available{views.append(path(source));views.append(actions([finder(source)]))}
   views.append(actions([button("选择已有环境…", changesLocation:true){[weak self] in self?.chooseWine()}]))
   card("Wine",views:views)
  default:
   let image = NSImageView(image: NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 64, height: 64)))
   image.imageScaling = .scaleProportionallyUpOrDown
   image.heightAnchor.constraint(equalToConstant: 64).isActive = true
   let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
   let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
   var versionText = version.map { "版本 " + $0 } ?? "版本信息未提供"
   if let build { versionText += "（构建 \(build)）" }
   card("GameShelf", detail: versionText, views: [image, label(versionText), label("macOS 15+", secondary: true), ActionButton("检查更新…"){[weak self] in self?.app?.checkForUpdates()}])
  }
  refreshActivity()
 }

 private func storageCard(_ title: String, detail: String, url: URL, runtime: Bool) {
  let status = label("正在读取磁盘信息…", size: 12, secondary: true)
  let progress = NSProgressIndicator()
  progress.style = .bar
  progress.isIndeterminate = false
  progress.minValue = 0
  progress.maxValue = 1
  progress.isHidden = true
  progress.setAccessibilityLabel("所在磁盘整体已用空间比例")
  volumeViews[url.path, default: []].append((status, progress))
  var controls: [NSView] = [finder(url)]
  if runtime { controls.append(button("更改位置…", changesLocation: true) { [weak self] in self?.chooseRuntime() }) }
  card(title, detail: detail, views: [path(url), status, progress, actions(controls)])
  if let info = volumeCache[url.path] { updateVolume(url.path, info: info) }
  else { probe(url) }
 }
 private func probe(_ url: URL) {
  let key = url.path
  guard !closed, !probing.contains(key) else { return }
  probing.insert(key)
  let generation = volumeGeneration
  // Capture the URL only: a disconnected volume must never retain this window.
  probeQueue.async { [weak self] in
   let result = SettingsStorageProbe.read(url)
   DispatchQueue.main.async { [weak self] in
    guard let self, !self.closed else { return }
    self.probing.remove(key)
    guard self.volumeGeneration == generation else {
     for (status, _) in self.volumeViews[key] ?? [] { status.stringValue = "位置已更改，请刷新磁盘信息。" }
     return
    }
    self.volumeCache[key] = result
    self.updateVolume(key, info: result)
   }
  }
 }
 private func updateVolume(_ key: String, info: SettingsVolumeInfo) {
  // Two cards can share one disk/path. Update both without starting another probe.
  guard selectedPage == 2 else { return }
  for (status, progress) in volumeViews[key] ?? [] {
   displayVolume(info, status: status, progress: progress)
  }
 }
 private func displayVolume(_ info: SettingsVolumeInfo, status: NSTextField, progress: NSProgressIndicator) {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  let name = info.name.isEmpty ? "所在磁盘" : info.name
  if let fraction = info.usedFraction, fraction.isFinite, let capacity = info.capacity, let available = info.available, info.isMounted {
   status.stringValue = "\(name) · 磁盘总容量 \(formatter.string(fromByteCount: capacity)) · 可用 \(formatter.string(fromByteCount: available))"
  } else { status.stringValue = "\(name) · \(info.statusText)" }
  if let fraction = info.usedFraction, fraction.isFinite, info.isMounted {
   progress.doubleValue = min(1, max(0, fraction))
   progress.isHidden = false
  } else { progress.isHidden = true }
 }
 private func refreshVolumes() {
  guard !closed else { return }
  // An explicit refresh never duplicates a probe that is still waiting on a volume.
  volumeCache.removeAll()
  renderPage()
 }

 private func guardChange() -> Bool {
  guard mayChange else {
   report(activity.restrictionText ?? "请先退出所有游戏并等待准备工作完成，再更改位置或运行环境。")
   return false
  }
  return true
 }
 private func report(_ message: String) {
  guard !closed, let window, window.attachedSheet == nil else { return }
  let alert = NSAlert()
  alert.messageText = "无法更改设置"
  alert.informativeText = message
  alert.addButton(withTitle: "好")
  alert.beginSheetModal(for: window)
 }
 private func chooseRuntime() {
  guard !validating, window?.attachedSheet == nil, guardChange(), let window else { return }
  let panel = NSOpenPanel()
  panel.title = "选择运行数据文件夹"
  panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
  panel.message = "只切换运行数据位置，不搬移旧环境、存档或日志。切换后可能使用不同的存档。"
  panel.prompt = "选择文件夹"
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.canCreateDirectories = true
  panel.allowsMultipleSelection = false
  panel.beginSheetModal(for: window) { [weak self] response in
   guard let self, !self.closed, response == .OK, let url = panel.url, self.guardChange() else { return }
   self.validate(url, wine: false) { [weak self] in self?.confirmRuntime(url) }
  }
  refreshActivity()
 }
 private func confirmRuntime(_ url: URL) {
  guard guardChange(), let window, window.attachedSheet == nil else { return }
  let alert = NSAlert()
  alert.messageText = "使用新的运行数据位置？"
  alert.informativeText = "新位置：\n\(url.path)\n\n已有环境、存档和日志保留在原位置，不会移动或删除。切换后可能使用不同的存档；如需继续使用旧存档，可切回原位置。"
  alert.addButton(withTitle: "使用此位置")
  alert.addButton(withTitle: "取消")
  alert.beginSheetModal(for: window) { [weak self] response in
   guard let self, !self.closed, response == .alertFirstButtonReturn, self.guardChange() else { return }
   UserDefaults.standard.set(url.path, forKey: "RuntimeDataRoot")
   self.refreshActivity()
  }
  refreshActivity()
 }
 private func chooseWine() {
  guard !validating, window?.attachedSheet == nil, guardChange(), let window else { return }
  let panel = NSOpenPanel()
  panel.title = "选择已有 Wineskin 应用"
  panel.directoryURL = wineSource.deletingLastPathComponent()
  panel.message = "选择本机已安装的 Wineskin .app。此操作不会安装引擎。"
  panel.prompt = "选择环境"
  panel.allowedContentTypes = [.applicationBundle]
  panel.canChooseFiles = true
  panel.canChooseDirectories = false
  panel.allowsMultipleSelection = false
  panel.beginSheetModal(for: window) { [weak self] response in
   guard let self, !self.closed, response == .OK, let url = panel.url, self.guardChange() else { return }
   self.validate(url, wine: true) { [weak self] in
    guard let self, self.guardChange() else { return }
    UserDefaults.standard.set(url.path, forKey: "WineSource")
    self.refreshActivity()
   }
  }
  refreshActivity()
 }
 private func validate(_ url: URL, wine: Bool, completion: @escaping () -> Void) {
  guard !closed, !validating else { return }
  validating = true
  let ticket = UUID()
  validationID = ticket
  refreshActivity()
  validationQueue.async { [weak self] in
   let fm = FileManager.default
   var directory: ObjCBool = false
   let valid: Bool
   if wine {
    let launcher = url.appendingPathComponent("Contents/MacOS/wineskinlauncher")
    valid = url.pathExtension.lowercased() == "app" && fm.fileExists(atPath: launcher.path, isDirectory: &directory) && !directory.boolValue
   } else {
    valid = url.isFileURL && fm.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue && fm.isWritableFile(atPath: url.path)
   }
   DispatchQueue.main.async { [weak self] in
    guard let self, !self.closed, self.validationID == ticket else { return }
    self.validating = false
    self.refreshActivity()
    guard self.guardChange() else { return }
    guard valid else {
     self.report(wine ? "所选应用不包含可识别的 Wineskin 启动器。请选择已有的 Wineskin .app。" : "所选文件夹不可用或不可写。请检查连接与访问权限。")
     return
    }
    completion()
   }
  }
 }
}

private final class SettingsFlippedView: NSView {
 override var isFlipped: Bool { true }
}
private final class SettingsActionButton: NSButton {
 var actionBlock: () -> Void
 init(_ title: String, padded: Bool = false, action: @escaping () -> Void) {
  actionBlock = action
  super.init(frame: .zero)
  if padded { cell = SettingsNavigationButtonCell(textCell: title) }
  self.title = title
  target = self
  self.action = #selector(invoke)
 }
 required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
 @objc private func invoke() { actionBlock() }
}

/// Insets only navigation artwork/text; the selected layer keeps its full bounds.
private final class SettingsNavigationButtonCell: NSButtonCell {
 override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
  super.drawInterior(withFrame: cellFrame.insetBy(dx: 12, dy: 0), in: controlView)
 }
}
