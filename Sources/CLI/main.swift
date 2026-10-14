// pintop 命令行入口（核心逻辑见 Core.swift）
import AppKit
import ApplicationServices
import ScreenCaptureKit

func ensureAccessibility() {
    if !hasAccessibility(prompt: true) {
        print("需要“辅助功能”权限：系统设置 → 隐私与安全性 → 辅助功能 → 允许当前终端 App，然后重新运行。")
        exit(1)
    }
}

func floatCmd(_ t: Win, scope: FloatScope) -> Never {
    ensureAccessibility()
    if !CGPreflightScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
        print("需要“屏幕录制”权限：系统设置 → 隐私与安全性 → 屏幕录制 → 允许当前终端 App，然后重启终端并重新运行。")
        exit(1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)                  // 无 Dock 图标
    let m = Mirror(target: t, allSpaces: scope.allSpaces, spaceID: scope.spaceID)
    m.onStop = { reason in print(reason); exit(reason.hasPrefix("目标窗口已关闭") || reason.hasPrefix("已取消") ? 0 : 1) }
    m.begin()
    signal(SIGINT) { _ in print("\n已取消悬浮。"); exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    print("悬浮中：\(t.app) — \(displayTitle(t))  模式：\(scope.label)。按 Ctrl+C 退出。")
    app.run()
    exit(0)
}

func dock(target: Win, side: Side?, amount: String, frame: String?, fit: [Win]) {
    ensureAccessibility()
    let r = applyDock(target: target, side: side, amount: amount, frame: frame, fit: fit)
    r.messages.forEach { print($0) }
    if !r.ok { exit(1) }
    print("完成。可自由拖动/缩放；运行 ./pintop restore 恢复原位置。")
}

func usage() {
    print("""
    pintop — 并排布局：把窗口摆到屏幕指定位置/大小（摆完即退出，不常驻）

      pintop                                   交互式
      pintop list                              列出窗口ID
      pintop float <ID> [--all]                镜像悬浮：被盖住时在最上层显示实时画面（--all=所有桌面）
      pintop spaces                            列出所有桌面（含全屏桌面）
      pintop float <ID> --space N              镜像悬浮，只出现在第 N 个桌面（序号见 spaces）
      pintop dock <ID> --right 35%             靠右，占 35% 宽（还可用 --left/--top/--bottom，也可写像素如 600）
      pintop dock <ID> --frame x,y,w,h         任意区域（像素或百分比，相对可用屏幕区域）
      pintop dock <ID> --right 35% --fit <ID2>[,<ID3>]   同时把其他窗口放进剩余区域（会改变它们的大小）
      pintop restore                           恢复之前被移动的窗口
    """)
}

func interactive() {
    let wins = pinnableWindows()
    guard !wins.isEmpty else { print("没有可操作的窗口"); exit(1) }
    ensureAccessibility()
    for (i, w) in wins.enumerated() { print("[\(i + 1)] \(w.app) — \(displayTitle(w))") }
    print("要摆放的窗口编号: ", terminator: "")
    guard let s = readLine(), let n = Int(s), (1...wins.count).contains(n) else { print("无效输入"); exit(1) }
    let t = wins[n - 1]
    print("模式 [1]镜像悬浮(当前桌面) [2]镜像悬浮(所有桌面) [3]镜像悬浮(指定桌面) [4]并排布局 (默认1): ", terminator: "")
    let mode = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    if mode == "3" {
        let spaces = listSpaces()
        for (i, s) in spaces.enumerated() { print("  [\(i + 1)] \(s.label)\(s.isCurrent ? "  ← 当前" : "")") }
        print("桌面编号: ", terminator: "")
        guard let s = readLine(), let n = Int(s), (1...max(spaces.count, 1)).contains(n), !spaces.isEmpty else { print("无效输入"); exit(1) }
        floatCmd(t, scope: FloatScope(allSpaces: false, spaceID: spaces[n - 1].id, label: spaces[n - 1].label))
    }
    if mode != "4" { floatCmd(t, scope: mode == "2" ? .all : .current) }
    print("位置 [1]靠右 [2]靠左 [3]靠上 [4]靠下 (默认1): ", terminator: "")
    let side: Side = ["2": .left, "3": .top, "4": .bottom][readLine()?.trimmingCharacters(in: .whitespaces) ?? ""] ?? .right
    print("大小（如 35% 或 600，默认 35%）: ", terminator: "")
    var amount = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    if amount.isEmpty { amount = "35%" }
    print("同时把哪些窗口放进剩余区域？输入编号，逗号分隔，回车跳过（会改变它们的大小）: ", terminator: "")
    let fit = (readLine() ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        .filter { (1...wins.count).contains($0) && wins[$0 - 1].id != t.id }.map { wins[$0 - 1] }
    dock(target: t, side: side, amount: amount, frame: nil, fit: fit)
}

// MARK: - main
let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

switch args.first {
case nil: interactive()
case "list":
    for w in pinnableWindows() { print(String(format: "%8d  %@ — %@", w.id, w.app, displayTitle(w))) }
case "float":
    guard args.count >= 2, let id = UInt32(args[1]), let t = pinnableWindows().first(where: { $0.id == id }) else {
        print("找不到该窗口ID，请先 ./pintop list"); exit(1)
    }
    var scope = args.contains("--all") ? FloatScope.all : FloatScope.current
    if let v = opt("--space") {
        let spaces = listSpaces()
        guard let n = Int(v), (1...max(spaces.count, 1)).contains(n), !spaces.isEmpty else {
            print("桌面序号无效，请先 ./pintop spaces 查看"); exit(1)
        }
        scope = FloatScope(allSpaces: false, spaceID: spaces[n - 1].id, label: spaces[n - 1].label)
    }
    floatCmd(t, scope: scope)
case "spaces":
    for (i, s) in listSpaces().enumerated() { print("[\(i + 1)] \(s.label)\(s.isCurrent ? "  ← 当前" : "")") }
case "restore": ensureAccessibility(); print(restore())
case "dock":
    let wins = pinnableWindows()
    guard args.count >= 2, let id = UInt32(args[1]), let t = wins.first(where: { $0.id == id }) else {
        print("找不到该窗口ID，请先 ./pintop list"); exit(1)
    }
    var side: Side? = nil, amount = ""
    for s in [Side.left, .right, .top, .bottom] { if let v = opt("--\(s.rawValue)") { side = s; amount = v } }
    let frame = opt("--frame")
    guard side != nil || frame != nil else { usage(); exit(1) }
    let fit = (opt("--fit") ?? "").split(separator: ",").compactMap { UInt32($0) }
        .compactMap { i in wins.first { $0.id == i && $0.id != t.id } }
    dock(target: t, side: side, amount: amount, frame: frame, fit: fit)
default: usage()
}
