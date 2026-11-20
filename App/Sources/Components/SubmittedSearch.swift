import SwiftUI

/// 提交式搜索框的状态（画廊列表、下载列表共用）。交互约定见 docs/APP_DESIGN.md「交互规范」：
/// - 摆放见 `ListSearch`：搜索栏在列表顶部、下滑时收起；导航栏的搜索按钮（`present()`）随时可打开
/// - 提交（键盘搜索键、点搜索历史）后收起搜索框，让导航栏按钮恢复显示；搜索框保留已生效的搜索词
/// - 取消：恢复为已生效的搜索词；用户清空搜索框后再取消，则清除搜索
/// - 获得焦点时光标在末尾（`SearchFieldCaret`）
@MainActor @Observable
final class SubmittedSearchState {
    /// 搜索框文字：编辑中为输入内容；不在编辑时为已生效的搜索词
    var text = ""
    var isPresented = false

    /// 程序写入的文字（不算用户编辑）
    @ObservationIgnored fileprivate var programmaticText: String?
    /// 本次编辑中搜索框最后的文字。系统退出编辑时清空文字（此时已不在编辑状态），不计入
    @ObservationIgnored fileprivate var editedText = ""
    /// 本次退出编辑是因为提交了搜索或打开了页面，而不是取消
    @ObservationIgnored fileprivate var endedBySubmit = false
    @ObservationIgnored fileprivate var syncID = 0
    @ObservationIgnored fileprivate var syncForce = false

    /// 打开搜索栏开始编辑（导航栏的搜索按钮；列表滚动后搜索栏已收起时也可用）
    func present() {
        isPresented = true
    }

    /// 结束编辑并按“提交”处理（提交搜索、从建议中打开页面）
    func endEditingBySubmit() {
        endedBySubmit = true
        isPresented = false
    }
}

extension View {
    /// 提交式搜索框。
    /// - Parameters:
    ///   - committed: 已生效条件对应的搜索词，每次调用读取最新值
    ///   - onSubmit: 用户按了键盘搜索键（之后自动收起搜索框）
    ///   - onClear: 用户清空搜索框后取消
    ///   - onEdit: 编辑中文字变化（含开始编辑时），用于建议或实时筛选
    ///   - onEndEditing: 退出编辑
    ///   - onSync: 搜索框写回已生效的搜索词之后
    func submittedSearch(_ state: SubmittedSearchState, committed: @escaping () -> String, prompt: String,
                         onSubmit: @escaping (String) -> Void, onClear: @escaping () -> Void,
                         onEdit: @escaping (String) -> Void = { _ in },
                         onEndEditing: @escaping () -> Void = {},
                         onSync: @escaping () -> Void = {}) -> some View {
        modifier(SubmittedSearchModifier(state: state, committed: committed, prompt: prompt,
                                         onSubmit: onSubmit, onClear: onClear, onEdit: onEdit,
                                         onEndEditing: onEndEditing, onSync: onSync))
    }
}

private struct SubmittedSearchModifier: ViewModifier {
    @Bindable var state: SubmittedSearchState
    let committed: () -> String
    let prompt: String
    let onSubmit: (String) -> Void
    let onClear: () -> Void
    let onEdit: (String) -> Void
    let onEndEditing: () -> Void
    let onSync: () -> Void

    func body(content: Content) -> some View {
        content
            .searchable(text: $state.text, isPresented: $state.isPresented,
                        placement: ListSearch.placement, prompt: Text(prompt))
            .onSubmit(of: .search) {
                onSubmit(state.text)
                state.endEditingBySubmit()
            }
            .onChange(of: state.text) { _, text in textChanged(text) }
            .onChange(of: state.isPresented) { _, active in presentationChanged(active) }
            // 条件在别处被改变（筛选、快速搜索、重置等）时，搜索框随之更新
            .onChange(of: committed()) { _, _ in
                if !state.isPresented { scheduleSync() }
            }
            // 出现后再写入（初始化时就有文字的话，系统会一直显示搜索范围栏）
            .onAppear { scheduleSync() }
    }

    /// 退出编辑：
    /// - 提交了搜索：搜索框显示新的搜索词
    /// - 取消且用户清空了搜索框：清除搜索
    /// - 取消：搜索框恢复为已生效的搜索词
    ///
    /// 点搜索历史时系统直接提交，文字的变化在收起之后才送达（editedText 还是空的），所以要先排除提交
    private func presentationChanged(_ active: Bool) {
        if active {
            state.editedText = state.text
            state.endedBySubmit = false
            onEdit(state.text)
            return
        }
        onEndEditing()
        let cancelled = !state.endedBySubmit
        state.endedBySubmit = false
        if cancelled, state.editedText.trimmingCharacters(in: .whitespaces).isEmpty {
            onClear()
        }
        scheduleSync(force: true)
    }

    private func textChanged(_ text: String) {
        if let expected = state.programmaticText {
            state.programmaticText = nil
            if text == expected { return }
        }
        guard state.isPresented else {
            // 不在编辑状态时文字被系统改动（收起搜索框时清空）：写回已生效的搜索词
            scheduleSync()
            return
        }
        state.editedText = text
        onEdit(text)
    }

    /// 在下一轮把已生效的搜索词写回搜索框（同一轮内的多次请求合并）。
    ///
    /// `force`：刚收起搜索框。系统收起时会清空输入框，但不一定同步更新绑定（压入的页面就不会）；
    /// 绑定值没变时 SwiftUI 不会重新写入输入框，因此先写入空值、下一帧再写回
    private func scheduleSync(force: Bool = false) {
        state.syncID += 1
        state.syncForce = state.syncForce || force
        let id = state.syncID
        let state = state
        let committed = committed
        let onSync = onSync
        Task { @MainActor in
            guard id == state.syncID else { return }
            let force = state.syncForce
            state.syncForce = false
            guard !state.isPresented else { return }
            if force, !state.text.isEmpty, state.text == committed() {
                Self.setText("", state)
                try? await Task.sleep(for: .milliseconds(50))
                guard id == state.syncID, !state.isPresented else { return }
            }
            Self.setText(committed(), state)
            onSync()
        }
    }

    private static func setText(_ text: String, _ state: SubmittedSearchState) {
        guard state.text != text else { return }
        state.programmaticText = text
        state.text = text
    }
}
