// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WSubscriptionKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "WSCore", targets: ["WSCore"]),
        .library(name: "WSCrypto", targets: ["WSCrypto"]),
        .library(name: "WSVault", targets: ["WSVault"]),
        .library(name: "WSDesignSystem", targets: ["WSDesignSystem"]),
        .library(name: "WSFeatures", targets: ["WSFeatures"])
    ],
    targets: [
        // 纯领域模型：零 UI、零 IO、可完整单测。macOS 上也编译，便于跑测试。
        .target(
            name: "WSCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 信封加密、KDF、密钥管理。不 import 任何业务模块。
        .target(
            name: "WSCrypto",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 文件访问与仓库。唯一持有密钥句柄的地方。
        .target(
            name: "WSVault",
            dependencies: ["WSCore", "WSCrypto"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 设计令牌 + 液态玻璃组件。
        .target(
            name: "WSDesignSystem",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 全部界面。
        .target(
            name: "WSFeatures",
            dependencies: ["WSCore", "WSVault", "WSDesignSystem"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "WSCoreTests", dependencies: ["WSCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "WSCryptoTests", dependencies: ["WSCrypto"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "WSVaultTests", dependencies: ["WSVault", "WSCore"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
