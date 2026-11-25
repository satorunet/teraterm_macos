// Tera Term マクロ (TTL) 処理系の中心部分。
// teraterm/ttpmacro の ttmparse.cpp / ttmbuff.c / ttl.cpp / ttmmain.cpp を Swift に移したもの。
// 元のコード: Copyright (C) 1994-1998 T. Teranishi, (C) 2004- TeraTerm Project (BSD 3-Clause)
//
// 文字列は Tera Term 5 と同じく UTF-8 のバイト列として扱う (strlen などはバイト数)。

import Foundation
import COniguruma

let MaxNameLen = 32
let MaxStrLen = 512
let MaxLineLen = 1024

/// エラー番号 (ttmparse.h)
enum E {
    static let closeParent = 1, cantCall = 2, cantConnect = 3, cantOpen = 4, divByZero = 5
    static let invalidCtl = 6, labelAlreadyDef = 7, labelReq = 8, linkFirst = 9, stackOver = 10
    static let syntax = 11, tooManyLabels = 12, tooManyVar = 13, typeMismatch = 14, varNotInit = 15
    static let closeComment = 16, outOfRange = 17, closeBracket = 18, fewMemory = 19, notSupported = 20
    static let cantExec = 21
    /// Tera Term Mac で足した: 一度つながった端末ウインドウが閉じた (本家 #1462)。
    /// 番号は外に見せない (reportError で linkFirst の代わりに文言だけ変える)
    static let linkLost = 101

    static func message(_ e: Int) -> String {
        switch e {
        case closeParent: return "\")\" expected."
        case cantCall: return "Can't call sub."
        case cantConnect: return "Can't link macro."
        case cantOpen: return "Can't open file."
        case divByZero: return "Divide by zero."
        case invalidCtl: return "Invalid control."
        case labelAlreadyDef: return "Label already defined."
        case labelReq: return "Label requiered."
        case linkFirst: return "Link macro first. Use 'connect' macro."
        case stackOver: return "Stack overflow."
        case syntax: return "Syntax error."
        case tooManyLabels: return "Too many labels."
        case tooManyVar: return "Too many variables."
        case typeMismatch: return "Type mismatch."
        case varNotInit: return "Variable not initialized."
        case closeComment: return "\"*/\" expected."
        case outOfRange: return "Index out of range."
        case closeBracket: return "\"]\" expected."
        case fewMemory: return "Can't allocate memory."
        case notSupported: return "Unknown command."
        case cantExec: return "Can't execute command."
        case linkLost: return "The link between the macro and Tera Term was lost. (The Tera Term window was closed.)"
        default: return "Unknown error message number."
        }
    }
}

enum VType: Int {
    case unknown = 0, integer = 1, logical = 2, string = 3, label = 4, intArray = 5, strArray = 6
}

/// 実行状態 (TTLStatus)
enum TTLState {
    case run, wait, waitLn, waitNL, wait2, pause, waitN, wait4all, sleep, end
}

/// 起こす条件 (waitevent)
enum Wakeup {
    static let timeout = 1, unlink = 2, disconn = 4, connect = 8, initial = 16
}

final class TTLVariable {
    var name: String
    var key: String
    var type: VType
    var int: Int32 = 0
    var str: [UInt8] = []
    var labPtr = 0
    var labLevel = 0
    var intAry: [Int32] = []
    var strAry: [[UInt8]?] = []
    init(_ name: String, _ type: VType) { self.name = name; self.key = name.asciiLowered; self.type = type }
}

/// マクロのエラー (実行を止めたとき)
public struct TTLError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public let file: String
    public let text: String
    public var description: String { "\(file) \(line) 行目: \(message)\n\(text)" }
}

extension Array where Element == UInt8 {
    /// UTF-8 として文字列にする (壊れたバイトは置き換え)
    var u8: String { String(decoding: self, as: UTF8.self) }
}
extension String {
    /// TTL の文字列値 (NUL より前、MaxStrLen-1 バイトまで)
    var ttl: [UInt8] {
        var b = Array(self.utf8)
        if let z = b.firstIndex(of: 0) { b.removeSubrange(z...) }
        return b
    }
}
extension String {
    /// 英字だけ小文字にする (識別子は ASCII だけなので lowercased() より速い)
    var asciiLowered: String {
        var b = Array(utf8)
        var changed = false
        for i in b.indices where b[i] >= 0x41 && b[i] <= 0x5A { b[i] |= 0x20; changed = true }
        return changed ? String(decoding: b, as: UTF8.self) : self
    }
}
func ttlTrunc(_ b: [UInt8]) -> [UInt8] { b.count > MaxStrLen - 1 ? Array(b[0..<(MaxStrLen - 1)]) : b }

public final class TTLInterpreter {
    // MARK: - 状態

    weak var host: TTLHost?
    public var cancelled: Bool {
        get { recv.lock(); defer { recv.unlock() }; return _cancelled }
        set { recv.lock(); _cancelled = newValue; recv.broadcast(); recv.unlock() }
    }
    var _cancelled = false
    /// マクロウインドウの「中断」(ttmmain.cpp Pause): 止めている間はコマンドを進めない
    public var paused: Bool {
        get { recv.lock(); defer { recv.unlock() }; return _paused }
        set { recv.lock(); _paused = newValue; recv.broadcast(); recv.unlock() }
    }
    var _paused = false
    /// マクロウインドウに出す「ファイル名と行番号」(別スレッドから読むのでロックして写す)
    public var progress: (file: String, line: Int) {
        recv.lock(); defer { recv.unlock() }
        return (progressFile, progressLine)
    }
    var progressFile = ""
    var progressLine = 0
    var progressNest = -1
    var clipboardCache: [UInt8]?

    var vars: [TTLVariable] = []
    var status: TTLState = .run

    // 行バッファ
    var lineBuff: [UInt8] = []
    var linePtr = 0
    var lineLen: Int { lineBuff.count }
    var lineParsePtr = 0
    private var commenting = false

    // マクロファイル (include の入れ子)
    static let maxNestLevel = 10
    struct MacroBuffer {
        var name = ""
        var path = ""
        var data: [UInt8] = []
        var ptr = 0
        var lineStarts: [Int] = [0]
    }
    var buffs: [MacroBuffer?] = Array(repeating: nil, count: TTLInterpreter.maxNestLevel)
    var iNest = 0
    var lineNo = 1
    var lineStart = 0

    // 制御スタック
    static let maxSP = 10
    enum Ctl { case call, `for`, `while` }
    struct Frame { var ptr: Int; var level: Int; var type: Ctl }
    var stack: [Frame] = []
    var nextFlag = false
    var endWhileFlag = 0
    var breakFlag = 0
    var continueFlag = false

    // if
    var parseAgain = false
    var ifNest = 0
    var elseFlag = 0
    var endIfFlag = 0

    // 時間切れ
    var timeLimit: Double = 0   // 秒
    var timeStart = Date()
    var timerOn = false
    var wakeupCondition = 0
    public var exitCode = 0

    /// 現在のフォルダ (setdir / getdir)
    var curDir: String
    public let macroPath: String

    // 受信 (ttmdde.c 相当)
    let recv = NSCondition()
    private var ring: [UInt8] = []
    var ringStart = 0
    var ringCount = 0
    static let ringBufSize = 4096 * 4
    var syncMode = false
    var comReady = true
    var linked = true
    /// waitevent 用: 接続状態の変化 (true = つながった) と、つながりが切れたこと
    var comEvents: [Bool] = []
    var linkEndEvent = false
    /// つながっていた端末ウインドウが閉じてリンクが切れた (endLink)。unlink・closett・connect で戻す。
    /// このときの "Link macro first." は linkLost の文言にする (本家 #1462)
    var linkLost = false
    // wait4all 用 (snoopBuffers は TTLMacroRegistry.lock で守る。キーはのぞいているマクロ)
    var snoopBuffers: [ObjectIdentifier: [UInt8]] = [:]
    var w4aTargets: [TTLInterpreter] = []
    var w4aFound: [Bool] = []
    var w4aFoundNum = 0
    var w4aNum = 0

    // wait
    var waitStr: [[UInt8]?] = Array(repeating: nil, count: 10)
    var waitCount = Array(repeating: 0, count: 10)
    var regexWait = false
    // waitrecv
    var wait2SubStr: [UInt8] = []
    var wait2Str: [UInt8] = []
    var wait2Len = 0, wait2SubPos = 0, wait2Found = false
    // waitln / recvln
    var recvLnBuff: [UInt8] = []
    var recvLnLast: UInt8 = 0
    var recvLnClear = true
    var waitNLen = 0
    // 正規表現の設定 (regexoption)。既定は Tera Term と同じ UTF-8・Ruby 文法・オプションなし
    var regexOpt: OnigOptionType = 0
    var regexEnc: OnigEncoding = TTLRegex.defaultEncoding
    var regexSyntax: UnsafeMutablePointer<OnigSyntaxType> = TTLRegex.defaultSyntax

    /// コマンドごとに追加したい処理 (ほかのファイルで使う)
    var fileHandles: [FileHandle?] = Array(repeating: nil, count: 16)
    var filePaths: [String] = Array(repeating: "", count: 16)
    var filePointer: [UInt64] = Array(repeating: 0, count: 16)
    var dirEnums: [(paths: [String], pos: Int)?] = Array(repeating: nil, count: 8)
    var multicastName = ""
    var debugFlag = 0

    // MARK: - 初期化 (InitTTL)

    /// - Parameters:
    ///   - path: マクロファイルのパス
    ///   - params: コマンドラインの引数 (params[2] 以降)。
    ///
    /// param1 / params[1] はファイル名だけ (Tera Term の ShortName。拡張子がなければ ".TTL" を付ける: FitFileNameW)。
    /// params[0] は Tera Term ではコマンドライン全体 (GetCommandLineW)。Mac では
    /// 「アプリの実行ファイル マクロのパス 引数…」を Windows のコマンドライン風につないだもの (空白を含むものは "" で囲む)。
    /// (ファイル名が "." で始まるとき Windows は先頭に "_" を足すが、Mac ではドットファイルが普通なのでそのまま)
    public init(path: String, host: TTLHost, params: [String] = []) throws {
        self.host = host
        // FitFileNameW: 拡張子 (".") がなければ ".TTL" を付けて開く。なければ Mac らしく指定どおりの名前も試す
        let base = (path as NSString).lastPathComponent
        var openPath = path
        if !base.isEmpty && !base.contains(".") {
            let fm = FileManager.default
            if fm.fileExists(atPath: path + ".TTL") { openPath = path + ".TTL" }
            else if fm.fileExists(atPath: path + ".ttl") { openPath = path + ".ttl" }
            else if !fm.fileExists(atPath: path) { openPath = path + ".TTL" }
        }
        self.macroPath = openPath
        let dir = (openPath as NSString).deletingLastPathComponent
        curDir = dir.isEmpty ? FileManager.default.currentDirectoryPath : dir
        ring = Array(repeating: 0, count: TTLInterpreter.ringBufSize)
        let shortName = base.isEmpty || base.contains(".") ? base : base + ".TTL"
        let app = ProcessInfo.processInfo.arguments.first ?? ""
        let cmdLine = ([app, openPath] + params).map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
        initVars(shortName: shortName, commandLine: cmdLine, params: params)
        if !loadMacroFile(openPath, 0) {
            throw TTLError(line: 0, message: "Can't open file.", file: TTLInterpreter.fileTitle(openPath), text: "")
        }
        // ラベル登録のエラーは見せるだけ。InitTTL は最後に必ず IdTTLRun にするので、「止める」を選んでも動く
        _ = registerLabels(0)
        status = .run
        lastError = nil
    }

    /// エラーダイアログに出すファイル名 (GetFileTitleW を MAXFILENAME-1 = 127 バイトまで)
    static func fileTitle(_ path: String) -> String {
        var b = Array((path as NSString).lastPathComponent.utf8)
        if b.count > 127 {
            b = Array(b[0..<127])
            // 途中で切れた UTF-8 の文字は落とす
            var n = 0
            while n < 3, !b.isEmpty, String(bytes: b, encoding: .utf8) == nil { b.removeLast(); n += 1 }
        }
        return String(decoding: b, as: UTF8.self)
    }

    /// テスト用: 文字列からマクロを作る
    public convenience init(source: String, host: TTLHost, baseDir: URL? = nil) throws {
        let dir = baseDir?.path ?? NSTemporaryDirectory()
        let p = (dir as NSString).appendingPathComponent(".teramac-\(UUID().uuidString).ttl")
        try Data(source.utf8).write(to: URL(fileURLWithPath: p))
        defer { try? FileManager.default.removeItem(atPath: p) }
        try self.init(path: p, host: host)
    }

    private func initVars(shortName: String, commandLine: String, params: [String]) {
        _ = newIntVar("result", 0)
        _ = newIntVar("timeout", 0)
        _ = newIntVar("mtimeout", 0)
        _ = newStrVar("inputstr", [])
        _ = newStrVar("matchstr", [])
        for i in 1...9 { _ = newStrVar("groupmatchstr\(i)", []) }
        // ParamCnt はファイル名を含む引数の数 (Params[1] = ファイル名, Params[2〜] = 引数)
        let all = [shortName] + params
        let paramCnt = max(1, all.count)
        _ = newIntVar("paramcnt", Int32(paramCnt))
        _ = newStrVar("param1", shortName.ttl)
        for i in 2...9 { _ = newStrVar("param\(i)", i - 1 < all.count ? all[i - 1].ttl : []) }
        _ = newStrAryVar("params", paramCnt + 1)
        if let v = vars.last {
            v.strAry[0] = commandLine.ttl
            if !shortName.isEmpty { v.strAry[1] = shortName.ttl }
            for i in 2..<(paramCnt + 1) where i - 1 < all.count { v.strAry[i] = all[i - 1].ttl }
        }
    }

    static let systemVariables: Set<String> = [
        "result", "timeout", "mtimeout", "inputstr", "matchstr",
        "groupmatchstr1", "groupmatchstr2", "groupmatchstr3", "groupmatchstr4", "groupmatchstr5",
        "groupmatchstr6", "groupmatchstr7", "groupmatchstr8", "groupmatchstr9",
        "paramcnt", "param1", "param2", "param3", "param4", "param5", "param6", "param7", "param8", "param9", "params",
    ]
    func isSystemVariable(_ n: String) -> Bool { TTLInterpreter.systemVariables.contains(n.lowercased()) }

    // MARK: - 字句解析 (ttmparse.cpp)

    @inline(__always) func ch(_ i: Int) -> UInt8 { i >= 0 && i < lineBuff.count ? lineBuff[i] : 0 }

    func updateLineParsePtr() { lineParsePtr = linePtr }

    func isCommentClosed() -> Bool {
        let r = !commenting
        commenting = false
        return r
    }

    func skipSpaces() -> UInt8 {
        var b = ch(linePtr)
        while linePtr < lineLen && (b == 0x20 || b == 0x09) { linePtr += 1; b = ch(linePtr) }
        return b
    }

    /// 空白とコメントを飛ばして次の 1 文字を返す (なければ 0)
    func getFirstChar() -> UInt8 {
        if linePtr >= lineLen { return 0 }
        var b = skipSpaces()
        if commenting {
            while linePtr < lineLen {
                if ch(linePtr) == 0x2A && ch(linePtr + 1) == 0x2F { commenting = false; linePtr += 2; break }
                linePtr += 1
            }
            if commenting { return 0 }
            b = skipSpaces()
        }
        repeat {
            if ch(linePtr) == 0x2F && ch(linePtr + 1) == 0x2A {
                var starting = true
                linePtr += 2
                while linePtr < lineLen {
                    if ch(linePtr) == 0x2A && ch(linePtr + 1) == 0x2F { linePtr += 2; starting = false; break }
                    linePtr += 1
                }
                b = skipSpaces()
                if starting { commenting = true }
            } else {
                break
            }
        } while b == 0x2F
        if linePtr >= lineLen { b = 0 }
        if b > 0x20 && b != 0x3B {   // ';'
            linePtr += 1
            return b
        }
        return 0
    }

    func checkParameterGiven() -> Bool {
        let p = linePtr
        let given = getFirstChar() != 0
        linePtr = p
        return given
    }

    static func isCsymf(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F }
    static func isCsym(_ b: UInt8) -> Bool { isCsymf(b) || (b >= 0x30 && b <= 0x39) }

    func getIdentifier() -> String? {
        let b = getFirstChar()
        if b == 0 { return nil }
        if !TTLInterpreter.isCsymf(b) { linePtr -= 1; return nil }
        var name = [b]
        while linePtr < lineLen && TTLInterpreter.isCsym(ch(linePtr)) {
            if name.count < MaxNameLen - 1 { name.append(ch(linePtr)) }
            linePtr += 1
        }
        return String(decoding: name, as: UTF8.self)
    }

    func checkReservedWord(_ s: String) -> Rsv? { ttlReservedWords[s.asciiLowered] }

    func getReservedWord() -> Rsv? {
        let p = linePtr
        guard let name = getIdentifier() else { return nil }
        if let w = checkReservedWord(name) { return w }
        linePtr = p
        return nil
    }

    func getOperator() -> Rsv? {
        let p = linePtr
        let b = getFirstChar()
        var w: Rsv
        switch b {
        case 0: return nil
        case 0x2A: w = .mul
        case 0x2B: w = .plus
        case 0x2D: w = .minus
        case 0x2F: w = .div
        case 0x25: w = .mod
        case 0x3D:
            w = .eQ
            if ch(linePtr) == 0x3D && linePtr < lineLen { linePtr += 1 }
        case 0x3C:
            w = .lT
            if linePtr < lineLen {
                switch ch(linePtr) {
                case 0x3D: w = .lE; linePtr += 1
                case 0x3E: w = .nE; linePtr += 1
                case 0x3C: w = .aLShift; linePtr += 1
                default: break
                }
            }
        case 0x3E:
            w = .gT
            if linePtr < lineLen {
                switch ch(linePtr) {
                case 0x3D: w = .gE; linePtr += 1
                case 0x3E:
                    w = .aRShift; linePtr += 1
                    if linePtr < lineLen && ch(linePtr) == 0x3E { w = .lRShift; linePtr += 1 }
                default: break
                }
            }
        case 0x26:
            w = .bAnd
            if linePtr < lineLen && ch(linePtr) == 0x26 { w = .lAnd; linePtr += 1 }
        case 0x7C:
            w = .bOr
            if linePtr < lineLen && ch(linePtr) == 0x7C { w = .lOr; linePtr += 1 }
        case 0x5E: w = .bXor
        case 0x7E: w = .bNot
        case 0x21:
            w = .lNot
            if linePtr < lineLen && ch(linePtr) == 0x3D { w = .nE; linePtr += 1 }
        default:
            linePtr -= 1
            guard let r = getReservedWord(), r.rawValue >= Rsv.operator_.rawValue else { linePtr = p; return nil }
            w = r
        }
        return w
    }

    func getLabelName() -> String? {
        let b = getFirstChar()
        if b == 0 { return nil }
        var name = [b]
        while linePtr < lineLen && TTLInterpreter.isCsym(ch(linePtr)) {
            if name.count < MaxNameLen - 1 { name.append(ch(linePtr)) }
            linePtr += 1
        }
        return String(decoding: name, as: UTF8.self)
    }

    private func getQuotedStr(_ str: inout [UInt8], _ q: UInt8) -> Int {
        var b = ch(linePtr)
        while linePtr < lineLen && (b >= 0x20 || b == 0x09) && b != q {
            if str.count < MaxStrLen - 1 { str.append(b) }
            linePtr += 1
            b = ch(linePtr)
        }
        if b == q && linePtr < lineLen {
            linePtr += 1
            return 0
        }
        return E.syntax
    }

    private func getCharByCode(_ str: inout [UInt8]) -> Int {
        var b = ch(linePtr)
        var n = 0
        if !(b >= 0x30 && b <= 0x39) && b != 0x24 { return E.syntax }
        if b != 0x24 {
            while linePtr < lineLen && b >= 0x30 && b <= 0x39 {
                n = (n &* 10 &+ Int(b - 0x30)) & 0xFFFF
                linePtr += 1
                b = ch(linePtr)
            }
        } else {
            linePtr += 1
            b = ch(linePtr)
            while linePtr < lineLen, let d = TTLInterpreter.hexVal(b) {
                n = (n &* 16 &+ d) & 0xFFFF
                linePtr += 1
                b = ch(linePtr)
            }
        }
        if n == 0 || n > 255 { return E.syntax }
        if str.count < MaxStrLen - 1 { str.append(UInt8(n)) }
        return 0
    }

    static func hexVal(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }

    /// 文字列定数 ('abc' "abc" #13 をつなげたもの)。定数でなければ nil
    func getString(_ err: inout Int) -> [UInt8]? {
        err = 0
        var q = getFirstChar()
        if q == 0 { return nil }
        linePtr -= 1
        if q != 0x22 && q != 0x27 && q != 0x23 { return nil }
        var str: [UInt8] = []
        while (q == 0x22 || q == 0x27 || q == 0x23) && err == 0 {
            linePtr += 1
            if q == 0x23 { err = getCharByCode(&str) } else { err = getQuotedStr(&str, q) }
            q = ch(linePtr)
        }
        return str
    }

    func getNumber() -> Int32? {
        var b = getFirstChar()
        if b == 0 { return nil }
        var num: Int32 = 0
        if b >= 0x30 && b <= 0x39 {
            num = Int32(b - 0x30)
            b = ch(linePtr)
            while linePtr < lineLen && b >= 0x30 && b <= 0x39 {
                num = num &* 10 &+ Int32(b - 0x30)
                linePtr += 1
                b = ch(linePtr)
            }
        } else if b == 0x24 {
            b = ch(linePtr)
            while linePtr < lineLen, let d = TTLInterpreter.hexVal(b) {
                num = num &* 16 &+ Int32(d)
                linePtr += 1
                b = ch(linePtr)
            }
        } else {
            linePtr -= 1
            return nil
        }
        return num
    }

    // MARK: - 変数

    /// 名前 (小文字) → vars の添字
    private var varIndex: [String: Int] = [:]

    func checkVar(_ name: String) -> (VType, Int)? {
        guard let i = varIndex[name.asciiLowered] else { return nil }
        return (vars[i].type, i)
    }

    private func addVar(_ v: TTLVariable) {
        if varIndex[v.key] == nil { varIndex[v.key] = vars.count }
        vars.append(v)
    }

    private func rebuildVarIndex() {
        varIndex = [:]
        for (i, v) in vars.enumerated() where varIndex[v.key] == nil { varIndex[v.key] = i }
    }

    @discardableResult func newIntVar(_ name: String, _ v: Int32) -> Bool {
        let x = TTLVariable(name, .integer); x.int = v; addVar(x); return true
    }
    @discardableResult func newStrVar(_ name: String, _ v: [UInt8]) -> Bool {
        let x = TTLVariable(name, .string); x.str = v; addVar(x); return true
    }
    /// intdim / strdim (ttmparse.cpp NewIntAryVar)。大きさの上限は見ない (calloc できるかだけ)。
    /// 負の大きさは calloc が失敗するので ErrFewMemory。変数は先に作られているので残る (大きさ 0 にしておく)
    func newIntAryVar(_ name: String, _ size: Int) -> Int {
        let x = TTLVariable(name, .intArray); addVar(x)
        guard size >= 0 && size <= TTLInterpreter.maxArraySize else { return E.fewMemory }
        x.intAry = Array(repeating: 0, count: size); return 0
    }
    func newStrAryVar(_ name: String, _ size: Int) -> Int {
        let x = TTLVariable(name, .strArray); addVar(x)
        guard size >= 0 && size <= TTLInterpreter.maxArraySize else { return E.fewMemory }
        x.strAry = Array(repeating: nil, count: size); return 0
    }
    /// calloc が失敗する大きさの代わり (メモリを使い切って落ちないように 2^26 要素まで)
    static let maxArraySize = 1 << 26
    func newLabVar(_ name: String, _ ptr: Int, _ level: Int) {
        let x = TTLVariable(name, .label); x.labPtr = ptr; x.labLevel = level; addVar(x)
    }
    func delLabVar(_ level: Int) {
        let n = vars.count
        vars.removeAll { $0.type == .label && $0.labLevel >= level }
        if vars.count != n { rebuildVarIndex() }
    }
    func delVar(_ id: Int) -> Int { vars.remove(at: id); rebuildVarIndex(); return 0 }

    func reDim(_ id: Int, _ size: Int, _ preserve: Bool) -> Int {
        let v = vars[id]
        switch v.type {
        case .intArray:
            if preserve {
                if size > v.intAry.count { v.intAry += Array(repeating: 0, count: size - v.intAry.count) } else { v.intAry = Array(v.intAry[0..<size]) }
            } else { v.intAry = Array(repeating: 0, count: size) }
        case .strArray:
            if preserve {
                if size > v.strAry.count { v.strAry += Array(repeating: nil, count: size - v.strAry.count) } else { v.strAry = Array(v.strAry[0..<size]) }
            } else { v.strAry = Array(repeating: nil, count: size) }
        default: return E.typeMismatch
        }
        return 0
    }

    // 変数 ID: 普通の変数は添字、配列の要素は ((配列の添字 + 1) << 32) | 要素番号。
    // Tera Term は << 16 で 65536 以上の要素が別の要素と重なる (不具合) が、ここでは 64 ビットにして重ならないようにする。
    // 式の値 (Int32) で文字列配列の要素を返すときは strRefs に入れて負の番号 -(添字 + 2) にする (strRef)
    static let elemShift = 32
    var strRefs: [Int] = []

    /// 式の値 (Int32) として渡せる文字列変数 ID
    func strRef(_ id: Int) -> Int32 {
        if id >= 0 && id <= Int(Int32.max) { return Int32(id) }
        strRefs.append(id)
        return Int32(-(strRefs.count + 1))   // -1 はエラーの印に使われるので -2 から
    }
    @inline(__always) private func resolveId(_ id: Int) -> Int {
        if id <= -2, -id - 2 < strRefs.count { return strRefs[-id - 2] }
        return id
    }

    func setIntVal(_ id: Int, _ val: Int32) {
        let id = resolveId(id)
        if id >> TTLInterpreter.elemShift != 0 { vars[(id >> TTLInterpreter.elemShift) - 1].intAry[id & 0xFFFF_FFFF] = val } else { vars[id].int = val }
    }
    func copyIntVal(_ id: Int) -> Int32 {
        let id = resolveId(id)
        if id >> TTLInterpreter.elemShift != 0 { return vars[(id >> TTLInterpreter.elemShift) - 1].intAry[id & 0xFFFF_FFFF] }
        return vars[id].int
    }
    func setStrVal(_ id: Int, _ s: [UInt8]) {
        let id = resolveId(id)
        var s = s
        if let z = s.firstIndex(of: 0) { s.removeSubrange(z...) }
        if id >> TTLInterpreter.elemShift != 0 { vars[(id >> TTLInterpreter.elemShift) - 1].strAry[id & 0xFFFF_FFFF] = s } else { vars[id].str = s }
    }
    func strVarPtr(_ id: Int) -> [UInt8] {
        let id = resolveId(id)
        if id >> TTLInterpreter.elemShift != 0 { return vars[(id >> TTLInterpreter.elemShift) - 1].strAry[id & 0xFFFF_FFFF] ?? [] }
        return vars[id].str
    }

    func getIntVarFromArray(_ id: Int, _ index: Int, _ err: inout Int) -> Int {
        let n = vars[id].intAry.count
        if index < 0 || index >= n { err = E.outOfRange; return -1 }
        err = 0
        return ((id + 1) << TTLInterpreter.elemShift) | index
    }
    func getStrVarFromArray(_ id: Int, _ index: Int, _ err: inout Int) -> Int {
        let n = vars[id].strAry.count
        if index < 0 || index >= n { err = E.outOfRange; return -1 }
        err = 0
        return ((id + 1) << TTLInterpreter.elemShift) | index
    }

    /// [式] があれば添字を返す
    func getIndex(_ err: inout Int) -> Int? {
        err = 0
        let p = linePtr
        if getFirstChar() == 0x5B {
            var idx: Int32 = 0
            getIntVal(&idx, &err)
            if err == 0 {
                if getFirstChar() == 0x5D { return Int(idx) }
                err = E.closeBracket
            }
        }
        linePtr = p
        return nil
    }

    // MARK: - 式

    /// 値 (整数なら値、文字列なら変数 ID)
    private func getFactor(_ type: inout VType, _ val: inout Int32, _ err: inout Int) -> Bool {
        let p = linePtr
        err = 0
        if let name = getIdentifier() {
            if let w = checkReservedWord(name) {
                if getFactor(&type, &val, &err) {
                    if err == 0 && type != .integer { err = E.typeMismatch }
                    switch w {
                    case .bNot: val = ~val
                    case .lNot: val = val == 0 ? 1 : 0
                    default: err = E.syntax
                    }
                } else {
                    err = E.syntax
                }
            } else if let (t, id) = checkVar(name) {
                type = t
                switch t {
                case .integer: val = vars[id].int
                case .string: val = Int32(id)
                case .intArray:
                    if let index = getIndex(&err) {
                        let a = vars[id].intAry
                        if index >= 0 && index < a.count { val = a[index]; type = .integer } else { err = E.outOfRange }
                    } else if err == 0 { val = Int32(id) }
                case .strArray:
                    if let index = getIndex(&err) {
                        let vid = getStrVarFromArray(id, index, &err)
                        if err == 0 { val = strRef(vid); type = .string }
                    } else if err == 0 { val = Int32(id) }
                default: break
                }
            } else {
                err = E.varNotInit
            }
        } else if let n = getNumber() {
            val = n
            type = .integer
        } else if let w = getOperator() {
            if getFactor(&type, &val, &err) {
                if err == 0 && type != .integer { err = E.typeMismatch }
                switch w {
                case .plus: break
                case .minus: val = 0 &- val
                case .bNot: val = ~val
                case .lNot: val = val == 0 ? 1 : 0
                default: err = E.syntax
                }
            } else {
                err = E.syntax
            }
        } else if getFirstChar() == 0x28 {
            if getExpression(&type, &val, &err) {
                if err == 0 && getFirstChar() != 0x29 { err = E.closeParent }
            } else {
                err = E.syntax
            }
        } else {
            err = 0
            return false
        }
        if err != 0 { linePtr = p }
        return true
    }

    private static let opsMul: Set<Rsv> = [.mul, .div, .mod]
    private static let opsAdd: Set<Rsv> = [.plus, .minus]
    private static let opsShift: Set<Rsv> = [.aRShift, .aLShift, .lRShift]
    private static let opsBAnd: Set<Rsv> = [.bAnd]
    private static let opsBXor: Set<Rsv> = [.bXor]
    private static let opsBOr: Set<Rsv> = [.bOr]
    private static let opsGreater: Set<Rsv> = [.lT, .gT, .lE, .gE]
    private static let opsEqual: Set<Rsv> = [.eQ, .nE]
    private static let opsLAnd: Set<Rsv> = [.lAnd]

    /// 2 項演算子の 1 段 (優先順位ごと)
    private func evalBinary(_ next: (inout VType, inout Int32, inout Int) -> Bool, ops: Set<Rsv>,
                            _ type: inout VType, _ val: inout Int32, _ err: inout Int,
                            apply: (Rsv, Int32, Int32) -> Int32?) -> Bool {
        var t = VType.unknown, v1: Int32 = 0, er = 0
        if !next(&t, &v1, &er) { return false }
        type = t; val = v1; err = er
        if er != 0 || t != .integer { return true }
        while true {
            let p = linePtr
            guard let w = getOperator() else { return true }
            if !ops.contains(w) { linePtr = p; return true }
            var v2: Int32 = 0
            if !next(&t, &v2, &er) { err = E.syntax; return true }
            if er != 0 { err = er; return true }
            if t != .integer { err = E.typeMismatch; return true }
            guard let r = apply(w, v1, v2) else { err = E.divByZero; return true }
            v1 = r
            val = v1
        }
    }

    private func evalMultiplication(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        // -2147483648 / -1 (と %) は Tera Term では例外で落ちる。ここでは落とさず -2147483648 (% は 0) にする
        evalBinary(getFactor, ops: TTLInterpreter.opsMul, &t, &v, &e) { w, a, b in
            switch w {
            case .mul: return a &* b
            case .div: return b == 0 ? nil : a.dividedReportingOverflow(by: b).partialValue
            default: return b == 0 ? nil : a.remainderReportingOverflow(dividingBy: b).partialValue
            }
        }
    }
    private func evalAddition(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalMultiplication, ops: TTLInterpreter.opsAdd, &t, &v, &e) { w, a, b in w == .plus ? a &+ b : a &- b }
    }
    private func evalBitShift(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalAddition, ops: TTLInterpreter.opsShift, &t, &v, &e) { w, a, b in
            var v2 = b
            var v1 = a
            if w == .aLShift { v2 = 0 &- v2 }
            if v2 <= -32 { v1 = 0 }
            else if v2 < 0 { v1 = v1 << Int32(-v2) }
            else if v2 == 0 { }
            else if v2 < 32 {
                if w == .lRShift { v1 = Int32(bitPattern: UInt32(bitPattern: v1) >> UInt32(v2)) } else { v1 = v1 >> v2 }
            } else {
                v1 = (v1 > 0 || w == .lRShift) ? 0 : ~0
            }
            return v1
        }
    }
    private func evalBitAnd(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalBitShift, ops: TTLInterpreter.opsBAnd, &t, &v, &e) { _, a, b in a & b }
    }
    private func evalBitXor(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalBitAnd, ops: TTLInterpreter.opsBXor, &t, &v, &e) { _, a, b in a ^ b }
    }
    private func evalBitOr(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalBitXor, ops: TTLInterpreter.opsBOr, &t, &v, &e) { _, a, b in a | b }
    }
    private func evalGreater(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalBitOr, ops: TTLInterpreter.opsGreater, &t, &v, &e) { w, a, b in
            switch w {
            case .lT: return a < b ? 1 : 0
            case .gT: return a > b ? 1 : 0
            case .lE: return a <= b ? 1 : 0
            default: return a >= b ? 1 : 0
            }
        }
    }
    private func evalEqual(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalGreater, ops: TTLInterpreter.opsEqual, &t, &v, &e) { w, a, b in w == .eQ ? (a == b ? 1 : 0) : (a != b ? 1 : 0) }
    }
    private func evalLogicalAnd(_ t: inout VType, _ v: inout Int32, _ e: inout Int) -> Bool {
        evalBinary(evalEqual, ops: TTLInterpreter.opsLAnd, &t, &v, &e) { _, a, b in (a != 0 && b != 0) ? 1 : 0 }
    }

    /// 式を読む。整数なら val に値、文字列なら val に変数 ID
    func getExpression(_ type: inout VType, _ val: inout Int32, _ err: inout Int) -> Bool {
        let p1 = linePtr
        var t = VType.unknown, v1: Int32 = 0, er = 0
        if !evalLogicalAnd(&t, &v1, &er) { linePtr = p1; return false }
        type = t; val = v1; err = er
        if er != 0 { linePtr = p1; return true }
        if t != .integer { return true }
        while true {
            let p2 = linePtr
            guard let w = getOperator() else { return true }
            if w != .lOr && w != .lXor { linePtr = p2; return true }
            var v2: Int32 = 0
            if !evalLogicalAnd(&t, &v2, &er) { err = E.syntax; linePtr = p1; return true }
            if er != 0 { err = er; linePtr = p1; return true }
            if t != .integer { err = E.typeMismatch; linePtr = p1; return true }
            v1 = w == .lOr ? ((v1 != 0 || v2 != 0) ? 1 : 0) : (((v1 != 0) != (v2 != 0)) ? 1 : 0)
            val = v1
        }
    }

    func getIntVal(_ val: inout Int32, _ err: inout Int) {
        updateLineParsePtr()
        if err != 0 { return }
        var t = VType.unknown
        if !getExpression(&t, &val, &err) { err = E.syntax; return }
        if err != 0 { return }
        if t != .integer { err = E.typeMismatch }
    }
    /// Int で受け取る版
    func getIntVal(_ err: inout Int) -> Int {
        var v: Int32 = 0
        getIntVal(&v, &err)
        return Int(v)
    }

    /// 整数変数を読む (なければ作る)
    func getIntVar(_ err: inout Int) -> Int {
        if err != 0 { return 0 }
        guard let name = getIdentifier() else { err = E.syntax; return 0 }
        if let (t, id) = checkVar(name) {
            switch t {
            case .integer: return id
            case .intArray:
                if let index = getIndex(&err) { return getIntVarFromArray(id, index, &err) }
                if err == 0 { err = E.typeMismatch }
                return 0
            default:
                err = E.typeMismatch
                return 0
            }
        }
        newIntVar(name, 0)
        return vars.count - 1
    }

    func getStrVal(_ err: inout Int) -> [UInt8] {
        updateLineParsePtr()
        return getStrVal2(&err, autoConversion: false)
    }

    func getStrVal2(_ err: inout Int, autoConversion: Bool) -> [UInt8] {
        if err != 0 { return [] }
        if let s = getString(&err) { return s }
        var t = VType.unknown, v: Int32 = 0
        if getExpression(&t, &v, &err) {
            if err != 0 { return [] }
            switch t {
            case .string: return ttlTrunc(strVarPtr(Int(v)))
            case .integer:
                if autoConversion { return String(v).ttl }
                err = E.typeMismatch
            default: err = E.typeMismatch
            }
        } else {
            err = E.syntax
        }
        return []
    }

    /// 文字列変数を読む (なければ作る)
    func getStrVar(_ err: inout Int) -> Int {
        if err != 0 { return 0 }
        guard let name = getIdentifier() else { err = E.syntax; return 0 }
        if let (t, id) = checkVar(name) {
            switch t {
            case .string: return id
            case .strArray:
                if let index = getIndex(&err) { return getStrVarFromArray(id, index, &err) }
                if err == 0 { err = E.typeMismatch }
                return 0
            default:
                err = E.typeMismatch
                return 0
            }
        }
        newStrVar(name, [])
        return vars.count - 1
    }

    /// ifdefined 用
    func getVarType(_ err: inout Int) -> VType {
        var type = VType.unknown
        if let name = getIdentifier() {
            if checkReservedWord(name) != nil {
                type = .unknown
            } else if let (t, id) = checkVar(name) {
                type = t
                switch t {
                case .intArray:
                    if let index = getIndex(&err) {
                        type = (index >= 0 && index < vars[id].intAry.count) ? .integer : .unknown
                    }
                case .strArray:
                    if let index = getIndex(&err) {
                        _ = getStrVarFromArray(id, index, &err)
                        type = err == 0 ? .string : .unknown
                    }
                default: break
                }
            }
        }
        err = 0
        return type
    }

    /// 配列変数 (intdim / strdim で作ったもの) を名前で読む
    func getAryVar(_ type: VType, _ err: inout Int) -> Int {
        if err != 0 { return 0 }
        guard let name = getIdentifier() else { err = E.syntax; return 0 }
        guard let (t, id) = checkVar(name) else { err = E.varNotInit; return 0 }
        if t != type { err = E.typeMismatch }
        return id
    }

    // MARK: - システム変数

    func setResult(_ v: Int) {
        if let (t, id) = checkVar("result"), t == .integer { setIntVal(id, Int32(truncatingIfNeeded: v)) }
    }
    func setInputStr(_ s: [UInt8]) {
        if let (t, id) = checkVar("inputstr"), t == .string { setStrVal(id, s) }
    }
    func setMatchStr(_ s: [UInt8]) {
        if let (t, id) = checkVar("matchstr"), t == .string { setStrVal(id, s) }
    }
    func setGroupMatchStr(_ n: Int, _ s: [UInt8]) {
        if let (t, id) = checkVar("groupmatchstr\(n)"), t == .string { setStrVal(id, s) }
    }
    func intVariable(_ name: String) -> Int32? {
        if let (t, id) = checkVar(name), t == .integer { return copyIntVal(id) }
        return nil
    }

    public func variable(_ name: String) -> TTLValue? {
        guard let (t, id) = checkVar(name) else { return nil }
        switch t {
        case .integer: return .int(Int(vars[id].int))
        case .string: return .str(vars[id].str.u8)
        default: return nil
        }
    }

    // MARK: - マクロファイル (ttmbuff.c)

    /// マクロファイルを読んで UTF-8 にする (fileread.cpp LoadFileU8C)。
    /// BOM (UTF-8 / UTF-16LE / UTF-16BE) を先に見る。BOM がなければ UTF-8、だめなら CP932
    /// (Windows ではシステムのコードページが先だが、Mac では UTF-8 が普通なので順番だけ Mac 流)。
    /// どれでも読めなければ nil (Can't open file)。中身は C の文字列なので最初の NUL で終わり。
    /// UTF-16 は壊れた並びがあっても置き換えて読む (WideCharToMultiByte と同じく失敗しない)
    static func loadText(_ path: String) -> [UInt8]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        let b = [UInt8](d)
        func cutNul(_ x: ArraySlice<UInt8>) -> [UInt8] {
            if let z = x.firstIndex(of: 0) { return Array(x[x.startIndex..<z]) }
            return Array(x)
        }
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return cutNul(b[3...]) }
        if b.starts(with: [0xFF, 0xFE]) || b.starts(with: [0xFE, 0xFF]) {
            let le = b[0] == 0xFF
            var units: [UInt16] = []
            var i = 2
            while i < b.count {
                let x = b[i], y: UInt8 = i + 1 < b.count ? b[i + 1] : 0
                // 奇数バイトで終わるときは最後の 1 バイトを下位バイトとみなす (後ろに付けた 0 と組になる)
                let u: UInt16 = i + 1 >= b.count ? UInt16(x) : (le ? UInt16(x) | UInt16(y) << 8 : UInt16(x) << 8 | UInt16(y))
                if u == 0 { break }
                units.append(u)
                i += 2
            }
            return Array(String(decoding: units, as: UTF16.self).utf8)
        }
        let raw = cutNul(b[...])
        if String(bytes: raw, encoding: .utf8) != nil { return raw }
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        if let s = String(bytes: raw, encoding: cp932) { return Array(s.utf8) }
        return nil
    }

    func loadMacroFile(_ path: String, _ level: Int) -> Bool {
        guard !path.isEmpty, level < TTLInterpreter.maxNestLevel else { return false }
        guard let data = TTLInterpreter.loadText(path) else { return false }
        var mb = MacroBuffer()
        mb.name = TTLInterpreter.fileTitle(path)
        mb.path = path
        mb.data = data
        mb.lineStarts = [0]
        for (i, b) in data.enumerated() where b == 0x0A && i != data.count - 1 { mb.lineStarts.append(i + 1) }
        buffs[level] = mb
        return true
    }

    var macroFileName: String { buffs[iNest]?.name ?? "" }

    private func currentLineNumber(_ pos: Int, _ starts: [Int]) -> Int {
        // 二分探索: pos より大きい最初の行頭の番号
        var lo = 0, hi = starts.count
        while lo < hi { let m = (lo + hi) / 2; if starts[m] <= pos { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// 次の 1 行を lineBuff に読む
    @discardableResult func getRawLine() -> Bool {
        guard buffs[iNest] != nil else { return false }
        let data = buffs[iNest]!.data
        var p = buffs[iNest]!.ptr
        lineStart = p
        var line: [UInt8] = []
        while p < data.count && (data[p] >= 0x20 || data[p] == 0x09) {
            if line.count < MaxLineLen - 1 { line.append(data[p]) }
            p += 1
        }
        lineBuff = line
        linePtr = 0
        lineParsePtr = 0
        lineNo = currentLineNumber(p, buffs[iNest]!.lineStarts)
        recv.lock(); progressLine = lineNo
        if progressFile.isEmpty || iNest != progressNest { progressFile = macroFileName; progressNest = iNest }
        recv.unlock()
        while p < data.count && data[p] < 0x20 && data[p] != 0x09 { p += 1 }
        buffs[iNest]!.ptr = p
        return !line.isEmpty || p < data.count
    }

    func getNewLine() -> Bool {
        var b: UInt8
        repeat {
            var ok = getRawLine()
            if !ok && iNest > 0 {
                repeat {
                    closeBuff(iNest)
                    iNest -= 1
                    ok = getRawLine()
                } while !ok && iNest > 0
            }
            if !ok { return false }
            b = getFirstChar()
            linePtr -= 1
        } while b == 0 || b == 0x3A
        return true
    }

    private func registerLabels(_ level: Int) -> [Int] {
        guard buffs[level] != nil else { return [] }
        let saveNest = iNest
        iNest = level
        buffs[level]!.ptr = 0
        var errors: [Int] = []
        while getRawLine() {
            var err = 0
            var b = getFirstChar()
            if b == 0x3A {
                if let lab = getLabelName(), getFirstChar() == 0 {
                    if checkVar(lab) != nil { err = E.labelAlreadyDef } else { newLabVar(lab, buffs[level]!.ptr, level) }
                } else {
                    err = E.syntax
                }
            } else {
                linePtr -= 1
            }
            // C コメントを探すため行末まで読む
            repeat {
                b = getFirstChar()
                if b == 0x22 || b == 0x27 || b == 0x23 {
                    linePtr -= 1
                    // Tera Term と同じく同じ Err を使う (閉じていない文字列もここでエラーになる)
                    _ = getString(&err)
                }
            } while b != 0
            // エラーがあっても最後まで調べる (「止める」を選ぶと status は end になる)
            if err > 0 { errors.append(err); reportError(err) }
        }
        if !isCommentClosed() { reportError(E.closeComment) }
        buffs[level]!.ptr = 0
        lineNo = 1
        iNest = saveNest
        return errors
    }

    func closeBuff(_ level: Int) {
        delLabVar(level)
        for i in level..<TTLInterpreter.maxNestLevel { buffs[i] = nil }
        while let f = stack.last, f.level >= level { stack.removeLast() }
    }

    var buffPtr: Int {
        get { buffs[iNest]?.ptr ?? 0 }
        set { buffs[iNest]?.ptr = newValue }
    }

    func jumpToLabel(_ id: Int) {
        let v = vars[id]
        if v.labLevel < iNest {
            iNest = v.labLevel
            closeBuff(iNest + 1)
        }
        buffPtr = v.labPtr
    }

    func callToLabel(_ id: Int) -> Int {
        let v = vars[id]
        if v.labLevel != iNest { return E.cantCall }
        if stack.count >= TTLInterpreter.maxSP { return E.stackOver }
        stack.append(Frame(ptr: buffPtr, level: iNest, type: .call))
        buffPtr = v.labPtr
        return 0
    }

    func returnFromSub() -> Int {
        guard let f = stack.last, f.type == .call else { return E.invalidCtl }
        stack.removeLast()
        if f.level < iNest { iNest = f.level; closeBuff(iNest + 1) }
        buffPtr = f.ptr
        return 0
    }

    func buffInclude(_ path: String) -> Bool {
        if iNest >= TTLInterpreter.maxNestLevel - 1 { return false }
        iNest += 1
        if loadMacroFile(path, iNest) {
            _ = registerLabels(iNest)
            return true
        }
        iNest -= 1
        return false
    }

    func exitBuffer() -> Bool {
        if iNest < 1 { return false }
        closeBuff(iNest)
        iNest -= 1
        return true
    }

    func setForLoop() -> Int {
        if stack.count >= TTLInterpreter.maxSP { return E.stackOver }
        stack.append(Frame(ptr: lineStart, level: iNest, type: .for))
        return 0
    }
    func lastForLoop() {
        guard let f = stack.last, f.type == .for else { return }
        stack[stack.count - 1].ptr = -1
    }
    func checkNext() -> Bool {
        if nextFlag { nextFlag = false; return true }
        return false
    }
    func nextLoop() -> Int {
        guard let f = stack.last, f.type == .for else { return E.invalidCtl }
        nextFlag = f.ptr != -1
        if !nextFlag { stack.removeLast(); return 0 }
        if f.level < iNest { iNest = f.level; closeBuff(iNest + 1) }
        buffPtr = f.ptr
        return 0
    }
    func setWhileLoop() -> Int {
        if stack.count >= TTLInterpreter.maxSP { return E.stackOver }
        stack.append(Frame(ptr: lineStart, level: iNest, type: .while))
        return 0
    }
    func endWhileLoop() { endWhileFlag = 1 }
    func backToWhile(_ flag: Bool) -> Int {
        guard let f = stack.last, f.type == .while else { return E.invalidCtl }
        stack.removeLast()
        if f.level < iNest { iNest = f.level; closeBuff(iNest + 1) }
        if flag { buffPtr = f.ptr }
        return 0
    }
    func breakLoop(_ w: Rsv) -> Int {
        guard let f = stack.last else { return E.invalidCtl }
        switch f.type {
        case .for, .while:
            if w == .continue {
                continueFlag = true
            } else {
                stack.removeLast()
                if f.level < iNest { iNest = f.level; closeBuff(iNest + 1) }
            }
            breakFlag = 1
        default:
            return E.invalidCtl
        }
        return 0
    }

    // MARK: - エラー

    /// エラーを出す。利用者が「中止」を選んだら終了
    func reportError(_ err: Int) {
        var start = lineParsePtr, end = linePtr
        if start == end { end = lineLen }
        start = min(start, lineLen); end = min(max(end, start), lineLen)
        recv.lock()
        let lost = linkLost && !linked
        recv.unlock()
        let message = E.message(err == E.linkFirst && lost ? E.linkLost : err)
        let stop = host?.ttlError(message: message, line: lineNo, lineText: lineBuff.u8, file: macroFileName,
                                  range: start..<end) ?? true
        if stop {
            status = .end
            lastError = TTLError(line: lineNo, message: message, file: macroFileName, text: lineBuff.u8)
        }
    }
    public private(set) var lastError: TTLError?

    // MARK: - 実行 (Exec / OnIdle)

    public func run() throws {
        TTLMacroRegistry.add(self)
        host?.ttlMacroStarted(self)
        defer { endTTL() }
        while status != .end {
            if cancelled { status = .end; break }
            if _paused {
                recv.lock()
                while _paused && !_cancelled { _ = recv.wait(until: Date(timeIntervalSinceNow: 0.2)) }
                recv.unlock()
                continue
            }
            switch status {
            case .run:
                exec()
            case .end:
                break
            default:
                waitStep()
            }
        }
        if let e = lastError { throw e }
    }

    private func endTTL() {
        recv.lock(); endWait4all(); recv.unlock()
        TTLMacroRegistry.remove(self)
        host?.ttlCloseStatus()
        for i in 0..<fileHandles.count { try? fileHandles[i]?.close(); fileHandles[i] = nil }
        closeBuff(0)
    }

    func exec() {
        if !parseAgain && !getNewLine() {
            status = .end
            return
        }
        parseAgain = false
        strRefs.removeAll(keepingCapacity: true)
        let err = execCmnd()
        if err > 0 { reportError(err) }
    }

    func checkThen(_ err: inout Int) -> Bool {
        while true {
            var b: UInt8
            repeat {
                b = getFirstChar()
                if b == 0 { return false }
            } while !TTLInterpreter.isCsymf(b)
            linePtr -= 1
            guard let t = getIdentifier() else { return false }
            if t.lowercased() == "then" { break }
        }
        if getFirstChar() != 0 { err = E.syntax }
        return true
    }

    func checkElseIf(_ err: inout Int) -> Int32 {
        err = 0
        var v: Int32 = 0
        getIntVal(&v, &err)
        if err != 0 { return 0 }
        if getReservedWord() != .then || getFirstChar() != 0 { err = E.syntax }
        return v
    }

    /// 1 行を実行する (ExecCmnd)
    func execCmnd() -> Int {
        var err = 0
        let w = getReservedWord()

        if endWhileFlag > 0 {
            if let w = w {
                switch w {
                case .while, .until, .do: endWhileFlag += 1
                case .endWhile, .endUntil, .loop: endWhileFlag -= 1
                default: break
                }
            }
            return 0
        }

        if breakFlag > 0 {
            if let w = w {
                switch w {
                case .if:
                    if checkThen(&err) { ifNest += 1 }
                case .endIf:
                    if ifNest < 1 { err = E.invalidCtl } else { ifNest -= 1 }
                case .for, .while, .until, .do: breakFlag += 1
                case .next, .endWhile, .endUntil, .loop: breakFlag -= 1
                default: break
                }
            }
            if breakFlag > 0 || !continueFlag { return err }
            continueFlag = false
        }

        if endIfFlag > 0 {
            if let w = w {
                if w == .if && checkThen(&err) { endIfFlag += 1 } else if w == .endIf { endIfFlag -= 1 }
            }
            return err
        }

        if elseFlag > 0 {
            if let w = w {
                if w == .if && checkThen(&err) { endIfFlag += 1 }
                else if w == .else { elseFlag -= 1 }
                else if w == .elseIf { if checkElseIf(&err) != 0 { elseFlag -= 1 } }
                else if w == .endIf { elseFlag -= 1; if elseFlag == 0 { ifNest -= 1 } }
            }
            return err
        }

        if let w = w {
            return dispatch(w)
        }
        if let name = getIdentifier() {
            return assign(name)
        }
        return E.syntax
    }

    /// 変数への代入 (x = 式)
    private func assign(_ name: String) -> Int {
        var err = 0
        let index = getIndex(&err)
        let withIndex = index != nil
        // Tera Term: GetIndex のエラーも「=」がないのも ErrNotSupported (Unknown command.)
        if err != 0 || getFirstChar() != 0x3D { return E.notSupported }
        var valType = VType.unknown
        var val: Int32 = 0
        let strConst = getString(&err)
        if strConst != nil {
            valType = .string
        } else if !getExpression(&valType, &val, &err) {
            err = E.syntax
        }
        if err != 0 { return err }
        if var (varType, id) = checkVar(name) {
            if let index = index {
                switch varType {
                case .intArray:
                    id = getIntVarFromArray(id, index, &err); if err == 0 { varType = .integer }
                case .strArray:
                    id = getStrVarFromArray(id, index, &err); if err == 0 { varType = .string }
                default: err = E.syntax
                }
            }
            if err != 0 { return err }
            if varType == valType {
                switch valType {
                case .integer: setIntVal(id, val)
                case .string: setStrVal(id, strConst ?? strVarPtr(Int(val)))
                default: err = E.syntax
                }
            } else {
                err = E.typeMismatch
            }
        } else if withIndex {
            err = E.syntax
        } else {
            switch valType {
            case .integer: newIntVar(name, val)
            case .string: newStrVar(name, strConst ?? strVarPtr(Int(val)))
            default: err = E.tooManyVar
            }
        }
        if err == 0 && getFirstChar() != 0 { err = E.syntax }
        return err
    }

    // MARK: - 待ち (OnIdle / OnTimer)

    /// timeout * 1000 + mtimeout (Tera Term と同じく 32 ビットの int。あふれて負になれば時間切れなし)
    func startTimer() {
        var t: Int32 = 0
        if let v = intVariable("timeout") { t = v &* 1000 }
        if let v = intVariable("mtimeout") { t = t &+ v }
        if t > 0 {
            timeLimit = Double(t) / 1000
            timeStart = Date()
            timerOn = true
        } else {
            timerOn = false
        }
    }

    /// CheckTimeout: GetTickCount() > TimeUp (ちょうどでは時間切れにしない)
    func checkTimeout() -> Bool { timerOn && Date().timeIntervalSince(timeStart) > timeLimit }

    /// 受信データ・時間切れ・切断を見て待ちを 1 回進める。進まなければ少し眠る
    private func waitStep() {
        var progressed = false
        recv.lock()
        defer { recv.unlock() }
        switch status {
        case .wait:
            let r = waitMatch()
            if r > 0 { timerOn = false; status = .run; setResult(r); clearWait(); progressed = true }
        case .wait4all:
            // 全部のウインドウでそろったら result = 1 (番号ではない)
            if wait4allMatch() { timerOn = false; status = .run; setResult(1); clearWait(); endWait4all(); progressed = true }
        case .waitLn:
            let r = waitMatch()
            if r > 0 {
                setResult(r)
                if waitStr[r - 1] == [0x0A] {
                    timerOn = false; clearWait(); status = .run; setInputStr(getRecvLnBuff())
                } else {
                    clearWait(); setWait(1, [0x0A]); status = .waitNL
                }
                progressed = true
            }
        case .waitNL:
            let r = waitMatch()
            if r > 0 { timerOn = false; status = .run; setInputStr(getRecvLnBuff()); progressed = true }
        case .wait2:
            if wait2() { timerOn = false; status = .run; setInputStr(wait2Str); setResult(1); progressed = true }
        case .waitN:
            if waitN() { timerOn = false; status = .run; setResult(1); setInputStr(getRecvLnBuff()); clearWaitN(); progressed = true }
        default: break
        }
        if progressed || status == .run { return }
        if _cancelled { status = .end; return }

        // OnTimer 相当: 時間切れ・切断
        let timeout = checkTimeout()
        switch status {
        case .wait4all:
            // Tera Term の OnTimer には wait4all の場合がなく、最後の else で IdTTLRun になる (result はそのまま)。
            // タイマーは timeout があれば最初の 50 ms、ComReady が 0 ならすぐに来る
            if !comReady || (timerOn && Date().timeIntervalSince(timeStart) >= TTLInterpreter.timerTick) {
                timerOn = false
                endWait4all()
                status = .run
                return
            }
        case .wait, .waitLn, .waitNL:
            if !linked || !comReady || timeout {
                setResult(0)
                if status == .waitNL { setInputStr(getRecvLnBuff()) }
                clearWait()
                status = .run
                return
            }
        case .wait2:
            if !linked || !comReady || timeout {
                if wait2Found { setInputStr(wait2Str); setResult(-1) } else { setInputStr([]); setResult(0) }
                status = .run
                return
            }
        case .waitN:
            if !linked || !comReady || timeout {
                let p = getRecvLnBuff()
                setInputStr(p)
                setResult(p.isEmpty ? 0 : -1)
                status = .run
                return
            }
        case .pause:
            if timeout || !timerOn { status = .run; return }
        case .sleep:
            if timeout && (wakeupCondition & Wakeup.timeout) != 0 {
                setResult(Wakeup.timeout); status = .run; return
            }
            // OnDdeComReady: waitevent のあとに接続状態が変わったときだけ起きる
            while !comEvents.isEmpty {
                let ready = comEvents.removeFirst()
                if ready && (wakeupCondition & Wakeup.connect) != 0 { setResult(Wakeup.connect); status = .run; return }
                if !ready && (wakeupCondition & Wakeup.disconn) != 0 { setResult(Wakeup.disconn); status = .run; return }
            }
            // OnDdeEnd: 端末とのつながりが切れた
            if linkEndEvent {
                linkEndEvent = false
                if (wakeupCondition & Wakeup.unlink) != 0 { setResult(Wakeup.unlink); status = .run; return }
            }
        default:
            status = .run
            return
        }
        _ = recv.wait(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - 受信バッファ (ttmdde.c)

    /// 端末に表示した文字 (UTF-8) を渡す。どのスレッドからでもよい
    /// NUL も届ける (Tera Term は DDE で 0x00/0x01 を 0x01 で包んで送り、Read1Byte で元に戻す)
    public func feed(_ bytes: [UInt8]) {
        recv.lock()
        for b in bytes { put1Byte(b) }
        TTLMacroRegistry.lock.lock()
        if !snoopBuffers.isEmpty {
            for k in Array(snoopBuffers.keys) {
                snoopBuffers[k]!.append(contentsOf: bytes)
                let over = snoopBuffers[k]!.count - TTLInterpreter.ringBufSize
                if over > 0 { snoopBuffers[k]!.removeFirst(over) }
            }
        }
        TTLMacroRegistry.lock.unlock()
        recv.broadcast()
        recv.unlock()
    }

    /// 接続状態が変わった
    public func setComReady(_ ready: Bool) {
        recv.lock()
        if ready != comReady {
            comEvents.append(ready)
            if comEvents.count > 64 { comEvents.removeFirst() }
        }
        comReady = ready
        recv.broadcast()
        recv.unlock()
    }

    /// 端末ウインドウが閉じるなどして、つながりが切れた (Tera Term の DDE 切断 → OnDdeEnd)。
    /// マクロは止まらずに続き、waitevent 2 が起きる。wait などは result = 0 で戻る
    public func endLink() {
        recv.lock()
        if linked { linkEndEvent = true; linkLost = true }
        linked = false
        recv.broadcast()
        recv.unlock()
    }

    // MARK: - wait4all (wait4all.c / ttmdde.c Wait4all)

    static let timerTick = 0.05   // TIMEOUT_TIMER_MS

    /// wait4all を始める (TTLWait4all)。いま動いているマクロ全部の受信をのぞき始める。
    /// Tera Term は共有メモリの各マクロのリングバッファから直接読む (ほかのマクロの分も読み進めてしまう) が、
    /// ここではほかのマクロの受信は写しを読むだけで、そのマクロの wait などからは消さない。
    /// どのロックも持たずに呼ぶこと
    func beginWait4all() {
        recv.lock(); endWait4all(); recv.unlock()
        let me = ObjectIdentifier(self)
        var list = TTLMacroRegistry.snapshot()
        if !list.contains(where: { $0 === self }) { list.append(self) }
        for t in list where t !== self {
            t.recv.lock()
            let backlog = (0..<t.ringCount).map { t.ring[(t.ringStart + $0) % t.ring.count] }
            TTLMacroRegistry.lock.lock()
            t.snoopBuffers[me] = backlog
            TTLMacroRegistry.lock.unlock()
            t.recv.unlock()
        }
        recv.lock()
        w4aTargets = list
        w4aFound = Array(repeating: false, count: list.count)
        w4aFoundNum = 0
        w4aNum = list.count
        status = .wait4all
        recv.unlock()
    }

    /// のぞくのをやめる (recv を持って呼んでよい)
    func endWait4all() {
        let me = ObjectIdentifier(self)
        TTLMacroRegistry.lock.lock()
        for t in w4aTargets where t !== self { t.snoopBuffers[me] = nil }
        TTLMacroRegistry.lock.unlock()
        w4aTargets = []
        w4aFound = []
        w4aFoundNum = 0
    }

    /// Wait4allOneBuffer の照合: 合わなければ最初の文字だけ見直す。WaitCount は全部のバッファで共通
    private func wait4allByte(_ b: UInt8) -> Int {
        var found = 0
        for i in stride(from: 9, through: 0, by: -1) {
            guard let s = waitStr[i] else { continue }
            if TTLInterpreter.waitAt(s, waitCount[i]) == Int(b) {
                waitCount[i] += 1
            } else if waitCount[i] > 0 {
                waitCount[i] = TTLInterpreter.waitAt(s, 0) == Int(b) ? 1 : 0
            }
            if waitCount[i] == s.count { found = i + 1 }
        }
        return found
    }

    /// Wait4all(): 全部そろったら true。recvln のバッファは使わない
    private func wait4allMatch() -> Bool {
        let me = ObjectIdentifier(self)
        for (k, t) in w4aTargets.enumerated() {
            var found = 0
            if t === self {
                while found == 0, let b = read1Byte() { found = wait4allByte(b) }
            } else {
                TTLMacroRegistry.lock.lock()
                if let buf = t.snoopBuffers[me] {
                    var n = 0
                    while found == 0 && n < buf.count { found = wait4allByte(buf[n]); n += 1 }
                    if n > 0 { t.snoopBuffers[me]!.removeFirst(n) }
                }
                TTLMacroRegistry.lock.unlock()
            }
            if found > 0 && !w4aFound[k] { w4aFound[k] = true; w4aFoundNum += 1 }
        }
        // 途中でマクロが減ったら、そろえる数も減らす
        let cur = TTLMacroRegistry.count()
        if cur < w4aNum { w4aNum = cur }
        return w4aFoundNum >= w4aNum
    }

    /// 待つ文字列の k 文字目 (C の文字列と同じく、終わりの次は 0。その先は何とも合わない)
    @inline(__always) static func waitAt(_ s: [UInt8], _ k: Int) -> Int {
        k < s.count ? Int(s[k]) : (k == s.count ? 0 : -1)
    }

    private func put1Byte(_ b: UInt8) {
        let size = ring.count
        let ptr = (ringStart + ringCount) % size
        if ringCount >= size {
            if syncMode {
                // 同期モードでは捨てずに広げる
                let old = (0..<ringCount).map { ring[(ringStart + $0) % size] }
                ring = old + Array(repeating: 0, count: size)
                ringStart = 0
                ring[ringCount] = b
                ringCount += 1
                return
            }
            ring[ptr] = b
            ringStart = (ringStart + 1) % size
        } else {
            ring[ptr] = b
            ringCount += 1
        }
    }

    func read1Byte() -> UInt8? {
        if ringCount <= 0 { return nil }
        let b = ring[ringStart]
        ringStart = (ringStart + 1) % ring.count
        ringCount -= 1
        return b
    }

    func flushRecv() {
        recv.lock()
        clearRecvLnBuff()
        ringStart = 0
        ringCount = 0
        recv.unlock()
    }

    func clearRecvLnBuff() { recvLnBuff = []; recvLnLast = 0 }

    func putRecvLnBuff(_ b: UInt8) {
        if recvLnLast == 0x0A && recvLnClear { clearRecvLnBuff() }
        if recvLnBuff.count < MaxStrLen - 1 { recvLnBuff.append(b) }
        recvLnLast = b
    }

    func getRecvLnBuff() -> [UInt8] {
        var b = recvLnBuff
        if b.last == 0x0A {
            b.removeLast()
            if b.last == 0x0D { b.removeLast() }
        }
        clearRecvLnBuff()
        return b
    }

    func clearWait() {
        for i in 0..<10 { waitStr[i] = nil; waitCount[i] = 0 }
        regexWait = false
    }
    func setWait(_ index: Int, _ s: [UInt8]) { waitStr[index - 1] = s; waitCount[index - 1] = 0 }
    func clearWaitN() { waitNLen = 0; recvLnClear = true }
    func setWaitN(_ n: Int) { waitNLen = n; recvLnClear = false }

    func setWait2(_ s: [UInt8], _ len: Int, _ pos: Int) {
        wait2SubStr = ttlTrunc(s)
        let subLen = wait2SubStr.count
        wait2Len = len < 1 ? 0 : min(len, MaxStrLen - 1)
        if wait2Len < subLen { wait2Len = subLen }
        if pos < 1 { wait2SubPos = 1 } else if pos > wait2Len - subLen + 1 { wait2SubPos = wait2Len - subLen + 1 } else { wait2SubPos = pos }
        wait2Str = []
        wait2Found = wait2SubStr.isEmpty
    }

    /// wait / waitln / waitregex の照合 (Wait())
    private func waitMatch() -> Int {
        var found = 0
        while found == 0, let b = read1Byte() {
            if b == 0x0A {
                let r = findRegexString()
                if r > 0 { found = r; break }
            }
            putRecvLnBuff(b)
            if !regexWait {
                for i in stride(from: 9, through: 0, by: -1) {
                    guard let s = waitStr[i] else { continue }
                    // C の文字列と同じく s の終わりの次は 0 とみなす。空の文字列は最初の 1 バイトで合う (NUL を除く)
                    let at = { (k: Int) in TTLInterpreter.waitAt(s, k) }
                    if at(waitCount[i]) == Int(b) {
                        waitCount[i] += 1
                    } else if waitCount[i] > 0 {
                        var j = waitCount[i] - 1
                        while j >= 0 {
                            if at(j) == Int(b) {
                                if j == 0 || (0..<j).allSatisfy({ at($0) == at(waitCount[i] - j + $0) }) { break }
                            }
                            j -= 1
                        }
                        waitCount[i] = j >= 0 ? j + 1 : 0
                    }
                    if waitCount[i] == s.count { found = i + 1 }
                }
            }
        }
        if found == 0 {
            let r = findRegexString()
            if r > 0 { found = r }
        }
        if found > 0 { clearWait() }
        return found
    }

    private func findRegexString() -> Int {
        if !regexWait || recvLnBuff.isEmpty { return 0 }
        for i in 0..<10 {
            guard let pat = waitStr[i] else { continue }
            if findRegexStringOne(pat, recvLnBuff) > 0 {
                setInputStr(getRecvLnBuff())
                return i + 1
            }
        }
        return 0
    }

    /// 正規表現で探す (FindRegexStringOne)。見つかれば 1 始まりのバイト位置、なければ 0、正規表現が壊れていれば -1。
    /// 見つかったら matchstr / groupmatchstr1〜9 に入れる
    func findRegexStringOne(_ pattern: [UInt8], _ target: [UInt8]) -> Int {
        switch TTLRegex.search(pattern, in: target, option: regexOpt, encoding: regexEnc, syntax: regexSyntax) {
        case .error: return -1
        case .noMatch: return 0
        case .match(let m):
            for i in 1...9 { setGroupMatchStr(i, []) }
            for (i, g) in m.groups.enumerated() {
                let piece = g.map { Array(target[$0]) } ?? []
                if i == 0 { setMatchStr(piece) } else if i <= 9 { setGroupMatchStr(i, piece) }
            }
            return m.position + 1
        }
    }

    private func wait2() -> Bool {
        while !(wait2Found && wait2Str.count == wait2Len), let b = read1Byte() {
            if wait2Str.count >= wait2Len {
                if wait2Len > 0 { wait2Str.removeFirst(); wait2Str.append(b) }
            } else {
                wait2Str.append(b)
            }
            if !wait2Found && wait2Str.count >= wait2SubPos + wait2SubStr.count - 1 {
                let s = wait2SubPos - 1
                if s >= 0 && s + wait2SubStr.count <= wait2Str.count {
                    wait2Found = Array(wait2Str[s..<(s + wait2SubStr.count)]) == wait2SubStr
                }
            }
        }
        return wait2Found && wait2Str.count == wait2Len
    }

    private func waitN() -> Bool {
        while recvLnBuff.count < waitNLen, let b = read1Byte() { putRecvLnBuff(b) }
        return recvLnBuff.count >= waitNLen
    }

    // MARK: - 便利関数 (各コマンドで使う)

    /// 行末であることを確かめる
    func endOfLine(_ err: inout Int) {
        if err == 0 && getFirstChar() != 0 { err = E.syntax }
    }

    /// 相対パスを現在のフォルダ基準にする (GetAbsPath)
    func absPath(_ s: [UInt8]) -> String {
        var p = s.u8
        if p.isEmpty { return p }
        p = TTLInterpreter.windowsPath(p)
        if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
        if !p.hasPrefix("/") { p = (curDir as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    /// Windows 風のパス (c:\dir\file, \ 区切り) を Mac のパスに寄せる
    static func windowsPath(_ s: String) -> String {
        var p = s.replacingOccurrences(of: "\\", with: "/")
        if p.count >= 2, p.dropFirst().first == ":", let d = p.first, d.isLetter {
            p = String(p.dropFirst(2))
            if p.isEmpty { p = "/" }
        }
        return p
    }

    /// 待つ (pause / mpause)。止められたら早めに戻る
    func sleep(_ sec: Double) {
        let end = Date(timeIntervalSinceNow: sec)
        recv.lock()
        while !_cancelled && Date() < end { _ = recv.wait(until: min(end, Date(timeIntervalSinceNow: 0.1))) }
        recv.unlock()
    }
}

/// 動いているマクロの一覧 (wait4all.c の共有メモリ WinList の代わり)。ロックの順番は 各マクロの recv → これ
final class TTLMacroRegistry {
    static let lock = NSLock()
    private static var running: [TTLInterpreter] = []
    static func add(_ m: TTLInterpreter) { lock.lock(); if !running.contains(where: { $0 === m }) { running.append(m) }; lock.unlock() }
    static func remove(_ m: TTLInterpreter) { lock.lock(); running.removeAll { $0 === m }; lock.unlock() }
    static func snapshot() -> [TTLInterpreter] { lock.lock(); defer { lock.unlock() }; return running }
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return running.count }
}

/// テストや外部から変数を見るための値
public enum TTLValue: CustomStringConvertible, Equatable {
    case int(Int)
    case str(String)
    public var description: String {
        switch self {
        case .int(let i): return String(i)
        case .str(let s): return s
        }
    }
}
