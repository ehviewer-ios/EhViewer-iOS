import SwiftUI
import EhCore

/// 跳页：旧版分页输入页码；新版游标分页按日期（seek）或时间跨度（jump）跳转。
/// 对应 Android `GalleryListScene.showGoToDialog` / `showPageJumpDialog` / `JumpDateSelector`
struct JumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    let vm: GalleryListModel

    private enum Mode: Hashable { case date, span }

    private static let spans: [(param: String, title: String)] = [
        ("1d", "1 天"), ("3d", "3 天"), ("1w", "1 周"), ("2w", "2 周"),
        ("1m", "1 个月"), ("6m", "6 个月"), ("1y", "1 年"), ("2y", "2 年"),
    ]

    @State private var pageText = ""
    @State private var pageError: String?
    @State private var mode: Mode = .date
    @State private var date = Date()
    @State private var span = "1w"
    @FocusState private var pageFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if vm.isNewStylePaging {
                    newStyleContent
                } else {
                    pageContent
                }
            }
            .navigationTitle("跳转")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") { go() }
                }
            }
        }
    }

    // MARK: 页码

    @ViewBuilder
    private var pageContent: some View {
        Section {
            TextField("页码", text: $pageText)
                .keyboardType(.numberPad)
                .focused($pageFocused)
                .onSubmit(go)
                .onAppear { pageFocused = true }
        } header: {
            Text("当前第 \(vm.firstPage + 1) 页，共 \(vm.pages == Int.max ? "?" : String(vm.pages)) 页")
        } footer: {
            if let pageError { Text(pageError).foregroundStyle(.red) }
        }
    }

    // MARK: 日期 / 时间跨度

    @ViewBuilder
    private var newStyleContent: some View {
        if let count = vm.resultCount, !count.isEmpty {
            Section {
                LabeledContent("搜索结果", value: count)
            }
        }
        Section {
            Picker("方式", selection: $mode) {
                Text("指定日期").tag(Mode.date)
                Text("向后跨越").tag(Mode.span)
            }
            .pickerStyle(.segmented)
        }
        switch mode {
        case .date:
            Section {
                DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
            } footer: {
                Text("显示该日期及更早发布的画廊。")
            }
        case .span:
            Section {
                Picker("跨度", selection: $span) {
                    ForEach(Self.spans, id: \.param) { s in
                        Text(s.title).tag(s.param)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("从当前位置向更早的时间跳过所选时长。")
            }
        }
        Section {
            Button("回到最新") {
                Task { await vm.refresh() }
                dismiss()
            }
            if vm.canJumpToLast {
                Button("跳到最早") {
                    vm.jumpToLast()
                    dismiss()
                }
            }
        }
    }

    private func go() {
        if vm.isNewStylePaging {
            let param: String
            switch mode {
            case .date:
                let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
                param = String(format: "seek=%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
            case .span:
                param = "jump=" + span
            }
            vm.jump(appendParam: param)
            dismiss()
        } else {
            guard let n = Int(pageText.trimmingCharacters(in: .whitespaces)) else {
                pageError = "请输入有效的数字"
                return
            }
            guard n >= 1, n <= vm.pages else {
                pageError = "超出范围"
                return
            }
            vm.jump(toPage: n - 1)
            dismiss()
        }
    }
}
