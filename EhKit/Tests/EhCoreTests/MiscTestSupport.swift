import Foundation

/// 杂项解析器测试用的样本读取
enum MiscFixture {
    static func html(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "html") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
