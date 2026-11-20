import AppKit
import TeraCore

/// TTL マクロを別スレッドで動かし、端末とのやりとりをつなぐ
final class MacroRunner: TTLHost {
    private weak var session: SessionWindowController?
    private var interp: TTLInterpreter!
    private let cond = NSCondition()
    private var buffer = ""
    private var cancelled = false
    private let baseDir: URL

    init(source: String, session: SessionWindowController, baseDir: URL) throws {
        self.session = session
        self.baseDir = baseDir
        interp = try TTLInterpreter(source: source, host: self, baseDir: baseDir)
    }

    func start(done: @escaping (String?) -> Void) {
        Thread.detachNewThread { [self] in
            var err: String?
            do { try interp.run() } catch { err = "\(error)" }
            DispatchQueue.main.async { done(err) }
        }
    }

    func cancel() {
        cond.lock()
        cancelled = true
        interp.cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    /// 受信した文字列 (メインスレッドから)
    func received(_ s: String) {
        cond.lock()
        buffer += s
        if buffer.count > 1_000_000 { buffer = String(buffer.suffix(500_000)) }
        cond.broadcast()
        cond.unlock()
    }

    func connectionChanged() {
        cond.lock(); cond.broadcast(); cond.unlock()
    }

    private func onMain<T>(_ f: () -> T) -> T {
        if Thread.isMainThread { return f() }
        return DispatchQueue.main.sync(execute: f)
    }

    // MARK: - TTLHost

    func ttlSend(_ s: String) {
        DispatchQueue.main.async { self.session?.sendText(s) }
    }

    func ttlWait(_ strings: [String], timeout: Double) -> Int {
        let deadline = timeout > 0 ? Date(timeIntervalSinceNow: timeout) : Date.distantFuture
        cond.lock()
        defer { cond.unlock() }
        while !cancelled {
            var best: (Int, String.Index)?
            for (i, s) in strings.enumerated() where !s.isEmpty {
                if let r = buffer.range(of: s), best == nil || r.upperBound < best!.1 {
                    best = (i + 1, r.upperBound)
                }
            }
            if let (i, end) = best {
                buffer = String(buffer[end...])
                return i
            }
            if !cond.wait(until: deadline) { return 0 }
        }
        return 0
    }

    func ttlWaitLine(_ strings: [String], timeout: Double) -> (Int, String) {
        let deadline = timeout > 0 ? Date(timeIntervalSinceNow: timeout) : Date.distantFuture
        cond.lock()
        defer { cond.unlock() }
        while !cancelled {
            while let nl = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
                let line = String(buffer[..<nl]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                buffer = String(buffer[buffer.index(after: nl)...])
                for (i, s) in strings.enumerated() where line.contains(s) { return (i + 1, line) }
            }
            if !cond.wait(until: deadline) { return (0, "") }
        }
        return (0, "")
    }

    func ttlFlushRecv() {
        cond.lock(); buffer = ""; cond.unlock()
    }

    func ttlMessage(_ text: String, title: String) {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.runModal()
        }
    }

    func ttlInput(_ text: String, title: String, secret: Bool) -> String? {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            let f: NSTextField = secret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                                        : NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            a.accessoryView = f
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "キャンセル")
            a.window.initialFirstResponder = f
            return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
        }
    }

    func ttlYesNo(_ text: String, title: String) -> Bool {
        onMain {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.addButton(withTitle: "はい")
            a.addButton(withTitle: "いいえ")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    func ttlConnect(_ spec: String) -> Bool {
        guard let s = ConnectionSpec.parse(spec) else { return false }
        return onMain { session?.connect(s) ?? false }
    }

    func ttlDisconnect() { onMain { session?.disconnect() } }

    func ttlLogOpen(_ path: String) -> Bool {
        var p = (path as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = baseDir.appendingPathComponent(p).path }
        return onMain { session?.startLog(path: p) ?? false }
    }

    func ttlLogClose() { onMain { session?.stopLog() } }
    func ttlSetTitle(_ s: String) { onMain { session?.window?.title = s } }
    func ttlBeep() { onMain { NSSound.beep() } }
    func ttlSendBreak() { onMain { session?.sendBreak(nil) } }
    func ttlIsConnected() -> Bool { onMain { session?.isConnected ?? false } }
    func ttlStatus(_ s: String) { onMain { session?.setStatus(s) } }
    func ttlCloseWindow() {
        DispatchQueue.main.async {
            self.session?.disconnect(silent: true)
            self.session?.window?.close()
        }
    }
}
