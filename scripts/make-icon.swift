// 生成 App 图标：
//   swift scripts/make-icon.swift build/AppIcon.iconset
//   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
// 样子：陶土色底，一张白色的横向幻灯片，中间一颗星（AI 讲课件）。颜色和应用里的强调色一致。
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// 从上到下的渐变。
func fillVertical(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32, in rect: CGRect) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

/// 四角星：四条边向中心收的弧线。
func sparkle(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat) {
    let k = r * 0.16
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
    ctx.addPath(path)
    ctx.fillPath()
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 图标网格：1024 的画布里内容占 824，圆角半径约 185
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = tile.width * 0.225
    let shape = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.028, color: rgb(0x000000, 0.22))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xC0573A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    fillVertical(ctx, 0xE2825F, 0xC0573A, in: tile)

    // 幻灯片
    let u = tile.width
    let slide = CGRect(x: tile.midX - u * 0.30, y: tile.midY - u * 0.21, width: u * 0.60, height: u * 0.42)
    let slidePath = CGPath(roundedRect: slide, cornerWidth: u * 0.065, cornerHeight: u * 0.065, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.012), blur: u * 0.04, color: rgb(0x000000, 0.12))
    ctx.addPath(slidePath)
    ctx.setFillColor(rgb(0xF6F1E9))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(slidePath)
    ctx.clip()
    fillVertical(ctx, 0xFFFFFF, 0xF6F1E9, in: slide)
    ctx.restoreGState()

    // 星
    ctx.setFillColor(rgb(0xCF6A47))
    sparkle(ctx, center: CGPoint(x: slide.midX, y: slide.midY), radius: u * 0.13)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("ok")
