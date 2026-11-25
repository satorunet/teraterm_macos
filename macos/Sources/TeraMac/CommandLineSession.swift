import Foundation
import TeraCore

/// 起動時のコマンドラインで変える設定 (このセッションだけ。保存はしない)
/// Tera Term は 1 ウインドウ 1 プロセスなので、コマンドラインの設定はそのウインドウだけのもの。
/// Mac 版は 1 プロセスなので、起動して最初に作るウインドウだけに使う
enum CommandLineSession {
    private static var used = false
    /// 起動時の TTProxy の -proxy= / -noproxy (最初のウインドウが受け取る)
    private static var startupProxy: ProxyURL?
    static func takeStartupProxy() -> ProxyURL? {
        defer { startupProxy = nil }
        return startupProxy
    }

    /// 起動時の引数 (main.swift と同じく AppKit の -psn / -NS / -Apple と --menu は除く)
    static var arguments: [String] {
        CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") && $0 != "--menu" }
    }

    /// 最初の 1 回だけ、コマンドラインの /B /KR= /KT= を設定に重ねる
    static func applyOnce(to s: TermSettings) -> TermSettings {
        guard !used else { return s }
        used = true
        let args = arguments
        guard !args.isEmpty else { return s }
        // 空白を含む引数は 1 つの語のまま渡す (中の " は "" にする。DequoteParam で戻る)
        let cl = TTCommandLine.parse(args.map {
            $0.contains(" ") || $0.contains("\t") ? "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : $0
        }.joined(separator: " "))
        startupProxy = cl.proxy
        return apply(cl, to: s)
    }

    /// kanjiOnly: /KR= /KT= だけ (connect マクロ。/B は接続ごとに渡す)
    static func apply(_ cl: TTCommandLine, kanjiOnly: Bool = false, to base: TermSettings) -> TermSettings {
        var s = base
        // /B (ttset.c: ParamBin → ts.TelBin)
        if !kanjiOnly, let b = cl.telBin { s.telBin = b }
        // /KR= /KT= (ttset.c _ParseParam: GetKanjiCodeFromStrW。知らない名前は UTF-8。5.2 で UTF8m はなくなった)
        if let k = cl.kanjiRecv { s.encoding = TermEncoding.fromKanjiCodeStr(k) }
        if let k = cl.kanjiSend { s.encodingSend = TermEncoding.fromKanjiCodeStr(k) }
        return s
    }
}
