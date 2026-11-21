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
    public init(path: String, host: TTLHost, params: [String] = []) throws {
        self.host = host
        self.macroPath = path
        let dir = (path as NSString).deletingLastPathComponent
        curDir = dir.isEmpty ? FileManager.default.currentDirectoryPath : dir
        ring = Array(repeating: 0, count: TTLInterpreter.ringBufSize)
        initVars(params: params)
        if !loadMacroFile(path, 0) {
            throw TTLError(line: 0, message: "Can't open file.", file: (path as NSString).lastPathComponent, text: "")
        }
        try registerLabelsOrThrow(0)
    }

    /// テスト用: 文字列からマクロを作る
    public convenience init(source: String, host: TTLHost, baseDir: URL? = nil) throws {
        let dir = baseDir?.path ?? NSTemporaryDirectory()
        let p = (dir as NSString).appendingPathComponent(".teramac-\(UUID().uuidString).ttl")
        try Data(source.utf8).write(to: URL(fileURLWithPath: p))
        defer { try? FileManager.default.removeItem(atPath: p) }
        try self.init(path: p, host: host)
    }

    private func initVars(params: [String]) {
        _ = newIntVar("result", 0)
        _ = newIntVar("timeout", 0)
        _ = newIntVar("mtimeout", 0)
        _ = newStrVar("inputstr", [])
        _ = newStrVar("matchstr", [])
        for i in 1...9 { _ = newStrVar("groupmatchstr\(i)", []) }
        let all = [(macroPath as NSString).lastPathComponent] + params
        let paramCnt = max(1, all.count)
        _ = newIntVar("paramcnt", Int32(paramCnt))
        _ = newStrVar("param1", macroPath.ttl)
        for i in 2...9 { _ = newStrVar("param\(i)", i - 1 < all.count ? all[i - 1].ttl : []) }
        _ = newStrAryVar("params", paramCnt + 1)
        if let v = vars.last {
            v.strAry[1] = macroPath.ttl
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
    func newIntAryVar(_ name: String, _ size: Int) -> Int {
        guard size >= 0 && size <= 65536 else { return E.outOfRange }
        let x = TTLVariable(name, .intArray); x.intAry = Array(repeating: 0, count: size); addVar(x); return 0
    }
    func newStrAryVar(_ name: String, _ size: Int) -> Int {
        guard size >= 0 && size <= 65536 else { return E.outOfRange }
        let x = TTLVariable(name, .strArray); x.strAry = Array(repeating: nil, count: size); addVar(x); return 0
    }
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

    // 変数 ID: 普通の変数は添字、配列の要素は ((配列の添字 + 1) << 16) | 要素番号

    func setIntVal(_ id: Int, _ val: Int32) {
        if id >> 16 != 0 { vars[(id >> 16) - 1].intAry[id & 0xFFFF] = val } else { vars[id].int = val }
    }
    func copyIntVal(_ id: Int) -> Int32 {
        if id >> 16 != 0 { return vars[(id >> 16) - 1].intAry[id & 0xFFFF] }
        return vars[id].int
    }
    func setStrVal(_ id: Int, _ s: [UInt8]) {
        var s = s
        if let z = s.firstIndex(of: 0) { s.removeSubrange(z...) }
        if id >> 16 != 0 { vars[(id >> 16) - 1].strAry[id & 0xFFFF] = s } else { vars[id].str = s }
    }
    func strVarPtr(_ id: Int) -> [UInt8] {
        if id >> 16 != 0 { return vars[(id >> 16) - 1].strAry[id & 0xFFFF] ?? [] }
        return vars[id].str
    }

    func getIntVarFromArray(_ id: Int, _ index: Int, _ err: inout Int) -> Int {
        let n = vars[id].intAry.count
        if index < 0 || index >= n { err = E.outOfRange; return -1 }
        err = 0
        return ((id + 1) << 16) | index
    }
    func getStrVarFromArray(_ id: Int, _ index: Int, _ err: inout Int) -> Int {
        let n = vars[id].strAry.count
        if index < 0 || index >= n { err = E.outOfRange; return -1 }
        err = 0
        return ((id + 1) << 16) | index
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
                        if err == 0 { val = Int32(vid); type = .string }
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

    /// ファイルを UTF-8 で読む。UTF-8 でなければ Shift_JIS (CP932) とみなす
    static func loadText(_ path: String) -> [UInt8]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        var b = [UInt8](d)
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return Array(b[3...]) }
        if b.starts(with: [0xFF, 0xFE]) || b.starts(with: [0xFE, 0xFF]) {
            let enc: String.Encoding = b[0] == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            return String(data: Data(b[2...]), encoding: enc).map { Array($0.utf8) }
        }
        if String(data: d, encoding: .utf8) != nil { return b }
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        if let s = String(data: d, encoding: cp932) { b = Array(s.utf8) }
        return b
    }

    func loadMacroFile(_ path: String, _ level: Int) -> Bool {
        guard !path.isEmpty, level < TTLInterpreter.maxNestLevel else { return false }
        guard let data = TTLInterpreter.loadText(path) else { return false }
        var mb = MacroBuffer()
        mb.name = (path as NSString).lastPathComponent
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
                    var e2 = 0
                    _ = getString(&e2)
                }
            } while b != 0
            if err > 0 { errors.append(err); reportError(err) }
            if status == .end { break }
        }
        if !isCommentClosed() { reportError(E.closeComment) }
        buffs[level]!.ptr = 0
        lineNo = 1
        iNest = saveNest
        return errors
    }

    private func registerLabelsOrThrow(_ level: Int) throws {
        _ = registerLabels(level)
        if status == .end { throw TTLError(line: lineNo, message: "マクロを止めました", file: macroFileName, text: "") }
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
        let stop = host?.ttlError(message: E.message(err), line: lineNo, lineText: lineBuff.u8, file: macroFileName,
                                  range: start..<end) ?? true
        if stop {
            status = .end
            lastError = TTLError(line: lineNo, message: E.message(err), file: macroFileName, text: lineBuff.u8)
        }
    }
    public private(set) var lastError: TTLError?

    // MARK: - 実行 (Exec / OnIdle)

    public func run() throws {
        host?.ttlMacroStarted(self)
        defer { endTTL() }
        while status != .end {
            if cancelled { status = .end; break }
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
        if err != 0 || getFirstChar() != 0x3D { return err != 0 ? err : E.notSupported }
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

    func startTimer() {
        var t = 0
        if let v = intVariable("timeout") { t = Int(v) * 1000 }
        if let v = intVariable("mtimeout") { t += Int(v) }
        if t > 0 {
            timeLimit = Double(t) / 1000
            timeStart = Date()
            timerOn = true
        } else {
            timerOn = false
        }
    }

    func checkTimeout() -> Bool { timerOn && Date().timeIntervalSince(timeStart) >= timeLimit }

    /// 受信データ・時間切れ・切断を見て待ちを 1 回進める。進まなければ少し眠る
    private func waitStep() {
        var progressed = false
        recv.lock()
        defer { recv.unlock() }
        switch status {
        case .wait, .wait4all:
            let r = waitMatch()
            if r > 0 { timerOn = false; status = .run; setResult(r); clearWait(); progressed = true }
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
        case .wait, .waitLn, .waitNL, .wait4all:
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
            if (wakeupCondition & Wakeup.connect) != 0 && comReady { setResult(Wakeup.connect); status = .run; return }
            if (wakeupCondition & Wakeup.disconn) != 0 && !comReady { setResult(Wakeup.disconn); status = .run; return }
        default:
            status = .run
            return
        }
        _ = recv.wait(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - 受信バッファ (ttmdde.c)

    /// 端末に表示した文字 (UTF-8) を渡す。どのスレッドからでもよい
    public func feed(_ bytes: [UInt8]) {
        recv.lock()
        for b in bytes where b != 0 { put1Byte(b) }
        recv.broadcast()
        recv.unlock()
    }

    /// 接続状態が変わった
    public func setComReady(_ ready: Bool) {
        recv.lock()
        comReady = ready
        recv.broadcast()
        recv.unlock()
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
                    if waitCount[i] < s.count && s[waitCount[i]] == b {
                        waitCount[i] += 1
                    } else if waitCount[i] > 0 {
                        var j = waitCount[i] - 1
                        while j >= 0 {
                            if s[j] == b {
                                if j == 0 || Array(s[0..<j]) == Array(s[(waitCount[i] - j)..<waitCount[i]]) { break }
                            }
                            j -= 1
                        }
                        waitCount[i] = j >= 0 ? j + 1 : 0
                    }
                    if waitCount[i] == s.count && !s.isEmpty { found = i + 1 }
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
