import Foundation

/// TTL マクロの値
public enum TTLValue: CustomStringConvertible {
    case int(Int)
    case str(String)

    public var description: String {
        switch self {
        case .int(let i): return String(i)
        case .str(let s): return s
        }
    }
    var intValue: Int {
        switch self {
        case .int(let i): return i
        case .str(let s): return Int(s.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    var isTrue: Bool { intValue != 0 }
}

public struct TTLError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "\(line) 行目: \(message)" }
}

/// マクロが端末に頼む操作 (アプリ側が実装する)
public protocol TTLHost: AnyObject {
    func ttlSend(_ s: String)
    /// 受信バッファから strings のどれかを待つ。見つかれば 1 始まりの番号、時間切れなら 0
    func ttlWait(_ strings: [String], timeout: Double) -> Int
    /// 1 行受信を待つ (waitln 用)。見つかった行を返す
    func ttlWaitLine(_ strings: [String], timeout: Double) -> (Int, String)
    func ttlFlushRecv()
    func ttlMessage(_ text: String, title: String)
    func ttlInput(_ text: String, title: String, secret: Bool) -> String?
    func ttlYesNo(_ text: String, title: String) -> Bool
    func ttlConnect(_ spec: String) -> Bool
    func ttlDisconnect()
    func ttlLogOpen(_ path: String) -> Bool
    func ttlLogClose()
    func ttlSetTitle(_ s: String)
    func ttlBeep()
    func ttlSendBreak()
    func ttlIsConnected() -> Bool
    func ttlStatus(_ s: String)
    func ttlCloseWindow()
}

public extension TTLHost {
    func ttlCloseWindow() { ttlDisconnect() }
}

/// Tera Term マクロ言語 (TTL) の主なコマンドを解釈して動かす
public final class TTLInterpreter {
    private struct Stmt {
        let line: Int
        let tokens: [Token]
    }
    enum Token: Equatable {
        case ident(String)
        case num(Int)
        case str(String)
        case op(String)
    }

    private var stmts: [Stmt] = []
    private var labels: [String: Int] = [:]
    private var vars: [String: TTLValue] = [:]
    private var callStack: [Int] = []
    private weak var host: TTLHost?
    private var pc = 0
    public var cancelled = false
    public let baseDir: URL?

    public init(source: String, host: TTLHost, baseDir: URL? = nil) throws {
        self.host = host
        self.baseDir = baseDir
        vars["timeout"] = .int(0)
        vars["mtimeout"] = .int(0)
        vars["result"] = .int(0)
        vars["inputstr"] = .str("")
        try parse(source)
    }

    public func variable(_ name: String) -> TTLValue? { vars[name.lowercased()] }

    // MARK: - 字句解析

    private func parse(_ source: String) throws {
        let rawLines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var inBlockComment = false
        for (i, raw) in rawLines.enumerated() {
            var text = raw
            if inBlockComment {
                if let r = text.range(of: "*/") { text = String(text[r.upperBound...]); inBlockComment = false } else { continue }
            }
            if let r = text.range(of: "/*"), !insideQuote(text, r.lowerBound) {
                if let e = text.range(of: "*/", range: r.upperBound..<text.endIndex) {
                    text.removeSubrange(r.lowerBound..<e.upperBound)
                } else {
                    text = String(text[..<r.lowerBound]); inBlockComment = true
                }
            }
            let toks = try tokenize(text, line: i + 1)
            if toks.isEmpty { continue }
            if case .op(":") = toks[0], toks.count >= 2, case .ident(let name) = toks[1] {
                labels[name.lowercased()] = stmts.count
                continue
            }
            stmts.append(Stmt(line: i + 1, tokens: toks))
        }
    }

    private func insideQuote(_ s: String, _ idx: String.Index) -> Bool {
        var q: Character?
        for i in s.indices {
            if i == idx { return q != nil }
            let c = s[i]
            if let qq = q { if c == qq { q = nil } } else if c == "'" || c == "\"" { q = c }
        }
        return false
    }

    private func tokenize(_ s: String, line: Int) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        var lastWasStringPiece = false
        func pushStr(_ piece: String) {
            // 'abc'#13#10'def' のような連結は 1 つの文字列にする
            if case .str(let prev)? = out.last, lastWasStringPiece {
                out[out.count - 1] = .str(prev + piece)
            } else {
                out.append(.str(piece))
            }
            lastWasStringPiece = true
        }
        while i < chars.count {
            let c = chars[i]
            if c == ";" { break }
            if c == " " || c == "\t" { i += 1; lastWasStringPiece = false; continue }
            if c == "'" || c == "\"" {
                var j = i + 1
                var buf = ""
                while j < chars.count && chars[j] != c { buf.append(chars[j]); j += 1 }
                if j >= chars.count { throw TTLError(line: line, message: "文字列が閉じていません") }
                pushStr(buf)
                i = j + 1
                continue
            }
            if c == "#" {
                var j = i + 1
                var buf = ""
                if j < chars.count && chars[j] == "$" {
                    j += 1
                    while j < chars.count && chars[j].isHexDigit { buf.append(chars[j]); j += 1 }
                    pushStr(String(UnicodeScalar(UInt32(buf, radix: 16) ?? 0).map { Character($0) } ?? " "))
                } else {
                    while j < chars.count && chars[j].isNumber { buf.append(chars[j]); j += 1 }
                    pushStr(String(UnicodeScalar(UInt32(buf) ?? 0).map { Character($0) } ?? " "))
                }
                i = j
                continue
            }
            lastWasStringPiece = false
            if c == "$" {
                var j = i + 1
                var buf = ""
                while j < chars.count && chars[j].isHexDigit { buf.append(chars[j]); j += 1 }
                out.append(.num(Int(buf, radix: 16) ?? 0)); i = j; continue
            }
            if c.isNumber {
                var j = i
                var buf = ""
                while j < chars.count && chars[j].isNumber { buf.append(chars[j]); j += 1 }
                out.append(.num(Int(buf) ?? 0)); i = j; continue
            }
            if c.isLetter || c == "_" {
                var j = i
                var buf = ""
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { buf.append(chars[j]); j += 1 }
                if j < chars.count && chars[j] == "[" {
                    // 配列は name[idx] を 1 つの名前として扱う (添字は実行時に評価)
                    var k = j + 1
                    var depth = 1
                    var inner = ""
                    while k < chars.count && depth > 0 {
                        if chars[k] == "[" { depth += 1 }
                        if chars[k] == "]" { depth -= 1; if depth == 0 { break } }
                        inner.append(chars[k]); k += 1
                    }
                    out.append(.ident(buf + "[" + inner + "]"))
                    i = k + 1
                    continue
                }
                out.append(.ident(buf)); i = j; continue
            }
            let two = i + 1 < chars.count ? String([c, chars[i + 1]]) : ""
            if ["==", "<>", "!=", "<=", ">=", "&&", "||", ">>", "<<", "+=", "-=", "*=", "/="].contains(two) {
                out.append(.op(two)); i += 2; continue
            }
            if "=<>+-*/%()&|^!~:,".contains(c) {
                out.append(.op(String(c))); i += 1; continue
            }
            throw TTLError(line: line, message: "読めない文字: \(c)")
        }
        return out
    }

    // MARK: - 式

    private struct ExprParser {
        let toks: [Token]
        var pos: Int
        let interp: TTLInterpreter
        let line: Int

        mutating func peekOp() -> String? {
            guard pos < toks.count else { return nil }
            if case .op(let o) = toks[pos] { return o }
            if case .ident(let i) = toks[pos] {
                let l = i.lowercased()
                if l == "and" || l == "or" || l == "xor" || l == "not" { return l }
            }
            return nil
        }

        mutating func parseOr() throws -> TTLValue {
            var l = try parseAnd()
            while let o = peekOp(), o == "||" || o == "or" || o == "xor" || o == "|" || o == "^" {
                pos += 1
                let r = try parseAnd()
                switch o {
                case "||": l = .int(l.isTrue || r.isTrue ? 1 : 0)
                case "^", "xor": l = .int(l.intValue ^ r.intValue)
                default: l = .int(l.intValue | r.intValue)
                }
            }
            return l
        }
        mutating func parseAnd() throws -> TTLValue {
            var l = try parseCmp()
            while let o = peekOp(), o == "&&" || o == "and" || o == "&" {
                pos += 1
                let r = try parseCmp()
                l = o == "&&" ? .int(l.isTrue && r.isTrue ? 1 : 0) : .int(l.intValue & r.intValue)
            }
            return l
        }
        mutating func parseCmp() throws -> TTLValue {
            let l = try parseAdd()
            if let o = peekOp(), ["==", "=", "<>", "!=", "<", ">", "<=", ">="].contains(o) {
                pos += 1
                let r = try parseAdd()
                let res: Bool
                if case .str(let a) = l, case .str(let b) = r {
                    switch o {
                    case "==", "=": res = a == b
                    case "<>", "!=": res = a != b
                    case "<": res = a < b
                    case ">": res = a > b
                    case "<=": res = a <= b
                    default: res = a >= b
                    }
                } else {
                    let a = l.intValue, b = r.intValue
                    switch o {
                    case "==", "=": res = a == b
                    case "<>", "!=": res = a != b
                    case "<": res = a < b
                    case ">": res = a > b
                    case "<=": res = a <= b
                    default: res = a >= b
                    }
                }
                return .int(res ? 1 : 0)
            }
            return l
        }
        mutating func parseAdd() throws -> TTLValue {
            var l = try parseMul()
            while let o = peekOp(), o == "+" || o == "-" {
                pos += 1
                let r = try parseMul()
                l = .int(o == "+" ? l.intValue &+ r.intValue : l.intValue &- r.intValue)
            }
            return l
        }
        mutating func parseMul() throws -> TTLValue {
            var l = try parseUnary()
            while let o = peekOp(), o == "*" || o == "/" || o == "%" || o == ">>" || o == "<<" {
                pos += 1
                let r = try parseUnary()
                switch o {
                case "*": l = .int(l.intValue &* r.intValue)
                case "/":
                    if r.intValue == 0 { throw TTLError(line: line, message: "0 で割りました") }
                    l = .int(l.intValue / r.intValue)
                case "%":
                    if r.intValue == 0 { throw TTLError(line: line, message: "0 で割りました") }
                    l = .int(l.intValue % r.intValue)
                case ">>": l = .int(l.intValue >> r.intValue)
                default: l = .int(l.intValue << r.intValue)
                }
            }
            return l
        }
        mutating func parseUnary() throws -> TTLValue {
            if let o = peekOp() {
                if o == "-" { pos += 1; return .int(-(try parseUnary()).intValue) }
                if o == "+" { pos += 1; return try parseUnary() }
                if o == "!" || o == "not" { pos += 1; return .int((try parseUnary()).isTrue ? 0 : 1) }
                if o == "~" { pos += 1; return .int(~(try parseUnary()).intValue) }
            }
            return try parsePrimary()
        }
        mutating func parsePrimary() throws -> TTLValue {
            guard pos < toks.count else { throw TTLError(line: line, message: "式が途中で終わっています") }
            let t = toks[pos]
            pos += 1
            switch t {
            case .num(let n): return .int(n)
            case .str(let s): return .str(s)
            case .ident(let name): return try interp.get(name, line: line)
            case .op("("):
                let v = try parseOr()
                if pos < toks.count, case .op(")") = toks[pos] { pos += 1 } else {
                    throw TTLError(line: line, message: "かっこが閉じていません")
                }
                return v
            default:
                throw TTLError(line: line, message: "式が読めません")
            }
        }
    }

    private func evalExpr(_ toks: [Token], line: Int) throws -> TTLValue {
        var p = ExprParser(toks: toks, pos: 0, interp: self, line: line)
        let v = try p.parseOr()
        if p.pos != toks.count { throw TTLError(line: line, message: "式のあとに余計なものがあります") }
        return v
    }

    private func resolveName(_ raw: String, line: Int) throws -> String {
        guard let b = raw.firstIndex(of: "[") else { return raw.lowercased() }
        let base = raw[..<b].lowercased()
        let inner = String(raw[raw.index(after: b)..<raw.index(before: raw.endIndex)])
        let idx = try evalExpr(try tokenize(inner, line: line), line: line).intValue
        return "\(base)[\(idx)]"
    }

    fileprivate func get(_ name: String, line: Int) throws -> TTLValue {
        let key = try resolveName(name, line: line)
        if let v = vars[key] { return v }
        throw TTLError(line: line, message: "変数がありません: \(name)")
    }

    private func set(_ name: String, _ v: TTLValue, line: Int) throws {
        vars[try resolveName(name, line: line)] = v
    }

    /// コマンドの引数をカンマなし・空白区切りの式として分ける
    private func splitArgs(_ toks: [Token]) -> [[Token]] {
        var args: [[Token]] = []
        var cur: [Token] = []
        var depth = 0
        var expectOperand = true
        for t in toks {
            if case .op(",") = t, depth == 0 { if !cur.isEmpty { args.append(cur) }; cur = []; expectOperand = true; continue }
            var isOperand = false
            var isBinaryOp = false
            switch t {
            case .op("("): depth += 1
            case .op(")"): depth -= 1
            case .op(let o) where o != "!" && o != "~": isBinaryOp = true
            case .ident(let s) where ["and", "or", "xor"].contains(s.lowercased()): isBinaryOp = true
            default: isOperand = true
            }
            if isOperand && !expectOperand && depth == 0 && !cur.isEmpty {
                args.append(cur); cur = []
            }
            cur.append(t)
            if case .op(")") = t { expectOperand = false } else if case .op("(") = t { expectOperand = true }
            else { expectOperand = isBinaryOp || (!isOperand) }
            if isOperand { expectOperand = false }
        }
        if !cur.isEmpty { args.append(cur) }
        return args
    }

    // MARK: - 実行

    public func run() throws {
        pc = 0
        while pc < stmts.count && !cancelled {
            let s = stmts[pc]
            pc += 1
            if try exec(s.tokens, line: s.line) == false { break }
        }
    }

    private func findBlockEnd(from start: Int, open: Set<String>, close: Set<String>, middle: Set<String> = []) -> (Int, [Int]) {
        var depth = 0
        var mids: [Int] = []
        var i = start
        while i < stmts.count {
            let t = stmts[i].tokens
            if case .ident(let c) = t[0] {
                let l = c.lowercased()
                // 1 行 if (if 式 then なし でコマンドが続く) は入れ子に数えない
                let isBlockIf = l != "if" || isBlockIfStmt(t)
                if open.contains(l) && isBlockIf { depth += 1 }
                else if close.contains(l) {
                    if depth == 0 { return (i, mids) }
                    depth -= 1
                } else if middle.contains(l) && depth == 0 { mids.append(i) }
            }
            i += 1
        }
        return (stmts.count, mids)
    }

    private func isBlockIfStmt(_ t: [Token]) -> Bool {
        if case .ident(let last) = t.last!, last.lowercased() == "then" { return true }
        return false
    }

    /// false を返すと終了
    private func exec(_ toks: [Token], line: Int) throws -> Bool {
        guard case .ident(let rawCmd) = toks[0] else { throw TTLError(line: line, message: "命令が読めません") }
        let cmd = rawCmd.lowercased()
        let rest = Array(toks.dropFirst())

        // 代入
        if let first = rest.first, case .op(let o) = first, ["=", "+=", "-=", "*=", "/="].contains(o),
           !["if", "elseif", "while", "until"].contains(cmd) {
            let v = try evalExpr(Array(rest.dropFirst()), line: line)
            if o == "=" { try set(rawCmd, v, line: line); return true }
            let cur = try get(rawCmd, line: line)
            switch o {
            case "+=":
                if case .str(let a) = cur { try set(rawCmd, .str(a + v.description), line: line) }
                else { try set(rawCmd, .int(cur.intValue + v.intValue), line: line) }
            case "-=": try set(rawCmd, .int(cur.intValue - v.intValue), line: line)
            case "*=": try set(rawCmd, .int(cur.intValue * v.intValue), line: line)
            default:
                if v.intValue == 0 { throw TTLError(line: line, message: "0 で割りました") }
                try set(rawCmd, .int(cur.intValue / v.intValue), line: line)
            }
            return true
        }

        let args = splitArgs(rest)
        func arg(_ i: Int) throws -> TTLValue {
            guard i < args.count else { throw TTLError(line: line, message: "\(cmd) の引数が足りません") }
            return try evalExpr(args[i], line: line)
        }
        func argOr(_ i: Int, _ d: TTLValue) throws -> TTLValue { i < args.count ? try arg(i) : d }
        func varName(_ i: Int) throws -> String {
            guard i < args.count, args[i].count == 1, case .ident(let n) = args[i][0] else {
                throw TTLError(line: line, message: "\(cmd) には変数名が要ります")
            }
            return n
        }
        guard let host = host else { return false }
        func timeoutSec() -> Double {
            let t = Double((vars["timeout"] ?? .int(0)).intValue) + Double((vars["mtimeout"] ?? .int(0)).intValue) / 1000
            return t
        }

        switch cmd {
        case "send":
            var s = ""
            for i in 0..<args.count {
                let v = try arg(i)
                if case .int(let n) = v, let u = UnicodeScalar(UInt32(truncatingIfNeeded: n)) { s.unicodeScalars.append(u) } else { s += v.description }
            }
            host.ttlSend(s)
        case "sendln":
            var s = ""
            for i in 0..<args.count {
                let v = try arg(i)
                if case .int(let n) = v, let u = UnicodeScalar(UInt32(truncatingIfNeeded: n)) { s.unicodeScalars.append(u) } else { s += v.description }
            }
            host.ttlSend(s + "\r")
        case "sendbreak": host.ttlSendBreak()
        case "wait", "waitln":
            var strs: [String] = []
            for i in 0..<args.count { strs.append(try arg(i).description) }
            if cmd == "wait" {
                vars["result"] = .int(host.ttlWait(strs, timeout: timeoutSec()))
            } else {
                let (r, l) = host.ttlWaitLine(strs, timeout: timeoutSec())
                vars["result"] = .int(r); vars["inputstr"] = .str(l)
            }
        case "flushrecv": host.ttlFlushRecv()
        case "pause":
            try sleep(Double(try arg(0).intValue))
        case "mpause":
            try sleep(Double(try arg(0).intValue) / 1000)
        case "messagebox":
            host.ttlMessage(try arg(0).description, title: try argOr(1, .str("Tera Term Mac")).description)
        case "inputbox", "passwordbox":
            let r = host.ttlInput(try arg(0).description, title: try argOr(1, .str("Tera Term Mac")).description, secret: cmd == "passwordbox")
            vars["inputstr"] = .str(r ?? "")
            vars["result"] = .int(r == nil ? 0 : 1)
        case "yesnobox":
            vars["result"] = .int(host.ttlYesNo(try arg(0).description, title: try argOr(1, .str("Tera Term Mac")).description) ? 1 : 0)
        case "statusbox":
            host.ttlStatus(try arg(0).description)
        case "closesbox": host.ttlStatus("")
        case "connect":
            let ok = host.ttlConnect(try arg(0).description)
            vars["result"] = .int(ok ? 2 : 0)
        case "disconnect": host.ttlDisconnect()
        case "testlink":
            vars["result"] = .int(host.ttlIsConnected() ? 2 : 0)
        case "logopen":
            vars["result"] = .int(host.ttlLogOpen(try arg(0).description) ? 1 : 0)
        case "logclose": host.ttlLogClose()
        case "settitle": host.ttlSetTitle(try arg(0).description)
        case "beep": host.ttlBeep()
        case "end", "exit": return false
        case "closett":
            host.ttlCloseWindow(); return false
        case "goto":
            guard case .ident(let l)? = rest.first, let t = labels[l.lowercased()] else {
                throw TTLError(line: line, message: "ラベルがありません")
            }
            pc = t
        case "call":
            guard case .ident(let l)? = rest.first, let t = labels[l.lowercased()] else {
                throw TTLError(line: line, message: "ラベルがありません")
            }
            callStack.append(pc); pc = t
        case "return":
            guard let r = callStack.popLast() else { return false }
            pc = r
        case "int2str":
            try set(try varName(0), .str(String(try arg(1).intValue)), line: line)
        case "str2int":
            let s = try arg(1).description.trimmingCharacters(in: .whitespaces)
            if let n = Int(s) { try set(try varName(0), .int(n), line: line); vars["result"] = .int(1) } else { vars["result"] = .int(0) }
        case "strconcat":
            let n = try varName(0)
            try set(n, .str(try get(n, line: line).description + (try arg(1).description)), line: line)
        case "strlen":
            vars["result"] = .int(try arg(0).description.count)
        case "strcompare":
            let a = try arg(0).description, b = try arg(1).description
            vars["result"] = .int(a == b ? 0 : (a < b ? -1 : 1))
        case "strscan":
            let a = try arg(0).description, b = try arg(1).description
            if let r = a.range(of: b) { vars["result"] = .int(a.distance(from: a.startIndex, to: r.lowerBound) + 1) } else { vars["result"] = .int(0) }
        case "strcopy":
            let s = Array(try arg(0).description)
            let pos = max(1, try arg(1).intValue) - 1
            let len = max(0, try arg(2).intValue)
            let piece = pos < s.count ? String(s[pos..<min(s.count, pos + len)]) : ""
            try set(try varName(3), .str(piece), line: line)
        case "strtrim":
            let n = try varName(0)
            let set_ = CharacterSet(charactersIn: try arg(1).description)
            try set(n, .str(try get(n, line: line).description.trimmingCharacters(in: set_)), line: line)
        case "strreplace":
            let n = try varName(0)
            let s = try get(n, line: line).description
            let r = s.replacingOccurrences(of: try arg(2).description, with: try arg(3).description, options: .regularExpression)
            try set(n, .str(r), line: line)
        case "sprintf", "sprintf2":
            var target = "inputstr"
            var start = 0
            if cmd == "sprintf2" { target = try varName(0); start = 1 }
            let fmt = try arg(start).description
            var vals: [TTLValue] = []
            if args.count > start + 1 { for i in (start + 1)..<args.count { vals.append(try arg(i)) } }
            try set(target, .str(ttlFormat(fmt, vals)), line: line)
        case "gettime", "getdate":
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = cmd == "gettime" ? "HH:mm:ss" : "yyyy-MM-dd"
            if args.count > 1 {
                f.dateFormat = strftimeToICU(try arg(1).description)
            }
            try set(try varName(0), .str(f.string(from: Date())), line: line)
        case "getenv":
            try set(try varName(1), .str(ProcessInfo.processInfo.environment[try arg(0).description] ?? ""), line: line)
        case "dispstr":
            var s = ""
            for i in 0..<args.count { s += try arg(i).description }
            host.ttlStatus(s)
        case "include":
            break
        case "for":
            // for 変数 開始 終了 ... next
            let n = try varName(0)
            let startV = try arg(1).intValue
            let endV = try arg(2).intValue
            let (nextIdx, _) = findBlockEnd(from: pc, open: ["for"], close: ["next"])
            try set(n, .int(startV), line: line)
            let bodyStart = pc
            let step = startV <= endV ? 1 : -1
            var i = startV
            while !cancelled {
                pc = bodyStart
                try runRange(until: nextIdx)
                if loopBreak { loopBreak = false; break }
                i = try get(n, line: line).intValue
                if i == endV { break }
                i += step
                try set(n, .int(i), line: line)
            }
            pc = nextIdx + 1
        case "while", "until":
            let (endIdx, _) = findBlockEnd(from: pc, open: ["while", "until"], close: ["endwhile", "enduntil"])
            let bodyStart = pc
            while !cancelled {
                let c = try evalExpr(rest, line: line).isTrue
                if cmd == "while" ? !c : c { break }
                pc = bodyStart
                try runRange(until: endIdx)
                if loopBreak { loopBreak = false; break }
            }
            pc = endIdx + 1
        case "do":
            let (loopIdx, _) = findBlockEnd(from: pc, open: ["do"], close: ["loop"])
            let bodyStart = pc
            let loopToks = Array(stmts[min(loopIdx, stmts.count - 1)].tokens.dropFirst())
            let preCond = rest
            while !cancelled {
                if let c = try condOf(preCond, line: line), !c { break }
                pc = bodyStart
                try runRange(until: loopIdx)
                if loopBreak { loopBreak = false; break }
                if loopIdx < stmts.count, let c = try condOf(loopToks, line: stmts[loopIdx].line), !c { break }
            }
            pc = loopIdx + 1
        case "break":
            loopBreak = true
        case "continue":
            loopContinue = true
        case "if":
            if isBlockIfStmt(toks) {
                try execIfBlock(Array(rest.dropLast()), line: line)
            } else {
                // if 式 コマンド
                var p = ExprParser(toks: rest, pos: 0, interp: self, line: line)
                let c = try p.parseOr()
                if c.isTrue && p.pos < rest.count {
                    return try exec(Array(rest[p.pos...]), line: line)
                }
            }
        case "elseif", "else":
            // 実行した if 節の終わりに来たので endif まで飛ぶ
            let (endIdx, _) = findBlockEnd(from: pc, open: ["if"], close: ["endif"])
            pc = endIdx + 1
        case "endif", "next", "endwhile", "enduntil", "loop":
            break
        case "show", "setsync", "setecho", "bplusrecv", "bplussend", "clearscreen", "restoresetup", "loadkeymap":
            break
        default:
            throw TTLError(line: line, message: "未対応の命令: \(rawCmd)")
        }
        return true
    }

    private var loopBreak = false
    private var loopContinue = false

    private func condOf(_ toks: [Token], line: Int) throws -> Bool? {
        guard case .ident(let w)? = toks.first else { return nil }
        let l = w.lowercased()
        let c = try evalExpr(Array(toks.dropFirst()), line: line).isTrue
        if l == "while" { return c }
        if l == "until" { return !c }
        return nil
    }

    /// pc から end (含まない) まで実行する。break / continue / goto で抜ける
    private func runRange(until end: Int) throws {
        while pc < end && !cancelled {
            let s = stmts[pc]
            pc += 1
            if try exec(s.tokens, line: s.line) == false { cancelled = true; return }
            if loopBreak { return }
            if loopContinue { loopContinue = false; return }
            if pc > end || pc < 0 { return }
        }
    }

    private func execIfBlock(_ cond: [Token], line: Int) throws {
        let (endIdx, mids) = findBlockEnd(from: pc, open: ["if"], close: ["endif"], middle: ["elseif", "else"])
        if try evalExpr(cond, line: line).isTrue { return }  // 次の elseif/else で endif へ飛ぶ
        for m in mids {
            let t = stmts[m].tokens
            guard case .ident(let w) = t[0] else { continue }
            if w.lowercased() == "else" { pc = m + 1; return }
            var c = Array(t.dropFirst())
            if case .ident(let last)? = c.last, last.lowercased() == "then" { c.removeLast() }
            if try evalExpr(c, line: stmts[m].line).isTrue { pc = m + 1; return }
        }
        pc = endIdx + 1
    }

    private func sleep(_ sec: Double) throws {
        var left = sec
        while left > 0 && !cancelled {
            let d = min(left, 0.1)
            Thread.sleep(forTimeInterval: d)
            left -= d
        }
    }

    private func ttlFormat(_ fmt: String, _ vals: [TTLValue]) -> String {
        var out = ""
        var it = vals.makeIterator()
        var chars = Array(fmt)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            if c != "%" { out.append(c); continue }
            var spec = "%"
            while let d = chars.first, !"dixXsco%".contains(d) { spec.append(d); chars = chars.dropFirst() }
            guard let conv = chars.first else { break }
            chars = chars.dropFirst()
            switch conv {
            case "%": out += "%"
            case "s": out += String(format: spec + "@", (it.next()?.description ?? "") as NSString)
            case "c":
                if let v = it.next(), let u = UnicodeScalar(UInt32(truncatingIfNeeded: v.intValue)) { out.unicodeScalars.append(u) }
            default:
                out += String(format: spec + "l" + (conv == "i" ? "d" : String(conv)), it.next()?.intValue ?? 0)
            }
        }
        return out
    }

    private func strftimeToICU(_ f: String) -> String {
        var out = ""
        var it = Array(f)[...]
        while let c = it.first {
            it = it.dropFirst()
            if c != "%" {
                if c.isLetter { out += "'\(c)'" } else { out.append(c) }
                continue
            }
            guard let d = it.first else { break }
            it = it.dropFirst()
            switch d {
            case "Y": out += "yyyy"
            case "y": out += "yy"
            case "m": out += "MM"
            case "d": out += "dd"
            case "H": out += "HH"
            case "M": out += "mm"
            case "S": out += "ss"
            case "a": out += "EEE"
            case "b": out += "MMM"
            default: out.append(d)
            }
        }
        return out
    }
}
