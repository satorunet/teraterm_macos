// swift-tools-version:5.5
// Tera Term SP (iPhone / iPad の試作版)。端末の中身 (TeraCore・鬼車・ファイル転送) は Mac 版と同じソース (Sources の中はリンク)。
// アプリは TeraSP.xcodeproj (scripts/gen-project.py が作る) がこのパッケージを読む。組み立て: ./scripts/build-sim.sh。SSH の部品は ./scripts/build-ssh-libs.sh が Vendor/ssh-<sim|device> に作る
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sshKind = ProcessInfo.processInfo.environment["TERASP_SSH_KIND"] ?? "sim"

let package = Package(
    name: "TeraSP",
    platforms: [.iOS(.v15), .macOS(.v10_14)],
    products: [
        .library(name: "TeraCore", targets: ["TeraCore"]),
        .library(name: "CSSH2", targets: ["CSSH2"]),
    ],
    targets: [
        .target(name: "COniguruma", path: "Sources/COniguruma",
                exclude: ["data", "COPYING"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("."), .headerSearchPath("data"), .define("HAVE_CONFIG_H"), .unsafeFlags(["-w"])]),
        .target(name: "CTeraFile", path: "Sources/CTeraFile",
                exclude: ["LICENSE"],
                sources: ["ttpfile", "glue"],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("compat"), .headerSearchPath("ttpfile"), .headerSearchPath("glue"), .unsafeFlags(["-w"])],
                cxxSettings: [.headerSearchPath("compat"), .headerSearchPath("ttpfile"), .headerSearchPath("glue"), .unsafeFlags(["-w"])],
                linkerSettings: [.linkedLibrary("iconv")]),
        .target(name: "TeraCore", dependencies: ["COniguruma", "CTeraFile"], path: "Sources/TeraCore"),
        // アプリの中の SSH (libssh2 BSD 3-Clause + OpenSSL 3 Apache 2.0)
        .target(name: "CSSH2", path: "Sources/CSSH2", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I" + root + "/Vendor/ssh-" + sshKind + "/include"])],
                linkerSettings: [.unsafeFlags([root + "/Vendor/ssh-" + sshKind + "/lib/libssh2.a", root + "/Vendor/ssh-" + sshKind + "/lib/libcrypto.a"])]),
    ]
)
