import XCTest
@testable import TeraCore

/// Tera Term のファイル転送プロトコル (CTeraFile) を 2 つの FileTransfer を背中合わせにつないで試す
final class FileTransferTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ftt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - helpers

    private func makeDir(_ name: String) -> URL {
        let u = tmp.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func allBytes() -> [UInt8] {
        // 全 256 値を 4 回 (1024 バイト)。制御文字・CAN・ZDLE・0xFF などを含む
        (0..<1024).map { UInt8($0 & 0xff) }
    }

    private func randomBytes(_ n: Int, seed: UInt64) -> [UInt8] {
        var x = seed
        return (0..<n).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: x >> 33)
        }
    }

    private struct Result {
        var sendOK: Bool?
        var recvOK: Bool?
        var sentBytes = 0
    }

    /// sender → receiver のループバック。データは非同期 (同じシリアルキュー) で相手の feed へ渡す
    private func loopback(send sendKind: FileTransferKind, recv recvKind: FileTransferKind,
                          file: URL, recvFiles: [String] = [], recvDir: URL,
                          options: FileTransferOptions = FileTransferOptions(),
                          recvOptions: FileTransferOptions? = nil,
                          timeout: TimeInterval = 15,
                          corrupt: ((inout [UInt8]) -> Void)? = nil) -> Result {
        let queue = DispatchQueue(label: "ftt.loopback")
        var result = Result()
        let done = expectation(description: "both finished")
        done.expectedFulfillmentCount = 2
        var sender: FileTransfer!
        var receiver: FileTransfer!
        queue.sync {
            sender = FileTransfer(kind: sendKind, files: [file.path], receiveDir: file.deletingLastPathComponent().path,
                                  options: options, queue: queue) { bytes in
                var b = bytes
                corrupt?(&b)
                queue.async { receiver?.feed(b) }
            }
            receiver = FileTransfer(kind: recvKind, files: recvFiles, receiveDir: recvDir.path,
                                    options: recvOptions ?? options, queue: queue) { bytes in
                queue.async { sender?.feed(bytes) }
            }
            sender.onFinish = { ok in result.sendOK = ok; result.sentBytes = sender.progress.byteCount; done.fulfill() }
            receiver.onFinish = { ok in result.recvOK = ok; done.fulfill() }
            XCTAssertTrue(sender.start(), "sender start")
            XCTAssertTrue(receiver.start(), "receiver start")
        }
        wait(for: [done], timeout: timeout)
        queue.sync {
            if sender.isRunning { sender.abort() }
            if receiver.isRunning { receiver.abort() }
        }
        return result
    }

    private func write(_ bytes: [UInt8], _ name: String, in dir: URL) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try Data(bytes).write(to: u)
        return u
    }

    private func read(_ u: URL) -> [UInt8] {
        (try? [UInt8](Data(contentsOf: u))) ?? []
    }

    /// 送受信が成功し、受信ファイルが同一であることを確かめる
    private func checkPair(_ s: FileTransferKind, _ r: FileTransferKind, data: [UInt8], name: String,
                           options: FileTransferOptions = FileTransferOptions(),
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let src = makeDir("src-\(name)"), dst = makeDir("dst-\(name)")
        let f = try write(data, name, in: src)
        let res = loopback(send: s, recv: r, file: f, recvDir: dst, options: options)
        XCTAssertEqual(res.sendOK, true, "\(s) success", file: file, line: line)
        XCTAssertEqual(res.recvOK, true, "\(r) success", file: file, line: line)
        let got = read(dst.appendingPathComponent(name))
        XCTAssertEqual(got.count, data.count, "size", file: file, line: line)
        XCTAssertTrue(got == data, "content of \(name)", file: file, line: line)
    }

    // MARK: - XMODEM

    private func checkXmodem(data: [UInt8], sendOpt: Int, recvOpt: Int, name: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let src = makeDir("src-\(name)"), dst = makeDir("dst-\(name)")
        let f = try write(data, name, in: src)
        var so = FileTransferOptions()
        so.applyMacroParameters(kind: .xmodemSend, xmodemOption: sendOpt)
        var ro = FileTransferOptions()
        ro.applyMacroParameters(kind: .xmodemRecv, binaryFlag: 1, xmodemOption: recvOpt)
        let res = loopback(send: .xmodemSend, recv: .xmodemRecv, file: f, recvFiles: [name], recvDir: dst,
                           options: so, recvOptions: ro)
        XCTAssertEqual(res.sendOK, true, "send", file: file, line: line)
        XCTAssertEqual(res.recvOK, true, "recv", file: file, line: line)
        let got = read(dst.appendingPathComponent(name))
        // XMODEM はブロック長まで 0x1A で埋める
        XCTAssertGreaterThanOrEqual(got.count, data.count, file: file, line: line)
        XCTAssertTrue(Array(got.prefix(data.count)) == data, "content", file: file, line: line)
        XCTAssertTrue(got.dropFirst(data.count).allSatisfy { $0 == 0x1a }, "padding", file: file, line: line)
        XCTAssertLessThan(got.count - data.count, 1024, file: file, line: line)
    }

    func testXmodemCRC() throws {
        try checkXmodem(data: allBytes(), sendOpt: XmodemOption.crc, recvOpt: XmodemOption.crc, name: "x_all.bin")
    }

    func testXmodemChecksum() throws {
        try checkXmodem(data: allBytes(), sendOpt: XmodemOption.crc, recvOpt: XmodemOption.check, name: "x_sum.bin")
    }

    func testXmodem1kRandom() throws {
        try checkXmodem(data: randomBytes(100 * 1024, seed: 1), sendOpt: XmodemOption.oneKCRC,
                        recvOpt: XmodemOption.oneKCRC, name: "x_1k.bin")
    }

    func testXmodemPadding() throws {
        try checkXmodem(data: randomBytes(1000, seed: 2), sendOpt: XmodemOption.crc, recvOpt: XmodemOption.crc,
                        name: "x_pad.bin")
    }

    func testXmodemTextModeConvertsLF() throws {
        let src = makeDir("src-xt"), dst = makeDir("dst-xt")
        let text = Array("abc\ndef\r\nghi\n".utf8)
        let f = try write(text, "t.txt", in: src)
        var so = FileTransferOptions()
        so.applyMacroParameters(kind: .xmodemSend, xmodemOption: 2)
        var ro = FileTransferOptions()
        ro.applyMacroParameters(kind: .xmodemRecv, binaryFlag: 0, xmodemOption: 2)
        XCTAssertFalse(ro.xmodemBin)
        let res = loopback(send: .xmodemSend, recv: .xmodemRecv, file: f, recvFiles: ["t.txt"], recvDir: dst,
                           options: so, recvOptions: ro)
        XCTAssertEqual(res.sendOK, true)
        XCTAssertEqual(res.recvOK, true)
        XCTAssertEqual(String(decoding: read(dst.appendingPathComponent("t.txt")), as: UTF8.self), "abc\r\ndef\r\nghi\r\n")
    }

    // MARK: - YMODEM / ZMODEM

    func testYmodemAllBytes() throws {
        try checkPair(.ymodemSend, .ymodemRecv, data: allBytes(), name: "y_all.bin")
    }

    func testYmodemRandom() throws {
        try checkPair(.ymodemSend, .ymodemRecv, data: randomBytes(100 * 1024 + 77, seed: 3), name: "y_rand.bin")
    }

    func testZmodemAllBytes() throws {
        try checkPair(.zmodemSend, .zmodemRecv, data: allBytes(), name: "z_all.bin")
    }

    func testZmodemRandom() throws {
        try checkPair(.zmodemSend, .zmodemRecv, data: randomBytes(100 * 1024 + 77, seed: 4), name: "z_rand.bin")
    }

    func testZmodemEscCtl() throws {
        var o = FileTransferOptions()
        o.zmodemEscCtl = true
        try checkPair(.zmodemSend, .zmodemRecv, data: allBytes(), name: "z_esc.bin", options: o)
    }

    func testYmodemEmptyFile() throws {
        try checkPair(.ymodemSend, .ymodemRecv, data: [], name: "y_empty.bin")
    }

    func testZmodemLogFile() throws {
        let logDir = makeDir("zlog")
        var o = FileTransferOptions()
        o.zmodemLog = true
        o.logDirectory = logDir.path
        try checkPair(.zmodemSend, .zmodemRecv, data: allBytes(), name: "z_log.bin", options: o)
        let log = String(decoding: read(logDir.appendingPathComponent("ZMODEM.LOG")), as: UTF8.self)
        XCTAssertTrue(log.contains("ZRQINIT"))
        XCTAssertTrue(log.contains("ZFIN"))
    }

    // MARK: - Kermit

    func testKermitAllBytes() throws {
        try checkPair(.kermitSend, .kermitRecv, data: allBytes(), name: "k_all.bin")
    }

    func testKermitRandom() throws {
        try checkPair(.kermitSend, .kermitRecv, data: randomBytes(100 * 1024 + 77, seed: 5), name: "k_rand.bin")
    }

    func testKermitLongPacketAttr() throws {
        var o = FileTransferOptions()
        o.kermitLongPacket = true
        o.kermitFileAttr = true
        try checkPair(.kermitSend, .kermitRecv, data: randomBytes(50 * 1024 + 3, seed: 6), name: "k_long.bin", options: o)
    }

    // MARK: - B-Plus / Quick-VAN

    // B-Plus は CompuServe のホストが主導するプロトコルで、Tera Term 同士では始まらない
    // (どちらも端末側でホストの DLE B を待つ)。そのためテスト側にホストを実装して試す。

    private func runBPlus(terminal kind: FileTransferKind, hostData: [UInt8], terminalFile: URL?, recvDir: URL,
                          name: String, crc: Bool) -> (ok: Bool?, host: BPlusHost) {
        let queue = DispatchQueue(label: "ftt.bplus")
        let done = expectation(description: "bplus")
        var ok: Bool?
        let host = BPlusHost(upload: kind == .bplusSend, fileName: name, data: hostData, crc: crc)
        var term: FileTransfer!
        queue.sync {
            host.send = { b in queue.async { term?.feed(b) } }
            var o = FileTransferOptions()
            // ttpfile/bplus.c の送信は bplussend に渡したファイルを使わず、ホストが 'TU' で要求した名前を
            // FileDir から GetReceiveFilename(unique = !OverWrite) で探す (Tera Term 本家と同じ挙動)。
            // AutoFileRename=on だと既存ファイルを避けた別名になって開けないので、送信テストでは off にする
            if kind == .bplusSend { o.autoFileRename = false }
            if let d = ProcessInfo.processInfo.environment["FTT_LOGDIR"] { o.bplusLog = true; o.logDirectory = d }
            term = FileTransfer(kind: kind, files: terminalFile.map { [$0.path] } ?? [], receiveDir: recvDir.path,
                                options: o, queue: queue) { b in queue.async { host.feed(b) } }
            term.onFinish = { ok = $0; done.fulfill() }
            XCTAssertTrue(term.start())
            host.start()
        }
        wait(for: [done], timeout: 30)
        queue.sync { if term.isRunning { term.abort() } }
        return (ok, host)
    }

    private func checkBPlusDownload(_ data: [UInt8], name: String, crc: Bool,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let dst = makeDir("bd-\(name)")
        let r = runBPlus(terminal: .bplusRecv, hostData: data, terminalFile: nil, recvDir: dst, name: name, crc: crc)
        XCTAssertEqual(r.ok, true, file: file, line: line)
        XCTAssertEqual(r.host.checkErrors, 0, file: file, line: line)
        XCTAssertTrue(read(dst.appendingPathComponent(name)) == data, "content", file: file, line: line)
    }

    private func checkBPlusUpload(_ data: [UInt8], name: String, crc: Bool,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let src = makeDir("bu-\(name)")
        let f = try write(data, name, in: src)
        let r = runBPlus(terminal: .bplusSend, hostData: [], terminalFile: f, recvDir: src, name: name, crc: crc)
        XCTAssertEqual(r.ok, true, file: file, line: line)
        XCTAssertEqual(r.host.checkErrors, 0, file: file, line: line)
        XCTAssertTrue(r.host.received == data, "content", file: file, line: line)
        XCTAssertTrue(r.host.closed, file: file, line: line)
    }

    func testBPlusRecvAllBytes() {
        checkBPlusDownload(allBytes(), name: "b_all.bin", crc: false)
        checkBPlusDownload(allBytes(), name: "b_allc.bin", crc: true)
    }

    func testBPlusRecvRandom() {
        checkBPlusDownload(randomBytes(100 * 1024 + 77, seed: 7), name: "b_rand.bin", crc: true)
    }

    func testBPlusSendAllBytes() throws {
        try checkBPlusUpload(allBytes(), name: "bs_all.bin", crc: false)
        try checkBPlusUpload(allBytes(), name: "bs_allc.bin", crc: true)
    }

    /// Tera Term 本家と同じく、AutoFileRename=on (既定) では bplussend がファイルを開けず失敗する
    func testBPlusSendDefaultOptionsFailsLikeWindows() throws {
        let src = makeDir("bq")
        let f = try write(allBytes(), "bq.bin", in: src)
        let queue = DispatchQueue(label: "ftt.bq")
        let done = expectation(description: "bq")
        var ok: Bool?
        let host = BPlusHost(upload: true, fileName: "bq.bin", data: [], crc: true)
        var term: FileTransfer!
        queue.sync {
            host.send = { b in queue.async { term?.feed(b) } }
            term = FileTransfer(kind: .bplusSend, files: [f.path], receiveDir: src.path, queue: queue) { b in
                queue.async { host.feed(b) }
            }
            term.onFinish = { ok = $0; done.fulfill() }
            XCTAssertTrue(term.start())
            host.start()
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(ok, false)
        XCTAssertTrue(host.received.isEmpty)
    }

    func testBPlusSendRandom() throws {
        try checkBPlusUpload(randomBytes(100 * 1024 + 77, seed: 11), name: "bs_rand.bin", crc: true)
    }

    func testQuickVANAllBytes() throws {
        try checkPair(.quickvanSend, .quickvanRecv, data: allBytes(), name: "q_all.bin")
    }

    func testQuickVANRandom() throws {
        try checkPair(.quickvanSend, .quickvanRecv, data: randomBytes(100 * 1024 + 77, seed: 8), name: "q_rand.bin")
    }

    // MARK: - misc

    func testSendMissingFileFailsToStart() {
        // XMODEM / YMODEM / B-Plus / Quick-VAN は Init でファイルを開くので開始に失敗する
        // (ZMODEM / Kermit は Windows 版と同じく開始後に開く)
        let t = FileTransfer(kind: .xmodemSend, files: [tmp.appendingPathComponent("nope").path],
                             receiveDir: tmp.path, queue: .main) { _ in }
        var finished = false
        t.onFinish = { _ in finished = true }
        XCTAssertFalse(t.start())
        XCTAssertFalse(t.isRunning)
        XCTAssertFalse(finished)
    }

    func testRelativePathUsesReceiveDir() throws {
        let src = makeDir("rel"), dst = makeDir("rel-dst")
        let data = randomBytes(3000, seed: 9)
        _ = try write(data, "r.bin", in: src)
        let queue = DispatchQueue(label: "ftt.rel")
        let done = expectation(description: "done")
        done.expectedFulfillmentCount = 2
        var s: FileTransfer!, r: FileTransfer!
        queue.sync {
            s = FileTransfer(kind: .zmodemSend, files: ["r.bin"], receiveDir: src.path, queue: queue) { b in queue.async { r.feed(b) } }
            r = FileTransfer(kind: .zmodemRecv, files: [], receiveDir: dst.path, queue: queue) { b in queue.async { s.feed(b) } }
            XCTAssertEqual(s.files, [src.appendingPathComponent("r.bin").path])
            s.onFinish = { XCTAssertTrue($0); done.fulfill() }
            r.onFinish = { XCTAssertTrue($0); done.fulfill() }
            XCTAssertTrue(s.start())
            XCTAssertTrue(r.start())
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(read(dst.appendingPathComponent("r.bin")), data)
    }

    func testAutoFileRename() throws {
        let src = makeDir("ren"), dst = makeDir("ren-dst")
        let data = allBytes()
        let f = try write(data, "a.bin", in: src)
        _ = try write([1, 2, 3], "a.bin", in: dst)
        let res = loopback(send: .zmodemSend, recv: .zmodemRecv, file: f, recvDir: dst)
        XCTAssertEqual(res.recvOK, true)
        XCTAssertEqual(read(dst.appendingPathComponent("a.bin")), [1, 2, 3])
        XCTAssertEqual(read(dst.appendingPathComponent("a1.bin")), data)
    }

    func testCancelZmodemSend() throws {
        let src = makeDir("cs"), dst = makeDir("cs-dst")
        let f = try write(randomBytes(400 * 1024, seed: 10), "c.bin", in: src)
        let queue = DispatchQueue(label: "ftt.cancel")
        let done = expectation(description: "done")
        done.expectedFulfillmentCount = 2
        var s: FileTransfer!, r: FileTransfer!
        var results: [Bool] = []
        queue.sync {
            s = FileTransfer(kind: .zmodemSend, files: [f.path], receiveDir: src.path, queue: queue) { b in queue.async { r.feed(b) } }
            r = FileTransfer(kind: .zmodemRecv, files: [], receiveDir: dst.path, queue: queue) { b in queue.async { s.feed(b) } }
            s.onFinish = { results.append($0); done.fulfill() }
            r.onFinish = { results.append($0); done.fulfill() }
            var cancelled = false
            r.onProgress = { p in
                if !cancelled && p.byteCount > 32 * 1024 { cancelled = true; r.cancel() }
            }
            XCTAssertTrue(s.start())
            XCTAssertTrue(r.start())
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(results, [false, false])
    }

    func testMacroXmodemOptionMapping() {
        // TERATERM.INI 既定 XmodemOpt=checksum
        var o = FileTransferOptions()
        XCTAssertEqual(o.xmodemOpt, XmodemOption.check)
        o.applyMacroParameters(kind: .xmodemRecv, binaryFlag: 1, xmodemOption: 3)
        XCTAssertEqual(o.xmodemOpt, XmodemOption.crc)       // 1k は受信側では CRC 扱い
        XCTAssertTrue(o.xmodemBin)
        o.applyMacroParameters(kind: .xmodemSend, xmodemOption: 3)
        XCTAssertEqual(o.xmodemOpt, XmodemOption.oneKCRC)
        o.applyMacroParameters(kind: .xmodemRecv, binaryFlag: 0, xmodemOption: 1)
        XCTAssertEqual(o.xmodemOpt, XmodemOption.oneKCksum) // ts.XmodemOpt の 1k は保持される
        XCTAssertFalse(o.xmodemBin)
        o.applyMacroParameters(kind: .xmodemSend, xmodemOption: 1)
        XCTAssertEqual(o.xmodemOpt, XmodemOption.check)
        // zmodemsend: 呼ばれた時点の XmodemBin を使い、引数は次回に効く (Windows 版と同じ)
        o.applyMacroParameters(kind: .zmodemSend, binaryFlag: 1)
        XCTAssertEqual(o.zmodemBinary, false)
        XCTAssertTrue(o.xmodemBin)
    }

    func testIniOptions() {
        let ini = IniFile(text: "[Tera Term]\nXmodemOpt=1k\nXmodemBin=off\nZmodemTimeouts=5,1,7,2\nAutoFileRename=off\nKmtLongPacket=on\n")
        let o = FileTransferOptions(ini: ini)
        XCTAssertEqual(o.xmodemOpt, XmodemOption.oneKCRC)
        XCTAssertFalse(o.xmodemBin)
        XCTAssertEqual(o.zmodemTimeOutNormal, 5)
        XCTAssertEqual(o.zmodemTimeOutTCPIP, 1)
        XCTAssertEqual(o.zmodemTimeOutInit, 7)
        XCTAssertEqual(o.zmodemTimeOutFin, 2)
        XCTAssertFalse(o.autoFileRename)
        XCTAssertTrue(o.kermitLongPacket)
    }
}

/// B-Plus のホスト側 (CompuServe) の最小実装。テスト専用。
/// upload = true: 端末からのアップロード (端末 bplussend) を受ける / false: 端末へダウンロード (bplusrecv)
final class BPlusHost {
    var send: (([UInt8]) -> Void)?
    private(set) var received: [UInt8] = []
    private(set) var closed = false
    private(set) var checkErrors = 0

    private let upload: Bool
    private let fileName: String
    private let data: [UInt8]
    private let useCRC: Bool
    private var cm = 0           // 0 = checksum, 1 = CRC (パラメータ交換後)
    private var seq = 0          // 最後に使われた (送受信) シーケンス番号
    private var waitingAck: Int?
    private var lastPacket: [UInt8] = []
    private var dataPos = 0
    private var step = 0         // 0: '+' 待ち, 1: 端末 '+' 受信済み, 2: T 送信済み, 3: データ, 4: TC 送信済み

    // 受信パーサ
    private enum RState { case idle, dle, pkt, check }
    private var rs = RState.idle
    private var quoted = false
    private var pkt: [UInt8] = []
    private var checkBytes: [UInt8] = []
    private var pktCM = 0

    init(upload: Bool, fileName: String, data: [UInt8], crc: Bool) {
        self.upload = upload
        self.fileName = fileName
        self.data = data
        self.useCRC = crc
    }

    func start() {
        // Transport parameters: WS WR BS CM DQ TL Q1-8 DR UR FI
        var p: [UInt8] = [1, 1, 16, useCRC ? 1 : 0, 1, 0]
        p += [UInt8](repeating: 0xff, count: 8)
        p += [0, 0, 0]
        sendPacket(UInt8(ascii: "+"), p)
        // 端末は '+' に ACK せず自分の '+' で答える
        seq = waitingAck ?? 0
        waitingAck = nil
    }

    private func nextSeq() -> Int { (seq + 1) % 10 }

    private func quote(_ b: UInt8, into out: inout [UInt8]) {
        if b <= 0x1f { out += [0x10, b + 0x40] }
        else if b >= 0x80 && b <= 0x9f { out += [0x10, b - 0x20] }
        else { out.append(b) }
    }

    private func check(_ bytes: [UInt8], cm: Int) -> [UInt8] {
        if cm == 1 {
            var crc: UInt16 = 0xffff
            for b in bytes {
                crc ^= UInt16(b) << 8
                for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
            }
            return [UInt8(crc >> 8), UInt8(crc & 0xff)]
        }
        var w: UInt16 = 0
        for b in bytes {
            w <<= 1
            if w > 0xff { w = (w & 0xff) + 1 }
            w += UInt16(b)
            if w > 0xff { w = (w & 0xff) + 1 }
        }
        return [UInt8(w)]
    }

    private func sendPacket(_ type: UInt8, _ payload: [UInt8]) {
        let s = nextSeq()
        let body: [UInt8] = [UInt8(0x30 + s), type] + payload + [0x03]
        var out: [UInt8] = [0x10, UInt8(ascii: "B"), body[0], type]
        for b in payload { quote(b, into: &out) }
        out.append(0x03)
        for b in check(body, cm: cm) { quote(b, into: &out) }
        waitingAck = s
        lastPacket = out
        send?(out)
    }

    private func sendAck(_ s: Int) { send?([0x10, UInt8(0x30 + s)]) }

    private func ackReceived(_ s: Int) {
        guard let w = waitingAck, w == s else { return }
        waitingAck = nil
        seq = s
        advance()
    }

    /// ACK を受けたので次を送る
    private func advance() {
        switch step {
        case 1:
            // 端末の '+' に ACK した後に T パケット
            step = 2
            let t: [UInt8] = [UInt8(ascii: upload ? "U" : "D"), UInt8(ascii: "B")] + Array(fileName.utf8)
            sendPacket(UInt8(ascii: "T"), t)
        case 2, 3:
            if upload { return }   // 端末が N を送ってくる
            step = 3
            if dataPos < data.count {
                let n = min(16 * 128 - 1, data.count - dataPos)
                let chunk = Array(data[dataPos..<dataPos + n])
                dataPos += n
                sendPacket(UInt8(ascii: "N"), chunk)
            } else {
                step = 4
                sendPacket(UInt8(ascii: "T"), [UInt8(ascii: "C")])
            }
        case 4:
            closed = true
        default:
            break
        }
    }

    private func packetReceived(_ p: [UInt8]) {
        guard p.count >= 3 else { return }
        let expect = check(p, cm: pktCM)
        if expect != checkBytes { checkErrors += 1; send?([0x15]); return }
        let s = Int(p[0]) - 0x30
        guard s == nextSeq() else { sendAck(seq); return }
        seq = s
        let type = p[1]
        let payload = Array(p[2..<(p.count - 1)])   // ETX を除く
        switch type {
        case UInt8(ascii: "+"):
            // 端末のパラメータ: 以降は合意した CM
            cm = Int(payload.count > 3 ? payload[3] : 0)
            step = 1
            sendAck(s)
            advance()
        case UInt8(ascii: "N"):
            received += payload
            sendAck(s)
        case UInt8(ascii: "T"):
            if payload.first == UInt8(ascii: "C") { closed = true }
            sendAck(s)
        case UInt8(ascii: "F"):
            checkErrors += 100
            sendAck(s)
        default:
            sendAck(s)
        }
    }

    func feed(_ bytes: [UInt8]) {
        for b in bytes {
            switch rs {
            case .idle:
                if b == 0x10 { rs = .dle }
                else if b == 0x15 || b == 0x05 { send?(lastPacket) }   // NAK / ENQ → 再送
            case .dle:
                if b == UInt8(ascii: "B") {
                    rs = .pkt; pkt = []; quoted = false
                    pktCM = cm
                } else if b >= 0x30 && b <= 0x39 {
                    rs = .idle
                    ackReceived(Int(b) - 0x30)
                } else { rs = .idle }
            case .pkt:
                if quoted {
                    quoted = false
                    pkt.append(b >= 0x40 && b <= 0x5f ? b - 0x40 : (b >= 0x60 && b <= 0x7f ? b + 0x20 : b))
                } else if b == 0x10 { quoted = true }
                else if b == 0x03 { pkt.append(b); rs = .check; checkBytes = [] }
                else { pkt.append(b) }
            case .check:
                if quoted {
                    quoted = false
                    checkBytes.append(b >= 0x40 && b <= 0x5f ? b - 0x40 : (b >= 0x60 && b <= 0x7f ? b + 0x20 : b))
                } else if b == 0x10 { quoted = true; continue }
                else { checkBytes.append(b) }
                if checkBytes.count == (pktCM == 1 ? 2 : 1) {
                    rs = .idle
                    packetReceived(pkt)
                }
            }
        }
    }
}
