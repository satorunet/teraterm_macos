import XCTest
@testable import TeraCore

/// Tera Term 本体の tests/*.ttl を画面なしで動かし、どの行でどんなエラーになったかを一覧にする。
/// TERAMAC_UPSTREAM_REPORT=<file> を付けて動かしたときだけ実行する (対話や接続が要るものが多いため)
final class TTLUpstreamTests: XCTestCase {
    final class Host: TTLHost {
        var log: [String] = []
        func ttlSend(_ bytes: [UInt8], mode: TTLSendMode) { log.append("send \(String(decoding: bytes, as: UTF8.self).debugDescription)") }
        func ttlMessageBox(_ text: String, title: String) -> Bool { log.append("msg [\(title)] \(text)"); return true }
        func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? { log.append("input [\(title)] \(text)"); return "input" }
        func ttlYesNoBox(_ text: String, title: String) -> Int { log.append("yesno [\(title)] \(text)"); return 1 }
        func ttlListBox(_ text: String, title: String, items: [String], selected: Int, options: TTLListBoxOptions) -> Int { log.append("list \(items)"); return selected }
        func ttlStatusBox(_ text: String, title: String) { log.append("status [\(title)] \(text)") }
        func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool {
            log.append("ERROR \(line): \(message) | \(lineText)")
            return false   // 「続ける」
        }
    }

    func testUpstreamMacros() throws {
        guard let out = ProcessInfo.processInfo.environment["TERAMAC_UPSTREAM_REPORT"] else { throw XCTSkip("TERAMAC_UPSTREAM_REPORT not set") }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tests").standardized
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".ttl") }.sorted()
        var report = ""
        for f in files {
            let host = Host()
            let path = dir.appendingPathComponent(f).path
            var status = "ok"
            do {
                let i = try TTLInterpreter(path: path, host: host, params: ["p2", "p3"])
                let done = DispatchSemaphore(value: 0)
                Thread.detachNewThread {
                    do { try i.run() } catch { status = "throw \(error)" }
                    done.signal()
                }
                if done.wait(timeout: .now() + 8) == .timedOut { i.cancelled = true; _ = done.wait(timeout: .now() + 2); status = "timeout (waiting)" }
            } catch {
                status = "load error \(error)"
            }
            report += "=== \(f): \(status)\n" + host.log.prefix(40).map { "  " + $0 }.joined(separator: "\n") + "\n"
        }
        try report.write(toFile: out, atomically: true, encoding: .utf8)
    }
}
