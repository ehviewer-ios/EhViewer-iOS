import SwiftUI
import PhotosUI
import UIKit
import EhCore

/// 以图搜图：从相册选图 + 选项，生成 `.imageSearch` 模式的列表条件。对应 Android `ImageSearchLayout`
struct ImageSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    var onSearch: (ListUrlBuilder) -> Void

    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var loading = false
    @State private var errorText: String?
    @State private var similarityScan = true
    @State private var onlyCovers = false
    @State private var showExpunged = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
                        ZStack {
                            if let image {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            } else {
                                VStack(spacing: 8) {
                                    if loading {
                                        ProgressView()
                                            .controlSize(.large)
                                        Text("正在读取图片…")
                                    } else {
                                        Image(systemName: "photo.on.rectangle.angled")
                                            .font(.largeTitle)
                                            .accessibilityHidden(true)
                                        Text("选择图片")
                                    }
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 160)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(image == nil ? "选择图片" : "更换图片"))
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("相似扫描", isOn: $similarityScan)
                    Toggle("只搜索封面", isOn: $onlyCovers)
                    Toggle("显示已删除的画廊", isOn: $showExpunged)
                } footer: {
                    Text("相似扫描可以找到经过缩放或轻微修改的图片。")
                }
            }
            .navigationTitle("以图搜图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("搜索") { submit() }
                        .disabled(imageData == nil || loading)
                }
            }
            .onChange(of: item) { _, newItem in
                Task { await load(newItem) }
            }
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let ui = UIImage(data: data) else {
                errorText = "无法读取图片"
                return
            }
            image = ui
            // 站点不一定支持 HEIC 等格式，统一转为 JPEG
            imageData = ui.jpegData(compressionQuality: 0.9) ?? data
        } catch {
            errorText = "无法读取图片：\(error.localizedDescription)"
        }
    }

    private func submit() {
        guard let imageData else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-search-\(UUID().uuidString).jpg")
        do {
            try imageData.write(to: url, options: .atomic)
        } catch {
            errorText = "无法写入临时文件：\(error.localizedDescription)"
            return
        }
        var b = ListUrlBuilder()
        b.mode = .imageSearch
        b.imagePath = url.path
        b.useSimilarityScan = similarityScan
        b.onlySearchCovers = onlyCovers
        b.showExpunged = showExpunged
        onSearch(b)
        dismiss()
    }
}
