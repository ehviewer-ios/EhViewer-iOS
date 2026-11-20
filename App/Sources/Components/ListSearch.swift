import SwiftUI

/// 列表页（画廊列表、下载、收藏、历史）的搜索栏，见 docs/APP_DESIGN.md「交互规范」：
/// - 搜索栏在列表顶部，往下滑时随导航栏收起，回到顶部时重新出现（系统行为）
/// - 导航栏有搜索按钮（`ListSearchButton`），翻到多深都能点按直接打开搜索栏
///
/// 没有用 iOS 26 的“收成导航栏按钮”（`searchToolbarBehavior(.minimize)`）：在标签栏 App 中
/// 点按展开后的关闭按钮无法退出搜索（iOS 27.2 实测，最小示例可复现；不在标签栏中时正常）
enum ListSearch {
    static let placement = SearchFieldPlacement.navigationBarDrawer(displayMode: .automatic)
}

extension View {
    /// 列表页的即时筛选搜索栏（收藏、历史；画廊列表与下载列表用 `submittedSearch`）
    func listSearchable(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) -> some View {
        searchable(text: text, isPresented: isPresented, placement: ListSearch.placement, prompt: Text(prompt))
    }
}

/// 导航栏中的搜索按钮：打开搜索栏（列表滚动后搜索栏已收起时也能直接搜索）
struct ListSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("搜索", systemImage: "magnifyingglass")
        }
    }
}
