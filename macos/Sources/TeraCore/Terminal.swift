import Foundation

public enum TColor: Equatable {
    case def
    case idx(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellAttr: Equatable {
    public var fg: TColor = .def
    public var bg: TColor = .def
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var blink = false
    public var reverse = false
    public var invisible = false
    public var strike = false
    public init() {}
}

public struct Cell: Equatable {
    public var ch: Character = " "
    public var attr = CellAttr()
    /// 1 = 半角, 2 = 全角の左半分, 0 = 全角の右半分
    public var width: UInt8 = 1
    public init() {}
    public init(ch: Character, attr: CellAttr, width: UInt8) {
        self.ch = ch; self.attr = attr; self.width = width
    }
}

public struct Line {
    public var cells: [Cell]
    /// 右端で自動折り返しして次の行に続いている
    public var wrapped = false
    public init(cols: Int, attr: CellAttr = CellAttr()) {
        var c = Cell(); c.attr.bg = attr.bg
        cells = Array(repeating: c, count: cols)
    }
    public var text: String {
        var s = ""
        for c in cells where c.width != 0 { s.append(c.ch) }
        return s
    }
}

public enum CursorStyle { case block, underline, bar }

/// VT100 / xterm 互換の端末画面
public final class Terminal {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var lines: [Line]
    private var savedMainLines: [Line]?
    public private(set) var scrollback: [Line] = []
    public var scrollbackLimit = 10000
    /// 画面から押し出された行の通算数 (選択範囲の位置合わせに使う)
    public private(set) var scrolledOutTotal = 0

    public private(set) var cx = 0
    public private(set) var cy = 0
    private var wrapPending = false
    public private(set) var attr = CellAttr()
    private var scrollTop = 0
    private var scrollBottom: Int
    private var tabs: [Bool] = []

    public private(set) var usingAlt = false
    public private(set) var appCursor = false
    public private(set) var appKeypad = false
    public private(set) var bracketedPaste = false
    public private(set) var cursorVisible = true
    public private(set) var reverseScreen = false
    public private(set) var cursorStyle: CursorStyle = .block
    /// 既定のカーソル形 (Tera Term の CursorShape)。リセットするとこれに戻る
    public var defaultCursorStyle: CursorStyle = .block { didSet { cursorStyle = defaultCursorStyle } }
    public private(set) var mouseMode = 0     // 0 / 1000 / 1002 / 1003
    public private(set) var mouseSGR = false
    private var autowrap = true
    private var insertMode = false
    private var originMode = false
    private var lnm = false

    /// 受信した CR を CR+LF として扱う (Tera Term の「改行コード 受信: CR+LF」)
    public var recvCRasCRLF = false
    /// 受信した LF を CR+LF として扱う
    public var recvLFasCRLF = false
    public var ambiguousWide = false
    public var answerback = "xterm"

    public var onResponse: ((String) -> Void)?
    public var onTitle: ((String) -> Void)?
    public var onBell: (() -> Void)?

    private enum Charset { case ascii, dec, uk }
    private var g: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    private var gl = 0
    private var singleShift: Int?

    private struct Saved {
        var cx = 0, cy = 0, attr = CellAttr(), g: [Charset] = [.ascii, .ascii, .ascii, .ascii], gl = 0
        var originMode = false, autowrap = true, wrapPending = false
    }
    private var saved = Saved()
    private var savedAlt = Saved()

    private enum State { case ground, esc, escInter, csi, osc, oscEsc, str, strEsc, charset(Int) }
    private var state: State = .ground
    private var params: [Int] = []
    private var curParam: Int?
    private var priv: Character?
    private var inter = ""
    private var escInter: Character = " "
    private var oscBuf = ""
    private var lastChar: Unicode.Scalar?
    private var lastWasCR = false

    /// 画面が変わったら true (描画側で false に戻す)
    public var dirty = true

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(2, cols)
        self.rows = max(1, rows)
        lines = (0..<self.rows).map { _ in Line(cols: max(2, cols)) }
        scrollBottom = self.rows - 1
        resetTabs()
    }

    // MARK: - 外から見る

    public var totalLines: Int { scrollback.count + rows }

    /// 0 = スクロールバックの一番古い行
    public func line(at index: Int) -> Line {
        if index < scrollback.count { return scrollback[index] }
        return lines[index - scrollback.count]
    }

    public var screenText: String {
        lines.map { $0.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    public func clearScrollback() {
        scrollback.removeAll()
        dirty = true
    }

    /// Tera Term の「画面クリア」
    public func clearScreen() {
        for y in 0..<rows { lines[y] = Line(cols: cols) }
        cx = 0; cy = 0; wrapPending = false
        dirty = true
    }

    // MARK: - サイズ変更

    public func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(2, newCols), nr = max(1, newRows)
        if nc == cols && nr == rows { return }
        func fit(_ l: inout Line) {
            if l.cells.count > nc {
                l.cells.removeLast(l.cells.count - nc)
                if l.cells[nc - 1].width == 2 { l.cells[nc - 1] = Cell() }
            } else if l.cells.count < nc {
                l.cells.append(contentsOf: Array(repeating: Cell(), count: nc - l.cells.count))
            }
        }
        for i in lines.indices { fit(&lines[i]) }
        if var m = savedMainLines {
            for i in m.indices { fit(&m[i]) }
            savedMainLines = m
        }
        if nr < rows {
            // カーソルより下の空行から消し、足りなければ上の行をスクロールバックへ
            var excess = rows - nr
            while excess > 0 && lines.count - 1 > cy && lines.last!.text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast(); excess -= 1
            }
            while excess > 0 {
                let l = lines.removeFirst()
                if !usingAlt { pushScrollback(l) }
                cy -= 1; excess -= 1
            }
            if lines.count > nr { lines.removeLast(lines.count - nr) }
            if var m = savedMainLines {
                while m.count > nr { m.removeFirst() }
                savedMainLines = m
            }
        } else if nr > rows {
            var add = nr - rows
            while add > 0 && !usingAlt && !scrollback.isEmpty {
                var l = scrollback.removeLast()
                fit(&l)
                lines.insert(l, at: 0)
                cy += 1; add -= 1
            }
            while add > 0 { lines.append(Line(cols: nc)); add -= 1 }
            if var m = savedMainLines {
                while m.count < nr { m.append(Line(cols: nc)) }
                savedMainLines = m
            }
        }
        cols = nc; rows = nr
        cy = max(0, min(cy, rows - 1))
        cx = max(0, min(cx, cols - 1))
        wrapPending = false
        scrollTop = 0; scrollBottom = rows - 1
        resetTabs()
        dirty = true
    }

    private func resetTabs() {
        tabs = (0..<cols).map { $0 % 8 == 0 && $0 != 0 }
    }

    // MARK: - 入力

    public func feed(_ s: String) {
        for sc in s.unicodeScalars { process(sc) }
        dirty = true
    }

    private func process(_ sc: Unicode.Scalar) {
        let v = sc.value
        switch state {
        case .ground:
            if v < 0x20 || v == 0x7F { control(v) } else { put(sc) }

        case .esc:
            if v < 0x20 { control(v); return }
            escape(sc)

        case .escInter:
            if v < 0x20 { control(v); return }
            if escInter == "#" && sc == "8" { decAlign() }
            if escInter == "%" { /* 文字コード指定は無視 */ }
            state = .ground

        case .charset(let which):
            let cs: Charset
            switch sc {
            case "0": cs = .dec
            case "A": cs = .uk
            default: cs = .ascii
            }
            g[which] = cs
            state = .ground

        case .csi:
            if v == 0x1B { state = .esc; return }
            if v == 0x18 || v == 0x1A { state = .ground; return }
            if v < 0x20 { control(v); return }
            switch v {
            case 0x30...0x39:
                curParam = (curParam ?? 0) &* 10 &+ Int(v - 0x30)
                if curParam! > 99999 { curParam = 99999 }
            case 0x3B, 0x3A:
                params.append(curParam ?? -1); curParam = nil
            case 0x3C...0x3F:
                priv = Character(sc)
            case 0x20...0x2F:
                inter.append(Character(sc))
            case 0x40...0x7E:
                if let p = curParam { params.append(p) } else if !params.isEmpty { params.append(-1) }
                csiDispatch(Character(sc))
                state = .ground
            default:
                state = .ground
            }

        case .osc:
            if v == 0x07 { oscDispatch(); state = .ground; return }
            if v == 0x1B { state = .oscEsc; return }
            if v == 0x18 || v == 0x1A { state = .ground; return }
            if oscBuf.count < 4096 { oscBuf.unicodeScalars.append(sc) }

        case .oscEsc:
            if sc == "\\" { oscDispatch(); state = .ground } else { state = .ground; process(sc) }

        case .str:
            if v == 0x1B { state = .strEsc } else if v == 0x07 || v == 0x18 || v == 0x1A { state = .ground }

        case .strEsc:
            state = sc == "\\" ? .ground : .str
        }
    }

    private func control(_ v: UInt32) {
        let wasCR = lastWasCR
        lastWasCR = false
        switch v {
        case 0x07: onBell?()
        case 0x08:
            if wrapPending { wrapPending = false } else if cx > 0 { cx -= 1 }
        case 0x09:
            var x = cx + 1
            while x < cols - 1 && !tabs[x] { x += 1 }
            cx = min(x, cols - 1); wrapPending = false
        case 0x0A, 0x0B, 0x0C:
            if recvCRasCRLF && wasCR && v == 0x0A { return }
            lineFeed()
            if lnm || recvLFasCRLF { cx = 0 }
        case 0x0D:
            cx = 0; wrapPending = false
            if recvCRasCRLF { lineFeed(); lastWasCR = true }
        case 0x0E: gl = 1
        case 0x0F: gl = 0
        case 0x18, 0x1A: state = .ground
        case 0x1B:
            state = .esc
            params = []; curParam = nil; priv = nil; inter = ""
        default: break
        }
    }

    private func escape(_ sc: Unicode.Scalar) {
        state = .ground
        switch sc {
        case "[":
            state = .csi; params = []; curParam = nil; priv = nil; inter = ""
        case "]":
            state = .osc; oscBuf = ""
        case "P", "_", "^", "X":
            state = .str
        case "(": state = .charset(0)
        case ")": state = .charset(1)
        case "*": state = .charset(2)
        case "+": state = .charset(3)
        case "#", "%", " ":
            escInter = Character(sc); state = .escInter
        case "7": saveCursor()
        case "8": restoreCursor()
        case "D": lineFeed()
        case "E": cx = 0; lineFeed()
        case "M": reverseIndex()
        case "H": if cx < cols { tabs[cx] = true }
        case "c": fullReset()
        case "=": appKeypad = true
        case ">": appKeypad = false
        case "N": singleShift = 2
        case "O": singleShift = 3
        case "n": gl = 2
        case "o": gl = 3
        default: break
        }
    }

    // MARK: - 文字を置く

    private static let decGraphics: [UInt32: Unicode.Scalar] = [
        0x5F: " ", 0x60: "◆", 0x61: "▒", 0x62: "␉", 0x63: "␌", 0x64: "␍", 0x65: "␊", 0x66: "°", 0x67: "±",
        0x68: "␤", 0x69: "␋", 0x6A: "┘", 0x6B: "┐", 0x6C: "┌", 0x6D: "└", 0x6E: "┼", 0x6F: "⎺",
        0x70: "⎻", 0x71: "─", 0x72: "⎼", 0x73: "⎽", 0x74: "├", 0x75: "┤", 0x76: "┴", 0x77: "┬",
        0x78: "│", 0x79: "≤", 0x7A: "≥", 0x7B: "π", 0x7C: "≠", 0x7D: "£", 0x7E: "·",
    ]

    private func blankCell() -> Cell {
        var c = Cell(); c.attr.bg = attr.bg; return c
    }

    private func put(_ input: Unicode.Scalar) {
        var sc = input
        let cs = g[singleShift ?? gl]
        singleShift = nil
        if cs == .dec, let m = Terminal.decGraphics[sc.value] { sc = m }
        if cs == .uk && sc == "#" { sc = "£" }

        let w = termCharWidth(sc, ambiguousWide: ambiguousWide)
        if w == 0 {
            // 直前の文字にくっつける
            var x = wrapPending ? cx : cx - 1
            if x >= 0 && x < cols {
                if lines[cy].cells[x].width == 0 && x > 0 { x -= 1 }
                var s = String(lines[cy].cells[x].ch)
                s.unicodeScalars.append(sc)
                if s.count == 1 { lines[cy].cells[x].ch = Character(s) }
            }
            return
        }
        if wrapPending {
            if autowrap {
                lines[cy].wrapped = true
                cx = 0
                lineFeed()
            }
            wrapPending = false
        }
        if w == 2 && cx >= cols - 1 {
            if autowrap {
                lines[cy].cells[cx] = blankCell()
                lines[cy].wrapped = true
                cx = 0
                lineFeed()
            } else {
                cx = cols - 2
            }
        }
        if insertMode { insertChars(w) }
        clearWide(cy, cx)
        if w == 2 { clearWide(cy, cx + 1) }
        lines[cy].cells[cx] = Cell(ch: Character(sc), attr: attr, width: UInt8(w))
        if w == 2 { lines[cy].cells[cx + 1] = Cell(ch: " ", attr: attr, width: 0) }
        lastChar = sc
        cx += w
        if cx >= cols {
            cx = cols - 1
            wrapPending = true
        }
    }

    /// 全角文字の片側だけ上書きされるとき、もう片側を消す
    private func clearWide(_ y: Int, _ x: Int) {
        guard x >= 0 && x < cols else { return }
        let c = lines[y].cells[x]
        if c.width == 0 && x > 0 { lines[y].cells[x - 1] = blankCell() }
        if c.width == 2 && x + 1 < cols { lines[y].cells[x + 1] = blankCell() }
    }

    private func pushScrollback(_ l: Line) {
        scrollback.append(l)
        scrolledOutTotal += 1
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
    }

    private func lineFeed() {
        wrapPending = false
        if cy == scrollBottom {
            scrollUp(1)
        } else if cy < rows - 1 {
            cy += 1
        }
    }

    private func reverseIndex() {
        wrapPending = false
        if cy == scrollTop {
            scrollDown(1)
        } else if cy > 0 {
            cy -= 1
        }
    }

    private func scrollUp(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            let l = lines.remove(at: scrollTop)
            if scrollTop == 0 && !usingAlt { pushScrollback(l) }
            lines.insert(Line(cols: cols, attr: attr), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            lines.remove(at: scrollBottom)
            lines.insert(Line(cols: cols, attr: attr), at: scrollTop)
        }
    }

    private func insertChars(_ n: Int) {
        let n = min(n, cols - cx)
        clearWide(cy, cx)
        var cells = lines[cy].cells
        cells.removeLast(n)
        cells.insert(contentsOf: Array(repeating: blankCell(), count: n), at: cx)
        if cells[cols - 1].width == 2 { cells[cols - 1] = blankCell() }
        lines[cy].cells = cells
    }

    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cx)
        clearWide(cy, cx)
        clearWide(cy, cx + n - 1)
        lines[cy].cells.removeSubrange(cx..<(cx + n))
        lines[cy].cells.append(contentsOf: Array(repeating: blankCell(), count: n))
        if lines[cy].cells[cx].width == 0 { lines[cy].cells[cx] = blankCell() }
    }

    private func erase(_ y: Int, _ from: Int, _ to: Int) {
        guard from < to else { return }
        clearWide(y, from)
        clearWide(y, to - 1)
        for x in from..<to { lines[y].cells[x] = blankCell() }
        if to == cols { lines[y].wrapped = false }
    }

    private func decAlign() {
        for y in 0..<rows {
            for x in 0..<cols { lines[y].cells[x] = Cell(ch: "E", attr: CellAttr(), width: 1) }
        }
        cx = 0; cy = 0
    }

    private func saveCursor() {
        let s = Saved(cx: cx, cy: cy, attr: attr, g: g, gl: gl, originMode: originMode, autowrap: autowrap, wrapPending: wrapPending)
        if usingAlt { savedAlt = s } else { saved = s }
    }

    private func restoreCursor() {
        let s = usingAlt ? savedAlt : saved
        cx = min(s.cx, cols - 1); cy = min(s.cy, rows - 1)
        attr = s.attr; g = s.g; gl = s.gl
        originMode = s.originMode; autowrap = s.autowrap; wrapPending = s.wrapPending
    }

    private func fullReset() {
        if usingAlt { leaveAlt() }
        attr = CellAttr()
        for y in 0..<rows { lines[y] = Line(cols: cols) }
        cx = 0; cy = 0; wrapPending = false
        scrollTop = 0; scrollBottom = rows - 1
        appCursor = false; appKeypad = false; bracketedPaste = false
        cursorVisible = true; reverseScreen = false; autowrap = true
        insertMode = false; originMode = false; lnm = false
        mouseMode = 0; mouseSGR = false; cursorStyle = defaultCursorStyle
        g = [.ascii, .ascii, .ascii, .ascii]; gl = 0
        saved = Saved(); savedAlt = Saved()
        resetTabs()
    }

    private func enterAlt() {
        guard !usingAlt else { return }
        savedMainLines = lines
        lines = (0..<rows).map { _ in Line(cols: cols) }
        usingAlt = true
    }

    private func leaveAlt() {
        guard usingAlt, let m = savedMainLines else { return }
        lines = m
        savedMainLines = nil
        usingAlt = false
    }

    // MARK: - CSI

    private func p(_ i: Int, _ def: Int) -> Int {
        guard i < params.count, params[i] > 0 else { return def }
        return params[i]
    }

    private func p0(_ i: Int) -> Int {
        guard i < params.count, params[i] >= 0 else { return 0 }
        return params[i]
    }

    private func moveTo(_ x: Int, _ y: Int) {
        let top = originMode ? scrollTop : 0
        let bottom = originMode ? scrollBottom : rows - 1
        cx = max(0, min(x, cols - 1))
        cy = max(top, min(y + top, bottom))
        wrapPending = false
    }

    private func csiDispatch(_ f: Character) {
        if priv == "?" { decPrivate(f); return }
        if priv == ">" {
            if f == "c" { onResponse?("\u{1B}[>0;10;1c") }
            return
        }
        if priv != nil { return }
        if inter == " " && f == "q" {
            switch p0(0) {
            case 0: cursorStyle = defaultCursorStyle
            case 1, 2: cursorStyle = .block
            case 3, 4: cursorStyle = .underline
            default: cursorStyle = .bar
            }
            return
        }
        if inter == "!" && f == "p" {
            // DECSTR (ソフトリセット)
            attr = CellAttr(); insertMode = false; originMode = false; autowrap = true
            cursorVisible = true; appCursor = false; appKeypad = false
            scrollTop = 0; scrollBottom = rows - 1
            return
        }
        if !inter.isEmpty { return }

        switch f {
        case "@": insertChars(p(0, 1))
        case "A":
            let top = cy >= scrollTop ? scrollTop : 0
            cy = max(top, cy - p(0, 1)); wrapPending = false
        case "B", "e":
            let bottom = cy <= scrollBottom ? scrollBottom : rows - 1
            cy = min(bottom, cy + p(0, 1)); wrapPending = false
        case "C", "a": cx = min(cols - 1, cx + p(0, 1)); wrapPending = false
        case "D": cx = max(0, cx - p(0, 1)); wrapPending = false
        case "E": cy = min(scrollBottom, cy + p(0, 1)); cx = 0; wrapPending = false
        case "F": cy = max(scrollTop, cy - p(0, 1)); cx = 0; wrapPending = false
        case "G", "`": cx = max(0, min(cols - 1, p(0, 1) - 1)); wrapPending = false
        case "H", "f": moveTo(p(1, 1) - 1, p(0, 1) - 1)
        case "I":
            for _ in 0..<p(0, 1) { control(0x09) }
        case "Z":
            for _ in 0..<p(0, 1) {
                var x = cx - 1
                while x > 0 && !tabs[x] { x -= 1 }
                cx = max(0, x)
            }
        case "J":
            switch p0(0) {
            case 0:
                erase(cy, cx, cols)
                for y in (cy + 1)..<max(cy + 1, rows) { erase(y, 0, cols) }
            case 1:
                for y in 0..<cy { erase(y, 0, cols) }
                erase(cy, 0, min(cx + 1, cols))
            case 2:
                for y in 0..<rows { erase(y, 0, cols) }
            case 3:
                scrollback.removeAll()
            default: break
            }
        case "K":
            switch p0(0) {
            case 0: erase(cy, cx, cols)
            case 1: erase(cy, 0, min(cx + 1, cols))
            case 2: erase(cy, 0, cols)
            default: break
            }
        case "L":
            if cy >= scrollTop && cy <= scrollBottom {
                let n = min(p(0, 1), scrollBottom - cy + 1)
                for _ in 0..<n {
                    lines.remove(at: scrollBottom)
                    lines.insert(Line(cols: cols, attr: attr), at: cy)
                }
                cx = 0; wrapPending = false
            }
        case "M":
            if cy >= scrollTop && cy <= scrollBottom {
                let n = min(p(0, 1), scrollBottom - cy + 1)
                for _ in 0..<n {
                    lines.remove(at: cy)
                    lines.insert(Line(cols: cols, attr: attr), at: scrollBottom)
                }
                cx = 0; wrapPending = false
            }
        case "P": deleteChars(p(0, 1))
        case "S": scrollUp(p(0, 1))
        case "T": scrollDown(p(0, 1))
        case "X":
            let n = min(p(0, 1), cols - cx)
            erase(cy, cx, cx + n)
        case "b":
            if let c = lastChar {
                for _ in 0..<min(p(0, 1), 65535) { put(c) }
            }
        case "c": onResponse?("\u{1B}[?1;2c")
        case "d": cy = max(0, min(rows - 1, p(0, 1) - 1 + (originMode ? scrollTop : 0))); wrapPending = false
        case "g":
            switch p0(0) {
            case 0: if cx < cols { tabs[cx] = false }
            case 3: tabs = Array(repeating: false, count: cols)
            default: break
            }
        case "h", "l":
            let on = f == "h"
            for m in params {
                if m == 4 { insertMode = on }
                if m == 20 { lnm = on }
            }
        case "m": sgr()
        case "n":
            switch p0(0) {
            case 5: onResponse?("\u{1B}[0n")
            case 6:
                let y = originMode ? cy - scrollTop : cy
                onResponse?("\u{1B}[\(y + 1);\(cx + 1)R")
            default: break
            }
        case "r":
            let top = p(0, 1) - 1
            let bottom = p(1, rows) - 1
            if top < bottom && bottom < rows {
                scrollTop = top; scrollBottom = bottom
                moveTo(0, 0)
            }
        case "s": saveCursor()
        case "u": restoreCursor()
        case "t":
            switch p0(0) {
            case 18: onResponse?("\u{1B}[8;\(rows);\(cols)t")
            default: break
            }
        default: break
        }
    }

    private func decPrivate(_ f: Character) {
        switch f {
        case "h", "l":
            let on = f == "h"
            for m in params {
                switch m {
                case 1: appCursor = on
                case 5: reverseScreen = on
                case 6: originMode = on; moveTo(0, 0)
                case 7: autowrap = on
                case 25: cursorVisible = on
                case 47, 1047:
                    if on { enterAlt() } else { leaveAlt() }
                case 1048:
                    if on { saveCursor() } else { restoreCursor() }
                case 1049:
                    if on {
                        saveCursor(); enterAlt()
                        for y in 0..<rows { lines[y] = Line(cols: cols) }
                    } else {
                        leaveAlt(); restoreCursor()
                    }
                case 1000, 1002, 1003: mouseMode = on ? m : 0
                case 1006: mouseSGR = on
                case 2004: bracketedPaste = on
                default: break
                }
            }
        case "n":
            if p0(0) == 6 {
                onResponse?("\u{1B}[?\(cy + 1);\(cx + 1)R")
            }
        default: break
        }
    }

    private func sgr() {
        if params.isEmpty { attr = CellAttr(); return }
        var i = 0
        while i < params.count {
            let v = params[i] < 0 ? 0 : params[i]
            switch v {
            case 0: attr = CellAttr()
            case 1: attr.bold = true
            case 2: attr.dim = true
            case 3: attr.italic = true
            case 4: attr.underline = true
            case 5, 6: attr.blink = true
            case 7: attr.reverse = true
            case 8: attr.invisible = true
            case 9: attr.strike = true
            case 21, 22: attr.bold = false; attr.dim = false
            case 23: attr.italic = false
            case 24: attr.underline = false
            case 25: attr.blink = false
            case 27: attr.reverse = false
            case 28: attr.invisible = false
            case 29: attr.strike = false
            case 30...37: attr.fg = .idx(UInt8(v - 30))
            case 39: attr.fg = .def
            case 40...47: attr.bg = .idx(UInt8(v - 40))
            case 49: attr.bg = .def
            case 90...97: attr.fg = .idx(UInt8(v - 90 + 8))
            case 100...107: attr.bg = .idx(UInt8(v - 100 + 8))
            case 38, 48:
                var color: TColor?
                if i + 1 < params.count {
                    if params[i + 1] == 5, i + 2 < params.count {
                        color = .idx(UInt8(max(0, min(255, params[i + 2]))))
                        i += 2
                    } else if params[i + 1] == 2 {
                        // 38;2;r;g;b と 38:2::r:g:b の両方を受ける
                        var j = i + 2
                        if params.count - j >= 4 && params[j] == -1 { j += 1 }
                        if j + 2 < params.count {
                            func c(_ k: Int) -> UInt8 { UInt8(max(0, min(255, params[k]))) }
                            color = .rgb(c(j), c(j + 1), c(j + 2))
                            i = j + 2
                        } else {
                            i = params.count
                        }
                    }
                }
                if let c = color {
                    if v == 38 { attr.fg = c } else { attr.bg = c }
                }
            default: break
            }
            i += 1
        }
    }

    private func oscDispatch() {
        guard let semi = oscBuf.firstIndex(of: ";") else { return }
        let code = oscBuf[..<semi]
        let body = String(oscBuf[oscBuf.index(after: semi)...])
        if code == "0" || code == "2" { onTitle?(body) }
    }
}
