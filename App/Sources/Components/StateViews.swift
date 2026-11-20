import SwiftUI

/// 空状态
struct EmptyStateView: View {
    let title: String
    var systemImage: String = "tray"
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}

/// 错误状态 + 重试
struct ErrorStateView: View {
    let error: Error
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            if let retry {
                Button("重试", action: retry).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 列表底部加载更多
struct LoadMoreFooter: View {
    enum State: Equatable { case idle, loading, failed(String), end }
    let state: State
    var onAppear: () -> Void = {}
    var retry: () -> Void = {}

    var body: some View {
        HStack {
            Spacer()
            switch state {
            case .idle:
                Color.clear.frame(height: 1).onAppear(perform: onAppear)
            case .loading:
                ProgressView().padding()
            case let .failed(msg):
                VStack(spacing: 6) {
                    Text(msg).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试", action: retry)
                        .buttonStyle(.bordered)
                }.padding()
            case .end:
                Text("没有更多了").font(.footnote).foregroundStyle(.tertiary).padding()
            }
            Spacer()
        }
        .listRowSeparator(.hidden)
    }
}
