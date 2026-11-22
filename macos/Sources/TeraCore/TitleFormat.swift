// ウインドウのタイトル (ttwinman.c ChangeTitle)
// 元のコード: Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project (BSD 3-Clause)

import Foundation

/// ChangeTitle の材料
public struct WindowTitleInput: Equatable {
    public enum Port: Equatable {
        /// TCP/IP (ホスト名と ts.TCPPort)。ログの再生やローカルシェルも名前だけここに入れる
        case tcp(host: String, port: Int)
        /// シリアル (Mac はデバイス名。Windows の "COM%d")
        case serial(name: String, baud: Int)
    }
    /// ts.TitleW (Title= / settitle / /W=)
    public var title: String
    /// cv.TitleRemoteW (OSC 0 / 2 で受けたタイトル)。空・nil は「ない」
    public var remoteTitle: String?
    /// AcceptTitleChangeRequest: off / overwrite / ahead / last
    public var acceptTitleChangeRequest: String
    /// TitleFormat (bit0 ホスト bit1 セッション番号 bit2 VT bit3 ホストを先に bit4 TCP ポート bit5 シリアルの速度)
    public var titleFormat: Int
    /// Connecting
    public var connecting: Bool
    /// cv.Ready
    public var ready: Bool
    public var port: Port?
    /// SerialNo (RegWin)
    public var serialNo: Int

    public init(title: String, remoteTitle: String? = nil, acceptTitleChangeRequest: String = "overwrite",
                titleFormat: Int = 13, connecting: Bool = false, ready: Bool = false, port: Port? = nil, serialNo: Int = 1) {
        self.title = title
        self.remoteTitle = remoteTitle
        self.acceptTitleChangeRequest = acceptTitleChangeRequest
        self.titleFormat = titleFormat
        self.connecting = connecting
        self.ready = ready
        self.port = port
        self.serialNo = serialNo
    }
}

public enum WindowTitle {
    /// DLG_MAIN_TITLE_CONNECTING / DLG_MAIN_TITLE_DISCONNECTED (ja_JP.lng)
    public static let connectingText = "[接続中...]"
    public static let disconnectedText = "[未接続]"

    /// タイトルとリモートのタイトルを AcceptTitleChangeRequest で合わせたもの (TempTitleWithRemote)
    public static func titleWithRemote(_ i: WindowTitleInput) -> String {
        guard !i.connecting, i.ready, let r = i.remoteTitle, !r.isEmpty else { return i.title }
        switch i.acceptTitleChangeRequest.lowercased() {
        case "off": return i.title
        case "ahead": return "\(r) \(i.title)"
        case "last": return "\(i.title) \(r)"
        default: return r
        }
    }

    /// ChangeTitle(): VT ウインドウのタイトル
    public static func make(_ i: WindowTitleInput) -> String {
        let withRemote = titleWithRemote(i)
        var t = withRemote
        let f = i.titleFormat
        if f & 1 != 0 {
            t += " - "
            if i.connecting {
                t += connectingText
            } else if !i.ready {
                t += disconnectedText
            } else {
                var str: String
                switch i.port {
                case .serial(let name, let baud)?:
                    str = f & 32 != 0 ? "\(name):\(baud)bps" : name
                case .tcp(let host, let port)?:
                    str = f & 16 != 0 ? "\(host):\(port)" : host
                case nil:
                    str = ""
                }
                if f & 8 != 0 {
                    // format ID = 13 (8 + 5): <host/port> - <title>
                    t = "\(str) - \(withRemote)"
                } else {
                    t += str
                }
            }
        }
        if f & 2 != 0 { t += " (\(i.serialNo))" }
        if f & 4 != 0 { t += " VT" }
        return t
    }
}
