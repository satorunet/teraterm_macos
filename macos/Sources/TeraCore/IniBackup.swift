import Foundation

/// TERATERM.INI のバックアップ (ttlib_static_cpp.cpp CreateBakupFile / MakeISO8601Str)。
/// 設定の保存で同じファイルに上書きするとき、IniAutoBackup=on (既定) なら
/// 同じフォルダに "<日時>_<ファイル名>" (日時は strftime "%Y%m%dT%H%M%S%z"、例 20211204T231234+0900_TERATERM.INI) を作る
public enum IniBackup {
    /// バックアップのファイル名 (prefix が nil なら現在日時 + "_")
    public static func backupPath(for path: String, prefix: String? = nil, date: Date = Date(),
                                  timeZone: TimeZone = .current) -> String {
        let pre = prefix ?? (iso8601(date, timeZone: timeZone) + "_")
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return (dir as NSString).appendingPathComponent(pre + name)
    }

    /// MakeISO8601Str: ローカル時刻の "%Y%m%dT%H%M%S%z"
    public static func iso8601(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd'T'HHmmssZ"   // Z = +0900 (strftime の %z と同じ)
        return f.string(from: date)
    }

    /// CreateBakupFile: ファイルがなければ何もしない。CopyFileW(..., TRUE) と同じく、同名のバックアップがあれば上書きしない
    @discardableResult
    public static func create(for path: String, prefix: String? = nil, date: Date = Date()) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let bak = backupPath(for: path, prefix: prefix, date: date)
        guard !fm.fileExists(atPath: bak) else { return nil }
        do { try fm.copyItem(atPath: path, toPath: bak) } catch { return nil }
        return bak
    }
}
