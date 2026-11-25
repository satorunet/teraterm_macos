import Foundation

/// Windows の .ini ファイル (TERATERM.INI など) を読む
/// セクション名・キー名は大文字小文字を区別しない (GetPrivateProfileString と同じ)
public struct IniFile {
    /// [セクション(小文字)] → [(キー, 値)] 出てきた順
    private var sections: [String: [(String, String)]] = [:]
    /// セクション名 (元の大文字小文字のまま、出てきた順)
    public private(set) var sectionNames: [String] = []

    public init(text: String) {
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), let end = line.lastIndex(of: "]") {
                let name = String(line[line.index(after: line.startIndex)..<end])
                current = name.lowercased()
                if !sectionNames.contains(where: { $0.lowercased() == current }) { sectionNames.append(name) }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            sections[current, default: []].append((k, IniFile.dequote(v)))
        }
    }

    /// バイト列から読む。UTF-16 (BOM 付き) / UTF-8 / Shift_JIS を自動判別
    public init?(data: Data) {
        let b = [UInt8](data.prefix(3))
        var text: String?
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE { text = String(data: data, encoding: .utf16LittleEndian) }
        else if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { text = String(data: data, encoding: .utf16BigEndian) }
        else if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { text = String(data: data.dropFirst(3), encoding: .utf8) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) }
        guard var t = text else { return nil }
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        self.init(text: t)
    }

    /// GetPrivateProfileString と同じく、前後の空白を除いたあと "..." か '...' で囲まれていれば 1 組だけ外す (#1557)
    public static func dequote(_ v: String) -> String {
        guard v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f else { return v }
        return String(v.dropFirst().dropLast())
    }

    /// 書くときの値: 読み直して同じになるように、前後に空白があるか引用符で囲まれた形なら "..." で囲む
    public static func quoteIfNeeded(_ v: String) -> String {
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        if trimmed != v || dequote(v) != v { return "\"" + v + "\"" }
        return v
    }

    public func string(_ section: String, _ key: String) -> String? {
        guard let s = sections[section.lowercased()] else { return nil }
        // 同じキーが複数あれば、Windows と同じく最初のもの
        return s.first(where: { $0.0.caseInsensitiveCompare(key) == .orderedSame })?.1
    }

    public func int(_ section: String, _ key: String) -> Int? {
        guard let v = string(section, key) else { return nil }
        return Int(v.trimmingCharacters(in: .whitespaces))
    }

    /// on/off の値 (Tera Term の GetOnOff と同じ: "on" のみ真)
    public func onOff(_ section: String, _ key: String) -> Bool? {
        guard let v = string(section, key)?.lowercased(), !v.isEmpty else { return nil }
        return v == "on" || v == "1" || v == "yes" || v == "true"
    }

    /// "1,2,3" のような数値の並び
    public func ints(_ section: String, _ key: String) -> [Int]? {
        guard let v = string(section, key), !v.isEmpty else { return nil }
        let n = v.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return n.isEmpty ? nil : n
    }

    public func keys(_ section: String) -> [(String, String)] { sections[section.lowercased()] ?? [] }
    public func hasSection(_ section: String) -> Bool { sections[section.lowercased()] != nil }
}
