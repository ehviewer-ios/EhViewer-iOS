import SwiftUI

/// 多选模式下网格单元右上角的勾选标记（收藏 / 下载共用）
struct SelectionCheckmark: View {
    let selected: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(selected ? Color.white : Color.white, selected ? Color.accentColor : Color.black.opacity(0.25))
            .shadow(radius: 1)
            .padding(6)
            .accessibilityHidden(true) // 选中状态由单元的 .isSelected trait 播报
    }
}

extension View {
    /// 网格单元的多选外观：选中时加描边并在右上角显示勾选
    func gridSelectionOverlay(isEditing: Bool, selected: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if isEditing { SelectionCheckmark(selected: selected) }
        }
        .overlay {
            if isEditing, selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
    }
}

/// 按日期跳转（新版分页 seek）
struct FavoritesDateJumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    let onJump: (Date) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("跳转到日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") {
                        onJump(date)
                        dismiss()
                    }
                }
            }
        }
    }
}
