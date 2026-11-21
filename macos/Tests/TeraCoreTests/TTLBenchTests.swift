import XCTest
@testable import TeraCore

final class TTLBenchTests: XCTestCase {
    /// 100 万回のループが数秒で終わること (Tera Term の tests/#35822-random.ttl は 1100 万回まわる)
    func testLoopSpeed() throws {
        #if DEBUG
        throw XCTSkip("速さはリリースビルドで測る (swift build -c release -Xswiftc -enable-testing --build-tests)")
        #endif
        let start = Date()
        let (_, i) = try runTTL("n = 0\nfor i 1 1000000\n  n = n + i % 7\nnext\n")
        let t = Date().timeIntervalSince(start)
        print("1M loop: \(t) s")
        XCTAssertEqual(i.variable("n"), .int(2999998))
        XCTAssertLessThan(t, 10)
    }
}
