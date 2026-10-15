// 生成 PinTop 的应用图标：一个窗口压在另一个窗口上面，并用图钉钉住。
// 用法：swiftc -O Resources/make_icon.swift -o /tmp/make_icon && /tmp/make_icon Resources/AppIcon.iconset
//       iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

/// 在 1024×1024 的画布上绘制（原点在左下）。
func drawIcon() {
    let ctx = NSGraphicsContext.current!.cgContext

    // —— 底座：macOS 风格圆角方块，蓝色渐变 ——
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 188, yRadius: 188)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    rgb(0.25, 0.40, 0.95).setFill(); tilePath.fill()
    ctx.restoreGState()
    ctx.saveGState()
    tilePath.addClip()
    NSGradient(starting: rgb(0.42, 0.64, 1.0), ending: rgb(0.20, 0.30, 0.86))!.draw(in: tile, angle: -90)
    // 顶部一层很淡的高光
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    ctx.restoreGState()

    // —— 后面的窗口：半透明，表示被压在下面的其他窗口 ——
    let back = NSRect(x: 205, y: 262, width: 430, height: 340)
    let backPath = NSBezierPath(roundedRect: back, xRadius: 44, yRadius: 44)
    NSColor.white.withAlphaComponent(0.38).setFill(); backPath.fill()

    // —— 前面的窗口：纯白，带标题栏，投影表示悬浮在最上面 ——
    let front = NSRect(x: 340, y: 340, width: 470, height: 380)
    let frontPath = NSBezierPath(roundedRect: front, xRadius: 46, yRadius: 46)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 36, color: NSColor.black.withAlphaComponent(0.34).cgColor)
    NSColor.white.setFill(); frontPath.fill()
    ctx.restoreGState()
    ctx.saveGState(); frontPath.addClip()
    rgb(0.84, 0.89, 1.0).setFill()
    NSRect(x: front.minX, y: front.maxY - 92, width: front.width, height: 92).fill()   // 标题栏
    ctx.restoreGState()
    // 标题栏左侧三个小圆点（窗口的“交通灯”，很淡，只用来说明这是窗口）
    for (i, c) in [rgb(0.99, 0.45, 0.42), rgb(0.99, 0.78, 0.30), rgb(0.38, 0.80, 0.45)].enumerated() {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: front.minX + 36 + CGFloat(i) * 40, y: front.maxY - 58, width: 24, height: 24)).fill()
    }
    // —— 图钉：钉在前面窗口的右上角，微微倾斜 ——
    ctx.saveGState()
    ctx.translateBy(x: 776, y: 688)
    ctx.rotate(by: -.pi / 5.2)
    ctx.scaleBy(x: 1.22, y: 1.22)
    // 针（先画，在钉帽下面）
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: -7, y: -40)); needle.line(to: NSPoint(x: 7, y: -40))
    needle.line(to: NSPoint(x: 0, y: -128)); needle.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    rgb(0.62, 0.66, 0.74).setFill(); needle.fill()
    ctx.restoreGState()
    // 钉身（梯形）+ 横档 + 钉帽
    let body = NSBezierPath()
    body.move(to: NSPoint(x: -26, y: -42)); body.line(to: NSPoint(x: 26, y: -42))
    body.line(to: NSPoint(x: 38, y: 40)); body.line(to: NSPoint(x: -38, y: 40)); body.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 16, color: NSColor.black.withAlphaComponent(0.38).cgColor)
    rgb(0.93, 0.25, 0.27).setFill(); body.fill()
    ctx.restoreGState()
    let bar = NSBezierPath(roundedRect: NSRect(x: -62, y: 36, width: 124, height: 26), xRadius: 13, yRadius: 13)
    rgb(0.84, 0.17, 0.21).setFill(); bar.fill()
    let head = NSBezierPath(roundedRect: NSRect(x: -42, y: 56, width: 84, height: 70), xRadius: 30, yRadius: 30)
    NSGradient(starting: rgb(1.0, 0.43, 0.43), ending: rgb(0.88, 0.17, 0.22))!.draw(in: head, angle: -90)
    // 钉身上的高光
    NSColor.white.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect: NSRect(x: -26, y: 70, width: 12, height: 42), xRadius: 6, yRadius: 6).fill()
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    g.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    g.cgContext.setShouldAntialias(true); g.cgContext.interpolationQuality = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
// iconutil 要求的文件名：icon_16x16.png、icon_16x16@2x.png ...
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(size: px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("已生成 \(out)")
