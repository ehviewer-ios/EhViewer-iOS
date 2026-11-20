// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EhKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EhCore", targets: ["EhCore"]),
        .library(name: "EhNetwork", targets: ["EhNetwork"]),
        .library(name: "EhStorage", targets: ["EhStorage"]),
        .library(name: "EhSpider", targets: ["EhSpider"]),
        .library(name: "EhTransfer", targets: ["EhTransfer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        // 纯逻辑：数据模型、URL 构造、HTML 解析、.ehviewer 文件格式。不依赖任何 Apple 专有框架。
        .target(
            name: "EhCore",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]
        ),
        // 网络：URLSession / 域前置(DF) 传输层、内置 hosts + DoH 解析、Cookie、EhAPI（对应 EhEngine）
        .target(
            name: "EhNetwork",
            dependencies: ["EhCore"]
        ),
        // 存储：GRDB 数据库（对应 greenDAO 各表）、设置项、目录管理
        .target(
            name: "EhStorage",
            dependencies: ["EhCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // 阅读加载与下载（对应 SpiderQueen / SpiderDen / DownloadManager / Archiver）
        .target(
            name: "EhSpider",
            dependencies: [
                "EhCore", "EhNetwork", "EhStorage",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // 设备间 WiFi 传输（与 Android 端帧协议兼容）
        .target(
            name: "EhTransfer",
            dependencies: ["EhCore", "EhStorage"]
        ),
        .testTarget(
            name: "EhCoreTests",
            dependencies: ["EhCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "EhStorageTests", dependencies: ["EhStorage"]),
        .testTarget(name: "EhNetworkTests", dependencies: ["EhNetwork"]),
        .testTarget(name: "EhSpiderTests", dependencies: ["EhSpider"]),
    ],
    swiftLanguageModes: [.v5]
)
