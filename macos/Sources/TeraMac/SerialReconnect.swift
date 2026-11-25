import Foundation
import TeraCore

/// シリアルポートの自動再接続 (vtwin.cpp class SerialReconnect, 5.4.0 / #435 7041c68a2)。
/// Tera Term は WM_DEVICECHANGE (DBT_DEVICEREMOVECOMPLETE / DBT_DEVICEARRIVAL) で USB シリアルの抜き差しを知る。
/// Mac は /dev/cu.* を見張って、消えたあと戻ってきたら同じ設定で開き直す。
/// - AutoComPortReconnect: on のときだけ
/// - AutoComPortReconnectDelayNormal: ポートが戻ってから開くまで待つ (ミリ秒)
/// - AutoComPortReconnectDelayIllegal: 本家はポートの名前が分からない通知 (DBT_DEVTYP_DEVICEINTERFACE だけ) のときに
///   この時間待つ。Mac はいつもポートの名前 (/dev/cu.*) で分かるので使わない (設定としては読み書きする)
/// - AutoComPortReconnectRetryInterval / RetryCount: 開けなかったときに、この間隔でこの回数まで開き直す
final class SerialReconnect {
    enum State { case none, waitDevice, waitTimer, reconnecting }
    private(set) var state = State.none
    private var params: SerialParams?
    private var retryLeft = 0
    private var pollTimer: Timer?
    private var openTimer: Timer?
    /// 開き直している最中 (connect を呼んでいる間。ほかからの接続なら待つのをやめる)
    private(set) var opening = false
    weak var session: SessionWindowController?

    init(session: SessionWindowController) { self.session = session }

    var isWaiting: Bool { state != .none }

    /// 開いていたポートが閉じた (読めなくなった)。ポートが消えていたら戻るのを待つ (SetAutoConnectPort)
    func portClosed(_ p: SerialParams) {
        guard let s = session, s.settings.autoComPortReconnect, state == .none else { return }
        if FileManager.default.fileExists(atPath: p.path) {
            // 抜いた直後はまだ残っていることがある: 少しだけ待って、消えたら待ち始める
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.state == .none, self.session?.isConnected == false,
                      !FileManager.default.fileExists(atPath: p.path) else { return }
                self.startWaiting(p)
            }
            return
        }
        startWaiting(p)
    }

    private func startWaiting(_ p: SerialParams) {
        guard let s = session else { return }
        params = p
        state = .waitDevice
        retryLeft = max(0, s.settings.autoComPortReconnectRetryCount)
        s.notice(Lang.m("CONN2_SERIAL_WAIT_RECONNECT", "%s が戻るのを待っています (自動再接続)", p.path))
        s.updateTitle()
        startPolling()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard let p = params else { cancel(); return }
        let exists = FileManager.default.fileExists(atPath: p.path)
        switch state {
        case .waitDevice:
            // DBT_DEVICEARRIVAL: ポートが戻った。DelayNormal 待ってから開く
            if exists, let s = session {
                state = .waitTimer
                schedule(ms: s.settings.autoComPortReconnectDelayNormal)
            }
        case .waitTimer, .reconnecting:
            // 再接続中に抜かれた: また戻るのを待つ (回数も戻す)
            if !exists && !opening {
                openTimer?.invalidate(); openTimer = nil
                state = .waitDevice
                retryLeft = max(0, session?.settings.autoComPortReconnectRetryCount ?? 0)
            }
        case .none:
            cancel()
        }
    }

    private func schedule(ms: Int) {
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: Double(max(0, ms)) / 1000, repeats: false) { [weak self] _ in self?.openSerial() }
    }

    /// OpenSerial: 開いてみる。最後の 1 回だけエラーを出す (cv.NoMsg)
    private func openSerial() {
        openTimer = nil
        guard let s = session, let p = params else { cancel(); return }
        state = .reconnecting
        var ok = false
        if FileManager.default.fileExists(atPath: p.path) {
            let quiet = retryLeft != 0
            opening = true
            ok = s.connect(.serial(p), quiet: quiet)
            opening = false
        }
        if ok || retryLeft == 0 {
            // 開けた / もう開き直さない
            cancel()
        } else {
            retryLeft -= 1
            schedule(ms: s.settings.autoComPortReconnectRetryInterval)
        }
        s.updateTitle()
    }

    /// 待つのをやめる (ほかの接続を始めた・ウインドウを閉じた)
    func cancel() {
        pollTimer?.invalidate(); pollTimer = nil
        openTimer?.invalidate(); openTimer = nil
        state = .none
        params = nil
    }
}
