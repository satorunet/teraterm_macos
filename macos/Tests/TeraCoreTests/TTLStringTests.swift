import XCTest
@testable import TeraCore

/// 文字列・日時・環境まわりのコマンド (ttl.cpp の動きを基準にする)
final class TTLStringTests: XCTestCase {

    private func s(_ i: TTLInterpreter, _ n: String) -> String? {
        if case .str(let v)? = i.variable(n) { return v }
        return nil
    }
    private func n(_ i: TTLInterpreter, _ v: String) -> Int? {
        if case .int(let x)? = i.variable(v) { return x }
        return nil
    }

    func testCode2StrStr2Code() throws {
        let (h, i) = try runTTL("""
        code2str a $414243
        code2str b $41004200
        code2str c 0
        str2code x 'ABC'
        str2code y 'ABCDE'
        str2code z 'あ'
        str2code w ''
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(s(i, "a"), "ABC")
        XCTAssertEqual(s(i, "b"), "A")          // 途中の 0 で切れる
        XCTAssertEqual(s(i, "c"), "")
        XCTAssertEqual(n(i, "x"), 0x414243)
        XCTAssertEqual(n(i, "y"), 0x42434445)   // 後ろ 4 バイト
        XCTAssertEqual(n(i, "z"), 0xE38182)     // UTF-8 のバイト
        XCTAssertEqual(n(i, "w"), 0)
    }

    func testInt2StrStr2Int() throws {
        let (_, i) = try runTTL("""
        int2str a -123
        str2int v1 '42abc'
        r1 = result
        str2int v2 '$ff'
        r2 = result
        str2int v3 '0x10'
        r3 = result
        str2int v4 'abc'
        r4 = result
        str2int v5 '  -7'
        r5 = result
        str2int v6 '$FFFFFFFF'
        str2int v7 ''
        r7 = result
        """)
        XCTAssertEqual(s(i, "a"), "-123")
        XCTAssertEqual(n(i, "v1"), 42); XCTAssertEqual(n(i, "r1"), 1)
        XCTAssertEqual(n(i, "v2"), 255); XCTAssertEqual(n(i, "r2"), 1)
        XCTAssertEqual(n(i, "v3"), 16); XCTAssertEqual(n(i, "r3"), 1)
        XCTAssertEqual(n(i, "v4"), 0); XCTAssertEqual(n(i, "r4"), 0)
        XCTAssertEqual(n(i, "v5"), -7); XCTAssertEqual(n(i, "r5"), 1)
        XCTAssertEqual(n(i, "v6"), -1)
        XCTAssertEqual(n(i, "v7"), 0); XCTAssertEqual(n(i, "r7"), 0)
    }

    func testStrCompareConcatLen() throws {
        let (_, i) = try runTTL("""
        strcompare 'abc' 'abd'
        c1 = result
        strcompare 'b' 'a'
        c2 = result
        strcompare 'x' 'x'
        c3 = result
        strcompare 'あ' 'a'
        c4 = result
        a = 'こん'
        strconcat a 'にちは'
        strlen a
        l1 = result
        strlen ''
        l2 = result
        """)
        XCTAssertEqual(n(i, "c1"), -1)
        XCTAssertEqual(n(i, "c2"), 1)
        XCTAssertEqual(n(i, "c3"), 0)
        XCTAssertEqual(n(i, "c4"), 1)    // unsigned char で比べる
        XCTAssertEqual(s(i, "a"), "こんにちは")
        XCTAssertEqual(n(i, "l1"), 15)   // バイト数
        XCTAssertEqual(n(i, "l2"), 0)
    }

    func testStrConcatTruncates() throws {
        let (_, i) = try runTTL("""
        a = ''
        for k 1 60
          strconcat a '0123456789'
        next
        strlen a
        """)
        XCTAssertEqual(n(i, "result"), 511)
    }

    func testStrCopy() throws {
        let (_, i) = try runTTL("""
        strcopy 'Tera Term' 6 4 a
        strcopy 'Tera Term' 0 4 b
        strcopy 'Tera Term' 6 100 c
        strcopy 'Tera Term' 20 3 d
        strcopy 'あいう' 4 3 e
        m1 = -1
        strcopy 'abc' 2 m1 f
        """)
        XCTAssertEqual(s(i, "a"), "Term")
        XCTAssertEqual(s(i, "b"), "Tera")
        XCTAssertEqual(s(i, "c"), "Term")
        XCTAssertEqual(s(i, "d"), "")
        XCTAssertEqual(s(i, "e"), "い")     // バイト位置
        XCTAssertEqual(s(i, "f"), "")
    }

    func testStrInsertRemove() throws {
        let (h, i) = try runTTL("""
        a = 'abcd'
        strinsert a 3 'XY'
        b = 'abc'
        strinsert b 4 'Z'
        c = 'あい'
        strinsert c 4 '!'
        d = 'Tera Term'
        strremove d 5 5
        e = 'あいう'
        strremove e 4 3
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(s(i, "a"), "abXYcd")
        XCTAssertEqual(s(i, "b"), "abcZ")
        XCTAssertEqual(s(i, "c"), "あ!い")
        XCTAssertEqual(s(i, "d"), "Tera")
        XCTAssertEqual(s(i, "e"), "あう")
    }

    func testStrInsertBadIndexIsSyntaxError() throws {
        XCTAssertThrowsError(try runTTL("a = 'abc'\nstrinsert a 5 'x'"))
        XCTAssertThrowsError(try runTTL("a = 'abc'\nstrremove a 2 3"))
        XCTAssertThrowsError(try runTTL("a = 'abc'\nstrremove a 1 0"))
    }

    func testStrScan() throws {
        let (_, i) = try runTTL("""
        strscan 'Tera Term' 'Term'
        r1 = result
        strscan 'Tera Term' 'xyz'
        r2 = result
        strscan 'Tera Term' ''
        r3 = result
        strscan 'あいう' 'う'
        r4 = result
        """)
        XCTAssertEqual(n(i, "r1"), 6)
        XCTAssertEqual(n(i, "r2"), 0)
        XCTAssertEqual(n(i, "r3"), 0)
        XCTAssertEqual(n(i, "r4"), 7)
    }

    func testStrMatch() throws {
        let (_, i) = try runTTL("""
        strmatch 'Tera Term 5.0' '(\\d+)\\.(\\d+)'
        r1 = result
        m = matchstr
        g1 = groupmatchstr1
        g2 = groupmatchstr2
        strmatch 'abc' 'x+'
        r2 = result
        strmatch 'あいう123' '[0-9]+'
        r3 = result
        strmatch 'abc' '('
        r4 = result
        """)
        XCTAssertEqual(n(i, "r1"), 11)
        XCTAssertEqual(s(i, "m"), "5.0")
        XCTAssertEqual(s(i, "g1"), "5")
        XCTAssertEqual(s(i, "g2"), "0")
        XCTAssertEqual(n(i, "r2"), 0)
        XCTAssertEqual(n(i, "r3"), 10)   // バイト位置
        XCTAssertEqual(n(i, "r4"), 0)    // 正しくない正規表現も 0
    }

    func testStrReplace() throws {
        let (_, i) = try runTTL("""
        a = 'aaa bbb aaa'
        strreplace a 1 'a+' 'X'
        r1 = result
        b = 'aaa bbb aaa'
        strreplace b 2 'aaa' 'X'
        r2 = result
        c = 'abc'
        strreplace c 1 'z' 'X'
        r3 = result
        d = 'abc'
        strreplace d 4 'c' 'X'
        r4 = result
        e = 'abc'
        strreplace e 1 '(' 'X'
        r5 = result
        f = 'あいう'
        strreplace f 1 'い' 'XX'
        r6 = result
        g = 'abc'
        strreplace g 0 'a' 'X'
        r7 = result
        """)
        XCTAssertEqual(s(i, "a"), "X bbb aaa"); XCTAssertEqual(n(i, "r1"), 1)
        XCTAssertEqual(s(i, "b"), "aaa bbb X"); XCTAssertEqual(n(i, "r2"), 1)
        XCTAssertEqual(s(i, "c"), "abc"); XCTAssertEqual(n(i, "r3"), 0)
        XCTAssertEqual(s(i, "d"), "abc"); XCTAssertEqual(n(i, "r4"), 0)
        XCTAssertEqual(s(i, "e"), "abc"); XCTAssertEqual(n(i, "r5"), -1)
        XCTAssertEqual(s(i, "f"), "あXXう"); XCTAssertEqual(n(i, "r6"), 1)
        XCTAssertEqual(n(i, "r7"), 0)
    }

    func testStrSpecial() throws {
        let (_, i) = try runTTL("""
        strspecial a 'a\\nb\\tc\\\\d\\qe'
        b = 'x\\0y'
        strspecial b
        """)
        XCTAssertEqual(s(i, "a"), "a\nb\tc\\d\\qe")
        XCTAssertEqual(s(i, "b"), "x")
    }

    func testStrSplitDocExamples() throws {
        let (_, i) = try runTTL("""
        src=',,Sun,Mon,Tue,,Thu,Fri,Sat'
        strsplit src ',' 7
        """)
        let exp1 = ["", "", "Sun", "Mon", "Tue", "", "Thu,Fri,Sat", "", ""]
        for k in 1...9 { XCTAssertEqual(s(i, "groupmatchstr\(k)"), exp1[k - 1], "g\(k)") }
        XCTAssertEqual(n(i, "result"), 7)

        let (_, i2) = try runTTL("""
        src='1,2,3,4,5,6,7,8,9,0'
        strsplit src ','
        """)
        for k in 1...9 { XCTAssertEqual(s(i2, "groupmatchstr\(k)"), "\(k)") }
        XCTAssertEqual(n(i2, "result"), 10)

        let (_, i3) = try runTTL("""
        src='あ、い'
        strsplit src ','
        r = result
        strsplit 'a|b' '|' 9
        """)
        XCTAssertEqual(n(i3, "r"), 1)
        XCTAssertEqual(s(i3, "groupmatchstr1"), "a")
        XCTAssertEqual(s(i3, "groupmatchstr2"), "b")
        XCTAssertEqual(s(i3, "groupmatchstr3"), "")
        XCTAssertEqual(n(i3, "result"), 2)
    }

    func testStrSplitErrors() throws {
        XCTAssertThrowsError(try runTTL("strsplit 'a,b' ',,'"))
        XCTAssertThrowsError(try runTTL("strsplit 'a、b' '、'"))   // 3 バイトの区切りはだめ
        XCTAssertThrowsError(try runTTL("strsplit 'a,b' ',' 10"))
        XCTAssertThrowsError(try runTTL("strsplit 'a,b' ',' 0"))
    }

    func testStrJoin() throws {
        let (_, i) = try runTTL("""
        groupmatchstr1="Jan"
        groupmatchstr2="Feb"
        groupmatchstr3="Mar"
        groupmatchstr4="Apr"
        groupmatchstr5="May"
        groupmatchstr6="Jun"
        groupmatchstr7="Jul"
        groupmatchstr8="Aug"
        groupmatchstr9="Sep"
        strjoin a ","
        strjoin b " and " 6
        groupmatchstr7=""
        groupmatchstr8=""
        groupmatchstr9=""
        strjoin c "," 9
        """)
        XCTAssertEqual(s(i, "a"), "Jan,Feb,Mar,Apr,May,Jun,Jul,Aug,Sep")
        XCTAssertEqual(s(i, "b"), "Jan and Feb and Mar and Apr and May and Jun")
        XCTAssertEqual(s(i, "c"), "Jan,Feb,Mar,Apr,May,Jun,,,")
        XCTAssertThrowsError(try runTTL("strjoin a ',' 10"))
    }

    func testStrTrimDocExamples() throws {
        let (_, i) = try runTTL("""
        a='   '#9' #include <stdio.h>      '#9' '
        strtrim a ' '#9
        b='*;|@123***456@|;'
        strtrim b '*;|@'
        c='*;|@123***456@|;'
        strtrim c '*;|@123456'
        d='#*;|@123***456@|;'
        strtrim d '*;|@'
        e='*;|@123***456@|;#'
        strtrim e '*;|@'
        f='　あ　'
        strtrim f '　'
        strlen f
        fl = result
        strcompare f #$81#$82
        fc = result
        """)
        XCTAssertEqual(s(i, "a"), "#include <stdio.h>")
        XCTAssertEqual(s(i, "b"), "123***456")
        XCTAssertEqual(s(i, "c"), "")
        XCTAssertEqual(s(i, "d"), "#*;|@123***456")
        XCTAssertEqual(s(i, "e"), "123***456@|;#")
        // バイト単位 (E3 80 80) で消すので、あ (E3 81 82) の E3 も消える
        XCTAssertEqual(n(i, "fl"), 2)
        XCTAssertEqual(n(i, "fc"), 0)
    }

    func testToLowerUpper() throws {
        let (_, i) = try runTTL("""
        tolower a 'Tera TERM Ａｂｃ ÄÖ'
        toupper b 'tera term ａｂｃ äö'
        """)
        XCTAssertEqual(s(i, "a"), "tera term Ａｂｃ ÄÖ")   // ASCII だけ
        XCTAssertEqual(s(i, "b"), "TERA TERM ａｂｃ äö")
    }

    func testSprintfDocExamples() throws {
        let (_, i) = try runTTL("""
        sprintf 'Tera Term 4.%d' 51
        a = inputstr
        sprintf 'Windows %d (+%s)' 2000 'SP4'
        b = inputstr
        sprintf '%s=%d %s=0x%x' 'dec' 10 'hex' 33
        c = inputstr
        sprintf 'pi=%f' "3.14159"
        d = inputstr
        sprintf 'pi=%.4e' "3.14159"
        e = inputstr
        sprintf 'pi=%.4g' "3.14159"
        f = inputstr
        sprintf '[%5d][%-5d][%05d][%+d][%X][%o][%c][%%]' 42 42 42 42 255 8 65
        g = inputstr
        sprintf '[%*d][%*.*s]' 4 7 5 3 'abcdef'
        h = inputstr
        sprintf '[%.*s]' 2 'あいう'
        strlen inputstr
        hl = result
        sprintf '%u' -1
        u = inputstr
        sprintf2 v '%s!' 'あ'
        r = result
        sprintf 'end%'
        k = inputstr
        sprintf '%5%d' 3
        l = inputstr
        """)
        XCTAssertEqual(s(i, "a"), "Tera Term 4.51")
        XCTAssertEqual(s(i, "b"), "Windows 2000 (+SP4)")
        XCTAssertEqual(s(i, "c"), "dec=10 hex=0x21")
        XCTAssertEqual(s(i, "d"), "pi=3.141590")
        XCTAssertEqual(s(i, "e"), "pi=3.1416e+00")
        XCTAssertEqual(s(i, "f"), "pi=3.142")
        XCTAssertEqual(s(i, "g"), "[   42][42   ][00042][+42][FF][10][A][%]")
        XCTAssertEqual(s(i, "h"), "[   7][  abc]")
        XCTAssertEqual(n(i, "hl"), 4)    // 精度はバイト数 (あ の途中で切れる)
        XCTAssertEqual(s(i, "u"), "4294967295")
        XCTAssertEqual(s(i, "v"), "あ!")
        XCTAssertEqual(n(i, "r"), 0)
        XCTAssertEqual(s(i, "k"), "end%")
        XCTAssertEqual(s(i, "l"), "%53")
    }

    func testSprintfPrecisionIsBytes() throws {
        let (_, i) = try runTTL("""
        sprintf2 v '[%.3s]' 'あいう'
        sprintf2 w '[%5s]' 'あ'
        """)
        XCTAssertEqual(s(i, "v"), "[あ]")
        XCTAssertEqual(s(i, "w"), "[  あ]")   // 幅もバイト数
    }

    /// マクロエラーで止まるはずのものを動かして、止まったあとの変数を見る
    private func runExpectingError(_ src: String, file: StaticString = #filePath, line: UInt = #line) throws -> TTLInterpreter {
        let i = try TTLInterpreter(source: src, host: FakeHost())
        XCTAssertThrowsError(try i.run(), file: file, line: line)
        return i
    }

    func testSprintfErrors() throws {
        // 書式が不正: result=2 でマクロエラー、inputstr はそのまま
        let i1 = try runExpectingError("inputstr = 'keep'\nsprintf '%ld' 1")
        XCTAssertEqual(n(i1, "result"), 2)
        XCTAssertEqual(s(i1, "inputstr"), "keep")
        // 引数が不正: result=3
        XCTAssertEqual(n(try runExpectingError("sprintf '%d' 'abc'"), "result"), 3)
        XCTAssertEqual(n(try runExpectingError("sprintf '%s'"), "result"), 3)
        XCTAssertEqual(n(try runExpectingError("sprintf '%*d' 'x' 1"), "result"), 3)
        // 書式がない: result=1
        XCTAssertEqual(n(try runExpectingError("sprintf"), "result"), 1)
        // sprintf2 の変数が不正: result=4
        XCTAssertEqual(n(try runExpectingError("sprintf2 1 '%d' 3"), "result"), 4)
        // 幅の '*' の後ろに数字 → 書式不正 2
        XCTAssertEqual(n(try runExpectingError("sprintf '%0*5d' 1 2"), "result"), 2)
        // '%' の後ろに変換文字以外 → 次の変換文字で 2
        XCTAssertEqual(n(try runExpectingError("sprintf '100%yes' 1"), "result"), 2)
    }

    func testGetDateGetTime() throws {
        let (h, i) = try runTTL("""
        result = 99
        getdate d
        r0 = result
        gettime t
        getdate f '%Y/%m/%d %H:%M:%S' 'GMT'
        r1 = result
        gettime g '%#d|%%|%#m'
        gettime x '%Q'
        r2 = result
        gettime y '%'
        r3 = result
        y2 = 'keep'
        gettime y2 ''
        r4 = result
        gettime z '%Y' 'JST-9'
        gettime c '%c'
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(n(i, "r0"), 99)    // 書式なしなら result は変えない
        XCTAssertNotNil(s(i, "d")?.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression))
        XCTAssertNotNil(s(i, "t")?.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression))
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy/MM/dd HH"
        XCTAssertEqual(s(i, "f")?.prefix(13).description, fmt.string(from: Date()))
        XCTAssertEqual(n(i, "r1"), 0)
        let cal = Calendar.current
        let now = Date()
        XCTAssertEqual(s(i, "g"), "\(cal.component(.day, from: now))|%|\(cal.component(.month, from: now))")
        XCTAssertEqual(n(i, "r2"), 2)
        XCTAssertEqual(s(i, "x"), "")   // getStrVar で作られるだけ
        XCTAssertEqual(n(i, "r3"), 2)
        XCTAssertEqual(n(i, "r4"), 1)       // strftime が 0 を返す
        XCTAssertEqual(s(i, "y2"), "keep")
        XCTAssertNotNil(s(i, "c")?.range(of: #"^\d\d/\d\d/\d\d \d\d:\d\d:\d\d$"#, options: .regularExpression))
        // TZ は元に戻る
        XCTAssertEqual(TimeZone.current.secondsFromGMT(), TimeZone.current.secondsFromGMT())
    }

    func testSetDateSetTimeDoNothing() throws {
        let (h, i) = try runTTL("""
        result = 5
        setdate '1997-08-01'
        settime '12:34:56'
        setdate 'xx'
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(n(i, "result"), 5)
        XCTAssertThrowsError(try runTTL("setdate 1"))
    }

    func testEnv() throws {
        let (_, i) = try runTTL("""
        setenv 'TTLSTRTEST_A' 'あいう'
        getenv 'TTLSTRTEST_A' a
        getenv 'ttlstrtest_a' b
        expandenv c 'x%TTLSTRTEST_A%y%NO_SUCH_VAR_Q%z%'
        d = '%TTLSTRTEST_A%'
        expandenv d
        expandenv f '%NO_SUCH_VAR_Q%TTLSTRTEST_A%'
        expandenv g '100%% %% $HOME ${HOME} %'
        expandenv h '%%TTLSTRTEST_A%'
        setenv 'TTLSTRTEST_A' ''
        getenv 'TTLSTRTEST_A' e
        """)
        XCTAssertEqual(s(i, "a"), "あいう")
        XCTAssertEqual(s(i, "b"), "あいう")          // Windows と同じく大文字小文字を区別しない
        XCTAssertEqual(s(i, "c"), "xあいうy%NO_SUCH_VAR_Q%z%")
        XCTAssertEqual(s(i, "d"), "あいう")
        // 無い名前は開き '%' だけ写してその直後から続ける (RtlExpandEnvironmentStrings_U)
        XCTAssertEqual(s(i, "f"), "%NO_SUCH_VAR_Qあいう")
        XCTAssertEqual(s(i, "g"), "100%% %% $HOME ${HOME} %")   // $VAR は展開しない
        XCTAssertEqual(s(i, "h"), "%あいう")                    // 空の名前も「無い名前」
        XCTAssertEqual(s(i, "e"), "")
        XCTAssertNil(getenv("TTLSTRTEST_A"))
    }

    func testGetVer() throws {
        let (_, i) = try runTTL("""
        result = 99
        getver v
        r0 = result
        getver v '4.56'
        r1 = result
        getver v '99.0'
        r2 = result
        getver v '5.8'
        r3 = result
        w = 'keep'
        getver w 'abc'
        r4 = result
        getver w '5'
        r5 = result
        """)
        XCTAssertEqual(s(i, "v"), "5.8")
        XCTAssertEqual(n(i, "r0"), 99)
        XCTAssertEqual(n(i, "r1"), 1)
        XCTAssertEqual(n(i, "r2"), -1)
        XCTAssertEqual(n(i, "r3"), 0)
        XCTAssertEqual(n(i, "r4"), -2)
        XCTAssertEqual(s(i, "w"), "keep")
        XCTAssertEqual(n(i, "r5"), -2)
    }

    func testGetIPAddr() throws {
        let (h, i) = try runTTL("""
        strdim a 32
        getipv4addr a n4
        r4 = result
        s4 = a[0]
        strdim b 32
        getipv6addr b n6
        r6 = result
        s6 = b[0]
        strdim c 1
        getipv4addr c m
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(n(i, "r4"), 1)
        XCTAssertEqual(n(i, "r6"), 1)
        if let c = n(i, "n4"), c > 0 {
            XCTAssertNotNil(s(i, "s4")?.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression))
            XCTAssertNotEqual(s(i, "s4"), "127.0.0.1")
        }
        if let c = n(i, "n6"), c > 0 {
            XCTAssertNotNil(s(i, "s6")?.range(of: #"^([0-9a-f]{4}:){7}[0-9a-f]{4}$"#, options: .regularExpression))
        }
        if let c = n(i, "m"), c > 1 { XCTAssertEqual(n(i, "result"), 0) }
        XCTAssertThrowsError(try runTTL("getipv4addr nosuch n"))
    }

    func testRandom() throws {
        let (h, i) = try runTTL("""
        mn = 100
        mx = -1
        for k 1 2000
          random v 3
          if v < mn mn = v
          if v > mx mx = v
        next
        random big 2147483647
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(n(i, "mn"), 0)
        XCTAssertEqual(n(i, "mx"), 3)
        XCTAssertGreaterThanOrEqual(n(i, "big") ?? -1, 0)
        XCTAssertThrowsError(try runTTL("random v 0"))
    }

    func testRotate() throws {
        let (_, i) = try runTTL("""
        rotateleft a 1 1
        rotateleft b $80000000 1
        rotateright c 1 1
        rotateleft d $12345678 36
        m4 = -4
        rotateright e $12345678 m4
        rotateleft f 5 0
        """)
        XCTAssertEqual(n(i, "a"), 2)
        XCTAssertEqual(n(i, "b"), 1)
        XCTAssertEqual(n(i, "c"), Int(Int32(bitPattern: 0x80000000)))
        XCTAssertEqual(n(i, "d"), 0x23456781)
        XCTAssertEqual(n(i, "e"), 0x23456781)
        XCTAssertEqual(n(i, "f"), 5)
    }

    func testUptime() throws {
        let (_, i) = try runTTL("uptime t")
        let ms = UInt32(truncatingIfNeeded: clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
        let t = UInt32(bitPattern: Int32(n(i, "t") ?? 0))
        XCTAssertLessThan(ms &- t, 5000)
    }

    func testGetSpecialFolderAndTTDir() throws {
        let (_, i) = try runTTL("""
        getspecialfolder a 'Desktop'
        r1 = result
        getspecialfolder b 'mydocuments'
        r2 = result
        getspecialfolder c 'NoSuchFolder'
        r3 = result
        getttdir d
        r4 = result
        """)
        XCTAssertEqual(s(i, "a"), NSHomeDirectory() + "/Desktop")
        XCTAssertEqual(n(i, "r1"), 1)
        XCTAssertEqual(s(i, "b"), NSHomeDirectory() + "/Documents")
        XCTAssertEqual(n(i, "r2"), 1)
        XCTAssertEqual(s(i, "c"), "")
        XCTAssertEqual(n(i, "r3"), 0)
        XCTAssertEqual(s(i, "d"), Bundle.main.bundlePath)
        XCTAssertEqual(n(i, "r4"), 1)
    }

    func testExec() throws {
        let dir = NSTemporaryDirectory()
        let (h, i) = try runTTL("""
        exec 'exit 3' 'hide' 1
        r1 = result
        exec 'true' 'HIDE'
        r2 = result
        exec 'pwd > ttlexec_out.txt' 'show' 1 '\(dir)'
        r3 = result
        exec 'true' 'show' 1 '/no/such/dir/xyz'
        r4 = result
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(n(i, "r1"), 3)
        XCTAssertEqual(n(i, "r2"), 0)
        XCTAssertEqual(n(i, "r3"), 0)
        XCTAssertEqual(n(i, "r4"), -1)
        let out = try String(contentsOfFile: (dir as NSString).appendingPathComponent("ttlexec_out.txt"))
        XCTAssertEqual((out.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).resolvingSymlinksInPath,
                       ((dir as NSString).standardizingPath as NSString).resolvingSymlinksInPath)
        XCTAssertThrowsError(try runTTL("exec 'true' 'bogus'"))
        XCTAssertThrowsError(try runTTL("exec ''"))
    }

    func testExecNotStartedAndWorkingDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ttlexec-\(UUID().uuidString)")
        let sub = base.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let (h, i) = try runTTL("""
        exec 'ttl_no_such_command_xyz' 'show' 1
        r1 = result
        exec 'ttl_no_such_command_xyz'
        r2 = result
        exec './sub' 'show' 1
        r3 = result
        setdir 'sub'
        exec 'pwd > out1.txt' 'hide' 1
        r4 = result
        exec 'pwd > out2.txt' 'hide' 1 'sub'
        r5 = result
        exec 'sleep 1'
        r6 = result
        """, host: FakeHost(), baseDirURL: base)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(n(i, "r1"), -1)      // 起動できない: 待つとき
        XCTAssertEqual(n(i, "r2"), -1)      // 待たないときも -1
        XCTAssertEqual(n(i, "r3"), -1)      // フォルダは実行できない
        XCTAssertEqual(n(i, "r4"), 0)
        XCTAssertEqual(n(i, "r5"), 0)
        XCTAssertEqual(n(i, "r6"), 0)
        func real(_ p: String) -> String { (p as NSString).resolvingSymlinksInPath }
        // setdir しても既定の作業フォルダはマクロのフォルダのまま
        let o1 = try String(contentsOf: base.appendingPathComponent("out1.txt"))
        XCTAssertEqual(real(o1.trimmingCharacters(in: .whitespacesAndNewlines)), real(base.path))
        // 相対の 4 番目の引数もマクロのフォルダ基準 (setdir 先の sub/sub ではない)
        let o2 = try String(contentsOf: sub.appendingPathComponent("out2.txt"))
        XCTAssertEqual(real(o2.trimmingCharacters(in: .whitespacesAndNewlines)), real(sub.path))
    }

    func testSprintfHexFloatAndSpecials() throws {
        let (h, i) = try runTTL("""
        sprintf2 a1 '%a' '1'
        sprintf2 a2 '%A' '1'
        sprintf2 a3 '%a' '0'
        sprintf2 a4 '%a' '-2'
        sprintf2 a5 '%a' '0.1'
        sprintf2 a6 '%.2a' '1.5'
        sprintf2 a7 '%.0a' '1.5'
        sprintf2 a8 '%#.0a' '1'
        sprintf2 a9 '[%12.1a][%-12.1a][%012.1a][%+.1a]' '1' '1' '1' '1'
        sprintf2 a10 '%.15a' '1'
        sprintf2 a11 '%a' '4.9406564584124654e-324'
        sprintf2 a12 '%.1a' '1.96875'
        sprintf2 a13 '%*.*a' 12 1 '1'
        sprintf2 n1 '%f' 'inf'
        sprintf2 n2 '%e' '-inf'
        sprintf2 n3 '%E' 'inf'
        sprintf2 n4 '%f' 'nan'
        sprintf2 n5 '%g' '-nan'
        sprintf2 n6 '%G' '-nan'
        sprintf2 n7 '[%6.2f][%-6f][%+f]' 'inf' 'inf' 'inf'
        sprintf2 n8 '%f' 'nan(ind)'
        sprintf2 n9 '%f' 'nan(snan)'
        sprintf2 n10 '%a' 'inf'
        sprintf2 f1 '%.2f|%e' '1.005' '12345'
        """)
        XCTAssertEqual(h.errors, [])
        XCTAssertEqual(s(i, "a1"), "0x1.0000000000000p+0")
        XCTAssertEqual(s(i, "a2"), "0X1.0000000000000P+0")
        XCTAssertEqual(s(i, "a3"), "0x0.0000000000000p+0")
        XCTAssertEqual(s(i, "a4"), "-0x1.0000000000000p+1")
        XCTAssertEqual(s(i, "a5"), "0x1.999999999999ap-4")
        XCTAssertEqual(s(i, "a6"), "0x1.80p+0")
        XCTAssertEqual(s(i, "a7"), "0x2p+0")
        XCTAssertEqual(s(i, "a8"), "0x1.p+0")
        XCTAssertEqual(s(i, "a9"), "[    0x1.0p+0][0x1.0p+0    ][0x00001.0p+0][+0x1.0p+0]")
        XCTAssertEqual(s(i, "a10"), "0x1.000000000000000p+0")
        XCTAssertEqual(s(i, "a11"), "0x0.0000000000001p-1022")
        XCTAssertEqual(s(i, "a12"), "0x2.0p+0")
        XCTAssertEqual(s(i, "a13"), "    0x1.0p+0")
        XCTAssertEqual(s(i, "n1"), "inf")
        XCTAssertEqual(s(i, "n2"), "-inf")
        XCTAssertEqual(s(i, "n3"), "INF")
        XCTAssertEqual(s(i, "n4"), "nan")
        XCTAssertEqual(s(i, "n5"), "-nan(ind)")
        XCTAssertEqual(s(i, "n6"), "-NAN(IND)")
        XCTAssertEqual(s(i, "n7"), "[   inf][inf   ][+inf]")
        XCTAssertEqual(s(i, "n8"), "-nan(ind)")
        XCTAssertEqual(s(i, "n9"), "nan(snan)")
        XCTAssertEqual(s(i, "n10"), "inf")
        XCTAssertEqual(s(i, "f1"), "1.00|1.234500e+04")
    }

    func testSetExitCode() throws {
        let (_, i) = try runTTL("setexitcode 7")
        XCTAssertEqual(i.exitCode, 7)
    }
}
