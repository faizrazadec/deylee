import AppKit
import Foundation
import Sparkle

/// Self-update, through Sparkle.
///
/// Deylee is not distributed through the App Store, so nothing updates it unless the
/// app does. Sparkle is the framework every other Mac app outside the store uses for
/// this, and using it rather than writing one is not laziness: an updater downloads
/// code and replaces the running application with it, which is the single most
/// dangerous thing this app does. That code should be the code thousands of shipped
/// apps have already had audited.
///
/// **What makes an update trustworthy here.** Deylee is signed ad hoc — there is no
/// Developer ID yet — so Sparkle cannot fall back on "the new version was signed by
/// whoever signed the old one". Authenticity rests entirely on an EdDSA (ed25519)
/// signature over the downloaded archive: the private key lives in one login Keychain
/// on one Mac, the public half ships in `Info.plist` as `SUPublicEDKey`, and Sparkle
/// refuses any archive that key did not sign. That is the reverse of a secret baked
/// into a binary — nothing extractable from the app can forge an update, because the
/// app only ever holds the public half.
///
/// **The feed is set at assembly, not committed.** `scripts/make-app.sh` writes
/// `SUFeedURL` into a release bundle and deletes it from a development one, so a debug
/// build has no feed at all and honestly reports having none rather than checking a
/// production appcast from somebody's laptop.
@MainActor
final class UpdaterService: NSObject {
    /// Whether this bundle can update itself: it needs both a feed to ask and a key to
    /// judge the answer with. A build missing either is not broken — it is a
    /// development build, and it says so in Settings rather than pretending.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String)?.isEmpty == false
        let key = (info?["SUPublicEDKey"] as? String)?.isEmpty == false
        return feed && key
    }

    /// Reported to Settings on every state change.
    var onStatus: ((SettingsUpdateStatus) -> Void)?

    private var controller: SPUStandardUpdaterController?

    /// Start checking on a schedule, if this build is configured for it.
    ///
    /// `startingUpdater: true` arms Sparkle's own timer, which is the whole point of
    /// automatic updates; the user's preference is applied on top rather than by
    /// withholding the start, so toggling it later takes effect without a relaunch.
    func start(automaticallyChecks: Bool) {
        guard Self.isConfigured else {
            onStatus?(.unsupported(reason: SettingsModel.noFeedReason))
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        // Download but do not install unattended. Replacing a running app underneath
        // somebody mid-timer is not a decision this app gets to make for them.
        controller.updater.automaticallyDownloadsUpdates = false
        self.controller = controller
        onStatus?(.idle)
    }

    /// Follow the preference without a relaunch.
    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    /// The Settings button. Shows Sparkle's own UI, which is the one people recognise.
    func checkNow() {
        guard let controller else {
            onStatus?(.unsupported(reason: SettingsModel.noFeedReason))
            return
        }
        onStatus?(.checking)
        controller.checkForUpdates(nil)
    }
}

extension UpdaterService: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.onStatus?(.available(version: version)) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.onStatus?(.upToDate) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Sparkle reports "no update found" through this path too on some routes, and a
        // cancelled check is not a failure worth a red line in Settings.
        let code = (error as NSError).code
        guard code != Int(SUError.noUpdateError.rawValue),
              code != Int(SUError.installationCanceledError.rawValue)
        else { return }
        let detail = error.localizedDescription
        Task { @MainActor in self.onStatus?(.failed(detail: detail)) }
    }
}
