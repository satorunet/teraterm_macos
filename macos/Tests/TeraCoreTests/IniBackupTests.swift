import XCTest
@testable import TeraCore

/// TERATERM.INI のバックアップ (CreateBakupFile) と loginfo の表示状態 (FLogInfo)
final class IniBackupTests: XCTestCase {
    func testBackupName() {
        // 2021-12-04 23:12:34 +0900 → 20211204T231234+0900_TERATERM.INI (MakeISO8601Str の %Y%m%dT%H%M%S%z)
        let tz = TimeZone(secondsFromGMT: 9 * 3600)!
        var c = DateComponents()
        c.year = 2021; c.month = 12; c.day = 4; c.hour = 23; c.minute = 12; c.second = 34
        c.timeZone = tz
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(IniBackup.backupPath(for: "/a/b/TERATERM.INI", date: d, timeZone: tz), "/a/b/20211204T231234+0900_TERATERM.INI")
        XCTAssertEqual(IniBackup.backupPath(for: "/a/b/TERATERM.INI", prefix: "bak_"), "/a/b/bak_TERATERM.INI")
    }

    func testCreateDoesNotOverwrite() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("inibak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ini = (dir as NSString).appendingPathComponent("TERATERM.INI")
        XCTAssertNil(IniBackup.create(for: ini))   // ファイルがなければ作らない
        try "[Tera Term]\nA=1\n".write(toFile: ini, atomically: true, encoding: .utf8)
        let d = Date()
        let bak = try XCTUnwrap(IniBackup.create(for: ini, date: d))
        XCTAssertEqual(try String(contentsOfFile: bak, encoding: .utf8), "[Tera Term]\nA=1\n")
        try "[Tera Term]\nA=2\n".write(toFile: ini, atomically: true, encoding: .utf8)
        XCTAssertNil(IniBackup.create(for: ini, date: d))   // CopyFileW(..., TRUE): 同名があれば上書きしない
        XCTAssertEqual(try String(contentsOfFile: bak, encoding: .utf8), "[Tera Term]\nA=1\n")
    }

    func testLogInfoShowStateFlags() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("loginfo-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        for (state, flag) in [(0, 16), (1, 32), (2, 64)] {
            var o = TTLLogOptions()
            o.dialogShowState = state
            let l = try XCTUnwrap(TeraLog(path: path, options: o))
            XCTAssertEqual(l.infoFlags & (16 | 32 | 64), flag)
            l.close()
        }
    }
}
