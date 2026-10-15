// PinTop App 入口：主窗口 + 菜单栏快捷菜单（核心逻辑见 Core.swift）
import AppKit
import ApplicationServices

/// 菜单项动作的包装（NSMenuItem 通过 representedObject 持有）
final class Action: NSObject {
    let fn: () -> Void
    init(_ fn: @escaping () -> Void) { self.fn = fn }
}

@main
struct PinTopApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)     // Dock 图标 + 主窗口；菜单栏图标作为快捷入口
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var pins: [CGWindowID: Mirror] = [:]
    var pinInfo: [CGWindowID: (app: String, title: String, scope: String)] = [:]
    // 主窗口控件
    var mainWin: NSWindow?
    var axLabel = NSTextField(), scLabel = NSTextField()
    var winPopup = NSPopUpButton(), spacePopup = NSPopUpButton(), sidePopup = NSPopUpButton()
    var sizeField = NSTextField()
    // 并排布局：自定义位置和大小
    var layoutModePopup: ClosurePopup!
    var sideRow = NSStackView(), customRow = NSStackView()
    var layoutHint = NSTextField(labelWithString: "")
    var xField = NSTextField(), yField = NSTextField(), wField = NSTextField(), hField = NSTextField()
    let pinsStack = NSStackView()   // 正在悬浮区域：「（无）」文字 或 可拖动排序的表格
    let pinTable = NSTableView()    // 每个悬浮窗口一行，支持拖动排序
    let pinScroll = NSScrollView()
    var pinTableHeight: NSLayoutConstraint!
    let noneLabel = NSTextField(labelWithString: "（无）")
    let pinDragType = NSPasteboard.PasteboardType("com.raindaydream.pintop.pinrow")
    var mainStack = NSStackView()
    var lastFitHeight: CGFloat = 0     // 上一次按内容计算出的高度，用来判断用户有没有手动调过窗口高度
    var listedWins: [Win] = []
    var spaceChoices: [FloatScope] = []   // 范围下拉框的各项（当前桌面 / 所有桌面 / 每个具体桌面）
    var forceRaiseUntil = Date.distantPast     // 在此时间之前，主窗口强制保持在镜像之上
    var pinOrder: [CGWindowID] = []     // 悬浮堆叠顺序，下标 0 = 最顶层
    // 应用内更新
    let updater = Updater()
    let updateBanner = NSStackView()                       // 主窗口顶部的「发现新版本」横幅
    let bannerLabel = NSTextField(labelWithString: "")
    let bannerProgress = NSProgressIndicator()
    var bannerNotesBtn: ClosureButton!
    var bannerActionBtn: ClosureButton!
    let versionLabel = NSTextField(labelWithString: "")      // 底部：「PinTop 1.0.0」
    let updateStatusLabel = NSTextField(labelWithString: "")  // 底部：「已是最新版本」等
    var checkUpdateBtn: ClosureButton!
    var allowMulti = false          // 是否允许同时悬浮多个窗口
    var multiBox = NSButton()
    var multiHolder: ClosureButton?   // 持有复选框动作的目标（NSButton.target 为弱引用）

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinTop")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updater.onChange = { [weak self] in self?.refreshUpdateUI() }
        showMain()
        updater.startAutoChecking()      // 启动后检查一次，之后每 6 小时一次
    }

    // 再次点击应用图标（已在运行）时重新显示提示
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    // MARK: 菜单
    func item(_ title: String, enabled: Bool = true, _ fn: (() -> Void)? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: fn == nil ? nil : #selector(runAction(_:)), keyEquivalent: "")
        it.target = self
        if let fn = fn { it.representedObject = Action(fn) }
        it.isEnabled = enabled && (fn != nil)
        return it
    }

    @objc func runAction(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.fn() }

    func label(_ w: Win) -> String {
        let t = displayTitle(w)
        let short = t.count > 36 ? String(t.prefix(36)) + "…" : t
        return "\(w.app) — \(short)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if updater.updateAvailable, let l = updater.latest {
            let busy: Bool = { switch updater.state { case .downloading, .installing: return true; default: return false } }()
            let it = item(busy ? "正在更新到 V\(l.version)…" : "⬆︎ 发现新版本 V\(l.version) — 点击更新", enabled: !busy) { [weak self] in
                self?.showMain(); self?.updater.startUpdate()
            }
            menu.addItem(it)
            menu.addItem(.separator())
        }
        let wins = pinnableWindows()

        let floatCur = NSMenuItem(title: "镜像悬浮（当前桌面）", action: nil, keyEquivalent: "")
        let floatAll = NSMenuItem(title: "镜像悬浮（所有桌面）", action: nil, keyEquivalent: "")
        let floatSpace = NSMenuItem(title: "镜像悬浮（指定桌面）", action: nil, keyEquivalent: "")
        let subSpace = NSMenu()
        for sp in listSpaces() {
            let winMenu = NSMenu()
            for w in wins {
                winMenu.addItem(item(label(w)) { [weak self] in
                    self?.startFloat(w, scope: FloatScope(allSpaces: false, spaceID: sp.id, label: sp.label))
                })
            }
            if wins.isEmpty { winMenu.addItem(item("（没有可操作的窗口）", enabled: false)) }
            let si = NSMenuItem(title: sp.label + (sp.isCurrent ? "（当前）" : ""), action: nil, keyEquivalent: "")
            si.submenu = winMenu
            subSpace.addItem(si)
        }
        floatSpace.submenu = subSpace
        let dockItem = NSMenuItem(title: "并排布局", action: nil, keyEquivalent: "")
        let subCur = NSMenu(), subAll = NSMenu(), subDock = NSMenu()
        for w in wins {
            subCur.addItem(item(label(w)) { [weak self] in self?.startFloat(w, scope: .current) })
            subAll.addItem(item(label(w)) { [weak self] in self?.startFloat(w, scope: .all) })
            let presets = NSMenu()
            for (name, side, amt) in [("靠右 35%", Side.right, "35%"), ("靠右 50%", .right, "50%"),
                                      ("靠左 35%", .left, "35%"), ("靠左 50%", .left, "50%"),
                                      ("靠上 40%", .top, "40%"), ("靠下 40%", .bottom, "40%")] {
                presets.addItem(item(name) { [weak self] in self?.dock(w, side, amt) })
            }
            let wi = NSMenuItem(title: label(w), action: nil, keyEquivalent: "")
            wi.submenu = presets
            subDock.addItem(wi)
        }
        for (it, sub) in [(floatCur, subCur), (floatAll, subAll), (dockItem, subDock)] {
            if wins.isEmpty { sub.addItem(item("（没有可操作的窗口）", enabled: false)) }
            it.submenu = sub
            menu.addItem(it)
            if it === floatAll { menu.addItem(floatSpace) }
        }

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(item("正在悬浮", enabled: false))
            for id in pinOrder {
                let info = pinInfo[id]
                let name = "\(info?.app ?? "?") — \(info?.title ?? "")（\(info?.scope ?? "")）"
                menu.addItem(item("取消：\(name)") { [weak self] in self?.stopPin(id) })
            }
            menu.addItem(item("取消全部悬浮") { [weak self] in
                guard let self = self else { return }
                for id in Array(self.pins.keys) { self.stopPin(id) }
            })
        }

        menu.addItem(.separator())
        let multi = item("允许同时悬浮多个窗口") { [weak self] in
            self?.allowMulti.toggle(); self?.multiBox.state = (self?.allowMulti == true) ? .on : .off
        }
        multi.state = allowMulti ? .on : .off
        menu.addItem(multi)
        menu.addItem(item("恢复被摆放窗口的位置") { [weak self] in
            guard self?.checkAccessibility() == true else { return }
            self?.notify("PinTop", restore())
        })

        let perm = NSMenuItem(title: "权限设置", action: nil, keyEquivalent: "")
        let permSub = NSMenu()
        permSub.addItem(item("辅助功能\(hasAccessibility(prompt: false) ? " ✓" : " ✗（需要）")") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        })
        permSub.addItem(item("屏幕录制\(CGPreflightScreenCaptureAccess() ? " ✓" : " ✗（镜像悬浮需要）")") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        })
        perm.submenu = permSub
        menu.addItem(perm)

        menu.addItem(.separator())
        menu.addItem(item("检查更新…（当前版本 \(updater.currentVersion)）") { [weak self] in
            self?.showMain(); self?.updater.check(manual: true)
        })
        menu.addItem(item("退出 PinTop") { NSApp.terminate(nil) })
    }

    // MARK: 动作
    func notify(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: "好")
        a.runModal()
    }

    func checkAccessibility() -> Bool {
        if hasAccessibility(prompt: false) { return true }
        _ = hasAccessibility(prompt: true)
        notify("需要“辅助功能”权限", "请在 系统设置 → 隐私与安全性 → 辅助功能 中允许 PinTop，然后重新操作。")
        return false
    }

    func startFloat(_ w: Win, scope: FloatScope) {
        guard checkAccessibility() else { return }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            notify("需要“屏幕录制”权限", "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 PinTop，然后退出并重新打开 PinTop。")
            return
        }
        if allowMulti { stopPin(w.id) } else { for id in Array(pins.keys) { stopPin(id) } }   // 默认一次只悬浮一个
        let m = Mirror(target: w, allSpaces: scope.allSpaces, spaceID: scope.spaceID)
        m.onStop = { [weak self] reason in
            DispatchQueue.main.async {
                self?.forgetPin(w.id); self?.refreshMain()
                if !reason.hasPrefix("目标窗口已关闭") && !reason.hasPrefix("已取消") { self?.notify("悬浮已停止", reason) }
            }
        }
        pins[w.id] = m
        pinInfo[w.id] = (w.app, displayTitle(w), scope.label)
        pinOrder.removeAll { $0 == w.id }
        pinOrder.insert(w.id, at: 0)          // 新悬浮的默认放在最顶层
        applyPinOrder()
        m.begin()
    }

    /// 把每个悬浮窗口的堆叠层级按 pinOrder 设置（下标 0 = 最顶层）
    func applyPinOrder() {
        Mirror.ranks = Dictionary(uniqueKeysWithValues: pinOrder.enumerated().map { ($0.element, $0.offset) })
        for (i, id) in pinOrder.enumerated() { pins[id]?.setStacking(rankFromTop: i, of: pinOrder.count) }
        updateMainWindowLevel()
    }

    /// 主窗口的层级：只有鼠标停在它上面、且该位置被镜像盖着时，才抬到镜像之上（保证按钮点得到）；
    /// 否则保持普通层级，让调整悬浮顺序的效果立刻可见，不被 PinTop 自己的窗口挡住。
    func updateMainWindowLevel() {
        guard let w = mainWin, w.isVisible else { return }
        let mirrors = pins.values.filter { $0.panel.isVisible }.map { $0.panel.frame }
        let hover = shouldRaiseMainWindow(pointer: NSEvent.mouseLocation, mainFrame: w.frame, visibleMirrorFrames: mirrors)
        let forced = Date() < forceRaiseUntil      // 从 Dock/菜单栏唤起窗口后，先短暂抬高让它可见
        let want: NSWindow.Level = (hover || forced)
            ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2 * max(pinOrder.count, 1) + 2) : .normal
        if w.level != want { w.level = want }
    }

    /// 把某个悬浮窗口移到第 index 层（0 起，0 = 最顶层），其余顺次让位
    func movePin(_ id: CGWindowID, to index: Int) {
        guard pinOrder.contains(id) else { return }
        pinOrder.removeAll { $0 == id }
        pinOrder.insert(id, at: min(max(index, 0), pinOrder.count))
        applyPinOrder()
        refreshMain()
    }

    func forgetPin(_ id: CGWindowID) {
        pins[id] = nil; pinInfo[id] = nil
        pinOrder.removeAll { $0 == id }
        applyPinOrder()
    }

    func stopPin(_ id: CGWindowID) {
        pins[id]?.stop()
        forgetPin(id)
    }

    func dock(_ w: Win, _ side: Side, _ amount: String) {
        guard checkAccessibility() else { return }
        let r = applyDock(target: w, side: side, amount: amount, frame: nil, fit: [])
        if !r.ok { notify("摆放失败", r.messages.joined(separator: "\n")) }
        else if r.messages.count > 1 { notify("已摆放，但与设置不完全一致", r.messages.dropFirst().joined(separator: "\n")) }
    }

    /// 摆到自定义的位置和大小。x、y 相对屏幕可用区域（避开菜单栏和 Dock）的左上角。
    func dockFrame(_ w: Win, x: String, y: String, width: String, height: String) {
        guard checkAccessibility() else { return }
        // 先在这里校验，才能给出「哪一项填错了」的具体提示
        let area = usableArea(for: w.bounds)
        let parsed = parseCustomFrame(x: x, y: y, w: width, h: height, area: area)
        guard parsed.rect != nil else { notify("位置和大小有误", parsed.error ?? "无法解析"); return }
        let r = applyDock(target: w, side: nil, amount: "", frame: "\(x),\(y),\(width),\(height)", fit: [])
        if !r.ok { notify("摆放失败", r.messages.joined(separator: "\n")) }
        else if r.messages.count > 1 { notify("已摆放，但与设置不完全一致", r.messages.dropFirst().joined(separator: "\n")) }
    }

    /// 把选中窗口当前的位置和大小填进输入框（坐标相对屏幕可用区域左上角）
    func fillCurrentFrame() {
        guard let win = selectedWindow() else { return }
        let fresh = pinnableWindows().first { $0.id == win.id } ?? win
        let area = usableArea(for: fresh.bounds)
        xField.stringValue = String(Int((fresh.bounds.minX - area.minX).rounded()))
        yField.stringValue = String(Int((fresh.bounds.minY - area.minY).rounded()))
        wField.stringValue = String(Int(fresh.bounds.width.rounded()))
        hField.stringValue = String(Int(fresh.bounds.height.rounded()))
    }

    /// 切换并排布局的模式：0 = 靠屏幕一侧，1 = 自定义位置和大小
    func updateLayoutMode() {
        let custom = layoutModePopup.indexOfSelectedItem == 1
        sideRow.isHidden = custom
        customRow.isHidden = !custom
        layoutHint.isHidden = !custom
        if custom, xField.stringValue.isEmpty, yField.stringValue.isEmpty { fillCurrentFrame() }   // 第一次切换时先填入当前值，方便微调
        if let w = mainWin, w.contentView != nil { refreshMain() }
    }
}

// MARK: - 主窗口
final class ClosureButton: NSButton {
    var fn: (() -> Void)?
    convenience init(_ title: String, _ fn: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.fn = fn; self.target = self; self.action = #selector(fire)
        bezelStyle = .rounded
    }
    @objc func fire() { fn?() }
}

final class ClosurePopup: NSPopUpButton {
    var fn: ((Int) -> Void)?
    convenience init(items: [String], selected: Int, _ fn: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        for t in items { menu?.addItem(NSMenuItem(title: t, action: nil, keyEquivalent: "")) }   // 不用 addItem(withTitle:)，避免同名项被合并
        selectItem(at: selected)
        self.fn = fn; target = self; action = #selector(fire)
    }
    @objc func fire() { fn?(indexOfSelectedItem) }
}

extension AppDelegate {
    func showMain() {
        if mainWin == nil { buildMain() }
        refreshMain()
        NSApp.activate(ignoringOtherApps: true)
        forceRaiseUntil = Date().addingTimeInterval(2)      // 唤起后 2 秒内保证窗口在镜像之上可见
        mainWin?.makeKeyAndOrderFront(nil)
        updateMainWindowLevel()
    }

    func header(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t); l.font = .boldSystemFont(ofSize: 13); return l
    }
    /// 水平一行。`stretch` 指定哪一项随窗口宽度伸缩；`spacer` 为 true 时在末尾加弹性空白（所有控件保持原大小）。
    func row(_ views: [NSView], stretch: Int? = 0, spacer: Bool = false) -> NSStackView {
        var vs = views
        if spacer { vs.append(NSView()) }
        let r = NSStackView(views: vs)
        r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY; r.distribution = .fill
        let flex = spacer ? vs.count - 1 : (stretch ?? -1)
        for (i, v) in vs.enumerated() {
            // 伸缩项用最低优先级，明确由它吸收多余的宽度；其余控件保持原大小
            v.setContentHuggingPriority(i == flex ? NSLayoutConstraint.Priority(1) : .defaultHigh, for: .horizontal)
            v.setContentCompressionResistancePriority(i == flex ? NSLayoutConstraint.Priority(1) : .defaultHigh, for: .horizontal)
        }
        return r
    }

    /// 文字标签被拉宽后默认会靠右显示，统一改为左对齐（可编辑的输入框不动）
    func leftAlignLabels(_ v: NSView) {
        if let t = v as? NSTextField, !t.isEditable { t.alignment = .left }
        v.subviews.forEach(leftAlignLabels)
    }

    func buildMain() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "PinTop"
        w.isReleasedWhenClosed = false

        // 权限
        axLabel = NSTextField(labelWithString: ""); scLabel = NSTextField(labelWithString: "")
        let axBtn = ClosureButton("授权") { [weak self] in _ = self?.checkAccessibility() }
        let scBtn = ClosureButton("授权") {
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }

        // 选择窗口
        winPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        winPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let refresh = ClosureButton("刷新") { [weak self] in self?.refreshMain() }

        // 镜像悬浮
        spacePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        // 选项在 refreshMain 里按当前的桌面列表动态生成
        let floatBtn = ClosureButton("开始镜像悬浮") { [weak self] in
            guard let self = self, let win = self.selectedWindow() else { return }
            let i = self.spacePopup.selectedItem?.representedObject as? Int ?? 0
            self.startFloat(win, scope: i < self.spaceChoices.count ? self.spaceChoices[i] : .current)
            self.refreshMain()
        }

        // 并排布局：两种模式 —— 靠屏幕一侧 / 自定义位置和大小
        sidePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sidePopup.addItems(withTitles: ["靠右", "靠左", "靠上", "靠下"])
        sizeField = NSTextField(string: "35%"); sizeField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        sizeField.placeholderString = "35% 或 600"
        layoutModePopup = ClosurePopup(items: ["靠屏幕一侧（靠右/左/上/下 + 大小）", "自定义位置和大小（X、Y、宽、高）"], selected: 0) { [weak self] _ in
            DispatchQueue.main.async { self?.updateLayoutMode() }
        }
        func coordField(_ f: NSTextField, _ placeholder: String) -> NSTextField {
            f.placeholderString = placeholder; f.alignment = .left
            f.widthAnchor.constraint(equalToConstant: 62).isActive = true; return f
        }
        func tag(_ t: String) -> NSTextField { let l = NSTextField(labelWithString: t); l.textColor = .secondaryLabelColor; return l }
        let readBtn = ClosureButton("读取当前窗口") { [weak self] in self?.fillCurrentFrame() }
        readBtn.toolTip = "把选中窗口现在的位置和大小填进来，再改一改"
        sideRow = row([sidePopup, sizeField], spacer: true)
        customRow = row([tag("X"), coordField(xField, "0"), tag("Y"), coordField(yField, "0"),
                         tag("宽"), coordField(wField, "800"), tag("高"), coordField(hField, "600"), readBtn], spacer: true)
        layoutHint = NSTextField(wrappingLabelWithString: "X、Y 是窗口左上角相对屏幕可用区域（菜单栏下方、Dock 之外）左上角的位置；单位像素，也可写百分比，如 50%。")
        layoutHint.font = .systemFont(ofSize: 11); layoutHint.textColor = .secondaryLabelColor
        customRow.isHidden = true; layoutHint.isHidden = true      // 默认是“靠屏幕一侧”
        let dockBtn = ClosureButton("摆放") { [weak self] in
            guard let self = self, let win = self.selectedWindow() else { return }
            if self.layoutModePopup.indexOfSelectedItem == 1 {
                self.dockFrame(win, x: self.xField.stringValue, y: self.yField.stringValue,
                               width: self.wField.stringValue, height: self.hField.stringValue)
            } else {
                let side: Side = [Side.right, .left, .top, .bottom][self.sidePopup.indexOfSelectedItem]
                self.dock(win, side, self.sizeField.stringValue.trimmingCharacters(in: .whitespaces))
            }
            self.refreshMain()
        }
        let restoreBtn = ClosureButton("恢复原位置") { [weak self] in
            guard self?.checkAccessibility() == true else { return }
            self?.notify("PinTop", restore())
        }

        // 正在悬浮：每个窗口一行（见 refreshMain）
        pinsStack.orientation = .vertical; pinsStack.alignment = .leading; pinsStack.spacing = 4
        // 可拖动排序的列表：左侧「☰」手柄，上下拖动整行即可调整悬浮顺序
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pin")); col.resizingMask = .autoresizingMask
        pinTable.addTableColumn(col)
        pinTable.headerView = nil
        pinTable.rowHeight = 30; pinTable.intercellSpacing = NSSize(width: 0, height: 4)
        pinTable.backgroundColor = .clear; pinTable.style = .plain
        pinTable.selectionHighlightStyle = .none
        pinTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        pinTable.dataSource = self; pinTable.delegate = self
        pinTable.registerForDraggedTypes([pinDragType])
        pinTable.setDraggingSourceOperationMask(.move, forLocal: true)
        pinTable.draggingDestinationFeedbackStyle = .gap          // 拖动时在目标位置腾出空隙
        pinScroll.documentView = pinTable
        pinScroll.hasVerticalScroller = false; pinScroll.drawsBackground = false
        pinScroll.borderType = .noBorder; pinScroll.verticalScrollElasticity = .none
        pinScroll.translatesAutoresizingMaskIntoConstraints = false
        pinTableHeight = pinScroll.heightAnchor.constraint(equalToConstant: 0)
        pinTableHeight.isActive = true
        noneLabel.textColor = .secondaryLabelColor; noneLabel.alignment = .left
        pinsStack.addArrangedSubview(noneLabel)
        pinsStack.addArrangedSubview(pinScroll)
        pinScroll.leadingAnchor.constraint(equalTo: pinsStack.leadingAnchor).isActive = true
        pinScroll.trailingAnchor.constraint(equalTo: pinsStack.trailingAnchor).isActive = true
        let stopAll = ClosureButton("全部取消") { [weak self] in
            guard let self = self else { return }
            for id in Array(self.pins.keys) { self.stopPin(id) }
            self.refreshMain()
        }

        multiBox = NSButton(checkboxWithTitle: "允许同时悬浮多个窗口（可在上方设置层级顺序）", target: nil, action: nil)
        multiBox.state = allowMulti ? .on : .off
        let multiAct = ClosureButton("") { }
        multiBox.target = multiAct; multiBox.action = #selector(ClosureButton.fire)
        multiAct.fn = { [weak self] in self?.allowMulti = (self?.multiBox.state == .on) }
        multiHolder = multiAct

        // 并排布局是独立于“悬浮”的另一个功能：放在最下面，用分隔线隔开，避免和悬浮部分混淆
        let separator = NSBox(); separator.boxType = .separator
        let stack = NSStackView(views: [
            header("权限"), row([axLabel, axBtn]), row([scLabel, scBtn]),                         // 0-2
            header("1. 选择窗口"), row([winPopup, refresh]),                                       // 3-4
            header("2. 镜像悬浮（窗口始终显示在最上层）"), row([spacePopup, floatBtn]),              // 5-6
            header("正在悬浮（拖动 ☰ 调整顺序，从上到下 = 从顶层到底层）"), pinsStack, row([stopAll, multiBox], spacer: true),   // 7-9
            separator,                                                                             // 10
            header("并排布局（不是悬浮：调整上面选中窗口的位置和大小）"),                            // 11
            layoutModePopup,                                                                       // 12 模式
            sideRow, customRow, layoutHint,                                                        // 13-15 按模式显示其一
            row([dockBtn, restoreBtn], spacer: true),                                              // 16
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8   // 标题等文字靠左
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for i in [2, 4, 6, 9] { stack.setCustomSpacing(14, after: stack.views[i]) }

        // —— 应用内更新：顶部横幅（默认隐藏）+ 底部版本行 ——
        bannerLabel.lineBreakMode = .byTruncatingTail; bannerLabel.font = .systemFont(ofSize: 13, weight: .medium)
        bannerProgress.isIndeterminate = false; bannerProgress.minValue = 0; bannerProgress.maxValue = 1
        bannerProgress.controlSize = .small; bannerProgress.widthAnchor.constraint(equalToConstant: 90).isActive = true
        bannerNotesBtn = ClosureButton("更新内容") { [weak self] in
            if let u = self?.updater.latest?.pageURL { NSWorkspace.shared.open(u) }
        }
        bannerActionBtn = ClosureButton("立即更新") { [weak self] in self?.updater.startUpdate() }
        bannerActionBtn.bezelStyle = .rounded; bannerActionBtn.keyEquivalent = ""
        let bannerRow = row([bannerLabel, bannerProgress, bannerNotesBtn, bannerActionBtn], stretch: 0)
        updateBanner.orientation = .vertical; updateBanner.addArrangedSubview(bannerRow)
        updateBanner.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        updateBanner.wantsLayer = true
        updateBanner.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        updateBanner.layer?.cornerRadius = 8
        bannerRow.widthAnchor.constraint(equalTo: updateBanner.widthAnchor, constant: -24).isActive = true
        updateBanner.isHidden = true
        stack.insertArrangedSubview(updateBanner, at: 0)
        stack.setCustomSpacing(14, after: updateBanner)

        versionLabel.stringValue = "PinTop \(updater.currentVersion)"; versionLabel.textColor = .secondaryLabelColor
        updateStatusLabel.textColor = .secondaryLabelColor; updateStatusLabel.lineBreakMode = .byTruncatingTail
        checkUpdateBtn = ClosureButton("检查更新") { [weak self] in self?.updater.check(manual: true) }
        let versionRow = row([versionLabel, updateStatusLabel, checkUpdateBtn], stretch: 1)
        stack.addArrangedSubview(versionRow)
        stack.setCustomSpacing(16, after: stack.views[stack.views.count - 2])
        stack.setCustomSpacing(12, after: separator)
        pinsStack.alignment = .leading
        // 长标题在下拉框里截断，而不是撑宽窗口
        for p in [winPopup, spacePopup, sidePopup, layoutModePopup!] { p.cell?.lineBreakMode = .byTruncatingTail }
        mainStack = stack

        // 内容放进容器并贴住左右/上边：窗口变宽时内容跟着变宽
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // 整行控件（下拉框/按钮行/列表/提示文字）贴住左右边缘，随窗口宽度伸缩；文字标题保持靠左
        for v in stack.arrangedSubviews where v is NSStackView || v is NSBox || v === layoutHint || v === layoutModePopup {
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
        }
        leftAlignLabels(stack)
        w.contentView = container
        let fit = stack.fittingSize
        w.setContentSize(NSSize(width: 480, height: fit.height))
        lastFitHeight = fit.height
        w.contentMinSize = NSSize(width: 440, height: fit.height)
        w.center()
        w.setFrameAutosaveName("PinTopMainWindow")   // 记住上次的窗口大小和位置
        mainWin = w
        // 自定义模式的说明文字会自动换行：窗口宽度变化时同步换行宽度
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
            guard let self = self, let w = self.mainWin else { return }
            self.layoutHint.preferredMaxLayoutWidth = max(100, w.contentLayoutRect.width - 40)
            self.layoutHint.invalidateIntrinsicContentSize()
        }
        let levelTimer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.updateMainWindowLevel() }
        RunLoop.main.add(levelTimer, forMode: .common)

        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.refreshMain()
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshPermissions() }
    }

    func selectedWindow() -> Win? {
        // 按窗口ID查找，而不是按下拉框序号
        guard let id = winPopup.selectedItem?.representedObject as? UInt32,
              let w = listedWins.first(where: { $0.id == id }) else { notify("PinTop", "请先选择一个窗口"); return nil }
        return w
    }

    func refreshPermissions() {
        guard mainWin != nil else { return }
        axLabel.stringValue = "辅助功能（摆放/点击转发）：" + (hasAccessibility(prompt: false) ? "✓ 已授权" : "✗ 未授权")
        scLabel.stringValue = "屏幕录制（镜像悬浮）：" + (CGPreflightScreenCaptureAccess() ? "✓ 已授权" : "✗ 未授权")
    }

    /// 窗口高度：用户没手动调过高度时随内容增减；调过则只保证不小于内容所需的最小高度
    func adjustMainHeight() {
        if let w = mainWin {
            mainStack.layoutSubtreeIfNeeded()
            let needH = mainStack.fittingSize.height
            let curH = w.contentLayoutRect.height
            let followContent = abs(curH - lastFitHeight) < 2
            lastFitHeight = needH
            w.contentMinSize = NSSize(width: 440, height: needH)
            if followContent || curH < needH {
                let old = w.frame
                w.setContentSize(NSSize(width: w.contentLayoutRect.width, height: needH))
                var f = w.frame; f.origin.y = old.maxY - f.height    // 保持左上角不动
                w.setFrame(f, display: true)
            }
        }
    }

    /// 根据 updater 的状态刷新：主窗口横幅、底部版本行、菜单栏图标旁的「↑」、Dock 角标。
    func refreshUpdateUI() {
        let cur = updater.currentVersion
        let v = updater.latest.map { "V" + $0.version } ?? ""
        var showBanner = false, text = "", progress: Double? = nil, actionTitle: String? = nil, showNotes = false
        switch updater.state {
        case .available:
            showBanner = true; text = "发现新版本 \(v)（当前 \(cur)）"; actionTitle = "立即更新"; showNotes = true
        case .downloading(let p):
            showBanner = true; text = "正在下载 \(v)… \(Int(p * 100))%"; progress = p
        case .installing:
            showBanner = true; text = "正在安装 \(v)，完成后会自动重启…"
        case .failed(let msg):
            if updater.updateAvailable { showBanner = true; text = "更新失败：\(msg)"; actionTitle = "重试"; showNotes = true }
        default: break
        }
        updateBanner.isHidden = !showBanner
        bannerLabel.stringValue = text; bannerLabel.toolTip = text
        bannerProgress.isHidden = progress == nil
        if let p = progress { bannerProgress.doubleValue = p }
        bannerActionBtn.isHidden = actionTitle == nil
        if let t = actionTitle { bannerActionBtn.title = t }
        bannerNotesBtn.isHidden = !showNotes

        var status = ""
        var busy = false
        switch updater.state {
        case .checking: status = "正在检查更新…"; busy = true
        case .upToDate: status = "已是最新版本"
        case .available: status = "有新版本 \(v)"
        case .downloading, .installing: busy = true
        case .failed(let msg): if !updater.updateAvailable { status = "检查更新失败：\(msg)" }
        case .idle: break
        }
        updateStatusLabel.stringValue = status; updateStatusLabel.toolTip = status
        checkUpdateBtn.isEnabled = !busy

        // 菜单栏图标旁的「↑」和 Dock 角标：不打开主窗口也能感知到有新版本
        statusItem?.button?.title = updater.updateAvailable ? " ↑" : ""
        NSApp.dockTile.badgeLabel = updater.updateAvailable ? "新" : nil
        if mainWin != nil { adjustMainHeight() }
    }

    func refreshMain() {
        refreshPermissions()
        let keep = (winPopup.selectedItem?.representedObject as? UInt32)
        listedWins = pinnableWindows()
        winPopup.removeAllItems()
        for w in listedWins {
            // 不能用 addItem(withTitle:)：同名条目会被它合并删除，导致序号与窗口错位
            let it = NSMenuItem(title: label(w), action: nil, keyEquivalent: "")
            it.representedObject = w.id
            winPopup.menu?.addItem(it)
        }
        if let k = keep, let idx = listedWins.firstIndex(where: { $0.id == k }) { winPopup.selectItem(at: idx) }
        if listedWins.isEmpty { winPopup.addItem(withTitle: "（没有可操作的窗口）") }

        // 悬浮范围：当前桌面 / 所有桌面 / 识别到的每个桌面（桌面可能增减，所以每次刷新都重建）
        let keepLabel = spaceChoices.indices.contains(spacePopup.indexOfSelectedItem) ? spaceChoices[spacePopup.indexOfSelectedItem].label : nil
        spaceChoices = [.current, .all] + listSpaces().map {
            FloatScope(allSpaces: false, spaceID: $0.id, label: $0.label)
        }
        spacePopup.removeAllItems()
        for (i, sc) in spaceChoices.enumerated() {
            let sp = spaceChoices[i].spaceID.flatMap { id in listSpaces().first { $0.id == id } }
            let title = i == 0 ? "当前桌面" : i == 1 ? "所有桌面（含全屏桌面）" : "指定：\(sc.label)\(sp?.isCurrent == true ? "（当前）" : "")"
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.representedObject = i
            spacePopup.menu?.addItem(it)
        }
        if let k = keepLabel, let idx = spaceChoices.firstIndex(where: { $0.label == k }) { spacePopup.selectItem(at: idx) }

        // 正在悬浮：表格逐行显示（可拖动排序）；没有悬浮窗口时显示「（无）」
        let n = pinOrder.count
        noneLabel.isHidden = n > 0
        pinScroll.isHidden = n == 0
        pinTable.reloadData()
        pinTableHeight.constant = CGFloat(n) * (pinTable.rowHeight + pinTable.intercellSpacing.height)
        adjustMainHeight()
    }
}

// MARK: - 「正在悬浮」列表：数据源与拖动排序
extension AppDelegate: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { pinOrder.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rank: Int) -> NSView? {
        guard rank < pinOrder.count else { return nil }
        let id = pinOrder[rank]
        let info = pinInfo[id]
        let handle = NSTextField(labelWithString: "☰")
        handle.textColor = .tertiaryLabelColor
        handle.toolTip = pinOrder.count > 1 ? "按住上下拖动，调整悬浮顺序" : nil
        let name = NSTextField(labelWithString: "\(info?.app ?? "?") — \(info?.title ?? "")（\(info?.scope ?? "")）")
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .left
        // 层级下拉框：与拖动排序等价，第 1 层 = 最顶
        let n = pinOrder.count
        let items = (0..<n).map { k in "第 \(k + 1) 层" + (n > 1 && k == 0 ? "（最顶）" : n > 1 && k == n - 1 ? "（最底）" : "") }
        let order = ClosurePopup(items: items, selected: rank) { [weak self] k in
            // 延后一拍：不能在下拉框自己的动作回调里把它销毁重建（菜单追踪还没结束）
            DispatchQueue.main.async { self?.movePin(id, to: k) }
        }
        order.isEnabled = n > 1
        let cancel = ClosureButton("取消") { [weak self] in
            DispatchQueue.main.async { self?.stopPin(id); self?.refreshMain() }
        }
        return row([handle, name, order, cancel], stretch: 1)
    }

    // 开始拖动：把窗口ID放进剪贴板。只有一行时没有顺序可调，不允许拖动。
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard pinOrder.count > 1, row < pinOrder.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(pinOrder[row]), forType: pinDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === pinTable else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }     // 只允许“插到某行之前”
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: pinDragType), let id = UInt32(s),
              let from = pinOrder.firstIndex(of: id) else { return false }
        let to = dragDestinationIndex(from: from, insertionRow: row)
        // 延后一拍：拖放回调里不能立刻重建正在被拖动的表格
        DispatchQueue.main.async { [weak self] in self?.movePin(id, to: to) }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
