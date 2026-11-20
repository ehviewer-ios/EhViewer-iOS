import SwiftUI
import EhCore

extension EhCategory {
    var color: Color {
        let v = colorARGB
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// 色块上的文字颜色：浅色底（黄/橙/浅绿）用黑字，保证对比度
    var foregroundColor: Color {
        let v = colorARGB
        func lin(_ c: UInt32) -> Double {
            let x = Double(c & 0xFF) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin(v >> 16) + 0.7152 * lin(v >> 8) + 0.0722 * lin(v)
        // 白字对比度 (1.05)/(l+0.05) 低于 3:1 时改用黑字
        return 1.05 / (l + 0.05) < 3 ? .black : .white
    }

    /// 展示名（与站点一致的英文名，分类名一般不翻译）
    var displayName: String {
        switch self {
        case .doujinshi: return "Doujinshi"
        case .manga: return "Manga"
        case .artistCG: return "Artist CG"
        case .gameCG: return "Game CG"
        case .western: return "Western"
        case .nonH: return "Non-H"
        case .imageSet: return "Image Set"
        case .cosplay: return "Cosplay"
        case .asianPorn: return "Asian Porn"
        case .misc: return "Misc"
        default: return "Unknown"
        }
    }
}

/// 分类色块标签
struct CategoryBadge: View {
    let category: EhCategory
    var compact = false

    var body: some View {
        Text(category.displayName.uppercased())
            .font(.caption2.weight(.bold))
            .dynamicTypeSize(compact ? .xSmall ... .large : .xSmall ... .accessibility2)
            .foregroundStyle(category.foregroundColor)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, 2)
            .background(category.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .lineLimit(1)
    }
}
