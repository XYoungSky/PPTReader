import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PPTReader

@Suite("框选：坐标换算")
struct PageRegionGeometryTests {
    /// 页面在视图中的位置（y 轴向上）。
    private let pageRect = CGRect(x: 100, y: 50, width: 400, height: 300)

    @Test("归一化：左上角为原点")
    func normalized() throws {
        // 视图里页面左上角那一块：x 100…200，y 250…350（y 轴向上，所以是页面顶部）
        let region = try #require(PageRegion.normalized(page: 3, rect: CGRect(x: 100, y: 250, width: 100, height: 100), in: pageRect))
        #expect(region.page == 3)
        #expect(region.x == 0)
        #expect(region.y == 0)
        #expect(region.width == 0.25)
        #expect(abs(region.height - 1.0 / 3) < 1e-9)
    }

    @Test("换算回视图坐标与原来一致")
    func roundTrip() throws {
        let rect = CGRect(x: 180, y: 120, width: 140, height: 60)
        let region = try #require(PageRegion.normalized(page: 1, rect: rect, in: pageRect))
        let back = region.rect(in: pageRect)
        #expect(abs(back.minX - rect.minX) < 1e-9 && abs(back.minY - rect.minY) < 1e-9)
        #expect(abs(back.width - rect.width) < 1e-9 && abs(back.height - rect.height) < 1e-9)
    }

    @Test("缩放、滚动后框跟着页面走")
    func followsPage() throws {
        let region = try #require(PageRegion.normalized(page: 1, rect: CGRect(x: 300, y: 200, width: 100, height: 50), in: pageRect))
        // 放大一倍并滚动之后，页面在视图里的位置变了
        let zoomed = CGRect(x: -40, y: -500, width: 800, height: 600)
        let rect = region.rect(in: zoomed)
        let expected = CGRect(x: 360, y: -200, width: 200, height: 100)
        #expect(abs(rect.minX - expected.minX) < 1e-9 && abs(rect.minY - expected.minY) < 1e-9)
        #expect(abs(rect.width - expected.width) < 1e-9 && abs(rect.height - expected.height) < 1e-9)
    }

    @Test("超出页面的部分裁掉")
    func clipped() throws {
        let region = try #require(PageRegion.normalized(page: 1, rect: CGRect(x: 0, y: 0, width: 200, height: 100), in: pageRect))
        #expect(region.x == 0)
        #expect(region.width == 0.25)
        #expect(abs(region.y + region.height - 1) < 1e-9, "贴着页面底边")
        #expect(abs(region.height - 50.0 / 300) < 1e-9)
    }

    @Test("反方向拖出来的框也能用")
    func negativeSize() throws {
        let region = try #require(PageRegion.normalized(page: 1, rect: CGRect(x: 300, y: 200, width: -100, height: -50), in: pageRect))
        #expect(region.width == 0.25)
    }

    @Test("太小或在页面外时不算框选")
    func tooSmall() {
        #expect(PageRegion.normalized(page: 1, rect: CGRect(x: 150, y: 100, width: 5, height: 40), in: pageRect) == nil)
        #expect(PageRegion.normalized(page: 1, rect: CGRect(x: 600, y: 100, width: 50, height: 50), in: pageRect) == nil)
        #expect(PageRegion.normalized(page: 1, rect: CGRect(x: 100, y: 100, width: 50, height: 50), in: .zero) == nil)
    }

    @Test("按页面显示尺寸换算成点")
    func pointRect() {
        let region = PageRegion(page: 1, x: 0.5, y: 0, width: 0.5, height: 0.25)
        // 左上角原点的 (50%, 0%) 在 y 轴向上的坐标里是页面的右上角
        #expect(region.pointRect(pageSize: CGSize(width: 800, height: 600)) == CGRect(x: 400, y: 450, width: 400, height: 150))
    }
}

@Suite("框选：截图尺寸")
struct PageRegionRenderSizeTests {
    @Test("中等大小的框按 2 倍渲染")
    func doubleScale() {
        #expect(PageRegion.renderScale(for: CGSize(width: 500, height: 300)) == 2)
        #expect(PageRegion.pixelSize(for: CGSize(width: 500, height: 300)) == (1000, 600))
    }

    @Test("大框的长边不超过 1600")
    func capped() {
        let size = PageRegion.pixelSize(for: CGSize(width: 1000, height: 700))
        #expect(size.width == 1600)
        #expect(size.height == 1120)
        let tall = PageRegion.pixelSize(for: CGSize(width: 300, height: 1200))
        #expect(tall.height == 1600)
    }

    @Test("小框放大到长边 768，但最多放大 8 倍")
    func smallBoxes() {
        #expect(PageRegion.pixelSize(for: CGSize(width: 200, height: 100)) == (768, 384))
        #expect(PageRegion.pixelSize(for: CGSize(width: 40, height: 20)) == (320, 160))
    }

    @Test("缩略图长边 480，小框最多放大 8 倍")
    func thumbnail() {
        let size = CGSize(width: 600, height: 300)
        #expect(PageRegion.pixelSize(for: size, scale: PageRegion.thumbnailScale(for: size)) == (480, 240))
        let tiny = CGSize(width: 30, height: 10)
        #expect(PageRegion.pixelSize(for: tiny, scale: PageRegion.thumbnailScale(for: tiny)) == (240, 80))
    }

    @Test("任何框的截图都不超过 1600，也不为空")
    func bounds() {
        for width in stride(from: 1.0, through: 3000, by: 37) {
            for height in [1.0, 9, 120, 800, 2400] {
                let (w, h) = PageRegion.pixelSize(for: CGSize(width: width, height: height))
                #expect(max(w, h) <= 1601 && w >= 1 && h >= 1, "\(width)×\(height)")
            }
        }
    }
}

@Suite("框选：提问文字")
struct RegionPromptTests {
    private let region = PageRegion(page: 4, x: 0.1, y: 0.25, width: 0.5, height: 0.2)

    @Test("框选动作生成的消息带上区域和框内文字，页码取框所在页")
    func userMessage() {
        let message = PromptBuilder.userMessage(for: .region(.explain, region, text: "E = mc^2"), page: 9)
        #expect(message.region == region)
        #expect(message.page == 4)
        #expect(message.selection == "E = mc^2")
        #expect(message.prompt?.isEmpty == false)
    }

    @Test("框内没有文字时不记 selection")
    func emptyText() {
        let message = PromptBuilder.userMessage(for: .region(.ask, region, text: ""), page: 4)
        #expect(message.selection == nil)
    }

    @Test("自由提问附带框选")
    func question() {
        let message = PromptBuilder.userMessage(for: .question("这是什么？", selection: "x", region: region), page: 1)
        #expect(message.content == "这是什么？")
        #expect(message.region == region)
        #expect(message.page == 4)
        let plain = PromptBuilder.userMessage(for: .question("hi", selection: nil), page: 2)
        #expect(plain.region == nil && plain.page == 2)
    }

    @Test("有截图时提示截图在后面，并附上框内文字")
    func withImage() {
        let text = PromptBuilder.regionText(region, selection: "框内文字", hasImage: true)
        #expect(text.contains("4"))
        #expect(text.contains("框内文字"))
        #expect(text.split(separator: "\n").count == 4, "位置、截图说明、文字标签、文字")
        #expect(text.contains("10%") && text.contains("25%") && text.contains("50%") && text.contains("20%"))
    }

    @Test("没有截图也没有文字时说明框内可能是图片")
    func nothing() {
        let withText = PromptBuilder.regionText(region, selection: "abc", hasImage: false)
        let empty = PromptBuilder.regionText(region, selection: "  ", hasImage: false)
        let imageOnly = PromptBuilder.regionText(region, selection: nil, hasImage: true)
        #expect(withText.split(separator: "\n").count == 3)
        #expect(empty.split(separator: "\n").count == 2)
        #expect(imageOnly.split(separator: "\n").count == 2)
        #expect(empty != imageOnly)
    }

    @Test("旧记录没有 region 也能读出")
    func decodeOldMessage() throws {
        let json = #"{"id":"\#(UUID().uuidString)","role":"user","content":"hi","isAuto":false,"stopped":false,"createdAt":0}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        #expect(message.region == nil)
        var withRegion = message
        withRegion.region = region
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(withRegion))
        #expect(decoded.region == region)
    }
}

/// 渲染：用一份四个象限颜色不同的 PDF 检查框内截图取对了位置，包括旋转过的页面。
@Suite("框选：渲染")
struct RegionRenderingTests {
    /// 宽 400、高 300 的页面：左上红、右上绿、左下蓝、右下黑（按未旋转时的方向）。
    private func makePDF(rotation: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 150, width: 200, height: 150), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 200, y: 150, width: 200, height: 150), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 200, height: 150), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 200, y: 0, width: 200, height: 150), CGColor(red: 0, green: 0, blue: 0, alpha: 1)),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color)
            context.fill(rect)
        }
        context.endPDFPage()
        context.closePDF()
        if rotation != 0 {
            let document = try #require(PDFDocument(url: url))
            document.page(at: 0)?.rotation = rotation
            #expect(document.write(to: url))
        }
        return url
    }

    /// 截图中心像素的颜色（r, g, b 取 0 或 1）。
    private func centerColor(_ jpeg: Data) throws -> (Int, Int, Int, width: Int, height: Int) {
        let image = try #require(NSBitmapImageRep(data: jpeg))
        let color = try #require(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let bit = { (value: CGFloat) in value > 0.5 ? 1 : 0 }
        return (bit(color.redComponent), bit(color.greenComponent), bit(color.blueComponent), image.pixelsWide, image.pixelsHigh)
    }

    @Test("未旋转的页面：各象限取对颜色")
    func unrotated() async throws {
        let renderer = PageRenderer(url: try makePDF(rotation: 0))
        let topLeft = try #require(await renderer.jpeg(region: PageRegion(page: 1, x: 0, y: 0, width: 0.5, height: 0.5)))
        let c = try centerColor(topLeft)
        #expect((c.0, c.1, c.2) == (1, 0, 0), "左上应为红色")
        #expect(c.width == 768 && c.height == 576, "200×150 的框放大到长边 768")
        let bottomRight = try #require(await renderer.jpeg(region: PageRegion(page: 1, x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        let d = try centerColor(bottomRight)
        #expect((d.0, d.1, d.2) == (0, 0, 0), "右下应为黑色")
    }

    /// 顺时针转 90° 后，显示出来的页面是 300 宽、400 高：原来的左下（蓝）转到了左上。
    @Test("旋转 90° 的页面按显示方向取区域")
    func rotated() async throws {
        let renderer = PageRenderer(url: try makePDF(rotation: 90))
        let topLeft = try #require(await renderer.jpeg(region: PageRegion(page: 1, x: 0, y: 0, width: 0.5, height: 0.5)))
        let c = try centerColor(topLeft)
        #expect((c.0, c.1, c.2) == (0, 0, 1), "显示时的左上应为原来的左下（蓝）")
        #expect(c.width == 576 && c.height == 768, "显示时框是 150 宽、200 高")
        let topRight = try #require(await renderer.jpeg(region: PageRegion(page: 1, x: 0.5, y: 0, width: 0.5, height: 0.5)))
        let d = try centerColor(topRight)
        #expect((d.0, d.1, d.2) == (1, 0, 0), "显示时的右上应为原来的左上（红）")
    }

    @Test("缩略图取同一块区域，尺寸更小")
    func thumbnailRender() async throws {
        let renderer = PageRenderer(url: try makePDF(rotation: 0))
        let thumb = try #require(await renderer.jpeg(region: PageRegion(page: 1, x: 0.5, y: 0, width: 0.5, height: 0.5), thumbnail: true))
        let c = try centerColor(thumb)
        #expect((c.0, c.1, c.2) == (0, 1, 0), "右上应为绿色")
        #expect(c.width == 480 && c.height == 360)
    }

    @Test("页码超出范围时没有截图")
    func missingPage() async throws {
        let renderer = PageRenderer(url: try makePDF(rotation: 0))
        #expect(await renderer.jpeg(region: PageRegion(page: 5, x: 0, y: 0, width: 1, height: 1)) == nil)
    }
}
