import XCTest
@testable import TeraCore

/// 1 バイトの文字コード (#510)・/KR /KT・IDN (#1493)・TTProxy のコマンドライン・端末サイズの上限
final class ConnFeatureTests: XCTestCase {
    // MARK: 1 バイトの文字コード

    func testSBCSDecode() {
        var d = StreamDecoder(encoding: .cp437)
        XCTAssertEqual(d.decode([0x41, 0xB3, 0xC4, 0xDB]), "A\u{2502}\u{2500}\u{2588}")
        d.encoding = .koi8r
        XCTAssertEqual(d.decode([0xC1, 0xC2]), "аб")
        d.encoding = .cp1252
        // 0x81 は CP1252 にない: CPxxx は捨てる (ParseCodePage)
        XCTAssertEqual(d.decode([0x80, 0x81, 0x41]), "€A")
        d.encoding = .iso8859_3
        // ISO8859-3 の 0xA5 は対応がない: そのまま U+00A5 (ParseEnglish → ParseFirst の後半)
        XCTAssertEqual(d.decode([0xA5, 0xA1]), "\u{00A5}\u{0126}")
        d.encoding = .iso8859_1
        XCTAssertEqual(d.decode([0xE9]), "é")
        d.encoding = .cp1251
        XCTAssertEqual(d.decode([0xCF, 0xF0, 0xE8]), "При")
        // 制御文字はそのまま
        d.encoding = .cp437
        XCTAssertEqual(d.decode([0x1B, 0x5B, 0x6D, 0x0D, 0x0A]), "\u{1B}[m\r\n")
    }

    func testSBCSEncode() {
        XCTAssertEqual(TermEncoding.cp437.encode("A│█"), [0x41, 0xB3, 0xDB])
        XCTAssertEqual(TermEncoding.koi8r.encode("аб"), [0xC1, 0xC2])
        XCTAssertEqual(TermEncoding.cp1252.encode("€あ"), [0x80, 0x3F])
        XCTAssertEqual(TermEncoding.iso8859_1.encode("éあ"), [0xE9, 0x3F])
        XCTAssertEqual(TermEncoding.iso8859_15.encode("€"), [0xA4])
    }

    func testDBCSOthers() {
        var d = StreamDecoder(encoding: .ks5601)
        // CP949 "한" = C7 D1。途中で切れても次に回す
        XCTAssertEqual(d.decode([0xC7]), "")
        XCTAssertEqual(d.decode([0xD1, 0x41]), "한A")
        XCTAssertEqual(TermEncoding.ks5601.encode("한"), [0xC7, 0xD1])
        d.encoding = .big5
        XCTAssertEqual(d.decode([0xA4, 0xA4]), "中")
        d.encoding = .gb2312
        XCTAssertEqual(d.decode([0xD6, 0xD0]), "中")
    }

    func testDecoderReset() {
        var d = StreamDecoder(encoding: .sjis)
        XCTAssertEqual(d.decode([0x82]), "")
        d.reset()
        XCTAssertEqual(d.decode([0x41]), "A")
        d.encoding = .jis
        XCTAssertEqual(d.decode([0x1B, 0x24, 0x42]), "")
        d.reset()
        // 漢字インの状態は捨てた: 英数として読む
        XCTAssertEqual(d.decode([0x24, 0x22]), "$\"")
    }

    func testKanjiCodeNames() {
        // GetKanjiCodeFromStr: 大文字小文字も区別、知らない名前は UTF-8 (5.2 で UTF8m はなくなった)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("UTF8m"), .utf8)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("UTF-8m"), .utf8)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("SJIS"), .sjis)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("sjis"), .utf8)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("EUC-JP"), .eucjp)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("Windows-1251"), .cp1251)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("CP1251"), .cp1251)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("KOI8-R"), .koi8r)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr("ISO8859-16"), .iso8859_16)
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr(""), .utf8)
        XCTAssertNil(TermEncoding.exactKanjiCodeStr("UTF8m"))
        // GetKanjiCodeStr: 最初に見つかった名前
        XCTAssertEqual(TermEncoding.cp1251.iniName, "Windows-1251")
        XCTAssertEqual(TermEncoding.eucjp.iniName, "EUC-JP")
        // 本家の一覧の全部の文字コードが INI の名前を持つ
        for e in TermEncoding.allCases { XCTAssertNotNil(TermEncoding.exactKanjiCodeStr(e.iniName), e.rawValue) }
        XCTAssertEqual(TermEncoding.guiList.first?.name, "UTF-8")
        XCTAssertEqual(Set(TermEncoding.guiList.map { $0.name }).count, TermEncoding.guiList.count)
    }

    func testCommandLineKanji() {
        let cl = TTCommandLine.parse("host /KR=CP437 /KT=KOI8-R")
        XCTAssertEqual(cl.kanjiRecv, "CP437")
        XCTAssertEqual(cl.kanjiSend, "KOI8-R")
        XCTAssertEqual(TermEncoding.fromKanjiCodeStr(cl.kanjiRecv!), .cp437)
    }

    func testCharWidthSBCS() {
        // U+2502 (│) は曖昧幅: 1 バイトの文字コードは半角、DBCS は全角、UTF-8 は設定どおり
        XCTAssertEqual(termCharWidth("\u{2502}", kanjiCode: .cp437), 1)
        XCTAssertEqual(termCharWidth("\u{2502}", ambiguousWide: true, kanjiCode: .cp437), 1)
        XCTAssertEqual(termCharWidth("\u{2502}", kanjiCode: .sjis), 2)
        XCTAssertEqual(termCharWidth("\u{2502}", kanjiCode: .ks5601), 2)
        XCTAssertEqual(termCharWidth("\u{2502}", ambiguousWide: true, kanjiCode: .utf8), 2)
        XCTAssertEqual(termCharWidth("\u{0436}", kanjiCode: .koi8r), 1)   // ж (曖昧)
        XCTAssertEqual(termCharWidth("\u{0436}", kanjiCode: .sjis), 2)
    }

    // MARK: 端末サイズ (4.106 TermWidthMax / TermHeightMax)

    func testTerminalSizeLimit() {
        let t = Terminal(cols: 80, rows: 24)
        t.resize(cols: 5000, rows: 5000)
        XCTAssertEqual(t.cols, 1000)
        XCTAssertEqual(t.rows, 500)
    }

    // MARK: IDN (RFC 3492)

    func testPunycode() {
        // RFC 3492 7.1 の例と、よく使われる例
        XCTAssertEqual(IDN.punycodeEncode("bücher"), "bcher-kva")
        XCTAssertEqual(IDN.punycodeEncode("日本語"), "wgv71a119e")
        XCTAssertEqual(IDN.punycodeEncode("他们为什么不说中文"), "ihqwcrb4cv8a8dqg056pqjye")
        XCTAssertEqual(IDN.punycodeEncode("3年B組金八先生"), "3B-ww4c5e180e575a65lsy2b")
        XCTAssertEqual(IDN.hostNameToASCII("日本語.jp"), "xn--wgv71a119e.jp")
        XCTAssertEqual(IDN.hostNameToASCII("例え.テスト"), "xn--r8jz45g.xn--zckzah")
        XCTAssertEqual(IDN.hostNameToASCII("Bücher.example"), "xn--bcher-kva.example")
        XCTAssertEqual(IDN.hostNameToASCII("日本語。jp"), "xn--wgv71a119e.jp")
        XCTAssertEqual(IDN.hostNameToASCII("example.com"), "example.com")
        XCTAssertEqual(IDN.hostNameToASCII("192.168.0.1"), "192.168.0.1")
    }

    // MARK: TTProxy のコマンドライン

    func testProxyOption() {
        let cl = TTCommandLine.parse("-proxy=socks5://user:p%40ss@proxy:1080 sshserver /ssh")
        XCTAssertEqual(cl.proxy?.kind, .socks5)
        XCTAssertEqual(cl.proxy?.host, "proxy")
        XCTAssertEqual(cl.proxy?.port, 1080)
        XCTAssertEqual(cl.proxy?.user, "user")
        XCTAssertEqual(cl.proxy?.pass, "p@ss")
        XCTAssertEqual(cl.host, "sshserver")
        XCTAssertEqual(cl.ssh, true)
        XCTAssertTrue(cl.unknown.isEmpty)

        let t = TTCommandLine.parse("/PROXY=telnet://proxy:8023 telnetserver:23 /nossh")
        XCTAssertEqual(t.proxy?.kind, .telnet)
        XCTAssertEqual(t.proxy?.port, 8023)
        XCTAssertEqual(t.host, "telnetserver")
        XCTAssertEqual(t.tcpPort, 23)

        // ポートなし: 0 (種類ごとの既定)。IPv6 は []
        XCTAssertEqual(TTCommandLine.parse("-proxy=http://proxy host").proxy?.port, 0)
        let v6 = TTCommandLine.parse("-proxy=http://[2001:db8::1]:8080 host").proxy
        XCTAssertEqual(v6?.host, "2001:db8::1")
        XCTAssertEqual(v6?.port, 8080)
        // 空白はクオートで (1.0.0.19 / 1.0.0.22)
        let q = TTCommandLine.parse("\"-proxy=http://us er:pw@proxy:80\" host")
        XCTAssertEqual(q.proxy?.user, "us er")
        XCTAssertEqual(q.host, "host")
        let q2 = TTCommandLine.parse("-proxy=\"http://us er@proxy:80\" host")
        XCTAssertEqual(q2.proxy?.user, "us er")
    }

    func testNoProxyAndInvalid() {
        let n = TTCommandLine.parse("-noproxy sshserver /ssh")
        XCTAssertEqual(n.proxy?.kind, .noneForce)
        XCTAssertEqual(n.proxy?.usesProxy, false)
        XCTAssertEqual(n.host, "sshserver")
        XCTAssertEqual(TTCommandLine.parse("-proxy=none:// host").proxy?.kind, .noneForce)
        // ポート 0・数字以外は読めない (設定のまま)
        XCTAssertNil(TTCommandLine.parse("-proxy=http://proxy:0 host").proxy)
        XCTAssertNil(TTCommandLine.parse("-proxy=http://proxy:abc host").proxy)
        XCTAssertNil(TTCommandLine.parse("-proxy=foo://proxy:80 host").proxy)
        // "/" の後ろが空: プロキシを使わない
        XCTAssertEqual(TTCommandLine.parse("-proxy=http://proxy:8080/ host").proxy?.kind, ProxyURL.Kind.none)
        // 指定がなければ nil
        XCTAssertNil(TTCommandLine.parse("host /ssh").proxy)
    }

    func testProxyRealHostAndTelnetURL() {
        // protocol://proxy:port/realhost: realhost に接続する
        let r = TTCommandLine.parse("http://proxy:8080/realhost /nossh")
        XCTAssertEqual(r.proxy?.kind, .http)
        XCTAssertEqual(r.proxy?.host, "proxy")
        XCTAssertEqual(r.host, "realhost")
        // telnet://host:port は Tera Term のもの (1.0.0.13)。設定のプロキシはそのまま (本家は TYPE_NONE で上書きするが、不具合なので合わせない)
        let t = TTCommandLine.parse("telnet://host:2323")
        XCTAssertEqual(t.host, "host")
        XCTAssertEqual(t.tcpPort, 2323)
        XCTAssertTrue(t.telnetURL)
        XCTAssertNil(t.proxy)
        XCTAssertNil(TTCommandLine.parse("telnet://host").proxy)
        // telnet://host (ポートなし。1.0.0.9) も Tera Term に任せる
        let t2 = TTCommandLine.parse("telnet://host")
        XCTAssertEqual(t2.host, "host")
        XCTAssertEqual(t2.tcpPort, 23)
        // ssh:// は TTProxy の種類ではない
        XCTAssertNil(TTCommandLine.parse("ssh://user@host").proxy)
    }
}
