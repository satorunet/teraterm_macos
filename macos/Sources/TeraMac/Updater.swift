import AppKit
import Sparkle

/// 自動アップデート (Sparkle)。新しい版は GitHub の appcast.xml で知らせる。
/// 「アップデートを自動で確認」は初期設定 ON (Info.plist の SUEnableAutomaticChecks)。メニューで OFF にできる
///
/// 確認用: TERAMAC_FEED_URL=<appcast の URL (file:// も可)> で見に行く先を変える。
/// TERAMAC_UPDATE_TEST=<ログ> を付けると、画面を出さずに確認→ダウンロード→入れ替えまで行い、経過をログに書く
final class AppUpdater: NSObject, NSMenuItemValidation, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?
    private let env = ProcessInfo.processInfo.environment

    /// アプリとして起動したときだけ動かす (swift run や自動テストでは動かさない)
    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              env["TERAMAC_SNAPSHOT"] == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        if env["TERAMAC_UPDATE_TEST"] != nil, let u = controller?.updater {
            log("start version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") feed=\(u.feedURL?.absoluteString ?? "-")")
            u.automaticallyDownloadsUpdates = true
            u.checkForUpdatesInBackground()
        }
    }

    var isAvailable: Bool { controller != nil }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let c = controller else {
            let a = NSAlert()
            a.messageText = "この版ではアップデートを確認できません"
            a.informativeText = "配布用のアプリ (Releases の DMG から入れたもの) で使えます。"
            a.runModal()
            return
        }
        c.checkForUpdates(sender)
    }

    @objc func toggleAutomaticChecks(_ sender: Any?) {
        guard let u = controller?.updater else { return }
        u.automaticallyChecksForUpdates.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleAutomaticChecks(_:)):
            item.state = (controller?.updater.automaticallyChecksForUpdates ?? false) ? .on : .off
            return controller != nil
        case #selector(checkForUpdates(_:)):
            return controller?.updater.canCheckForUpdates ?? true
        default:
            return true
        }
    }

    /// アプリのメニューに入れる項目
    func menuItems() -> [NSMenuItem] {
        let check = NSMenuItem(title: "アップデートを確認…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        check.target = self
        let auto = NSMenuItem(title: "アップデートを自動で確認", action: #selector(toggleAutomaticChecks(_:)), keyEquivalent: "")
        auto.target = self
        return [check, auto]
    }

    // MARK: - SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? { env["TERAMAC_FEED_URL"] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("found \(item.displayVersionString) url=\(item.fileURL?.absoluteString ?? "-")")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { log("no update") }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { log("error \(error.localizedDescription)") }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) { log("downloaded \(item.displayVersionString)") }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { log("installing \(item.displayVersionString)") }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        log("ready to install \(item.displayVersionString)")
        // 確認用のときはすぐ入れ替えて起動し直す
        if env["TERAMAC_UPDATE_TEST"] != nil { immediateInstallationBlock(); return true }
        return false
    }

    private func log(_ s: String) {
        guard let path = env["TERAMAC_UPDATE_TEST"] else { return }
        let line = "\(Date()) \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
