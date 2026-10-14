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
    var pinInfo: [CGWindowID: (app: String, title: String, all: Bool)] = [:]
    // 主窗口控件
    var mainWin: NSWindow?
    var axLabel = NSTextField(), scLabel = NSTextField()
    var winPopup = NSPopUpButton(), spacePopup = NSPopUpButton(), sidePopup = NSPopUpButton(), pinPopup = NSPopUpButton()
    var sizeField = NSTextField()
    var listedWins: [Win] = []
    var allowMulti = false          // 是否允许同时悬浮多个窗口
    var multiBox = NSButton()
    var multiHolder: ClosureButton?   // 持有复选框动作的目标（NSButton.target 为弱引用）

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinTop")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        showMain()
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
        let wins = pinnableWindows()

        let floatCur = NSMenuItem(title: "镜像悬浮（当前桌面）", action: nil, keyEquivalent: "")
        let floatAll = NSMenuItem(title: "镜像悬浮（所有桌面）", action: nil, keyEquivalent: "")
        let dockItem = NSMenuItem(title: "并排布局", action: nil, keyEquivalent: "")
        let subCur = NSMenu(), subAll = NSMenu(), subDock = NSMenu()
        for w in wins {
            subCur.addItem(item(label(w)) { [weak self] in self?.startFloat(w, all: false) })
            subAll.addItem(item(label(w)) { [weak self] in self?.startFloat(w, all: true) })
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
        }

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(item("正在悬浮", enabled: false))
            for (id, _) in pins.sorted(by: { $0.key < $1.key }) {
                let info = pinInfo[id]
                let name = "\(info?.app ?? "?") — \(info?.title ?? "")（\(info?.all == true ? "所有桌面" : "当前桌面")）"
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

    func startFloat(_ w: Win, all: Bool) {
        guard checkAccessibility() else { return }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            notify("需要“屏幕录制”权限", "请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许 PinTop，然后退出并重新打开 PinTop。")
            return
        }
        if allowMulti { stopPin(w.id) } else { for id in Array(pins.keys) { stopPin(id) } }   // 默认一次只悬浮一个
        let m = Mirror(target: w, allSpaces: all)
        m.onStop = { [weak self] reason in
            DispatchQueue.main.async {
                self?.pins[w.id] = nil; self?.pinInfo[w.id] = nil; self?.refreshMain()
                if !reason.hasPrefix("目标窗口已关闭") && !reason.hasPrefix("已取消") { self?.notify("悬浮已停止", reason) }
            }
        }
        pins[w.id] = m
        pinInfo[w.id] = (w.app, displayTitle(w), all)
        m.begin()
    }

    func stopPin(_ id: CGWindowID) {
        pins[id]?.stop()
        pins[id] = nil; pinInfo[id] = nil
    }

    func dock(_ w: Win, _ side: Side, _ amount: String) {
        guard checkAccessibility() else { return }
        let r = applyDock(target: w, side: side, amount: amount, frame: nil, fit: [])
        if !r.ok { notify("摆放失败", r.messages.joined(separator: "\n")) }
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

extension AppDelegate {
    func showMain() {
        if mainWin == nil { buildMain() }
        refreshMain()
        NSApp.activate(ignoringOtherApps: true)
        mainWin?.makeKeyAndOrderFront(nil)
    }

    func header(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t); l.font = .boldSystemFont(ofSize: 13); return l
    }
    func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views); r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY; return r
    }

    func buildMain() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
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
        spacePopup.addItems(withTitles: ["当前桌面", "所有桌面（含全屏桌面）"])
        let floatBtn = ClosureButton("开始镜像悬浮") { [weak self] in
            guard let self = self, let win = self.selectedWindow() else { return }
            self.startFloat(win, all: self.spacePopup.indexOfSelectedItem == 1)
            self.refreshMain()
        }

        // 并排布局
        sidePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sidePopup.addItems(withTitles: ["靠右", "靠左", "靠上", "靠下"])
        sizeField = NSTextField(string: "35%"); sizeField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let dockBtn = ClosureButton("摆放") { [weak self] in
            guard let self = self, let win = self.selectedWindow() else { return }
            let side: Side = [Side.right, .left, .top, .bottom][self.sidePopup.indexOfSelectedItem]
            self.dock(win, side, self.sizeField.stringValue.trimmingCharacters(in: .whitespaces))
            self.refreshMain()
        }
        let restoreBtn = ClosureButton("恢复原位置") { [weak self] in
            guard self?.checkAccessibility() == true else { return }
            self?.notify("PinTop", restore())
        }

        // 正在悬浮
        pinPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        pinPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stopBtn = ClosureButton("取消所选") { [weak self] in
            guard let self = self, self.pinPopup.indexOfSelectedItem >= 0,
                  let id = self.pinPopup.selectedItem?.representedObject as? UInt32 else { return }
            self.stopPin(id); self.refreshMain()
        }
        let stopAll = ClosureButton("全部取消") { [weak self] in
            guard let self = self else { return }
            for id in Array(self.pins.keys) { self.stopPin(id) }
            self.refreshMain()
        }

        multiBox = NSButton(checkboxWithTitle: "允许同时悬浮多个窗口（最近点击的在最上层）", target: nil, action: nil)
        multiBox.state = allowMulti ? .on : .off
        let multiAct = ClosureButton("") { }
        multiBox.target = multiAct; multiBox.action = #selector(ClosureButton.fire)
        multiAct.fn = { [weak self] in self?.allowMulti = (self?.multiBox.state == .on) }
        multiHolder = multiAct

        let tip = NSTextField(wrappingLabelWithString:
            "提示：镜像悬浮时，被盖住的窗口会在最上层显示实时画面，点击它即可继续操作。也可点屏幕顶部菜单栏的图钉图标快速使用。")
        tip.font = .systemFont(ofSize: 11); tip.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            header("权限"), row([axLabel, axBtn]), row([scLabel, scBtn]),
            header("1. 选择窗口"), row([winPopup, refresh]),
            header("2. 镜像悬浮（窗口始终显示在最上层）"), row([spacePopup, floatBtn]),
            header("   或：并排布局（把窗口摆到屏幕一侧）"), row([sidePopup, sizeField, dockBtn, restoreBtn]),
            header("正在悬浮"), row([pinPopup, stopBtn, stopAll]), multiBox,
            tip,
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.setCustomSpacing(14, after: stack.views[2]); stack.setCustomSpacing(14, after: stack.views[4])
        stack.setCustomSpacing(14, after: stack.views[8])
        for v in [stack.views[1], stack.views[2], stack.views[4], stack.views[6], stack.views[8], stack.views[10]] {
            v.widthAnchor.constraint(equalToConstant: 440).isActive = true
        }
        tip.preferredMaxLayoutWidth = 440
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
        mainWin = w

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

        pinPopup.removeAllItems()
        for (id, _) in pins.sorted(by: { $0.key < $1.key }) {
            let info = pinInfo[id]
            let it = NSMenuItem(title: "\(info?.app ?? "?") — \(info?.title ?? "")（\(info?.all == true ? "所有桌面" : "当前桌面")）", action: nil, keyEquivalent: "")
            it.representedObject = id
            pinPopup.menu?.addItem(it)
        }
        if pins.isEmpty { pinPopup.addItem(withTitle: "（无）") }
    }
}
