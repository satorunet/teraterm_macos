// ログファイル (filesys_log.cpp の FLog* を移したもの)
// (Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project, BSD 3-Clause)

import Foundation

/// 1 つのログファイル。
/// テキストのログ (binary=0) は端末が出す「表示した文字」(エスケープシーケンスなし・改行を CR+LF にそろえた UTF-8。マクロに渡すものと同じ) を書く。
/// バイナリのログは受信したバイトをそのまま書く。
public final class TeraLog {
    /// テキストのログの文字コード (LogCode_t: LOG_UTF8 / LOG_UTF16LE / LOG_UTF16BE)
    public enum Code: Int { case utf8 = 0, utf16le, utf16be }

    public let path: String
    /// テキストのログの文字コード
    public let code: Code
    /// BOM を書く (新規・テキストのときだけ。ローテートで開き直したときも書く)
    public let bom: Bool
    /// FixLogOption のあとの値 (バイナリなら plainText / timestamp は off)
    public private(set) var options: TTLLogOptions
    public var paused = false
    /// 接続した時刻 (タイムスタンプの種類 3 用)
    public var connectedTime: Date
    public let startTime: Date

    // ローテート (ログごとに初期化される)
    private var rotateSize = 0       // 0 = しない
    private var rotateStep = 0       // 0 = 上限なし (loopmax 10000)
    /// 転送済容量 (ローテートで 0 に戻る)
    public private(set) var byteCount = 0
    /// UTF-16 にするとき、途中で切れた UTF-8 の残り
    private var pendingUTF8: [UInt8] = []

    private var handle: FileHandle?
    private var atLineHead = true

    public var isBinary: Bool { options.binary }

    /// FixLogOption
    public static func fixOptions(_ o: TTLLogOptions) -> TTLLogOptions {
        var o = o
        if o.binary { o.plainText = false; o.timestamp = false }
        return o
    }

    public init?(path: String, options: TTLLogOptions, code: Code = .utf8, bom: Bool = false,
                 connectedTime: Date = Date(), now: Date = Date()) {
        self.path = path
        self.options = TeraLog.fixOptions(options)
        self.code = code
        self.bom = bom
        self.connectedTime = connectedTime
        startTime = now
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) || !options.append {
            guard fm.createFile(atPath: path, contents: nil) else { return nil }
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        if options.append { h.seekToEndOfFile() } else { h.truncateFile(atOffset: 0) }
        handle = h
        // BOM出力: 追記ではない(新規) && バイナリではない && BOM を出力時
        if !options.append && !options.binary && bom { writeBOM() }
    }

    /// FLogOutputBOM
    private func writeBOM() {
        let b: [UInt8]
        switch code {
        case .utf8: b = [0xEF, 0xBB, 0xBF]
        case .utf16le: b = [0xFF, 0xFE]
        case .utf16be: b = [0xFE, 0xFF]
        }
        handle?.write(Data(b))
        byteCount += b.count
    }

    /// テキストのログ: UTF-8 を選んだ文字コードにする
    private func encodeText(_ utf8: [UInt8]) -> [UInt8] {
        guard code != .utf8 else { return utf8 }
        var src = pendingUTF8 + utf8
        pendingUTF8 = []
        // 末尾の途中で切れた UTF-8 は次に回す
        var i = src.count - 1
        var back = 0
        while i >= 0 && back < 4 && src[i] & 0xC0 == 0x80 { i -= 1; back += 1 }
        if i >= 0 {
            let lead = src[i]
            let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            if src.count - i < need {
                pendingUTF8 = Array(src[i...])
                src.removeSubrange(i...)
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(src.count * 2)
        for u in String(decoding: src, as: UTF8.self).utf16 {
            if code == .utf16le { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
            else { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
        }
        return out
    }

    deinit { handle?.closeFile() }

    public func close() {
        handle?.closeFile()
        handle = nil
    }

    /// loginfo の結果 (1 binary, 2 append, 4 plain text, 8 timestamp, 16 hide dialog)
    public var infoFlags: Int {
        (options.binary ? 1 : 0) | (options.append ? 2 : 0) | (options.plainText ? 4 : 0)
            | (options.timestamp ? 8 : 0) | (options.hideDialog ? 16 : 0)
    }

    // MARK: - 書く

    /// 端末が表示した文字 (テキストのログだけ)
    public func putText(_ utf8: [UInt8], now: Date = Date()) {
        guard !options.binary, !paused, handle != nil else { return }
        write(encodeText(textWithTimestamps(utf8, now: now)))
    }

    /// 受信したバイト (バイナリのログだけ)
    public func putBinary(_ bytes: [UInt8]) {
        guard options.binary, !paused, handle != nil else { return }
        write(bytes)
    }

    /// logwrite: 一時停止中でも書く。テキストならタイムスタンプも付ける。
    /// encoded はバイナリのログのとき書くもの (端末の文字コードにしたもの)
    public func writeString(_ utf8: [UInt8], encoded: [UInt8]? = nil, now: Date = Date()) {
        guard handle != nil else { return }
        if options.binary { write(encoded ?? utf8) } else { write(encodeText(textWithTimestamps(utf8, now: now))) }
    }

    private func textWithTimestamps(_ utf8: [UInt8], now: Date) -> [UInt8] {
        guard options.timestamp else { return utf8 }
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count + 32)
        var ts: [UInt8]?
        for b in utf8 {
            if atLineHead {
                atLineHead = false
                if ts == nil { ts = Array(timestampText(now: now).utf8) }
                out += ts!
            }
            out.append(b)
            if b == 0x0A { atLineHead = true }
        }
        return out
    }

    private func write(_ b: [UInt8]) {
        guard !b.isEmpty, let h = handle else { return }
        h.write(Data(b))
        byteCount += b.count
        rotateIfNeeded()
    }

    // MARK: - タイムスタンプ

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// FLogTimeStampStrW (LogTimestampFormat の既定 "%Y-%m-%d %H:%M:%S.%N")
    public func timestampText(now: Date = Date()) -> String {
        TeraLog.timestampText(type: options.timestampType, now: now, start: startTime, connected: connectedTime)
    }

    public static func timestampText(type: Int, now: Date, start: Date, connected: Date) -> String {
        let body: String
        switch type {
        case 1: body = utcFormatter.string(from: now)
        case 2, 3: body = elapsed(now.timeIntervalSince(type == 2 ? start : connected))
        default: body = localFormatter.string(from: now)
        }
        return "[\(body)] "
    }

    /// strelapsedW: "日 時:分:秒.ミリ秒"
    public static func elapsed(_ t: TimeInterval) -> String {
        let ms = max(0, Int(t * 1000))
        return String(format: "%d %02d:%02d:%02d.%03d", ms / 86_400_000, ms / 3_600_000 % 24, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    // MARK: - ローテート

    /// FLogOpen のローテートの設定 (ts.LogRotate / LogRotateSize (バイト) / LogRotateStep)。
    /// ローテートするときは、数え始めをいまのファイルの大きさにする (追記のとき)
    public func configureRotation(enabled: Bool, size: Int, step: Int) {
        guard enabled else { rotateSize = 0; rotateStep = 0; return }
        rotateSize = max(0, size)
        rotateStep = max(0, step)
        if let h = handle { byteCount = Int(h.offsetInFile) }
    }

    /// logrotate size N / rotate N / halt
    public func setRotate(_ command: String) {
        let p = command.split(separator: " ")
        switch p.first {
        case "size": rotateSize = Int(p.count > 1 ? p[1] : "") ?? 0
        case "rotate": rotateStep = Int(p.count > 1 ? p[1] : "") ?? 0
        case "halt": rotateSize = 0; rotateStep = 0
        default: break
        }
    }

    /// LogRotate: 大きさが N を超えたら path → path.1 → path.2 …
    private func rotateIfNeeded() {
        guard rotateSize > 0, byteCount > rotateSize else { return }
        byteCount = 0
        handle?.closeFile()
        let fm = FileManager.default
        let loopmax = rotateStep > 0 ? rotateStep : 10000
        var i = 1
        while i <= loopmax {
            if !fm.fileExists(atPath: "\(path).\(i)") { break }
            i += 1
        }
        if i > loopmax { i = loopmax }
        var k = i - 1
        while k >= 0 {
            let old = k == 0 ? path : "\(path).\(k)"
            let new = "\(path).\(k + 1)"
            try? fm.removeItem(atPath: new)
            try? fm.moveItem(atPath: old, toPath: new)
            k -= 1
        }
        fm.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        if !options.binary && bom { writeBOM() }
    }

    // MARK: - ファイル名 (FLogGetLogFilename)

    /// strftime で使える書式 (IsValidStrftimeCode)
    private static let strftimeChars = Set("aAbBcdHIjmMpSUwWxXyYzZ%")

    /// deleteInvalidStrftimeCharW: 使えない % 書式を消す
    public static func deleteInvalidStrftimeChars(_ s: String) -> String {
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            if c[i] == "%" {
                if i + 1 < c.count {
                    var p = i + 1
                    if i + 2 < c.count && c[i + 1] == "#" { p = i + 2 }
                    if strftimeChars.contains(c[p]) {
                        out += String(c[i...p])
                    }
                    i = p + 1
                } else {
                    i += 1   // % で終わっていたら捨てる
                }
            } else {
                out.append(c[i]); i += 1
            }
        }
        return out
    }

    /// Mac のファイル名に使えない文字 (/ と :) を置き換える
    public static func replaceInvalidFileNameChars(_ s: String, with r: Character = "_") -> String {
        String(s.map { $0 == "/" || $0 == ":" ? r : $0 })
    }

    /// &h (ホスト / シリアルポート名) &p (TCP のポート) &u (ログインユーザ名) を展開する (ConvertLognameW)
    public static func convertLogname(_ s: String, host: String?, port: Int?, user: String) -> String {
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            if c[i] == "&" && i + 1 < c.count {
                switch c[i + 1] {
                case "h": if let h = host { out += replaceInvalidFileNameChars(h) }; i += 2
                case "p": if let p = port { out += String(p) }; i += 2
                case "u": out += user; i += 2
                default: i += 1   // & だけ捨てる
                }
            } else {
                out.append(c[i]); i += 1
            }
        }
        return out
    }

    /// strftime (ローカル時刻)
    public static func strftime(_ format: String, date: Date) -> String {
        if format.isEmpty { return "" }
        var t = time_t(date.timeIntervalSince1970)
        var tmv = tm()
        localtime_r(&t, &tmv)
        var size = 256
        while size < 65536 {
            var buf = [Int8](repeating: 0, count: size)
            let n = Darwin.strftime(&buf, size, format, &tmv)
            if n > 0 { return String(cString: buf) }
            size *= 2
        }
        return ""
    }

    /// ログのファイル名を決める。
    /// 名前の部分に strftime と &h &p &u を展開し、使えない文字を _ にする。相対パスは logDir から
    public static func logFileName(_ name: String, logDir: String, host: String?, port: Int?,
                                   user: String = NSUserName(), date: Date = Date()) -> String {
        let expanded = (name as NSString).expandingTildeInPath
        let dir: String
        let file: String
        if expanded.hasPrefix("/") {
            dir = (expanded as NSString).deletingLastPathComponent
            file = (expanded as NSString).lastPathComponent
        } else {
            // 相対パス: ログのフォルダから (途中のフォルダは残す)
            let sub = (expanded as NSString).deletingLastPathComponent
            dir = sub.isEmpty ? logDir : (logDir as NSString).appendingPathComponent(sub)
            file = (expanded as NSString).lastPathComponent
        }
        let fmt = deleteInvalidStrftimeChars(file)
        if fmt.isEmpty { return (dir as NSString).appendingPathComponent("") }
        let timed = strftime(fmt, date: date)
        let named = replaceInvalidFileNameChars(convertLogname(timed, host: host, port: port, user: user))
        return ((dir as NSString).appendingPathComponent(named) as NSString).standardizingPath
    }
}
