import AppKit
import TeraCore

/// ファイル転送の進み具合 (Windows 版の転送ダイアログ CProtoDlg にあたる)。Cancel / Esc で転送を中断する。
/// 転送の案内は端末に出さない (マクロの wait やログに入らないように)
final class TransferProgressPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let protoLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    var onCancel: (() -> Void)?

    func show(title: String, over parent: NSWindow?) {
        let p = panel ?? makePanel()
        panel = p
        p.title = "Tera Term: \(title)"
        protoLabel.stringValue = ""
        fileLabel.stringValue = ""
        countLabel.stringValue = ""
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        if let w = parent {
            let f = w.frame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
            if p.parent == nil { w.addChildWindow(p, ordered: .above) }
        }
        p.orderFront(nil)
    }

    func update(_ pr: FileTransferProgress) {
        protoLabel.stringValue = pr.protocolText
        if let f = pr.fileName { fileLabel.stringValue = f }
        var t = Lang.m("XFER_BYTES", "%d バイト", pr.byteCount)
        if pr.packetNumber > 0 { t += "  " + Lang.m("XFER_PACKET", "パケット %d", pr.packetNumber) }
        if pr.elapsed > 0 { t += "  " + Lang.m("XFER_SECONDS", "%d 秒", Int(pr.elapsed.rounded())) }
        countLabel.stringValue = t
        if let pc = pr.percent, pr.totalBytes != nil {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = min(100, max(0, pc))
        }
    }

    /// 自由な内容で表示する (SCP・ファイル送信用)。percent が nil なら進み具合不明の表示
    func set(proto: String, file: String?, detail: String, percent: Double?) {
        protoLabel.stringValue = proto
        if let f = file { fileLabel.stringValue = f }
        countLabel.stringValue = detail
        if let pc = percent {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.doubleValue = min(100, max(0, pc))
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    func close() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
                        styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.delegate = self
        let v = NSView(frame: p.contentRect(forFrameRect: p.frame))
        for l in [protoLabel, fileLabel, countLabel] {
            l.lineBreakMode = .byTruncatingMiddle
            l.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(l)
        }
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bar)
        let cancel = NSButton(title: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(cancel)
        NSLayoutConstraint.activate([
            protoLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            protoLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            protoLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            fileLabel.topAnchor.constraint(equalTo: protoLabel.bottomAnchor, constant: 4),
            fileLabel.leadingAnchor.constraint(equalTo: protoLabel.leadingAnchor),
            fileLabel.trailingAnchor.constraint(equalTo: protoLabel.trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 4),
            countLabel.leadingAnchor.constraint(equalTo: protoLabel.leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: protoLabel.trailingAnchor),
            bar.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: protoLabel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: protoLabel.trailingAnchor),
            cancel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            cancel.trailingAnchor.constraint(equalTo: protoLabel.trailingAnchor),
        ])
        p.contentView = v
        return p
    }

    @objc private func cancelPressed(_ sender: Any?) { onCancel?() }
}

/// sendfile の送信 (SendMemContinuously): チャンクを送り、チャンクの間で SendfileDelayTick 待つ
final class SendFileJob {
    private let plan: SendFilePlan
    private let send: (SendFilePlan.Chunk) -> Void
    private var index = 0
    private var done = false
    var onFinish: (() -> Void)?
    /// 送ったバイト数と全体のバイト数
    var onProgress: ((Int, Int) -> Void)?
    private lazy var sizes: [Int] = plan.chunks.map {
        switch $0 { case .text(let t): return t.utf8.count; case .binary(let b): return b.count }
    }
    private var sentBytes = 0
    var totalBytes: Int { sizes.reduce(0, +) }

    init(plan: SendFilePlan, send: @escaping (SendFilePlan.Chunk) -> Void) {
        self.plan = plan
        self.send = send
    }

    func start() { step() }

    /// 残りを送らずに終える (切断・ウインドウを閉じたとき)
    func finish() {
        guard !done else { return }
        done = true
        onFinish?()
    }

    private func step() {
        while !done && index < plan.chunks.count {
            send(plan.chunks[index])
            sentBytes += sizes[index]
            index += 1
            onProgress?(sentBytes, totalBytes)
            if index < plan.chunks.count && plan.delayMs > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(plan.delayMs)) { [weak self] in self?.step() }
                return
            }
        }
        finish()
    }
}

/// scp を別プロセスで動かし、進み具合を読む (scp は端末につながっているときだけ進み具合を出すので疑似端末を使う)
final class ScpJob {
    private let process = Process()
    private var master: Int32 = -1
    private var source: DispatchSourceRead?
    private var buf = ""
    var onProgress: ((_ file: String, _ percent: Double, _ detail: String) -> Void)?
    var onFinish: ((Bool) -> Void)?

    init(arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = arguments
    }

    func start() -> Bool {
        var m: Int32 = -1, sl: Int32 = -1
        var ws = winsize(ws_row: 24, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &sl, nil, nil, &ws) == 0 else { return false }
        master = m
        let slave = FileHandle(fileDescriptor: sl, closeOnDealloc: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = slave
        process.standardError = slave
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.finished(p.terminationStatus == 0) }
        }
        do { try process.run() } catch { close(m); return false }
        try? slave.close()
        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: .main)
        src.setEventHandler { [weak self] in self?.readOutput() }
        source = src
        src.resume()
        return true
    }

    func cancel() { if process.isRunning { process.terminate() } }

    private func readOutput() {
        var b = [UInt8](repeating: 0, count: 4096)
        let n = read(master, &b, b.count)
        guard n > 0 else { return }
        buf += String(decoding: b[0..<n], as: UTF8.self)
        // scp の進み具合は "名前   37%  123KB 120.5KB/s   00:03 ETA" を CR で上書きしていく
        let parts = buf.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        buf = parts.last ?? ""
        for line in parts.dropLast() { parse(line) }
        parse(buf)
    }

    private func parse(_ line: String) {
        let pattern = "^(.*?)\\s+(\\d+)%\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return }
        func g(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
        let pc = Double(g(2)) ?? 0
        onProgress?(g(1).trimmingCharacters(in: .whitespaces), pc, "\(g(3))  \(g(4))  " + Lang.m("XFER_REMAINING", "残り %s", g(5)))

    }

    private func finished(_ ok: Bool) {
        source?.cancel()
        source = nil
        if master >= 0 { close(master); master = -1 }
        onFinish?(ok)
        onFinish = nil
    }
}
