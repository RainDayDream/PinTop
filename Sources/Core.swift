// pintop — 并排布局工具 (macOS)
//
// 把某个窗口摆到屏幕的指定位置/大小（靠左/右/上/下 N%，或任意区域），
// 可选地把其他窗口放进剩余区域。摆放完成后程序即退出，不常驻、不抢焦点，
// 之后你可以像平时一样自由拖动/缩放窗口。原位置会被记录，可一键恢复。
//
// 只使用公开的 Accessibility / CoreGraphics API，不读取或修改窗口内容。
// Build: swiftc -O pintop.swift -o pintop
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia

// 唯一使用的非公开符号：把 AX 窗口映射到 CGWindowID（只读，Hammerspoon/yabai 等广泛使用）
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - 窗口
struct Win {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let bounds: CGRect   // 全局坐标，原点在左上（与 AX 一致）
}

func pinnableWindows() -> [Win] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return arr.compactMap { d in
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              let id = d[kCGWindowNumber as String] as? UInt32,
              let pid = d[kCGWindowOwnerPID as String] as? Int32, pid != getpid(),
              let b = d[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        guard r.width > 80, r.height > 50 else { return nil }
        return Win(id: id, pid: pid, app: d[kCGWindowOwnerName as String] as? String ?? "?",
                   title: d[kCGWindowName as String] as? String ?? "", bounds: r)
    }
}

func axWindow(_ w: Win) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &ref) == .success,
          let wins = ref as? [AXUIElement] else { return nil }
    return wins.first { el in
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(el, &wid) == .success && wid == w.id
    }
}

func displayTitle(_ w: Win) -> String {
    if !w.title.isEmpty { return w.title }
    if let ax = axWindow(w) {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &ref) == .success,
           let t = ref as? String, !t.isEmpty { return t }
    }
    return "(无标题)"
}

/// 设置窗口 frame。先缩放再移动再缩放，兼容有最小尺寸/跨屏的窗口。
@discardableResult
func setFrame(_ ax: AXUIElement, _ r: CGRect) -> Bool {
    var size = r.size, pos = r.origin
    guard let sv = AXValueCreate(.cgSize, &size), let pv = AXValueCreate(.cgPoint, &pos) else { return false }
    let a = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sv)
    let b = AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, pv)
    let c = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, sv)
    return a == .success && b == .success && c == .success
}

// MARK: - 屏幕区域
extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// 窗口所在屏幕的可用区域（避开菜单栏和 Dock），转换为左上原点坐标。
func usableArea(for window: CGRect) -> CGRect {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    func topLeft(_ vf: CGRect) -> CGRect { CGRect(x: vf.minX, y: primaryH - vf.maxY, width: vf.width, height: vf.height) }
    let areas = NSScreen.screens.map { topLeft($0.visibleFrame) }
    return areas.max { $0.intersection(window).area < $1.intersection(window).area } ?? areas.first ?? window
}

// MARK: - 布局参数
enum Side: String { case left, right, top, bottom }

/// "35%" → 占 total 的 35%；"600" → 600 像素
func parseLength(_ s: String, total: CGFloat) -> CGFloat? {
    if s.hasSuffix("%"), let v = Double(s.dropLast()) { return total * CGFloat(v) / 100 }
    if let v = Double(s) { return CGFloat(v) }
    return nil
}

/// 返回 (目标窗口区域, 剩余区域)
func split(_ area: CGRect, side: Side, amount: String) -> (CGRect, CGRect)? {
    let horizontal = (side == .left || side == .right)
    let total = horizontal ? area.width : area.height
    guard let len0 = parseLength(amount, total: total) else { return nil }
    let len = min(max(len0, 200), total - 200)
    switch side {
    case .left:   return (CGRect(x: area.minX, y: area.minY, width: len, height: area.height),
                          CGRect(x: area.minX + len, y: area.minY, width: area.width - len, height: area.height))
    case .right:  return (CGRect(x: area.maxX - len, y: area.minY, width: len, height: area.height),
                          CGRect(x: area.minX, y: area.minY, width: area.width - len, height: area.height))
    case .top:    return (CGRect(x: area.minX, y: area.minY, width: area.width, height: len),
                          CGRect(x: area.minX, y: area.minY + len, width: area.width, height: area.height - len))
    case .bottom: return (CGRect(x: area.minX, y: area.maxY - len, width: area.width, height: len),
                          CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - len))
    }
}

func parseFrame(_ s: String, area: CGRect) -> CGRect? {
    let p = s.split(separator: ",").map(String.init)
    guard p.count == 4,
          let x = parseLength(p[0], total: area.width), let y = parseLength(p[1], total: area.height),
          let w = parseLength(p[2], total: area.width), let h = parseLength(p[3], total: area.height) else { return nil }
    return CGRect(x: area.minX + x, y: area.minY + y, width: w, height: h)
}

// MARK: - 备份/恢复
struct Saved: Codable { let pid: Int32; let wid: UInt32; let x, y, w, h: Double }
let stateURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pintop_state.json")

func load() -> [Saved] {
    guard let d = try? Data(contentsOf: stateURL), let a = try? JSONDecoder().decode([Saved].self, from: d) else { return [] }
    return a
}

func save(_ items: [Saved]) {
    // 已有备份则保留最早的原始位置，避免多次 dock 后丢失最初位置
    var all = load()
    for it in items where !all.contains(where: { $0.wid == it.wid }) { all.append(it) }
    if let d = try? JSONEncoder().encode(all) { try? d.write(to: stateURL) }
}

func record(_ w: Win) -> Saved {
    Saved(pid: w.pid, wid: w.id, x: w.bounds.minX, y: w.bounds.minY, w: w.bounds.width, h: w.bounds.height)
}

func restore() -> String {
    let items = load()
    guard !items.isEmpty else { return "没有可恢复的记录" }
    let all = pinnableWindows()
    var ok = 0
    for it in items {
        guard let w = all.first(where: { $0.id == it.wid && $0.pid == it.pid }), let ax = axWindow(w) else { continue }
        if setFrame(ax, CGRect(x: it.x, y: it.y, width: it.w, height: it.h)) { ok += 1 }
    }
    try? FileManager.default.removeItem(at: stateURL)
    return "已恢复 \(ok)/\(items.count) 个窗口（已关闭的窗口会被跳过）"
}

// MARK: - 桌面（Space）
// 通过系统私有的只读接口读取桌面列表；只读取，不会移动或修改任何窗口/桌面。
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

struct SpaceInfo {
    let id: UInt64
    let label: String       // 如 “桌面 2”、“全屏：Safari”
    let isCurrent: Bool
}

/// 悬浮范围：当前桌面 / 所有桌面 / 某个具体桌面
struct FloatScope {
    var allSpaces = false
    var spaceID: UInt64? = nil
    var label = "当前桌面"
    static let current = FloatScope()
    static let all = FloatScope(allSpaces: true, spaceID: nil, label: "所有桌面")
}

private func displaySpaces() -> [[String: Any]] {
    (CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]]) ?? []
}

/// 每个显示器当前正在显示的桌面ID
func currentSpaceIDs() -> Set<UInt64> {
    Set(displaySpaces().compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? UInt64 })
}

/// 按 Mission Control 顺序列出所有桌面（含其他 App 的全屏桌面）
func listSpaces() -> [SpaceInfo] {
    let displays = displaySpaces()
    let current = currentSpaceIDs()
    var out: [SpaceInfo] = []
    for (di, d) in displays.enumerated() {
        let prefix = displays.count > 1 ? "显示器 \(di + 1) · " : ""
        var n = 0
        for s in (d["Spaces"] as? [[String: Any]] ?? []) {
            guard let id = s["ManagedSpaceID"] as? UInt64 else { continue }
            let type = s["type"] as? Int ?? 0
            let label: String
            if type == 4 {   // 其他 App 的全屏桌面
                let name = (s["pid"] as? Int32).flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "App"
                label = "\(prefix)全屏：\(name)"
            } else { n += 1; label = "\(prefix)桌面 \(n)" }
            out.append(SpaceInfo(id: id, label: label, isCurrent: current.contains(id)))
        }
    }
    return out
}

// MARK: - 镜像悬浮窗
final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class MirrorView: NSView {
    weak var owner: Mirror?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { owner?.forward(e, .leftMouseDown, .left) }
    override func mouseDragged(with e: NSEvent) { owner?.forward(e, .leftMouseDragged, .left) }
    override func mouseUp(with e: NSEvent) { owner?.forward(e, .leftMouseUp, .left) }
    override func rightMouseDown(with e: NSEvent) { owner?.forward(e, .rightMouseDown, .right) }
    override func rightMouseDragged(with e: NSEvent) { owner?.forward(e, .rightMouseDragged, .right) }
    override func rightMouseUp(with e: NSEvent) { owner?.forward(e, .rightMouseUp, .right) }
    override func scrollWheel(with e: NSEvent) { owner?.scroll(e) }
}

/// 悬浮窗口右上角的“取消悬浮”浮标
final class BadgeView: NSView {
    weak var owner: Mirror?
    let label = NSTextField(labelWithString: "✕ 取消悬浮")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        layer?.cornerRadius = 7
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = bounds.insetBy(dx: 4, dy: 2)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { owner?.finish("已取消悬浮") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor }
    override func mouseExited(with e: NSEvent) { layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor }
}

/// 目标窗口被盖住时，在最上层显示它的实时画面；点击时激活真窗口并转发鼠标操作。
final class Mirror: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 当前所有正在悬浮的窗口ID：多个悬浮窗口之间互不视为“盖住”对方，避免互相抢占
    static var pinned = Set<CGWindowID>()
    let target: Win
    let allSpaces: Bool
    let spaceID: UInt64?                // 指定桌面模式：镜像只出现在这个桌面
    var crossSpace: Bool { allSpaces || spaceID != nil }
    let panel: Panel
    let badge: Panel
    let badgeView = BadgeView(frame: NSRect(x: 0, y: 0, width: 82, height: 22))
    let view = MirrorView()
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    var stream: SCStream?
    var config = SCStreamConfiguration()
    var lastFrame = CGRect.zero
    var pressed = false
    var realOnScreen = true
    var fullscreenSpace = false      // 当前桌面是别的 App 的全屏桌面（真窗口在这里不可见）
    var live: Bool { realOnScreen && !fullscreenSpace }
    var candidate = CGRect.zero
    var lastBuffer: CVPixelBuffer?
    let debug = ProcessInfo.processInfo.environment["PINTOP_DEBUG"] != nil
    var onStop: ((String) -> Void)?   // 悬浮结束（窗口关闭/捕获失败）时回调，参数为原因
    var timer: Timer?
    var observer: NSObjectProtocol?
    var stopped = false

    init(target: Win, allSpaces: Bool, spaceID: UInt64? = nil) {
        self.target = target; self.allSpaces = allSpaces; self.spaceID = spaceID
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        badge = Panel(contentRect: NSRect(x: 0, y: 0, width: 82, height: 22), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = (allSpaces || spaceID != nil) ? .statusBar : .floating   // 全屏桌面里需要更高层级
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenAuxiliary]
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        view.owner = self
        panel.contentView = view
        // 取消浮标：比镜像面板高一层，始终可点
        badge.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        badge.isOpaque = false; badge.backgroundColor = .clear; badge.hasShadow = true
        badge.hidesOnDeactivate = false; badge.isReleasedWhenClosed = false
        badge.collectionBehavior = panel.collectionBehavior
        badgeView.owner = self
        badge.contentView = badgeView
        // 切换桌面后，重新应用桌面行为并强制重新显示（all 模式）
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.stopped else { return }
            if self.allSpaces {
                self.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                self.badge.collectionBehavior = self.panel.collectionBehavior
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.tick() }
        }
    }

    /// 开始捕获并跟踪目标窗口
    func begin() {
        Mirror.pinned.insert(target.id)
        Task { @MainActor in
            do { try await self.start() } catch { self.finish("启动失败：\(error.localizedDescription)") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// 停止悬浮并释放资源（不触发 onStop）
    func stop() {
        guard !stopped else { return }
        stopped = true
        Mirror.pinned.remove(target.id)
        timer?.invalidate(); timer = nil
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o); observer = nil }
        panel.orderOut(nil); panel.close()
        badge.orderOut(nil); badge.close()
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
    }

    func finish(_ reason: String) {
        guard !stopped else { return }
        stop(); onStop?(reason)
    }

    func configure(_ size: CGSize) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(1, Int(size.width * scale)); config.height = max(1, Int(size.height * scale))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.queueDepth = 4
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let sw = content.windows.first(where: { $0.windowID == target.id }) else {
            throw NSError(domain: "pintop", code: 1, userInfo: [NSLocalizedDescriptionKey: "屏幕捕获找不到该窗口"])
        }
        configure(target.bounds.size)
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: sw), configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pintop.capture"))
        try await s.startCapture()
        stream = s
    }

    // 画面帧 → 面板图层
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        // 真窗口不在当前桌面时系统给的是空白帧：冻结最后一帧有效画面，并持有其缓冲区避免被复用
        DispatchQueue.main.async {
            guard self.live else { return }
            self.lastBuffer = pb
            self.view.layer?.contents = surf
        }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.finish("屏幕捕获已停止：\(error.localizedDescription)") }
    }

    func nsFrame(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height) }

    func tick() {
        if stopped { return }
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard all.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == target.id }) else {
            finish("目标窗口已关闭"); return
        }
        let wins = pinnableWindows()
        var bounds = lastFrame
        var show: Bool
        // 全屏桌面检测：别的 App 的窗口恰好铺满整块屏幕（含菜单栏区域）
        let primH = primaryH
        fullscreenSpace = crossSpace && wins.contains { w in
            w.pid != target.pid && NSScreen.screens.contains { sc in
                abs(w.bounds.width - sc.frame.width) < 2 && abs(w.bounds.height - sc.frame.height) < 2
                && abs(w.bounds.minX - sc.frame.minX) < 2 && abs(w.bounds.minY - (primH - sc.frame.maxY)) < 2
            }
        }
        if let i = wins.firstIndex(where: { $0.id == target.id }) {
            realOnScreen = true; bounds = wins[i].bounds
            show = wins[..<i].contains { !Mirror.pinned.contains($0.id) && $0.bounds.width > 40 && $0.bounds.height > 40 && $0.bounds.intersects(bounds) }
        } else {
            realOnScreen = false; show = crossSpace       // 在其他桌面/已最小化
        }
        if fullscreenSpace { show = true }
        if pressed { show = true }                      // 拖动期间不能隐藏，否则会丢失鼠标抬起事件
        // 只采纳“稳定且在屏幕内”的位置：切换桌面时真窗口会随动画滑出屏幕，不能记成新位置
        let prev = candidate; candidate = bounds
        let screens = NSScreen.screens.map { NSRect(x: $0.frame.minX, y: primaryH - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        let onScreenArea = screens.reduce(CGFloat(0)) { $0 + $1.intersection(bounds).area }
        let onScreen = bounds.area > 0 && onScreenArea >= bounds.area * 0.9
        let accept = live && onScreen && (bounds == prev || pressed || lastFrame == .zero)
        if !accept { bounds = lastFrame }
        if bounds != lastFrame, bounds.width > 0 {
            let sizeChanged = bounds.size != lastFrame.size
            lastFrame = bounds
            panel.setFrame(nsFrame(bounds), display: true)
            if sizeChanged, let s = stream { configure(bounds.size); Task { try? await s.updateConfiguration(config) } }
        }
        // 指定桌面模式：只在目标桌面显示。不在目标桌面时绝不 orderFront（否则面板会落到当前桌面）
        if let target = spaceID, !currentSpaceIDs().contains(target) {
            if panel.isVisible && panel.isOnActiveSpace { panel.orderOut(nil) }
            if badge.isVisible && badge.isOnActiveSpace { badge.orderOut(nil) }
            return
        }
        // 取消浮标：窗口在屏幕上（真窗口或镜像可见）时显示在其右上角，随窗口移动
        if realOnScreen || show, lastFrame.width > 0 {
            let f = nsFrame(lastFrame)
            badge.setFrameOrigin(NSPoint(x: f.maxX - badge.frame.width - 10, y: f.maxY - badge.frame.height - 5))
            if !badge.isVisible || !badge.isOnActiveSpace { badge.orderFrontRegardless() }
        } else if badge.isVisible { badge.orderOut(nil) }
        if debug { print("tick show=\(show) realOnScreen=\(realOnScreen) visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) visibleOnScreen=\(panel.occlusionState.contains(.visible)) frame=\(panel.frame.integral) screen=\(panel.screen != nil) level=\(panel.level.rawValue) frontApp=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")") }
        if show {
            // 窗口可能已 orderFront 但不在当前桌面（isVisible 仍为 true），所以同时检查 isOnActiveSpace
            if !panel.isVisible || !panel.isOnActiveSpace { panel.orderFrontRegardless() }
        } else if panel.isVisible { panel.orderOut(nil) }
    }

    // MARK: 输入转发
    func activateTarget() {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: target.pid)?.activate()
    }

    func tag(_ ev: CGEvent) {
        ev.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(target.id))   // window under mouse
        ev.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(target.id))
    }

    func forward(_ e: NSEvent, _ t: CGEventType, _ b: CGMouseButton) {
        guard live else { return }                       // 真窗口在别的桌面/全屏桌面时，镜像只读，避免意外跳转桌面
        let loc = NSEvent.mouseLocation
        let pt = CGPoint(x: loc.x, y: primaryH - loc.y)
        let n = Int64(e.clickCount)
        let isDown = (t == .leftMouseDown || t == .rightMouseDown)
        if isDown { pressed = true; activateTarget(); panel.orderFrontRegardless() }   // 最近点击的镜像排在其他镜像之上
        if t == .leftMouseUp || t == .rightMouseUp { pressed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in     // 等激活生效；统一延迟保证事件顺序
            if isDown, let ax = axWindow(target) { AXUIElementPerformAction(ax, kAXRaiseAction as CFString) }
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: pt, mouseButton: b) else { return }
            ev.setIntegerValueField(.mouseEventClickState, value: n)
            tag(ev)
            ev.postToPid(target.pid)
        }
    }

    func scroll(_ e: NSEvent) {
        guard live else { return }
        let loc = NSEvent.mouseLocation
        let units: CGScrollEventUnit = e.hasPreciseScrollingDeltas ? .pixel : .line
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                               wheel1: Int32(e.scrollingDeltaY), wheel2: Int32(e.scrollingDeltaX), wheel3: 0) else { return }
        ev.location = CGPoint(x: loc.x, y: primaryH - loc.y)
        tag(ev)
        ev.postToPid(target.pid)
    }
}

// MARK: - 并排布局
/// 摆放窗口；返回 (是否成功, 提示信息)。不会终止进程。
func applyDock(target: Win, side: Side?, amount: String, frame: String?, fit: [Win]) -> (ok: Bool, messages: [String]) {
    let area = usableArea(for: target.bounds)
    var msgs: [String] = []
    let targetRect: CGRect
    var rest: CGRect? = nil
    if let f = frame {
        guard let r = parseFrame(f, area: area) else { return (false, ["--frame 格式应为 x,y,w,h（像素或百分比）"]) }
        targetRect = r
    } else {
        guard let s = side, let parts = split(area, side: s, amount: amount) else { return (false, ["无法解析位置/大小参数"]) }
        targetRect = parts.0; rest = parts.1
    }
    guard let ax = axWindow(target) else { return (false, ["无法访问该窗口（可能已关闭）"]) }
    save([record(target)] + fit.map(record))
    let ok = setFrame(ax, targetRect)
    msgs.append(ok ? "已摆放：\(target.app)" : "该窗口拒绝被调整大小/位置（例如全屏或固定大小的窗口）")
    if !fit.isEmpty {
        if let rest = rest {
            for w in fit {
                guard let a = axWindow(w) else { continue }
                msgs.append(setFrame(a, rest) ? "已放入剩余区域：\(w.app)" : "\(w.app) 拒绝被调整")
            }
        } else { msgs.append("--frame 模式下不支持 --fit") }
    }
    return (ok, msgs)
}

func hasAccessibility(prompt: Bool) -> Bool {
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
}
