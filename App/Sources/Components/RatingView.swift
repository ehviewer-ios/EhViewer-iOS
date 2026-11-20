import SwiftUI

/// 星级显示（0–5，支持半星）
struct RatingView: View {
    let rating: Float
    /// 默认字号下的星星尺寸，随动态字体缩放
    var size: CGFloat = 11
    var color: Color = .orange
    /// 当前用户已评分（星星颜色区分之外，读屏也会说明）
    var userRated: Bool = false
    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: symbol(for: i))
                    .font(.system(size: size * scale))
                    .foregroundStyle(color)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("评分 \(String(format: "%.1f", rating))" + (userRated ? "，已评分" : "")))
    }

    private func symbol(for i: Int) -> String {
        let v = rating - Float(i)
        if v >= 0.75 { return "star.fill" }
        if v >= 0.25 { return "star.leadinghalf.filled" }
        return "star"
    }
}

/// 可交互评分（0.5 步进），用于评分对话框
struct RatingPicker: View {
    @Binding var rating: Float
    var size: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            RatingView(rating: rating, size: size)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let starsWidth = size * 5 + 4
                    let originX = (geo.size.width - starsWidth) / 2
                    let x = min(max(value.location.x - originX, 0), starsWidth)
                    let raw = Float(x / starsWidth * 5)
                    rating = max(0.5, (raw * 2).rounded(.up) / 2)
                })
        }
        .frame(height: size + 8)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(rating) }, set: { rating = Float($0) }), in: 0.5...5, step: 0.5) {
                Text("评分")
            }
            .accessibilityValue(Text(String(format: "%.1f 星", rating)))
        }
        .sensoryFeedback(.selection, trigger: rating)
    }
}
