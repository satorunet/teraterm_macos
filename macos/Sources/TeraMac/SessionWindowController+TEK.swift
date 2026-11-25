import AppKit
import TeraCore

/// VT ウインドウと TEK ウインドウの切り替え (teraterm.cpp OnIdle の ActiveWin、vtwin.cpp OpenTEK、ttwinman.c VTActivate)
extension SessionWindowController {
    var tekWindow: TEKWindowController? { TEKWindowController.of(self) }

    /// 受信の振り分け (OnIdle: ActiveWin == IdTEK なら TEKParse)。received() で decode する前に呼ぶ:
    ///     bytes = routeTEK(bytes); if bytes.isEmpty { return }
    /// 戻り値は VT が読む分 (TEK が全部読んだら空)
    func routeTEK(_ bytes: [UInt8]) -> [UInt8] {
        installTEKHook()
        guard let tek = tekWindow, tek.isActiveWin else { return bytes }
        guard let rest = tek.feed(bytes) else { return [] }
        tekActivateVT(focus: false)
        return rest
    }

    /// VT の ChangeEmu = IdTEK を受ける (AutoWinSwitch は受信のたびに設定から写す)
    func installTEKHook() {
        term.autoWinSwitch = settings.autoWinSwitch
        if term.onEnterTEK == nil {
            term.onEnterTEK = { [weak self] rest in self?.enterTEK(rest) }
        }
    }

    /// VT が TEK に切り替えた: TEK ウインドウを開いて (OpenTEK) 残りを TEK に読ませる
    private func enterTEK(_ rest: [UInt8]) {
        let tek = openTEKWindow()
        if let back = tek.feed(rest) { tekReturnedToVT(back) }
    }

    /// TEK が VT に戻した (ChangeEmu = IdVT → VTActivate): 残りを VT に読ませる
    func tekReturnedToVT(_ rest: [UInt8]) {
        tekActivateVT(focus: true)
        guard !rest.isEmpty else { return }
        var d = StreamDecoder(encoding: settings.encoding)
        let s = d.decode(rest)
        guard !s.isEmpty else { return }
        term.feed(s)
        termView.dataArrived()
    }

    /// VTActivate: ActiveWin = IdVT にして VT ウインドウを前へ
    func tekActivateVT(focus: Bool = true) {
        tekWindow?.isActiveWin = false
        guard focus, let w = presentingWindow else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    /// CVTWindow::OpenTEK: ActiveWin = IdTEK。なければ作る、あれば前へ
    @discardableResult
    func openTEKWindow() -> TEKWindowController {
        installTEKHook()
        let tek: TEKWindowController
        if let t = tekWindow {
            tek = t
        } else {
            tek = TEKWindowController(session: self)
            TEKWindowController.bySession[ObjectIdentifier(self)] = tek
        }
        tek.isActiveWin = true
        if let w = tek.window, w.isMiniaturized { w.deminiaturize(nil) }
        tek.showWindow(nil)
        tek.window?.makeKeyAndOrderFront(nil)
        return tek
    }

    /// OnControlCloseTEK: なければビープ
    func closeTEKWindow() {
        guard let t = tekWindow else { NSSound.beep(); return }
        t.close()
    }
}
