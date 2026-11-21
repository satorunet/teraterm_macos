import XCTest
@testable import TeraCore

/// ファイル操作・パスワード関係のマクロコマンド (TTLFiles.swift)
final class TTLFileTests: XCTestCase {
    var dir = ""

    override func setUpWithError() throws {
        dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ttlfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 読み取り専用にしたものも消せるように戻す
        if let e = FileManager.default.enumerator(atPath: dir) {
            for case let f as String in e { chmod((dir as NSString).appendingPathComponent(f), 0o755) }
        }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// 一時フォルダを setdir してから動かす
    @discardableResult
    func run(_ src: String, host: FakeHost = FakeHost()) throws -> (FakeHost, TTLInterpreter) {
        try runTTL("setdir '\(dir)'\n" + src, host: host)
    }

    func path(_ name: String) -> String { (dir as NSString).appendingPathComponent(name) }
    func write(_ name: String, _ bytes: [UInt8]) throws { try Data(bytes).write(to: URL(fileURLWithPath: path(name))) }
    func writeText(_ name: String, _ s: String) throws { try write(name, Array(s.utf8)) }
    func read(_ name: String) -> [UInt8] { [UInt8](FileManager.default.contents(atPath: path(name)) ?? Data()) }
    func readText(_ name: String) -> String { String(decoding: read(name), as: UTF8.self) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }

    func int(_ i: TTLInterpreter, _ n: String) -> Int? { if case .int(let v)? = i.variable(n) { return v }; return nil }
    func str(_ i: TTLInterpreter, _ n: String) -> String? { if case .str(let v)? = i.variable(n) { return v }; return nil }

    // MARK: - fileopen / filereadln

    func testFileReadlnLineEndings() throws {
        // CRLF, LF, CR だけ, 空行, 最後は改行なし
        try writeText("a.txt", "one\r\ntwo\nthree\rfour\r\n\r\nlast")
        let (_, i) = try run("""
        fileopen fh 'a.txt' 0
        h = fh
        filereadln fh l1
        r1 = result
        filereadln fh l2
        filereadln fh l3
        filereadln fh l4
        filereadln fh l5
        r5 = result
        filereadln fh l6
        r6 = result
        filereadln fh l7
        r7 = result
        fileclose fh
        """)
        XCTAssertEqual(int(i, "h"), 0)
        XCTAssertEqual(str(i, "l1"), "one"); XCTAssertEqual(int(i, "r1"), 0)
        XCTAssertEqual(str(i, "l2"), "two")
        XCTAssertEqual(str(i, "l3"), "three")
        XCTAssertEqual(str(i, "l4"), "four")
        XCTAssertEqual(str(i, "l5"), ""); XCTAssertEqual(int(i, "r5"), 0)
        XCTAssertEqual(str(i, "l6"), "last"); XCTAssertEqual(int(i, "r6"), 0)
        XCTAssertEqual(str(i, "l7"), ""); XCTAssertEqual(int(i, "r7"), 1)
    }

    func testFileReadlnCRAtEOFAndLongLine() throws {
        let long = String(repeating: "x", count: 600)
        try writeText("b.txt", long + "\nend\r")
        let (_, i) = try run("""
        fileopen fh 'b.txt' 0 1
        filereadln fh l1
        filereadln fh l2
        r2 = result
        filereadln fh l3
        r3 = result
        strlen l1
        n1 = result
        fileclose fh
        """)
        XCTAssertEqual(int(i, "n1"), 511)
        XCTAssertEqual(str(i, "l2"), "end"); XCTAssertEqual(int(i, "r2"), 0)
        XCTAssertEqual(int(i, "r3"), 1)
    }

    func testFileOpenModesAndHandles() throws {
        try writeText("c.txt", "abc")
        let (_, i) = try run("""
        fileopen a 'c.txt' 1
        filewrite a 'def'
        fileclose a
        fileopen b 'missing.txt' 0 1
        fileopen c 'new.txt' 0
        fileopen d 'c.txt' 0 1
        filewrite d 'zzz'
        fileclose c
        fileclose d
        fileopen e 'c:bad:name' 0
        """)
        XCTAssertEqual(readText("c.txt"), "abcdef")          // 追記
        XCTAssertEqual(int(i, "b"), -1)                       // 読み取り専用はなければ失敗
        XCTAssertEqual(int(i, "c"), 0)                        // 空いている最初の番号
        XCTAssertEqual(int(i, "d"), 1)
        XCTAssertTrue(exists("new.txt"))                      // 読み書きはなければ作る
        XCTAssertEqual(readText("c.txt"), "abcdef")          // 読み取り専用には書けない
        XCTAssertEqual(int(i, "e"), -1)                       // GetAbsPath の失敗
    }

    func testSixteenHandles() throws {
        let (_, i) = try run("""
        for k 0 16
          sprintf2 n 'h%d.txt' k
          fileopen fh n 0
          last = fh
        next
        fileopen x 'h0.txt' 0
        fileclose 3
        fileopen y 'h0.txt' 0
        """)
        XCTAssertEqual(int(i, "last"), -1)   // 17 個目
        XCTAssertEqual(int(i, "x"), -1)
        XCTAssertEqual(int(i, "y"), 3)
    }

    func testFileOpenSyntaxError() throws {
        XCTAssertThrowsError(try run("fileopen fh '' 0"))
        XCTAssertThrowsError(try run("fileopen fh 'a' 0 0 9"))
    }

    // MARK: - fileread / filewrite

    func testFileReadAndWrite() throws {
        let (_, i) = try run("""
        filecreate fh 'w.bin'
        r0 = result
        filewrite fh 'AB'
        filewrite fh 0
        filewrite fh 256+67
        filewriteln fh '日本'
        fileclose fh
        fileopen fh 'w.bin' 0
        fileread fh 2 s1
        r1 = result
        fileseek fh 1 1
        fileread fh 1 s2
        fileread fh 100 s3
        r3 = result
        fileclose fh
        """)
        XCTAssertEqual(int(i, "r0"), 0)
        XCTAssertEqual(read("w.bin"), [0x41, 0x42, 0x00, 0x43] + Array("日本".utf8) + [0x0D, 0x0A])
        XCTAssertEqual(str(i, "s1"), "AB"); XCTAssertEqual(int(i, "r1"), 0)
        XCTAssertEqual(str(i, "s2"), "C")
        XCTAssertEqual(str(i, "s3"), "日本\r\n"); XCTAssertEqual(int(i, "r3"), 1)
    }

    func testFileReadExactAndRange() throws {
        try writeText("e.txt", "1234")
        let (_, i) = try run("""
        fileopen fh 'e.txt' 0
        fileread fh 4 s
        r = result
        fileread fh 1 t
        r2 = result
        """)
        XCTAssertEqual(str(i, "s"), "1234"); XCTAssertEqual(int(i, "r"), 0)
        XCTAssertEqual(str(i, "t"), ""); XCTAssertEqual(int(i, "r2"), 1)
        XCTAssertThrowsError(try run("fileopen fh 'e.txt' 0\nfileread fh 0 s"))
        XCTAssertThrowsError(try run("fileopen fh 'e.txt' 0\nfileread fh 512 s"))
    }

    func testFileWriteSyntax() throws {
        XCTAssertThrowsError(try run("filecreate fh 'x'\nfilewrite fh 'a' 'b'"))
    }

    func testInvalidHandleReadln() throws {
        let (_, i) = try run("""
        filereadln 5 s
        r = result
        fileread 99 3 t
        r2 = result
        filewrite 7 'x'
        fileclose 9
        """)
        XCTAssertEqual(int(i, "r"), 1); XCTAssertEqual(str(i, "s"), "")
        XCTAssertEqual(int(i, "r2"), 1)
    }

    // MARK: - ファイルポインタ

    func testSeekMarkPtr() throws {
        try writeText("s.txt", "0123456789")
        let (_, i) = try run("""
        fileopen fh 's.txt' 0
        fileseek fh 3 0
        filemarkptr fh
        fileread fh 2 a
        fileseekback fh
        fileread fh 1 b
        m2 = -2
        fileseek fh m2 2
        fileread fh 2 c
        m100 = -100
        fileseek fh m100 1
        fileread fh 1 d
        fileseek fh 0 5
        fileread fh 1 e
        """)
        XCTAssertEqual(str(i, "a"), "34")
        XCTAssertEqual(str(i, "b"), "3")
        XCTAssertEqual(str(i, "c"), "89")
        XCTAssertEqual(str(i, "d"), "")   // 先頭より前には動かない (EOF のまま)
        XCTAssertEqual(str(i, "e"), "")
    }

    func testFileStrSeek() throws {
        try writeText("f.txt", "aaab xx aab yy")
        let (_, i) = try run("""
        fileopen fh 'f.txt' 0
        filestrseek fh 'aab'
        r1 = result
        fileread fh 3 a
        filestrseek fh 'aab'
        r2 = result
        fileread fh 3 b
        filestrseek fh 'zzz'
        r3 = result
        fileread fh 2 c
        """)
        // 単純な比較なので "aaab" の中の "aab" は見つからない (元のコードと同じ)
        XCTAssertEqual(int(i, "r1"), 1); XCTAssertEqual(str(i, "a"), " yy")
        XCTAssertEqual(int(i, "r2"), 0); XCTAssertEqual(str(i, "b"), "")
        XCTAssertEqual(int(i, "r3"), 0)
    }

    func testFileStrSeek2() throws {
        try writeText("g.txt", "abc-xyz-abc-end")
        let (_, i) = try run("""
        fileopen fh 'g.txt' 1
        filestrseek2 fh 'abc'
        r1 = result
        filemarkptr fh
        fileread fh 5 a
        fileseekback fh
        filestrseek2 fh 'abc'
        r2 = result
        fileread fh 3 b
        filestrseek2 fh 'q'
        r3 = result
        fileread fh 1 c
        fileseek fh 0 0
        filestrseek2 fh 'a'
        r4 = result
        """)
        // 見つかったら文字列の直前、ファイルの先頭ならゼロオフセット
        XCTAssertEqual(int(i, "r1"), 1); XCTAssertEqual(str(i, "a"), "-abc-")
        XCTAssertEqual(int(i, "r2"), 1); XCTAssertEqual(str(i, "b"), "abc")
        XCTAssertEqual(int(i, "r3"), 0); XCTAssertEqual(str(i, "c"), "-")
        XCTAssertEqual(int(i, "r4"), 1)   // ポインタ 0 でも 1 バイト目は調べる (元のコードの動き)
    }

    func testFileStrSeek2SkipsLastByteAtEOF() throws {
        // EOF から始めると最後の 1 バイトは調べない (元のコードの動き)
        try writeText("h.txt", "xa")
        let (_, i) = try run("""
        fileopen fh 'h.txt' 1
        filestrseek2 fh 'a'
        r = result
        """)
        XCTAssertEqual(int(i, "r"), 0)
    }

    // MARK: - filelock

    func testFileLock() throws {
        try writeText("l.txt", "x")
        let (_, i) = try run("""
        fileopen a 'l.txt' 0
        fileopen b 'l.txt' 0
        filelock a 0
        r1 = result
        filelock b 0
        r2 = result
        filelock a 0
        r3 = result
        fileunlock a
        r4 = result
        fileunlock a
        r5 = result
        filelock b 1
        r6 = result
        filelock 12 0
        r7 = result
        fileunlock 13
        r8 = result
        """)
        XCTAssertEqual(int(i, "r1"), 0)
        XCTAssertEqual(int(i, "r2"), 1)
        XCTAssertEqual(int(i, "r3"), 1)
        XCTAssertEqual(int(i, "r4"), 0)
        XCTAssertEqual(int(i, "r5"), 1)
        XCTAssertEqual(int(i, "r6"), 0)
        XCTAssertEqual(int(i, "r7"), 1)
        XCTAssertEqual(int(i, "r8"), 1)
    }

    // MARK: - ファイル単位

    func testFileCreateTruncates() throws {
        try writeText("t.txt", "old content")
        let (_, i) = try run("""
        filecreate fh 't.txt'
        r = result
        filewrite fh 'new'
        fileclose fh
        filecreate g 'nodir/x.txt'
        r2 = result
        """)
        XCTAssertEqual(int(i, "r"), 0)
        XCTAssertEqual(readText("t.txt"), "new")
        XCTAssertEqual(int(i, "g"), -1); XCTAssertEqual(int(i, "r2"), 2)
    }

    func testFileConcat() throws {
        try writeText("1.txt", "abc")
        try writeText("2.txt", String(repeating: "0123456789", count: 10))
        let (_, i) = try run("""
        fileconcat '1.txt' '2.txt'
        r1 = result
        fileconcat '1.txt' '1.TXT'
        r2 = result
        fileconcat 'new.txt' 'none.txt'
        r3 = result
        fileconcat 'nodir/a' '2.txt'
        r4 = result
        fileconcat 'a:b:c' '2.txt'
        r5 = result
        foldercreate 'fold'
        fileconcat '1.txt' 'fold'
        r6 = result
        fileconcat '1.txt' './1.txt'
        r7 = result
        fileconcat '1.txt' '\(dir)/1.txt'
        r8 = result
        """)
        XCTAssertEqual(int(i, "r1"), 0)
        XCTAssertEqual(readText("1.txt"), "abc" + String(repeating: "0123456789", count: 10))
        XCTAssertEqual(int(i, "r2"), 2)
        XCTAssertEqual(int(i, "r3"), 0); XCTAssertTrue(exists("new.txt"))   // 元のコードと同じく 0
        XCTAssertEqual(int(i, "r4"), 3)
        XCTAssertEqual(int(i, "r5"), -1)
        // フォルダは開けないので何もしないで 0
        XCTAssertEqual(int(i, "r6"), 0)
        // 書き方が違う同じファイル: _stricmp では別物、2 つ目は共有違反で開けない → 0、何も足さない
        XCTAssertEqual(int(i, "r7"), 0)
        XCTAssertEqual(int(i, "r8"), 2)     // GetAbsPath の結果が同じ文字列
        XCTAssertEqual(readText("1.txt"), "abc" + String(repeating: "0123456789", count: 10))
        XCTAssertThrowsError(try run("fileconcat '1.txt' ''"))
    }

    func testFileCopy() throws {
        try writeText("src.txt", "data")
        try writeText("ro.txt", "ro")
        chmod(path("ro.txt"), 0o444)
        let (_, i) = try run("""
        filecopy 'src.txt' 'dst.txt'
        r1 = result
        filecopy 'src.txt' 'dst.txt'
        r2 = result
        filecopy 'src.txt' 'SRC.TXT'
        r3 = result
        filecopy 'none.txt' 'x.txt'
        r4 = result
        filecopy 'src.txt' 'ro.txt'
        r5 = result
        filecopy 'x:y:z' 'x'
        r6 = result
        filecopy 'src.txt' 'x:y:z'
        r7 = result
        filecopy 'src.txt' './src.txt'
        r8 = result
        filecopy 'src.txt' '\(dir)/SRC.txt'
        r9 = result
        """)
        XCTAssertEqual(int(i, "r1"), 0); XCTAssertEqual(readText("dst.txt"), "data")
        XCTAssertEqual(int(i, "r2"), 0)    // 上書きする
        XCTAssertEqual(int(i, "r3"), -3)
        XCTAssertEqual(int(i, "r4"), -4)
        XCTAssertEqual(int(i, "r5"), -4); XCTAssertEqual(readText("ro.txt"), "ro")
        XCTAssertEqual(int(i, "r6"), -1)
        XCTAssertEqual(int(i, "r7"), -2)
        // 書き方が違う同じファイル: CopyFileW が失敗する → -4。中身はそのまま
        XCTAssertEqual(int(i, "r8"), -4); XCTAssertEqual(readText("src.txt"), "data")
        XCTAssertEqual(int(i, "r9"), -3)
    }

    func testFileRenameDeleteSearch() throws {
        try writeText("a.txt", "a")
        try writeText("b.txt", "b")
        try writeText("ro.txt", "r")
        chmod(path("ro.txt"), 0o444)
        let (_, i) = try run("""
        filerename 'a.txt' 'A.TXT'
        r1 = result
        filerename 'a.txt' 'b.txt'
        r2 = result
        filerename 'a.txt' 'ファイル.txt'
        r3 = result
        filerename 'none' 'x'
        r4 = result
        filesearch 'ファイル.txt'
        s1 = result
        filesearch 'a.txt'
        s2 = result
        filedelete 'ファイル.txt'
        d1 = result
        filedelete 'ファイル.txt'
        d2 = result
        filedelete 'ro.txt'
        d3 = result
        filesearch '.'
        s3 = result
        """)
        XCTAssertEqual(int(i, "r1"), 2)
        XCTAssertEqual(int(i, "r2"), -3); XCTAssertEqual(readText("b.txt"), "b")
        XCTAssertEqual(int(i, "r3"), 0)
        XCTAssertEqual(int(i, "r4"), -3)
        XCTAssertEqual(int(i, "s1"), 1)
        XCTAssertEqual(int(i, "s2"), 0)
        XCTAssertEqual(int(i, "d1"), 0)
        XCTAssertEqual(int(i, "d2"), -1)
        XCTAssertEqual(int(i, "d3"), -1)     // 読み取り専用は消せない (DeleteFile と同じ)
        XCTAssertEqual(int(i, "s3"), 1)
        XCTAssertThrowsError(try run("filedelete ''"))
    }

    func testFileTruncate() throws {
        try writeText("t.bin", "0123456789")
        let (_, i) = try run("""
        filetruncate 't.bin' 4
        r1 = result
        filetruncate 't.bin' 6
        r2 = result
        filetruncate 'new.bin' 3
        r3 = result
        filetruncate 't.bin' -1
        r4 = result
        """)
        XCTAssertEqual(int(i, "r1"), 0); XCTAssertEqual(int(i, "r2"), 0)
        XCTAssertEqual(read("t.bin"), Array("0123".utf8) + [0, 0])
        XCTAssertEqual(int(i, "r3"), 0); XCTAssertEqual(read("new.bin"), [0, 0, 0])
        XCTAssertEqual(int(i, "r4"), -1)
        XCTAssertThrowsError(try run("filetruncate 't.bin'"))
    }

    func testFileStat() throws {
        try writeText("st.txt", "12345")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path("st.txt"))
        try FileManager.default.createDirectory(atPath: path("sub"), withIntermediateDirectories: false)
        let (_, i) = try run("""
        filestat 'st.txt' size mtime drive
        r1 = result
        filestat 'c:st2.txt' size2
        r2 = result
        filestat 'sub' size3
        r3 = result
        filestat 'st.txt' size4
        r4 = result
        """)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(int(i, "r1"), 0)
        XCTAssertEqual(int(i, "size"), 5)
        XCTAssertEqual(str(i, "mtime"), f.string(from: date))
        XCTAssertEqual(str(i, "drive"), "?")
        XCTAssertEqual(int(i, "r2"), -1)
        XCTAssertEqual(int(i, "r3"), -1)      // フォルダは CreateFile で開けない
        XCTAssertEqual(int(i, "r4"), 0); XCTAssertEqual(int(i, "size4"), 5)
    }

    // MARK: - findfirst

    func testFindFirstNext() throws {
        for n in ["b.txt", "A.TXT", "日本語.txt", "c.log", "d.txt.bak"] { try writeText(n, "x") }
        let (_, i) = try run("""
        findfirst dh '*.txt' n1
        h = dh
        r1 = result
        findnext dh n2
        findnext dh n3
        findnext dh n4
        r4 = result
        findclose dh
        findnext dh n5
        r5 = result
        findfirst dh2 '*.zip' z
        rz = result
        hz = dh2
        findfirst dh3 '' all
        findclose dh3
        findfirst dh4 'c.*' cc
        findclose dh4
        """)
        XCTAssertEqual(int(i, "h"), 0); XCTAssertEqual(int(i, "r1"), 1)
        XCTAssertEqual([str(i, "n1"), str(i, "n2"), str(i, "n3")], ["A.TXT", "b.txt", "日本語.txt"])
        XCTAssertEqual(str(i, "n4"), ""); XCTAssertEqual(int(i, "r4"), 0)
        XCTAssertEqual(int(i, "r5"), 0)
        XCTAssertEqual(int(i, "rz"), 0); XCTAssertEqual(int(i, "hz"), -1); XCTAssertEqual(str(i, "z"), "")
        XCTAssertEqual(str(i, "all"), ".")    // FindFirstFile は "." から返す
        XCTAssertEqual(str(i, "cc"), "c.log")
    }

    func testFindFirstLimit() throws {
        try writeText("x.txt", "x")
        let (_, i) = try run("""
        for k 1 9
          findfirst dh '*.txt' n
          last = dh
        next
        findclose 2
        findfirst again '?.txt' m
        """)
        XCTAssertEqual(int(i, "last"), -1)
        XCTAssertEqual(int(i, "again"), 2)
        XCTAssertEqual(str(i, "m"), "x.txt")
    }

    // MARK: - フォルダ

    func testFolders() throws {
        let (_, i) = try run("""
        foldercreate 'フォルダ'
        r1 = result
        foldercreate 'フォルダ'
        r2 = result
        foldersearch 'フォルダ'
        s1 = result
        filecreate fh 'フォルダ/a.txt'
        fileclose fh
        folderdelete 'フォルダ'
        r3 = result
        filedelete 'フォルダ/a.txt'
        folderdelete 'フォルダ'
        r4 = result
        foldersearch 'フォルダ'
        s2 = result
        foldercreate 'x:y:z'
        r5 = result
        """)
        XCTAssertEqual(int(i, "r1"), 0)
        XCTAssertEqual(int(i, "r2"), 2)
        XCTAssertEqual(int(i, "s1"), 1)
        XCTAssertEqual(int(i, "r3"), 2)     // 空でなければ消さない
        XCTAssertEqual(int(i, "r4"), 0)
        XCTAssertEqual(int(i, "s2"), 0)
        XCTAssertEqual(int(i, "r5"), -1)
        XCTAssertThrowsError(try run("foldercreate ''"))
    }

    // MARK: - 属性

    func testFileAttributes() throws {
        try writeText("f.txt", "x")
        try writeText(".hidden", "x")
        try FileManager.default.createDirectory(atPath: path("d"), withIntermediateDirectories: false)
        let (_, i) = try run("""
        getfileattr 'f.txt'
        a1 = result
        getfileattr 'd'
        a2 = result
        getfileattr 'none'
        a3 = result
        getfileattr '.hidden'
        a4 = result
        setfileattr 'f.txt' $21
        s1 = result
        getfileattr 'f.txt'
        a5 = result
        setfileattr 'f.txt' $22
        s2 = result
        getfileattr 'f.txt'
        a6 = result
        setfileattr 'f.txt' $80
        getfileattr 'f.txt'
        a7 = result
        setfileattr 'none' 1
        s3 = result
        """)
        XCTAssertEqual(int(i, "a1"), 0x20)
        XCTAssertEqual(int(i, "a2"), 0x10)
        XCTAssertEqual(int(i, "a3"), -1)
        XCTAssertEqual(int(i, "a4"), 0x22)
        XCTAssertEqual(int(i, "s1"), 1); XCTAssertEqual(int(i, "a5"), 0x21)
        XCTAssertEqual(int(i, "s2"), 1); XCTAssertEqual(int(i, "a6"), 0x22)
        XCTAssertEqual(int(i, "a7"), 0x20)
        XCTAssertEqual(int(i, "s3"), 0)
    }

    // MARK: - パス

    func testDirAndPathStrings() throws {
        try FileManager.default.createDirectory(atPath: path("sub"), withIntermediateDirectories: false)
        let (_, i) = try run("""
        getdir d0
        setdir 'sub'
        getdir d1
        setdir 'nothere'
        getdir d2
        setdir '..'
        getdir d3
        makepath p1 'c:\\teraterm' 'test.txt'
        makepath p2 '/Users/x/' 'test.txt'
        makepath p3 '/Users/x' 'test.txt'
        basename b1 'c:\\teraterm\\test.txt'
        basename b2 '/Users/x/テスト.txt'
        basename b3 'noslash'
        dirname n1 'c:\\teraterm\\test.txt'
        dirname n2 'c:\\teraterm\\'
        dirname n3 'c:\\teraterm'
        dirname n4 '/Users/x/テスト.txt'
        dirname n5 'noslash'
        basename b4 'a:b:c'
        """)
        let real = (dir as NSString).standardizingPath
        XCTAssertEqual(str(i, "d0"), real)
        XCTAssertEqual(str(i, "d1"), (real as NSString).appendingPathComponent("sub"))
        XCTAssertEqual(str(i, "d2"), (real as NSString).appendingPathComponent("sub"))
        XCTAssertEqual(str(i, "d3"), real)
        XCTAssertEqual(str(i, "p1"), "c:\\teraterm\\test.txt")
        XCTAssertEqual(str(i, "p2"), "/Users/x/test.txt")
        XCTAssertEqual(str(i, "p3"), "/Users/x/test.txt")
        XCTAssertEqual(str(i, "b1"), "test.txt")
        XCTAssertEqual(str(i, "b2"), "テスト.txt")
        XCTAssertEqual(str(i, "b3"), "noslash")
        XCTAssertEqual(str(i, "n1"), "c:\\teraterm")
        XCTAssertEqual(str(i, "n2"), "c:")
        XCTAssertEqual(str(i, "n3"), "c:")
        XCTAssertEqual(str(i, "n4"), "/Users/x")
        XCTAssertEqual(str(i, "n5"), "")
        XCTAssertEqual(str(i, "b4"), "")
    }

    // MARK: - checksum / crc

    func testChecksumKnownAnswers() throws {
        try writeText("k.txt", "123456789")
        try writeText("empty.txt", "")
        // crc*file / checksum*file は CreateFile に名前をそのまま渡す: 相対パスはマクロのフォルダ基準
        let (_, i) = try runTTL("""
        crc32 c32 '123456789'
        crc16 c16 '123456789'
        checksum8 s8 '123456789'
        checksum16 s16 '123456789'
        checksum32 s32 '123456789'
        crc32 cj 'あ'
        crc32file f32 'k.txt'
        r1 = result
        crc16file f16 'k.txt'
        checksum8file f8 'k.txt'
        checksum16file fs16 'k.txt'
        checksum32file fs32 'k.txt'
        crc32file none 'none.txt'
        r2 = result
        e = 7
        crc32file e 'empty.txt'
        r3 = result
        x = 5
        crc32 x ''
        foldercreate 'sub'
        setdir 'sub'
        crc32file f32b 'k.txt'
        r4 = result
        crc32file f32c '../k.txt'
        r5 = result
        """, host: FakeHost(), baseDirURL: URL(fileURLWithPath: dir))
        XCTAssertEqual(int(i, "c32"), Int(Int32(bitPattern: 0xCBF43926)))   // -873187034
        XCTAssertEqual(int(i, "c32"), -873187034)
        XCTAssertEqual(int(i, "c16"), 0x906E)          // CRC-16/X-25
        XCTAssertEqual(int(i, "s8"), 477 & 0xFF)
        XCTAssertEqual(int(i, "s16"), 477)
        XCTAssertEqual(int(i, "s32"), 477)
        // "あ" = E3 81 82
        let a: [UInt8] = [0xE3, 0x81, 0x82]
        let expect = a.withUnsafeBytes { TTLInterpreter.checksumValue(.crc32, $0) }
        XCTAssertEqual(int(i, "cj"), Int(Int32(bitPattern: expect)))
        XCTAssertEqual(int(i, "f32"), -873187034); XCTAssertEqual(int(i, "r1"), 0)
        XCTAssertEqual(int(i, "f16"), 0x906E)
        XCTAssertEqual(int(i, "f8"), 0xDD)
        XCTAssertEqual(int(i, "fs16"), 477)
        XCTAssertEqual(int(i, "fs32"), 477)
        XCTAssertEqual(int(i, "r2"), -1)
        XCTAssertEqual(int(i, "r3"), -1); XCTAssertEqual(int(i, "e"), 7)    // 空ファイルは CreateFileMapping が失敗
        XCTAssertEqual(int(i, "x"), 5)                                       // 空文字列は何もしない
        // setdir しても crc32file の相対パスは最初のフォルダ基準のまま
        XCTAssertEqual(int(i, "f32b"), -873187034); XCTAssertEqual(int(i, "r4"), 0)
        XCTAssertEqual(int(i, "r5"), -1)
    }

    // MARK: - ttmenc.c

    /// ttmenc.c を MSVC の rand() (srand(0x2345)) と一緒にコンパイルして得た値
    func testEncryptKnownAnswer() {
        let cases: [(String, String)] = [
            ("a", "40h,,>"),
            ("password", "44h\",'1nKma&>M@^!J=^Hff>"),
            ("Sesame!123", "4lhp,71nKiaE>e@T!6=KHZf?\\?Cd&>"),
            ("日本語pass", "4Qhc,@1`K,av>b@[!(=BH\"f+\\OCz&|(_|Z0q2\\"),
        ]
        for (plain, enc) in cases {
            XCTAssertEqual(TTLPasswordCrypto.encrypt(Array(plain.utf8), seed: 0x2345).u8, enc, plain)
            XCTAssertEqual(TTLPasswordCrypto.decrypt(Array(enc.utf8)).u8, plain, plain)
        }
        // 別の種でも戻せる
        for seed: UInt32 in [0, 1, 0xFFFF, 12345] {
            let e = TTLPasswordCrypto.encrypt(Array("p@ss w0rd".utf8), seed: seed)
            XCTAssertTrue(e.allSatisfy { $0 >= 0x21 && $0 <= 0x7E })
            XCTAssertEqual(TTLPasswordCrypto.decrypt(e).u8, "p@ss w0rd")
        }
        XCTAssertEqual(TTLPasswordCrypto.decrypt(Array("garbage".utf8)), [])
        XCTAssertEqual(TTLPasswordCrypto.encrypt([], seed: 1), [])
    }

    func testSetGetPasswordRoundTrip() throws {
        let (h, i) = try run("""
        setpassword 'pw.dat' 'foo' 'secret'
        r1 = result
        setpassword 'pw.dat' 'bar' 'パスワード'
        getpassword 'pw.dat' 'foo' p1
        r2 = result
        getpassword 'pw.dat' 'BAR' p2
        ispassword 'pw.dat' 'foo'
        i1 = result
        ispassword 'pw.dat' 'baz'
        i2 = result
        getpassword 'pw.dat' 'baz' p3
        r3 = result
        delpassword 'pw.dat' 'foo'
        ispassword 'pw.dat' 'foo'
        i3 = result
        ispassword 'pw.dat' 'bar'
        i4 = result
        setpassword 'pw.dat' 'bar' 'changed'
        getpassword 'pw.dat' 'bar' p4
        """)
        XCTAssertEqual(int(i, "r1"), 1)
        XCTAssertEqual(str(i, "p1"), "secret"); XCTAssertEqual(int(i, "r2"), 1)
        XCTAssertEqual(str(i, "p2"), "パスワード")
        XCTAssertEqual(int(i, "i1"), 1); XCTAssertEqual(int(i, "i2"), 0)
        XCTAssertEqual(str(i, "p3"), "typed"); XCTAssertEqual(int(i, "r3"), 1)   // ダイアログで入力
        XCTAssertEqual(int(i, "i3"), 0); XCTAssertEqual(int(i, "i4"), 1)
        XCTAssertEqual(str(i, "p4"), "changed")
        _ = h
        // INI の形 (CRLF、[Password] セクション)
        let text = readText("pw.dat")
        let lines = text.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.first, "[Password]")
        XCTAssertEqual(lines.count, 4)            // [Password], bar=, baz=, ""
        XCTAssertTrue(lines[1].hasPrefix("bar="))
        XCTAssertTrue(lines[2].hasPrefix("baz="))
        XCTAssertEqual(lines[3], "")
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let v = String(lines[1].dropFirst(4))
        XCTAssertEqual(TTLPasswordCrypto.decrypt(Array(v.utf8)).u8, "changed")
    }

    func testPasswordFileFromWindows() throws {
        // Windows で作ったファイル (CRLF、ほかのセクション、空白付きのキー) を読み書きする
        let win = "[Other]\r\nfoo=x\r\n\r\n[password]\r\n foo = 44h\",'1nKma&>M@^!J=^Hff>\r\nkeep=1\r\n\r\n[Last]\r\nz=1\r\n"
        try writeText("win.dat", win)
        let (_, i) = try run("""
        getpassword 'win.dat' 'FOO' p
        r = result
        setpassword 'win.dat' 'new' 'abc'
        delpassword 'win.dat' 'keep'
        getpassword 'win.dat' 'new' q
        """)
        XCTAssertEqual(str(i, "p"), "password"); XCTAssertEqual(int(i, "r"), 1)
        XCTAssertEqual(str(i, "q"), "abc")
        let lines = readText("win.dat").components(separatedBy: "\r\n")
        XCTAssertEqual(Array(lines[0..<5]), ["[Other]", "foo=x", "", "[password]", " foo = 44h\",'1nKma&>M@^!J=^Hff>"])
        XCTAssertTrue(lines[5].hasPrefix("new="))
        XCTAssertEqual(Array(lines[6...]), ["", "[Last]", "z=1", ""])
        // セクションごと消す
        try run("delpassword 'win.dat' ''")
        XCTAssertEqual(readText("win.dat"), "[Other]\r\nfoo=x\r\n\r\n[Last]\r\nz=1\r\n")
    }

    func testPasswordDialogClosedEndsMacro() throws {
        final class CloseHost: TTLHost {
            func ttlSend(_ bytes: [UInt8], mode: TTLSendMode) {}
            func ttlMessageBox(_ text: String, title: String) -> Bool { true }
            func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? { nil }
            func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool { true }
        }
        let host = CloseHost()
        let i = try TTLInterpreter(source: "setdir '\(dir)'\nx = 1\ngetpassword 'none.dat' 'foo' p\nx = 2\n", host: host)
        try i.run()
        XCTAssertEqual(int(i, "x"), 1)
        XCTAssertFalse(exists("none.dat"))
    }

    func testPasswordSyntax() throws {
        XCTAssertThrowsError(try run("setpassword 'a' 'b' ''"))
        XCTAssertThrowsError(try run("ispassword 'a' ''"))
        let (_, i) = try run("""
        p = 'x'
        getpassword '' 'foo' p
        """)
        XCTAssertEqual(str(i, "p"), "")   // 空にしてから戻る
    }

    // MARK: - ttmenc2.c

    /// ttmenc2.c を OpenSSL とつないで、salt を 0x10.. 0x20.. 0x30.. に固定して得た行
    static let encrypt2KAT = "AAIQERITFBUWFxgZGhscHR4ftAdZYllP7ESgTLfipRo5asOy+6TuFrQBE3WnVjL36YI8iALBr8kNINT7BUI3pGIbh127lFxRF2Y3YqpJQl/YASAhIiMkJSYnKCkqKywtLi8sTjd2KkT/kf6h1Mr3AdhcXupPVhimnvW7GHcUBfOm9P52Cz1iM7iCpwkJHJ4pygzxCDAjNYiLp8YrHIRex185mJJw4mfUSvVoMA0kMNJrA/RtBgIDQuU0fyeU+xrgJV53ogWQBlin7Rr6VjxW+NJzmqYmnqvBRkqm0sT47Itj/e8cbRQTaPInOIbMDX8RRL6l3aGPr7qXES0n1HeT7jHYDCoDCVhS0+toxQvoa/SfuVirLLOgUL0wQLpH6Hrmd9zOeG01CjhDaONvNgmBwv0wseL6RijSvIB+4dZjxsSynkgswuz6y2UlWqlYRsCRLXTsGcrpsQi5LnXcF+Xq23kdANAY5r/W/BTEk2zWePKZmn6fF9iyqYb32dtz"

    func testEncrypt2KnownAnswer() throws {
        let salt = { (b: UInt8) in (0..<16).map { b + UInt8($0) } }
        let p = try XCTUnwrap(TTLEncrypt2.makeProfile(key: Array("foo".utf8), pass: Array("bar".utf8),
                                                      encryptStr: Array("Sesame!".utf8),
                                                      keySalt: salt(0x10), passSalt: salt(0x20), encSalt: salt(0x30)))
        XCTAssertEqual(TTLEncrypt2.b64encode(p).u8, TTLFileTests.encrypt2KAT)
        // Windows で書いたファイルとして読む
        try writeText("pw2.dat", TTLFileTests.encrypt2KAT + "\r\n")
        let (_, i) = try run("""
        ispassword2 'pw2.dat' 'foo'
        i1 = result
        ispassword2 'pw2.dat' 'Foo'
        i2 = result
        getpassword2 'pw2.dat' 'foo' pw 'Sesame!'
        r1 = result
        getpassword2 'pw2.dat' 'foo' bad 'wrong'
        r2 = result
        """)
        XCTAssertEqual(int(i, "i1"), 1)
        XCTAssertEqual(int(i, "i2"), 0)       // 識別子は大文字小文字を区別する
        XCTAssertEqual(str(i, "pw"), "bar"); XCTAssertEqual(int(i, "r1"), 1)
        XCTAssertEqual(str(i, "bad"), ""); XCTAssertEqual(int(i, "r2"), 0)
    }

    func testEncrypt2RoundTrip() throws {
        try writeText("p2.dat", "not a profile line\r\n")
        let host = FakeHost()
        host.inputs = ["入力した"]
        let (_, i) = try run("""
        setpassword2 'p2.dat' 'foo' 'bar' 'key1'
        r1 = result
        setpassword2 'p2.dat' 'baz' 'パス' 'key1'
        getpassword2 'p2.dat' 'baz' g1 'key1'
        r2 = result
        setpassword2 'p2.dat' 'foo' 'bar2' 'key1'
        getpassword2 'p2.dat' 'foo' g2 'key1'
        getpassword2 'p2.dat' 'new' g3 'key1'
        r3 = result
        ispassword2 'p2.dat' 'new'
        i1 = result
        delpassword2 'p2.dat' 'baz'
        ispassword2 'p2.dat' 'baz'
        i2 = result
        ispassword2 'p2.dat' 'foo'
        i3 = result
        """, host: host)
        XCTAssertEqual(int(i, "r1"), 1)
        XCTAssertEqual(str(i, "g1"), "パス"); XCTAssertEqual(int(i, "r2"), 1)
        XCTAssertEqual(str(i, "g2"), "bar2")
        XCTAssertEqual(str(i, "g3"), "入力した"); XCTAssertEqual(int(i, "r3"), 1)
        XCTAssertEqual(int(i, "i1"), 1)
        XCTAssertEqual(int(i, "i2"), 0)
        XCTAssertEqual(int(i, "i3"), 1)
        let lines = readText("p2.dat").components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 4)          // ほかの行 + foo + new + ""
        XCTAssertEqual(lines[0], "not a profile line")
        XCTAssertEqual(lines[1].count, 508)
        // 全部消す (Encrypt2 でない行は残る)
        try run("delpassword2 'p2.dat' ''")
        XCTAssertEqual(readText("p2.dat"), "not a profile line\r\n")
        XCTAssertThrowsError(try run("setpassword2 'p2.dat' 'a' 'b' ''"))
        XCTAssertThrowsError(try run("delpassword2 '' 'a'"))
        // 長すぎるパスワード (203 バイトを超える) は失敗
        let (_, j) = try run("setpassword2 'p2.dat' 'a' '\(String(repeating: "x", count: 204))' 'k'\nr = result")
        XCTAssertEqual(int(j, "r"), 0)
    }
}
