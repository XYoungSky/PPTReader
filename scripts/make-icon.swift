// 生成 App 图标：swift scripts/make-icon.swift <输出目录>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 图标网格：内容区约占 80%，圆角约 22.5%
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(red: 0.24, green: 0.42, blue: 0.95, alpha: 1).cgColor,
                  NSColor(red: 0.43, green: 0.30, blue: 0.88, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // 课件页
    let page = CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.2,
                      width: rect.width * 0.48, height: rect.height * 0.6)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: rect.width * 0.05, cornerHeight: rect.width * 0.05, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor(red: 0.30, green: 0.40, blue: 0.85, alpha: 0.35).cgColor)
    for i in 0..<4 {
        let w = page.width * (i == 0 ? 0.62 : (i == 3 ? 0.45 : 0.72))
        let y = page.maxY - page.height * (0.2 + CGFloat(i) * 0.16)
        let bar = CGRect(x: page.minX + page.width * 0.14, y: y, width: w, height: page.height * 0.065)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil))
        ctx.fillPath()
    }

    // 星光
    func sparkle(center: CGPoint, r: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center.x, y: center.y + r))
        p.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: CGPoint(x: center.x + r * 0.15, y: center.y + r * 0.15))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: CGPoint(x: center.x + r * 0.15, y: center.y - r * 0.15))
        p.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: CGPoint(x: center.x - r * 0.15, y: center.y - r * 0.15))
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: CGPoint(x: center.x - r * 0.15, y: center.y + r * 0.15))
        ctx.addPath(p)
        ctx.fillPath()
    }
    ctx.setFillColor(NSColor(red: 1, green: 0.85, blue: 0.35, alpha: 1).cgColor)
    sparkle(center: CGPoint(x: rect.minX + rect.width * 0.74, y: rect.minY + rect.height * 0.36), r: rect.width * 0.16)
    ctx.setFillColor(NSColor.white.cgColor)
    sparkle(center: CGPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.6), r: rect.width * 0.07)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("ok")
