import Foundation

/// 画廊列表/详情/页面解析器测试用的样本读取
enum GalleryFixture {
    static func load(_ name: String, ext: String = "html") throws -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: ext) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
