# EhViewer iOS 移植规范

源项目：[Ehviewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ)（Android）
Java 源码根：`app/src/main/java/com/hippo/ehviewer/`（以下简称 `$A`）

iOS 工程：
- `EhKit/` —— SwiftPM 包，所有非 UI 逻辑
  - `EhCore`：模型、URL、HTML 解析（SwiftSoup）、文件格式。**不得 import 任何 Apple 专有框架**（UIKit/Network/CryptoKit 等），只用 Foundation + SwiftSoup，保证 Linux 可编译测试
  - `EhNetwork`：HTTP 传输、DF/DoH、Cookie、EhAPI
  - `EhStorage`：GRDB 数据库、Settings、目录
  - `EhSpider`：在线阅读加载器、下载管理
  - `EhTransfer`：WiFi 互传
- `App/` —— SwiftUI 应用（XcodeGen 生成工程）

## 构建与测试

EhKit 可以在 Linux 或 macOS 上单独编译和测试（Swift 6 工具链；macOS 上跑测试需要完整的 Xcode）：
```bash
cd EhKit
swift build --scratch-path /tmp/ehkit-<你的任务名>
swift test  --scratch-path /tmp/ehkit-<你的任务名> --filter <TestName>
```
- **每个并行任务必须用自己独立的 `--scratch-path`**，不要用默认 `.build`。
- `#if canImport(Network)` 等只在 Apple 平台编译的代码，要在 macOS 上 `swift build` 验证。
- App 层只能在 Mac 上编译：`scripts/build-sim.sh`（模拟器编译，输出错误摘要）。

## 代码约定

- Swift 5 语言模式（Package 中 `swiftLanguageModes: [.v5]`），tools 6.0，目标 iOS 17 / macOS 14。
- 模型用 `struct`，`Codable, Sendable, Hashable`；字段名尽量保留 Android 原名（驼峰），方便对照。
- 依赖站点的函数显式接收 `EhSite` 参数，不读取全局设置。设置值通过参数传入。
- 解析器写成 `public enum XxxParser { public static func parse(_ html: String, ...) throws -> Result }`，与 Java 类名一一对应，文件放 `EhCore/Parsers/XxxParser.swift`。
- 错误统一抛 `EhError`（`EhCore/Models/EhError.swift`）。
- 逐行对照 Java 逻辑翻译：选择器、正则、边界判断都保持一致；Java 中 `ParserUtils.trim/parseInt` 等工具在 `EhCore/Utils/ParserUtils.swift` 里统一实现。
- 正则用 `NSRegularExpression`（Linux 也可用）。注意 Java 的 `Pattern` 与 ICU 语法细微差异（`\\p{...}`、占有量词等）。
- 注释用中文，简洁；在类型头部注明对应的 Android 类名。
- 不要修改 `Package.swift`；需要新依赖时在报告里说明。
- 不要修改不属于你任务范围的文件。需要共享模型的新字段时，只在你负责的文件中添加；若必须改共享模型，在报告中写清楚。

## 测试

- 测试框架：Swift Testing（`import Testing`，`@Test`，`#expect`）。
- HTML 样本：`EhKit/Tests/EhCoreTests/Fixtures/`（来自 Android 端测试资源）。读取方式：
  `Bundle.module.url(forResource: "Fixtures/xxx", withExtension: "html")`（Fixtures 以 `.copy` 方式打包，路径带目录前缀）。
- 参考 Android 测试：`app/src/test/java/com/hippo/ehviewer/client/parser/*Test.java`，断言尽量移植过来。
