import CoreGraphics
import Foundation

/// 在课件上框选的区域。位置按页面显示时的宽高归一化（0…1，左上角为原点），与缩放、滚动和页面旋转无关；
/// 重新生成回答时按它重新渲染截图，记录里不存图片。
struct PageRegion: Codable, Equatable, Sendable {
    /// 页码，从 1 开始。
    var page: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// 框的边长至少这么多（视图中的点）才算框选，否则当作点按。
    static let minimumSide: CGFloat = 8

    /// 截图的长边：按 2 倍分辨率渲染，但不超过 1600（和整页截图一致，避免大框的图片过大、费用过高），
    /// 也不少于 768（框很小时放大渲染，模型才看得清）。
    static let maxPixels: CGFloat = 1600
    static let minPixels: CGFloat = 768
    /// 放大渲染的上限：框极小时不必再放大。
    static let maxScale: CGFloat = 8
    /// 对话气泡里缩略图的长边（像素，约为 2 倍屏上的 240pt）。
    static let thumbnailPixels: CGFloat = 480

    /// 把视图中的框换算成相对页面的位置。两个矩形用同一坐标系（y 轴向上，与 PDFView 一致）。
    /// 框先裁到页面范围内；裁完太小时返回 nil。
    static func normalized(page: Int, rect: CGRect, in pageRect: CGRect) -> PageRegion? {
        let clipped = rect.standardized.intersection(pageRect)
        guard !clipped.isNull, pageRect.width > 0, pageRect.height > 0,
              clipped.width >= minimumSide, clipped.height >= minimumSide else { return nil }
        return PageRegion(page: page,
                          x: Double((clipped.minX - pageRect.minX) / pageRect.width),
                          y: Double((pageRect.maxY - clipped.maxY) / pageRect.height),
                          width: Double(clipped.width / pageRect.width),
                          height: Double(clipped.height / pageRect.height))
    }

    /// 换算回视图坐标（y 轴向上），`pageRect` 是页面当前在视图中的位置。
    func rect(in pageRect: CGRect) -> CGRect {
        CGRect(x: pageRect.minX + x * pageRect.width,
               y: pageRect.maxY - (y + height) * pageRect.height,
               width: width * pageRect.width,
               height: height * pageRect.height)
    }

    /// 框在页面上的位置（页面显示方向的点，y 轴向上、原点在左下），`pageSize` 是页面显示时的尺寸（已考虑旋转）。
    func pointRect(pageSize: CGSize) -> CGRect {
        rect(in: CGRect(origin: .zero, size: pageSize))
    }

    /// 每个点渲染成多少像素。
    static func renderScale(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 1 }
        let scale = min(max(2, minPixels / longest), maxPixels / longest)
        return min(scale, maxScale)
    }

    /// 缩略图每个点渲染成多少像素：长边 480，同样最多放大 8 倍。
    static func thumbnailScale(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 1 }
        return min(thumbnailPixels / longest, maxScale)
    }

    /// 截图的像素尺寸。
    static func pixelSize(for size: CGSize, scale: CGFloat? = nil) -> (width: Int, height: Int) {
        let scale = scale ?? renderScale(for: size)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }
}
