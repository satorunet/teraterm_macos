import XCTest
@testable import TeraCore

/// 「その他の設定」の 端末 / 制御シーケンス / エンコーディング タブの動き (vtterm.c / ttwinman.c / charset.cpp / makeoutputstring.cpp)
final class TerminalSettingsTests: XCTestCase {
    private func make(cols: Int = 20, rows: Int = 4) -> (Terminal, () -> String) {
        let t = Terminal(cols: cols, rows: rows)
        var out = ""
        t.onResponse = { out += $0 }
        return (t, { let o = out; out = ""; return o })
    }

    private func row(_ t: Terminal, _ y: Int) -> String {
        t.lines[y].text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    // MARK: 端末ID

    func testPrimaryDAForEveryTerminalID() {
        let expected: [String: String] = [
            "VT100": "1;2", "VT100J": "5;2", "VT101": "1;0", "VT102": "6", "VT102J": "15",
            "VT220": "62;1;2;6;7;8;9", "VT220J": "62;1;2;5;6;7;8", "VT282": "62;1;2;4;5;6;7;8;10;11",
            "VT320": "63;1;2;6;7;8;9", "VT382": "63;1;2;4;5;6;7;8;10;15", "VT420": "64;1;2;6;7;8;9;15;18;19;21",
            "VT520": "65;1;2;7;9;12;18;19;21;23;24;42;44;45;46", "VT525": "65;1;2;7;9;12;18;19;21;22;23;24;42;44;45;46",
        ]
        for (id, p) in expected {
            let (t, out) = make()
            t.terminalID = TerminalID(ini: id)
            t.feed("\u{1B}[c")
            XCTAssertEqual(out(), "\u{1B}[?\(p)c", id)
            t.feed("\u{1B}Z")   // DECID
            XCTAssertEqual(out(), "\u{1B}[?\(p)c", id)
            // DA2 は端末IDによらない
            t.feed("\u{1B}[>c")
            XCTAssertEqual(out(), "\u{1B}[>32;331;0c", id)
        }
        XCTAssertEqual(TerminalID(ini: "vt320"), .vt100)   // 大文字小文字は区別
        XCTAssertEqual(TerminalID(ini: "VT420").vtLevel, 4)
    }

    func testDumbTerminalShowsControlsAndIgnoresEscapes() {
        let (t, out) = make()
        t.terminalID = .dumb
        t.feed("a\u{1B}[2Jb\tc\r\nd\u{1B}[c")
        XCTAssertEqual(row(t, 0), "a\u{241B}[2Jb\u{2409}c")
        XCTAssertEqual(row(t, 1), "d\u{241B}[c")
        XCTAssertEqual(out(), "")
    }

    func testAnswerback() {
        let t = Terminal()
        var got: [UInt8] = []
        t.onResponseBytes = { got += $0 }
        t.feed("\u{05}")
        XCTAssertEqual(got, [])           // 空なら送らない
        t.answerbackBytes = [0x41, 0x0D, 0xFF]
        t.feed("\u{05}")
        XCTAssertEqual(got, [0x41, 0x0D, 0xFF])
    }

    // MARK: タイトル

    func testTitleFormatter() {
        XCTAssertEqual(TitleFormatter.title(local: "TT", remote: "host", mode: .overwrite), "host")
        XCTAssertEqual(TitleFormatter.title(local: "TT", remote: "host", mode: .ahead), "host TT")
        XCTAssertEqual(TitleFormatter.title(local: "TT", remote: "host", mode: .last), "TT host")
        XCTAssertEqual(TitleFormatter.title(local: "TT", remote: "host", mode: .off), "TT")
        XCTAssertEqual(TitleFormatter.title(local: "TT", remote: nil, mode: .ahead), "TT")
        XCTAssertEqual(TitleFormatter.title(local: "TT", remote: "host", mode: .overwrite, connected: false), "TT")
        XCTAssertEqual(TitleChangeMode(ini: "ON"), .overwrite)
        XCTAssertEqual(TitleChangeMode(ini: "bogus"), .off)
    }

    func testOSCTitleAndChangeModes() {
        let t = Terminal()
        var titles: [String] = []
        t.onTitle = { titles.append($0) }
        t.localTitle = "TT"
        t.feed("\u{1B}]0;one\u{07}")
        XCTAssertEqual(t.remoteTitle, "one")
        XCTAssertEqual(t.windowTitle, "one")
        t.feed("\u{1B}]1;icon\u{1B}\\")
        XCTAssertEqual(t.remoteTitle, "icon")
        t.titleChangeMode = .last
        XCTAssertEqual(t.windowTitle, "TT icon")
        t.feed("\u{1B}]2;\u{07}")
        XCTAssertNil(t.remoteTitle)
        XCTAssertEqual(titles, ["one", "icon", ""])
        t.titleChangeMode = .off
        t.feed("\u{1B}]2;ignored\u{07}")
        XCTAssertNil(t.remoteTitle)
        XCTAssertEqual(titles.count, 3)
    }

    func testTitleReport() {
        let (t, out) = make()
        t.localTitle = "TT"
        t.feed("\u{1B}]2;host\u{07}")
        t.feed("\u{1B}[21t")
        XCTAssertEqual(out(), "\u{1B}]l\u{1B}\\")    // 既定は空白
        t.titleReportMode = .ignore
        t.feed("\u{1B}[21t\u{1B}[20t")
        XCTAssertEqual(out(), "")
        t.titleReportMode = .accept
        t.feed("\u{1B}[21t")
        XCTAssertEqual(out(), "\u{1B}]lhost\u{1B}\\")
        t.titleChangeMode = .ahead
        t.feed("\u{1B}[20t")
        XCTAssertEqual(out(), "\u{1B}]Lhost TT\u{1B}\\")
        t.titleChangeMode = .off
        t.feed("\u{1B}[21t")
        XCTAssertEqual(out(), "\u{1B}]lTT\u{1B}\\")
    }

    func testTitleStack() {
        let t = Terminal()
        var last: String?
        t.onTitle = { last = $0 }
        t.feed("\u{1B}]2;first\u{07}\u{1B}[22;0t\u{1B}]2;second\u{07}")
        XCTAssertEqual(t.remoteTitle, "second")
        t.feed("\u{1B}[23;0t")
        XCTAssertEqual(t.remoteTitle, "first")
        XCTAssertEqual(last, "first")
    }

    // MARK: ウィンドウ操作・報告

    func testWindowControlSequences() {
        let (t, out) = make(cols: 80, rows: 24)
        var ops: [WindowOp] = []
        t.onWindowOp = { ops.append($0) }
        t.feed("\u{1B}[8;30;100t\u{1B}[8;0;0t\u{1B}[2t\u{1B}[3;10;20t\u{1B}[4;300;400t\u{1B}[9;1t\u{1B}[10;2t")
        XCTAssertEqual(ops, [.resizeTerminal(cols: 100, rows: 30), .resizeTerminal(cols: 80, rows: 24), .iconify,
                             .move(x: 10, y: 20), .resizePixels(width: 400, height: 300), .maximize, .toggleMaximize])
        ops = []
        t.windowCtrlEnabled = false
        t.feed("\u{1B}[8;30;100t\u{1B}[1t")
        XCTAssertEqual(ops, [])

        t.feed("\u{1B}[18t")
        XCTAssertEqual(out(), "\u{1B}[8;24;80t")
        t.feed("\u{1B}[14t")
        XCTAssertEqual(out(), "")         // 情報がないと答えない
        var info = WindowInfo()
        info.clientWidth = 640; info.clientHeight = 384; info.windowWidth = 650; info.windowHeight = 420
        info.windowX = 5; info.windowY = 6; info.clientX = 7; info.clientY = 30
        info.cellWidth = 8; info.cellHeight = 16; info.screenCols = 200; info.screenRows = 60
        info.iconified = true
        t.windowInfo = { info }
        t.feed("\u{1B}[14t\u{1B}[14;2t\u{1B}[13t\u{1B}[13;2t\u{1B}[16t\u{1B}[19t\u{1B}[11t")
        XCTAssertEqual(out(), "\u{1B}[4;384;640t\u{1B}[4;420;650t\u{1B}[3;5;6t\u{1B}[3;7;30t\u{1B}[6;16;8t\u{1B}[9;60;200t\u{1B}[2t")
        t.windowReportEnabled = false
        t.feed("\u{1B}[18t\u{1B}[14t")
        XCTAssertEqual(out(), "")
    }

    // MARK: カーソル

    func testCursorControlIsGated() {
        let t = Terminal()
        t.feed("\u{1B}[4 q\u{1B}[?12l")
        XCTAssertEqual(t.cursorStyle, .block)
        XCTAssertTrue(t.cursorBlink)
        t.cursorCtrlEnabled = true
        t.feed("\u{1B}[4 q")
        XCTAssertEqual(t.cursorStyle, .underline)
        XCTAssertFalse(t.cursorBlink)
        t.feed("\u{1B}[5 q")
        XCTAssertEqual(t.cursorStyle, .bar)
        XCTAssertTrue(t.cursorBlink)
        t.feed("\u{1B}[?12l")
        XCTAssertFalse(t.cursorBlink)
        t.feed("\u{1B}[34h")
        XCTAssertEqual(t.cursorStyle, .underline)
        t.feed("\u{1B}[34l\u{1B}[33l")
        XCTAssertEqual(t.cursorStyle, .block)
        XCTAssertTrue(t.cursorBlink)
    }

    // MARK: クリップボード (OSC 52)

    func testClipboardWriteAndRead() {
        let (t, out) = make()
        var written: [String] = []
        var notices: [ClipboardNotice] = []
        t.onClipboardWrite = { written.append($0) }
        t.onClipboardRead = { "クリップ" }
        t.onClipboardNotice = { notices.append($0) }
        let b64 = Data("日本".utf8).base64EncodedString()
        t.feed("\u{1B}]52;c;\(b64)\u{07}\u{1B}]52;c;?\u{07}")
        XCTAssertEqual(written, [])
        XCTAssertEqual(notices, [.writeRejected, .readRejected])
        XCTAssertEqual(out(), "")

        notices = []
        t.clipboardAccess = ClipboardAccess(ini: "on")
        t.feed("\u{1B}]52;c;\(b64)\u{1B}\\")
        XCTAssertEqual(written, ["日本"])
        t.feed("\u{1B}]52;pc;?\u{07}")
        XCTAssertEqual(out(), "\u{1B}]52;pc;" + Data("クリップ".utf8).base64EncodedString() + "\u{1B}\\")
        XCTAssertEqual(notices, [.write("日本"), .read])
        XCTAssertEqual(notices[0].message, "リモートホストがクリップボードに書き込みました。\n--\n日本")

        notices = []
        t.notifyClipboardAccess = false
        t.clipboardAccess = .write
        t.feed("\u{1B}]52;c;\(Data("x".utf8).base64EncodedString())\u{07}\u{1B}]52;c;?\u{07}")
        XCTAssertEqual(written.last, "x")
        XCTAssertEqual(notices, [])
        XCTAssertEqual(out(), "")
    }

    func testClipboardUsesSendEncodingForRead() {
        let (t, out) = make()
        t.clipboardAccess = .read
        t.sendEncoding = .sjis
        t.onClipboardRead = { "あ" }
        t.feed("\u{1B}]52;c;?\u{07}")
        XCTAssertEqual(out(), "\u{1B}]52;c;" + Data([0x82, 0xA0]).base64EncodedString() + "\u{1B}\\")
    }

    // MARK: スクロールバッファの消去

    func testClearScrollBufferFromRemote() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("1\r\n2\r\n3\r\n4")
        XCTAssertEqual(t.scrollback.count, 2)
        t.clearScrollbackFromRemote = false
        t.feed("\u{1B}[3J")
        XCTAssertEqual(t.scrollback.count, 2)
        XCTAssertEqual(row(t, 1), "4")
        t.clearScrollbackFromRemote = true
        t.feed("\u{1B}[3J")
        XCTAssertEqual(t.scrollback.count, 0)
        XCTAssertEqual(row(t, 1), "")      // ClearBuffer: 画面も消えてカーソルは左上
        XCTAssertEqual(t.cx, 0); XCTAssertEqual(t.cy, 0)
    }

    // MARK: 印刷

    func testPrinterControllerMode() {
        let t = Terminal(cols: 10, rows: 3)
        var prints: [PrintRequest] = []
        t.onPrint = { prints.append($0) }
        // 無効なら CSI 5 i は無視して画面に出す
        t.feed("\u{1B}[5iabc\u{1B}[4i")
        XCTAssertEqual(row(t, 0), "abc")
        XCTAssertEqual(prints, [])
        t.printerCtrlEnabled = true
        t.feed("\r\n\u{1B}[5ixyz\r\n\u{1B}[1mq\u{1B}[4iZ")
        XCTAssertEqual(prints, [.text("xyz\r\nmq")])
        XCTAssertEqual(row(t, 1), "Z")
        prints = []
        t.feed("\u{1B}[i\u{1B}[?19l\u{1B}[0i\u{1B}[?1i")
        XCTAssertEqual(prints, [.screen(wholeScreen: true), .screen(wholeScreen: false), .text("Z\r\n")])
        prints = []
        t.feed("\u{1B}[?5iline\n\u{1B}[?4ix\n")
        XCTAssertEqual(prints, [.text("Zline\r\n")])
    }

    // MARK: ベル

    func testBellKindAndRateLimit() {
        let t = Terminal()
        var now = 100.0
        t.bellClock = { now }
        var kinds: [BellKind] = []
        t.onBellKind = { kinds.append($0) }
        t.bellMode = .visual
        t.feed("\u{07}\u{1B}g")
        XCTAssertEqual(kinds, [.visual, .visual])
        // 2 秒以内に続けて鳴ると (RingBell と同じく 6 回目のあと) 5 秒止まる
        kinds = []
        now = 200
        for _ in 0..<8 { t.feed("\u{07}"); now += 0.1 }
        XCTAssertEqual(kinds.count, 6)
        now += 10
        t.feed("\u{07}")
        XCTAssertEqual(kinds.count, 7)
        kinds = []
        now += 10
        t.bellMode = .off
        t.feed("\u{07}")
        XCTAssertEqual(kinds, [])
        XCTAssertEqual(BellKind(ini: "on"), .sound)
    }

    func testLegacyOnBellStillCalled() {
        let t = Terminal()
        var n = 0
        t.onBell = { n += 1 }
        t.feed("\u{07}")
        XCTAssertEqual(n, 1)
    }

    // MARK: DEC Special Graphics

    func testDecSpecialMappingModes() {
        let t = Terminal(cols: 10, rows: 1)
        t.ambiguousWide = true
        // 2: マッピングしない → DEC の文字は 1 桁の特殊文字、Unicode の罫線は Unicode のまま (曖昧幅で 2 桁)
        t.feed("\u{1B}(0q\u{1B}(B─")
        XCTAssertEqual(t.lines[0].cells[0].ch, "─")
        XCTAssertEqual(t.lines[0].cells[0].width, 1)
        XCTAssertTrue(t.lines[0].cells[0].attr.decSpecial)
        XCTAssertEqual(t.lines[0].cells[1].width, 2)
        XCTAssertFalse(t.lines[0].cells[1].attr.decSpecial)

        // 0: Unicode → DEC (罫線素片のビット) → 1 桁
        t.feed("\r\u{1B}[K")
        t.decSpecialMapping = .unicodeToDec
        t.feed("━·")
        XCTAssertEqual(t.lines[0].cells[0].ch, "─")
        XCTAssertEqual(t.lines[0].cells[0].width, 1)
        XCTAssertTrue(t.lines[0].cells[0].attr.decSpecial)
        // 中点は bit2。既定 (3) では中点はマッピングしない
        XCTAssertFalse(t.lines[0].cells[1].attr.decSpecial)
        t.unicodeToDecSpMask = 7
        t.feed("·")
        XCTAssertTrue(t.lines[0].cells[3].attr.decSpecial)
        XCTAssertEqual(t.lines[0].cells[3].width, 1)

        // 1: DEC → Unicode → 曖昧幅の規則
        t.feed("\r\u{1B}[K")
        t.decSpecialMapping = .decToUnicode
        t.feed("\u{1B}(0q\u{1B}(B")
        XCTAssertEqual(t.lines[0].cells[0].ch, "─")
        XCTAssertEqual(t.lines[0].cells[0].width, 2)
        XCTAssertFalse(t.lines[0].cells[0].attr.decSpecial)
    }

    // MARK: 絵文字の幅

    func testEmojiWidthOverride() {
        XCTAssertEqual(termCharWidth("\u{2614}"), 2)                      // ☔ (East Asian Wide)
        XCTAssertEqual(termCharWidth("\u{2614}", emojiWidth: 1), 1)
        XCTAssertEqual(termCharWidth("\u{A9}"), 1)
        XCTAssertEqual(termCharWidth("\u{A9}", emojiWidth: 2), 2)         // © も絵文字
        XCTAssertEqual(termCharWidth("\u{1F600}", emojiWidth: 1), 2)      // U+1F000 以上はいつも全角
        XCTAssertEqual(termCharWidth("A", emojiWidth: 2), 1)
        let t = Terminal(cols: 10, rows: 1)
        t.emojiWidthOverride = 1
        t.feed("\u{2614}x")
        XCTAssertEqual(row(t, 0), "\u{2614}x")
        XCTAssertEqual(t.cx, 2)
        // UTF-8 でないときは効かない
        t.receiveEncoding = .sjis
        t.feed("\r\u{2614}")
        XCTAssertEqual(t.cx, 2)
    }

    // MARK: JIS

    func testJISSendOptions() {
        func enc(_ s: String, _ o: JISSendOptions) -> [UInt8] { TermEncoding.jis.encode(s, jis: o) }
        let def = JISSendOptions()
        XCTAssertEqual(enc("漢a", def), [0x1B, 0x24, 0x42, 0x34, 0x41, 0x1B, 0x28, 0x42, 0x61])
        let at = JISSendOptions(kanjiIn: "@", kanjiOut: "J", katakana7: false)
        XCTAssertEqual(enc("漢a", at), [0x1B, 0x24, 0x40, 0x34, 0x41, 0x1B, 0x28, 0x4A, 0x61])
        XCTAssertEqual(JISSendOptions(kanjiIn: "x", kanjiOut: "H", katakana7: false).kanjiOut, 0x4A)
        XCTAssertEqual(JISSendOptions(kanjiIn: "x", kanjiOut: "H", katakana7: false, allowWrongSequence: true).kanjiOut, 0x48)
        XCTAssertEqual(JISSendOptions(kanjiIn: "x", kanjiOut: "?", katakana7: false).kanjiIn, 0x42)
        // 半角カナ: 8 ビットならそのまま、7 ビットなら SO … SI
        XCTAssertEqual(enc("ｱa", def), [0xB1, 0x61])
        XCTAssertEqual(enc("ｱｲa", JISSendOptions(kanjiIn: "B", kanjiOut: "B", katakana7: true)), [0x0E, 0x31, 0x32, 0x0F, 0x61])
        // 続けて送るとき: 漢字アウトは次の英数の前に付く
        var e = JISEncoder(options: def)
        XCTAssertEqual(e.encode("漢"), [0x1B, 0x24, 0x42, 0x34, 0x41])
        XCTAssertEqual(e.encode("\r"), [0x1B, 0x28, 0x42, 0x0D])
        // static の既定 (TermEncoding.encode) も設定に従う
        let saved = TermEncoding.jisSendOptions
        TermEncoding.jisSendOptions = at
        XCTAssertEqual(TermEncoding.jis.encode("漢"), [0x1B, 0x24, 0x40, 0x34, 0x41, 0x1B, 0x28, 0x4A])
        TermEncoding.jisSendOptions = saved
    }

    func testJISReceiveKatakana7() {
        var d = StreamDecoder(encoding: .jis)
        // 8 (既定): GR は半角カナ
        XCTAssertEqual(d.decode([0xB1, 0x41]), "ｱA")
        // SO / SI はどちらでも半角カナ
        XCTAssertEqual(d.decode([0x0E, 0x31, 0x0F, 0x31]), "ｱ1")
        // 7: GR は 8 ビットの JIS 漢字
        d.jis7Katakana = true
        XCTAssertEqual(d.decode([0xB4, 0xC1, 0x41]), "漢A")
        XCTAssertEqual(d.decode([0xB4]), "")
        XCTAssertEqual(d.decode([0xC1]), "漢")
        // ESC ( H も英数に戻す
        XCTAssertEqual(d.decode([0x1B, 0x24, 0x42, 0x34, 0x41, 0x1B, 0x28, 0x48, 0x41]), "漢A")
    }

    // MARK: まとめてかける

    func testApplyTeraTermSettings() {
        let t = Terminal()
        t.feed("\u{1B}]2;remote\u{07}")
        t.applyTeraTermSettings(terminalID: "VT382", answerback: [0x41], title: "New",
                                acceptTitleChangeRequest: "overwrite", titleReportSequence: "accept",
                                windowCtrlSequence: false, windowReportSequence: true, cursorCtrlSequence: true,
                                clipboardAccessFromRemote: "write", notifyClipboardAccess: false,
                                clearScrollBufferFromRemote: false, printerCtrlSequence: true, beep: "visual",
                                receive: .utf8, send: .eucjp, decSpMappingDir: 1, unicodeToDecSpMapping: 7,
                                unicodeEmojiOverride: true, unicodeEmojiWidth: 2)
        XCTAssertEqual(t.terminalID, .vt382)
        XCTAssertNil(t.remoteTitle)          // タイトルを変えて上書きモードならリモートタイトルを消す
        XCTAssertEqual(t.windowTitle, "New")
        XCTAssertEqual(t.titleReportMode, .accept)
        XCTAssertFalse(t.windowCtrlEnabled)
        XCTAssertTrue(t.cursorCtrlEnabled)
        XCTAssertEqual(t.clipboardAccess, .write)
        XCTAssertEqual(t.bellMode, .visual)
        XCTAssertEqual(t.decSpecialMapping, .decToUnicode)
        XCTAssertEqual(t.unicodeToDecSpMask, 7)
        XCTAssertEqual(t.emojiWidthOverride, 2)
        XCTAssertEqual(t.sendEncoding, .eucjp)
    }
}
