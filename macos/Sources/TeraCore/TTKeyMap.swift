import Foundation

// KEYBOARD.CNF のキーマップ (teraterm/keyboard.c, ttpset/ttset_keyboard.c, common/tttypes_key.h)
//
// Tera Term のキーコードは「PC (IBM PC/AT) のスキャンコード (拡張キーは +256)」に
// Shift = +512 (0x200), Ctrl = +1024 (0x400), Alt = +2048 (0x800) を足したもの (KEYCODE.TXT)。
// Mac のキーは TTKeyMap.pcScanCode(macKeyCode:) で同じ番号に直す (Option = Alt)。

/// Tera Term のキー番号 (tttypes_key.h の Id*)
public enum TTKeyID {
    public static let up = 1, down = 2, right = 3, left = 4
    public static let num0 = 5, num9 = 14
    public static let minus = 15, comma = 16, period = 17, slash = 18, asterisk = 19, plus = 20, enter = 21
    public static let pf1 = 22, pf2 = 23, pf3 = 24, pf4 = 25
    public static let find = 26, insert = 27, remove = 28, select = 29, prev = 30, next = 31
    public static let f6 = 32, f7 = 33, f8 = 34, f9 = 35, f10 = 36, f11 = 37, f12 = 38, f13 = 39, f14 = 40
    public static let help = 41, doKey = 42, f17 = 43, f18 = 44, f19 = 45, f20 = 46
    public static let xf1 = 47, xf2 = 48, xf3 = 49, xf4 = 50, xf5 = 51
    public static let udk6 = 52, udk20 = 66
    public static let hold = 67, print = 68, breakKey = 69, xBackTab = 70
    public static let cmdEditCopy = 71, cmdEditPaste = 72, cmdEditPasteCR = 73, cmdEditCLS = 74, cmdEditCLB = 75
    public static let cmdCtrlOpenTEK = 76, cmdCtrlCloseTEK = 77
    public static let cmdLineUp = 78, cmdLineDown = 79, cmdPageUp = 80, cmdPageDown = 81
    public static let cmdBuffTop = 82, cmdBuffBottom = 83
    public static let cmdNextWin = 84, cmdPrevWin = 85, cmdNextSWin = 86, cmdPrevSWin = 87
    public static let cmdLocalEcho = 88, cmdScrollLock = 89
    public static let user1 = 90
    public static let numOfUserKey = 99
    public static let keyMax = user1 + numOfUserKey - 1
}

public struct TTKeyMap {
    /// Map[id - 1] = キーコード (0xFFFF = 割り当てなし)
    public private(set) var map = [Int](repeating: 0xFFFF, count: TTKeyID.keyMax)
    public struct UserKey: Equatable {
        public var keyCode: Int
        public var type: Int      // 0: IdBinary 1: IdText 2: IdMacro 3: IdCommand
        public var string: String
        public var ttKeyCode: Int
    }
    public private(set) var userKeys: [UserKey] = []
    /// 読み込みの警告 ("Keycode %d is used more than once")
    public private(set) var warnings: [String] = []

    /// 何も割り当てない (KEYBOARD.CNF がないときの Tera Term と同じ)
    public init() {}

    /// _ReadKeyboardCnf
    public init(ini: IniFile) {
        for (sec, list) in TTKeyMap.lists {
            for (id, name) in list {
                guard let v = ini.string(sec, name) else { continue }
                map[id - 1] = TTKeyMap.parseCode(v)
            }
        }
        // ReadUserkeysSection
        for i in 0..<TTKeyID.numOfUserKey {
            let tt = TTKeyID.user1 + i
            guard let v = ini.string("User keys", "User\(i + 1)"), !v.isEmpty else { continue }
            if v.lowercased().hasPrefix("off") { map[tt - 1] = 0xFFFF; continue }
            let parts = v.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[2].isEmpty,
                  let code = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let type = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            userKeys.append(UserKey(keyCode: code, type: type, string: parts[2], ttKeyCode: tt))
            map[tt - 1] = code & 0xFFFF
        }
        // 重複チェック: 後に出たもの (j) と同じ番号の先のもの (i) を無効にする
        for j in 1..<map.count where map[j] != 0xFFFF {
            for i in 0..<j where map[i] == map[j] {
                warnings.append("Keycode \(map[j]) is used more than once")
                map[i] = 0xFFFF
            }
        }
    }

    public init?(path: String) {
        guard let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) else { return nil }
        self.init(ini: ini)
    }

    /// Tera Term に付いてくる KEYBOARD.CNF (installer/release/IBMKEYB.CNF)
    public static let ibmDefault = TTKeyMap(ini: IniFile(text: ibmKeybCnf))

    /// swscanf("%hd"): 空・off・数でなければ割り当てなし
    static func parseCode(_ v: String) -> Int {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.lowercased() == "off" { return 0xFFFF }
        var digits = ""
        for (i, c) in t.enumerated() {
            if c.isASCII && c.isNumber || (i == 0 && (c == "-" || c == "+")) { digits.append(c) } else { break }
        }
        guard let n = Int(digits) else { return 0xFFFF }
        return Int(UInt16(truncatingIfNeeded: Int16(truncatingIfNeeded: n)))
    }

    /// GetKeyCode: キーコード → Tera Term のキー番号 (なければ 0)
    public func keyID(forCode code: Int) -> Int {
        var k = TTKeyID.keyMax
        while k > 0 && map[k - 1] != code { k -= 1 }
        return k
    }

    public func code(for id: Int) -> Int? {
        guard id >= 1 && id <= map.count, map[id - 1] != 0xFFFF else { return nil }
        return map[id - 1]
    }

    /// キーを押したときにすること (GetKeyStr の結果)
    public enum Action: Equatable {
        /// そのまま送る (IdBinary)
        case binary(String)
        /// 改行コードを変換して送る (IdText)
        case text(String)
        /// マクロファイルを実行する (IdMacro)
        case macro(String)
        /// メニューコマンド (IdCommand, WM_COMMAND の ID)
        case command(Int)
        /// ショートカット (WM_USER_ACCELCOMMAND。Hold / Print / Break / IdCmd*)
        case accel(Int)
    }

    /// GetKeyStr。nil は何もしない (CodeLength = 0)
    public func action(for id: Int, appKeypad: Bool, appCursor: Bool, send8Bit: Bool = false) -> Action? {
        let csi = send8Bit ? "\u{9B}" : "\u{1B}["
        let ss3 = send8Bit ? "\u{8F}" : "\u{1B}O"
        switch id {
        case TTKeyID.up: return .binary((appCursor ? ss3 : csi) + "A")
        case TTKeyID.down: return .binary((appCursor ? ss3 : csi) + "B")
        case TTKeyID.right: return .binary((appCursor ? ss3 : csi) + "C")
        case TTKeyID.left: return .binary((appCursor ? ss3 : csi) + "D")
        case TTKeyID.num0...TTKeyID.num9:
            let n = id - TTKeyID.num0
            return .binary(appKeypad ? ss3 + String(UnicodeScalar(UInt8(0x70 + n))) : String(n))
        case TTKeyID.minus: return .binary(appKeypad ? ss3 + "m" : "-")
        case TTKeyID.comma: return .binary(appKeypad ? ss3 + "l" : ",")
        case TTKeyID.period: return .binary(appKeypad ? ss3 + "n" : ".")
        case TTKeyID.enter: return appKeypad ? .binary(ss3 + "M") : .text("\r")
        case TTKeyID.slash: return .binary(appKeypad ? ss3 + "o" : "/")
        case TTKeyID.asterisk: return .binary(appKeypad ? ss3 + "j" : "*")
        case TTKeyID.plus: return .binary(appKeypad ? ss3 + "k" : "+")
        case TTKeyID.pf1: return .binary(ss3 + "P")
        case TTKeyID.pf2: return .binary(ss3 + "Q")
        case TTKeyID.pf3: return .binary(ss3 + "R")
        case TTKeyID.pf4: return .binary(ss3 + "S")
        case TTKeyID.find: return .binary(csi + "1~")
        case TTKeyID.insert: return .binary(csi + "2~")
        case TTKeyID.remove: return .binary(csi + "3~")
        case TTKeyID.select: return .binary(csi + "4~")
        case TTKeyID.prev: return .binary(csi + "5~")
        case TTKeyID.next: return .binary(csi + "6~")
        case TTKeyID.f6...TTKeyID.f20:
            let nums = [17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34]
            return .binary(csi + "\(nums[id - TTKeyID.f6])~")
        case TTKeyID.xf1...TTKeyID.xf5: return .binary(csi + "\(11 + id - TTKeyID.xf1)~")
        case TTKeyID.xBackTab: return .binary(csi + "Z")
        case TTKeyID.hold, TTKeyID.print, TTKeyID.breakKey, TTKeyID.cmdEditCopy...TTKeyID.cmdScrollLock:
            return .accel(id)
        case TTKeyID.user1...TTKeyID.keyMax:
            guard let u = userKeys.first(where: { $0.ttKeyCode == id }) else { return nil }
            switch u.type {
            case 0: return .binary(TTKeyMap.hex2Str(u.string))
            case 1: return .text(TTKeyMap.hex2Str(u.string))
            case 2: return .macro(u.string)
            case 3:
                // swscanf("%hd")
                let c = TTKeyMap.parseCode(u.string)
                return c == 0xFFFF ? nil : .command(c)
            default: return nil
            }
        default:
            return nil   // UDK6-20 (DECUDK で決まる) など
        }
    }

    /// Hex2StrW: "$XX" を 16 進の文字に (DelimList・User keys の文字列)
    public static func hex2Str(_ s: String) -> String {
        let a = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func hexv(_ c: Unicode.Scalar?) -> UInt32 {
            guard let c = c else { return 0 }
            switch c {
            case "0"..."9": return c.value - 0x30
            case "A"..."F": return c.value - 0x37
            case "a"..."f": return c.value - 0x57
            default: return 0
            }
        }
        while i < a.count {
            var b = a[i]
            if b == "$" {
                i += 1
                let hi = hexv(i < a.count ? a[i] : nil)
                i += 1
                let lo = hexv(i < a.count ? a[i] : nil)
                b = UnicodeScalar(hi << 4 | lo)!
            }
            out.append(b)
            i += 1
        }
        return String(out)
    }

    // MARK: - Mac のキー → PC のスキャンコード

    /// Mac の仮想キーコード (kVK_*) → PC/AT のスキャンコード (拡張キーは +256)。
    /// 文字キーは位置で対応させる (Mac の JIS 配列と PC の 106 配列は同じ位置に同じキー)。
    /// テンキーは刻印で対応させる (Mac の clear = NumLock、= は PC の 106 にない 0x59)。
    /// F13〜F20 は刻印どおり (Windows の VK_F13〜VK_F20 のスキャンコード)。
    public static let macToScan: [UInt16: Int] = [
        // 文字キー (kVK_ANSI_*)
        0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45, 8: 46, 9: 47, 10: 86, 11: 48,
        12: 16, 13: 17, 14: 18, 15: 19, 16: 21, 17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7, 23: 6,
        24: 13, 25: 10, 26: 8, 27: 12, 28: 9, 29: 11, 30: 27, 31: 24, 32: 22, 33: 26, 34: 23, 35: 25,
        36: 28, 37: 38, 38: 36, 39: 40, 40: 37, 41: 39, 42: 43, 43: 51, 44: 53, 45: 49, 46: 50, 47: 52,
        48: 15, 49: 57, 50: 41, 51: 14, 53: 1,
        // JIS: ¥ と _ (ろ)
        93: 125, 94: 115,
        // テンキー
        65: 83, 67: 55, 69: 78, 71: 325, 75: 309, 76: 284, 78: 74, 81: 89,
        82: 82, 83: 79, 84: 80, 85: 81, 86: 75, 87: 76, 88: 77, 89: 71, 91: 72, 92: 73,
        // 編集キー (help = Insert の位置)
        114: 338, 115: 327, 116: 329, 117: 339, 119: 335, 121: 337,
        123: 331, 124: 333, 125: 336, 126: 328,
        // ファンクションキー
        122: 59, 120: 60, 99: 61, 118: 62, 96: 63, 97: 64, 98: 65, 100: 66, 101: 67, 109: 68, 103: 87, 111: 88,
        105: 100, 107: 101, 113: 102, 106: 103, 64: 104, 79: 105, 80: 106, 90: 107,
    ]

    /// Tera Term のキーコード (スキャンコード + 修飾キー)。対応しないキーは nil
    public static func keyCode(macKeyCode: UInt16, shift: Bool, control: Bool, alt: Bool) -> Int? {
        guard var s = macToScan[macKeyCode] else { return nil }
        if shift { s |= 0x200 }
        if control { s |= 0x400 }
        if alt { s |= 0x800 }
        return s
    }

    // MARK: - 区分

    static let lists: [(String, [(Int, String)])] = [
        ("VT editor keypad", [(1, "Up"), (2, "Down"), (3, "Right"), (4, "Left"), (26, "Find"), (27, "Insert"),
                              (28, "Remove"), (29, "Select"), (30, "Prev"), (31, "Next")]),
        ("VT numeric keypad", [(5, "Num0"), (6, "Num1"), (7, "Num2"), (8, "Num3"), (9, "Num4"), (10, "Num5"),
                               (11, "Num6"), (12, "Num7"), (13, "Num8"), (14, "Num9"), (15, "NumMinus"),
                               (16, "NumComma"), (17, "NumPeriod"), (21, "NumEnter"), (18, "NumSlash"),
                               (19, "NumAsterisk"), (20, "NumPlus"), (22, "PF1"), (23, "PF2"), (24, "PF3"), (25, "PF4")]),
        ("VT function keys", [(67, "Hold"), (68, "Print"), (69, "Break"), (32, "F6"), (33, "F7"), (34, "F8"),
                              (35, "F9"), (36, "F10"), (37, "F11"), (38, "F12"), (39, "F13"), (40, "F14"),
                              (41, "Help"), (42, "Do"), (43, "F17"), (44, "F18"), (45, "F19"), (46, "F20")]
            + (6...20).map { (TTKeyID.udk6 + $0 - 6, "UDK\($0)") }),
        ("X function keys", [(47, "XF1"), (48, "XF2"), (49, "XF3"), (50, "XF4"), (51, "XF5"), (70, "XBackTab")]),
        ("Shortcut keys", [(71, "EditCopy"), (72, "EditPaste"), (73, "EditPasteCR"), (74, "EditCLS"), (75, "EditCLB"),
                           (76, "ControlOpenTEK"), (77, "ControlCloseTEK"), (78, "LineUp"), (79, "LineDown"),
                           (80, "PageUp"), (81, "PageDown"), (82, "BuffTop"), (83, "BuffBottom"),
                           (84, "NextWin"), (85, "PrevWin"), (86, "NextShownWin"), (87, "PrevShownWin"),
                           (88, "LocalEcho"), (89, "ScrollLock")]),
    ]

    /// installer/release/IBMKEYB.CNF (Tera Term ではこれが KEYBOARD.CNF として入る)
    static let ibmKeybCnf = """
    [VT editor keypad]
    Up=328
    Down=336
    Right=333
    Left=331
    Insert=338
    Find=327
    Prev=329
    Remove=339
    Select=335
    Next=337
    [VT numeric keypad]
    Num0=82
    Num1=79
    Num2=80
    Num3=81
    Num4=75
    Num5=76
    Num6=77
    Num7=71
    Num8=72
    Num9=73
    NumComma=1102
    NumPlus=78
    NumPeriod=83
    NumEnter=284
    NumSlash=309
    NumAsterisk=55
    NumMinus=74
    PF1=59
    PF2=60
    PF3=61
    PF4=62
    [VT function keys]
    Hold=off
    Print=off
    Break=off
    F6=64
    F7=65
    F8=66
    F9=67
    F10=68
    F11=87
    F12=88
    F13=573
    F14=574
    Help=575
    Do=576
    F17=577
    F18=578
    F19=579
    F20=580
    UDK6=1088
    UDK7=1089
    UDK8=1090
    UDK9=1091
    UDK10=1092
    UDK11=1111
    UDK12=1112
    UDK13=1597
    UDK14=1598
    UDK15=1599
    UDK16=1600
    UDK17=1601
    UDK18=1602
    UDK19=1603
    UDK20=1604
    [X function keys]
    XF1=off
    XF2=off
    XF3=off
    XF4=off
    XF5=63
    XBackTab=527
    [Shortcut keys]
    EditCopy=1362
    EditPaste=850
    EditPasteCR=off
    EditCLS=off
    EditCLB=off
    ControlOpenTEK=off
    ControlCloseTEK=off
    LineUp=1352
    LineDown=1360
    PageUp=1353
    PageDown=1361
    BuffTop=1351
    BuffBottom=1359
    NextWin=1039
    NextShownWin=off
    PrevWin=1551
    PrevShownWin=off
    LocalEcho=off
    ScrollLock=70
    """
}

// MARK: - URL の検出 (buffer.c mark_url_w / isURLchar)

public enum TTURL {
    /// mark_url_w の schemes
    public static let schemes = ["https://", "http://", "sftp://", "tftp://", "news://", "ftp://", "mms://"]

    /// isURLchar (RFC3986, sakura editor の表)
    public static func isURLChar(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        guard v > 0x20 && v < 0x7F else { return false }
        return !"\"'()*<>[]^`{|}".unicodeScalars.contains(u)   // 表で 0 の文字
    }

    /// 文字の並び (折り返しでつながった行を 1 つにしたもの) の中で URL になる位置。
    /// scheme で始まり、URL の文字が続くところまで
    public static func urlRanges(_ s: [Unicode.Scalar]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        let n = s.count
        while i < n {
            var matched = 0
            if s[i] == "h" || s[i] == "s" || s[i] == "t" || s[i] == "n" || s[i] == "f" || s[i] == "m" {
                for sc in schemes {
                    let u = Array(sc.unicodeScalars)
                    if i + u.count <= n && Array(s[i..<(i + u.count)]) == u { matched = u.count; break }
                }
            }
            if matched > 0 {
                var e = i + matched
                while e < n && isURLChar(s[e]) { e += 1 }
                out.append(i..<e)
                i = e
            } else {
                i += 1
            }
        }
        return out
    }
}
