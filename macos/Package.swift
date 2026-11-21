// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "TeraMac",
    platforms: [.macOS(.v11)],
    dependencies: [
        // 自動アップデート (MIT License)
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.6")),   // 2.10 からは macOS 12 以上になるので 2.9 系
    ],
    targets: [
        // 正規表現ライブラリ 鬼車 (Oniguruma 6.9.10, BSD 2-Clause)。Tera Term のマクロと同じ正規表現にするため
        .target(name: "COniguruma", path: "Sources/COniguruma",
                exclude: ["data", "COPYING"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .headerSearchPath("data"), .define("HAVE_CONFIG_H"),
                            .unsafeFlags(["-w"])]),
        // Tera Term のファイル転送プロトコル (ttpfile/ の XMODEM/YMODEM/ZMODEM/Kermit/B-Plus/Quick-VAN, BSD 3-Clause)
        .target(name: "CTeraFile", path: "Sources/CTeraFile",
                exclude: ["LICENSE"],
                sources: ["ttpfile", "glue"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("compat"), .headerSearchPath("ttpfile"), .headerSearchPath("glue"),
                            .unsafeFlags(["-w"])],
                cxxSettings: [.headerSearchPath("compat"), .headerSearchPath("ttpfile"), .headerSearchPath("glue"),
                              .unsafeFlags(["-w"])],
                linkerSettings: [.linkedLibrary("iconv")]),
        .target(name: "TeraCore", dependencies: ["COniguruma", "CTeraFile"], path: "Sources/TeraCore",
                swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release))]),
        .target(name: "TeraUninstall", path: "Sources/TeraUninstall"),
        .executableTarget(name: "TeraMac", dependencies: ["TeraCore", "TeraUninstall", .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/TeraMac",
                          // この Mac の SDK には Sparkle の見出しが使う NS_SWIFT_SENDABLE がないので空にする (注釈だけなので動きは変わらない)
                          swiftSettings: [.unsafeFlags(["-Xcc", "-DNS_SWIFT_SENDABLE="])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "TeraCoreTests", dependencies: ["TeraCore"], path: "Tests/TeraCoreTests"),
    ]
)
