import SwiftUI

/// 关于。对应 Android `AboutFragment` / `about_settings.xml`
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "book.pages")
                        .font(.largeTitle)
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("EhViewer").font(.title2.weight(.semibold))
                    Text("版本 \(SettingsFormat.appVersion)").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Text("EhViewer 与 E-Hentai.org 无任何联系。")
            } header: {
                Text("声明")
            }

            Section("源项目") {
                Link(destination: URL(string: "https://github.com/xiaojieonly/Ehviewer_CN_SXJ")!) {
                    LabeledContent("Ehviewer_CN_SXJ（Android）") { Image(systemName: "arrow.up.right.square") }
                }
                Link(destination: URL(string: "https://github.com/seven332/EhViewer")!) {
                    LabeledContent("EhViewer（原作者 Hippo）") { Image(systemName: "arrow.up.right.square") }
                }
                Link(destination: URL(string: "https://github.com/EhTagTranslation/Database")!) {
                    LabeledContent("标签翻译数据库") { Image(systemName: "arrow.up.right.square") }
                }
            }

            Section {
                NavigationLink("GNU GPL v3.0") { LicenseView() }
                Link(destination: URL(string: "https://github.com/kean/Nuke")!) {
                    LabeledContent("Nuke", value: "MIT")
                }
                Link(destination: URL(string: "https://github.com/groue/GRDB.swift")!) {
                    LabeledContent("GRDB.swift", value: "MIT")
                }
                Link(destination: URL(string: "https://github.com/scinfu/SwiftSoup")!) {
                    LabeledContent("SwiftSoup", value: "MIT")
                }
                Link(destination: URL(string: "https://github.com/weichsel/ZIPFoundation")!) {
                    LabeledContent("ZIPFoundation", value: "MIT")
                }
            } header: {
                Text("许可证")
            } footer: {
                Text("本应用移植自 Android 版 EhViewer，按 GNU General Public License v3.0 发布。")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                EhViewer
                Copyright (C) 2015-2019 Hippo Seven
                Copyright (C) xiaojieonly and contributors
                Copyright (C) 2026 EhViewer for iOS contributors

                This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

                This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

                You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.
                """)
                .font(.footnote)
                .textSelection(.enabled)
                Link("阅读 GNU GPL v3.0 全文", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
            .padding()
        }
        .navigationTitle("GPL-3.0")
        .navigationBarTitleDisplayMode(.inline)
    }
}
