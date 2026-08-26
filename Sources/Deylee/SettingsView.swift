import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import DeyleeKit

// MARK: - Window state

/// The outcome of the last preference write, shown once in the header.
///
/// There is no Save button anywhere in this window, so this line is the only
/// confirmation a write ever gets — which is exactly why a *failed* write has to be
/// reported in the same place rather than silently reverting the control.
enum SettingsSaveStatus: Equatable {
    case idle
    case saved
    case failed
}

/// Where a user-invoked database backup has got to.
enum SettingsBackupState: Equatable {
    case idle
    case busy
    case done(path: String)
    case failed(message: String)
}

/// What Deylee knows about a newer version of itself.
///
/// A release build updates itself through Sparkle. ``SettingsUpdateStatus/unsupported(reason:)``
/// is no longer the permanent state of every shipped build — it is what a development
/// build reports, because `make-app.sh` gives only a release bundle an update feed.
enum SettingsUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloading(percent: Double)
    case downloaded(version: String)
    case manual(version: String)
    case unsupported(reason: String)
    /// The detail is diagnostic and stays in the tooltip; the line says only what the
    /// user needs to know.
    case failed(detail: String)
}

/// The Settings window's state.
///
/// Preferences are deliberately not part of ``AppModel``: ``PreferencesStore`` is
/// already the single source of truth for them and announces every successful write to
/// every surface. This model owns only what the window itself owns — the outcome of
/// the last write, the backup in flight, the update line — and mirrors the store, so a
/// control always renders the value that was actually stored rather than the value the
/// user asked for.
@MainActor
@Observable
final class SettingsModel {
    /// How long the "Saved" line stays up before fading out.
    static let savedVisibleMs = 1_800

    /// Shown when this bundle has no update feed, which is the case for a development
    /// build by design — `make-app.sh` writes `SUFeedURL` into a release bundle only.
    ///
    /// It used to say updates needed a signed build. That was inherited from Squirrel,
    /// which refuses an unsigned bundle outright. Sparkle does not: with no Developer
    /// ID it validates the archive's EdDSA signature instead, so an ad-hoc signed
    /// release updates itself perfectly well and the old sentence was simply wrong.
    static let noFeedReason =
        "This build has no update feed — check the Releases page."

    private static let releasesURLString = "https://github.com/faizrazadec/deylee-ios/releases"

    /// The last set the store returned. Defaults until ``load()`` has run, which is
    /// what ``loaded`` gates the whole body on.
    private(set) var prefs: Preferences = .defaults
    private(set) var loaded = false

    private(set) var saveStatus: SettingsSaveStatus = .idle
    private(set) var backup: SettingsBackupState = .idle
    /// `nil` until the folder has been resolved; the box reads "Locating…" until then.
    private(set) var dataFolderPath: String?

    private(set) var updateStatus: SettingsUpdateStatus
    /// `nil` until the version is known — the row then shows a bare "Version" rather
    /// than a guessed number, because the number is the whole point of the line.
    private(set) var currentVersion: String?
    /// False on a build with no update feed, where the scheduled check is never armed
    /// and the toggle would be a switch wired to nothing.
    let canAutoUpdate: Bool

    /// Set by whoever owns an update service. Left `nil` on a build that has none, in
    /// which case the only action the line ever offers is the Releases page.
    @ObservationIgnored var onCheckForUpdates: (() -> Void)?
    @ObservationIgnored var onDownloadUpdate: (() -> Void)?
    @ObservationIgnored var onInstallUpdate: (() -> Void)?

    // MARK: Screen capture
    //
    // The window shows what is actually stored rather than what the setting says,
    // because "capture is on" and "there are 412 images of my screen on this disk" are
    // different facts and only the second one is the reason somebody opens this screen.

    private(set) var captureCount = 0
    private(set) var captureBytes = 0
    /// macOS's answer, which is separate from the preference: a person can want capture
    /// on and still not have granted screen recording, and the screen has to say which.
    private(set) var capturePermission: CaptureService.Permission = .unknown

    /// Supplied by the app, which owns the store.
    @ObservationIgnored var readCaptureFootprint: (() -> (count: Int, bytes: Int))?
    @ObservationIgnored var onDeleteAllCaptures: (() -> Void)?
    /// Runs when capture is switched on, so permission is asked for and one image is
    /// taken while the person is still looking at the switch they just moved.
    @ObservationIgnored var onCaptureEnabled: (() -> Void)?
    /// Opens the window that shows the images themselves.
    @ObservationIgnored var onReviewCaptures: (() -> Void)?

    func refreshCaptureFootprint() {
        let footprint = readCaptureFootprint?() ?? (count: 0, bytes: 0)
        captureCount = footprint.count
        captureBytes = footprint.bytes
    }

    func applyCapturePermission(_ permission: CaptureService.Permission) {
        capturePermission = permission
    }

    func deleteAllCaptures() {
        onDeleteAllCaptures?()
        refreshCaptureFootprint()
    }

    /// "412 images · 61 MB", or the sentence that says there is nothing to worry about.
    var captureFootprintDescription: String {
        guard captureCount > 0 else { return "Nothing has been captured." }
        let size = ByteCountFormatter.string(fromByteCount: Int64(captureBytes), countStyle: .file)
        return "\(captureCount) image\(captureCount == 1 ? "" : "s") · \(size), stored encrypted on this Mac."
    }

    /// The window the save panel hangs off, so the sheet cannot be lost behind it.
    @ObservationIgnored weak var hostWindow: NSWindow?

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private var unsubscribe: PreferencesUnsubscribe?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    init(
        store: PreferencesStore,
        canAutoUpdate: Bool = false,
        currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String
    ) {
        self.store = store
        self.canAutoUpdate = canAutoUpdate
        self.currentVersion = currentVersion
        self.updateStatus =
            canAutoUpdate ? .idle : .unsupported(reason: SettingsModel.noFeedReason)
    }

    // MARK: Loading

    func load() {
        guard !loaded else { return }
        prefs = store.getAll()
        dataFolderPath = DataStore.folderURL.path(percentEncoded: false)
        // A write from anywhere else — the startup login-item reconciliation, another
        // surface — has to land here too, or the window would go on showing a value the
        // store no longer holds.
        unsubscribe = store.onChange { [weak self] next in
            Task { @MainActor [weak self] in
                self?.prefs = next
            }
        }
        loaded = true
    }

    func stopObserving() {
        unsubscribe?()
        unsubscribe = nil
        flashTask?.cancel()
    }

    // MARK: Writes

    /// Writes one preference and reports the outcome.
    ///
    /// A preference write is the one operation in the app allowed to fail loudly: every
    /// value it could quietly fall back to is a value this window would then report as
    /// saved. A refusal therefore flashes and re-adopts the stored set, which snaps the
    /// control back to what is really on disk.
    ///
    /// The key is picked inside `change` rather than passed in: SwiftUI declares a
    /// `PreferenceKey` protocol of its own and the `DeyleeKit` module name is shadowed by
    /// a type of the same name, so the preference-key enum cannot be *named* in a file
    /// that imports both — but it is still inferred from the store's own signature.
    func write(_ change: (PreferencesStore) throws -> Preferences) {
        do {
            prefs = try change(store)
            flash(.saved)
        } catch {
            report(error)
        }
    }

    /// A refused write leaves the store exactly as it was, so re-reading it is what
    /// snaps the control back to the value that is really on disk.
    private func report(_ error: Error) {
        NSLog("[deylee] \((error as? PreferenceWriteError)?.message ?? "\(error)")")
        prefs = store.getAll()
        flash(.failed)
    }

    /// Launch at login, applied to the system before it is persisted.
    ///
    /// The OS is the source of truth, so it is asked first: storing a preference the
    /// system then refused would leave a switch that is on and a login item that does
    /// not exist. A refusal is reported like any other failed write.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            report(error)
            return
        }
        write { try $0.write(.launchAtLogin, .bool(enabled)) }
    }

    /// One field on screen, two preferences underneath.
    ///
    /// They are written in sequence so the second write sees the first one's store, and
    /// an incomplete time never reaches here — a half-written reminder would fire at an
    /// hour the user never chose.
    func writeReminderTime(hour: Int, minute: Int) {
        guard hour != prefs.reminderHour || minute != prefs.reminderMinute else { return }
        write { store in
            _ = try store.write(.reminderHour, .number(Double(hour)))
            return try store.write(.reminderMinute, .number(Double(minute)))
        }
    }

    private func flash(_ status: SettingsSaveStatus) {
        saveStatus = status
        // Rapid edits restart the window rather than stacking timers, so the line stays
        // up for the whole burst instead of blinking once per keystroke.
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(SettingsModel.savedVisibleMs))
            guard !Task.isCancelled else { return }
            self?.saveStatus = .idle
        }
    }

    // MARK: Data

    /// Revealing is a fire-and-forget shell call: a failure shows up as "nothing
    /// opened", and the path is on screen right above the button either way.
    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([DataStore.databaseURL])
    }

    func backUpDatabase() {
        guard backup != .busy else { return }
        // Nothing to copy means the backup never starts, as opposed to starting and
        // failing to write — the two are different failures and read differently.
        guard DataStore.databaseExists else {
            backup = .failed(message: "The backup could not be started.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Back up Deylee data"
        panel.nameFieldStringValue = "deylee-backup-\(todayKey()).sqlite"
        if let sqlite = UTType(filenameExtension: "sqlite") {
            panel.allowedContentTypes = [sqlite]
        }
        panel.canCreateDirectories = true

        backup = .busy
        let complete: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                // Dismissing the save dialog is a normal outcome, not something to report.
                self.backup = .idle
                return
            }
            self.copyDatabase(to: destination)
        }

        if let hostWindow {
            panel.beginSheetModal(for: hostWindow) { response in
                MainActor.assumeIsolated { complete(response) }
            }
        } else {
            complete(panel.runModal())
        }
    }

    /// The copy runs off the main thread: it is an online backup of a file that can be
    /// hundreds of megabytes, and the window must keep drawing while it steps.
    private func copyDatabase(to destination: URL) {
        Task { [weak self] in
            // Read here, on the main actor, and carried into the copy. The key lives in
            // the vault, which is main-actor state, and reaching for it from a detached
            // task is both a data race and a second trip through the Keychain.
            let key: [UInt8]
            do {
                key = try StoreKey.loadOrCreate()
            } catch {
                let message = error.localizedDescription
                self?.backup = .failed(
                    message: message.isEmpty ? "The backup could not be written." : message
                )
                return
            }

            let result: SettingsBackupState = await Task.detached {
                do {
                    // The store is encrypted, so the key is needed to read it; the
                    // backup itself is plaintext, an export the owner can open
                    // anywhere.
                    try DataStore.backup(to: destination, key: key)
                    return .done(path: destination.path(percentEncoded: false))
                } catch {
                    let message = error.localizedDescription
                    return .failed(
                        message: message.isEmpty
                            ? "The backup could not be written." : message
                    )
                }
            }.value
            self?.backup = result
        }
    }

    // MARK: Updates

    func applyUpdateStatus(_ status: SettingsUpdateStatus) {
        updateStatus = status
    }

    func openReleases() {
        guard let url = URL(string: SettingsModel.releasesURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    func checkForUpdates() { onCheckForUpdates?() }
    func downloadUpdate() { onDownloadUpdate?() }
    func installUpdate() { onInstallUpdate?() }

    // MARK: Derived copy

    var versionLabel: String {
        guard let currentVersion else { return "Version" }
        return "Version \(currentVersion)"
    }

    /// Nothing ever checks on a build with no feed, so the notification this line used
    /// to promise was never coming; the Releases page is the only place a new version
    /// shows up.
    var versionDescription: String? {
        canAutoUpdate
            ? nil
            : "This build can’t install updates or check for them, so Deylee won’t tell you when a new version exists — look on the Releases page."
    }

    /// The section header makes the same claim as the toggle and has to fall the same
    /// way: promising a check two lines above the place it was just withdrawn would put
    /// the lie straight back.
    var updatesSectionDescription: String {
        canAutoUpdate
            ? "A signed version check against Deylee’s own update feed. No account, no telemetry, no payload."
            : "This build has no update feed, so Deylee never checks. New versions live on the project’s releases page."
    }

    var updateCheckDescription: String {
        canAutoUpdate
            ? "Deylee’s only network request. Nothing is downloaded without asking."
            : "This build has no update feed, so there is nothing to check on a schedule. Deylee makes no network request either way."
    }

    /// The reminder time as a `Date` on today's date, which is the only shape a
    /// `DatePicker` will take. Only the hour and the minute are ever read back out.
    var reminderTime: Date {
        Calendar.current.date(
            bySettingHour: prefs.reminderHour,
            minute: prefs.reminderMinute,
            second: 0,
            of: Date()
        ) ?? Date()
    }
}

// MARK: - Window

/// The Settings window: every control writes through on change, and the header line is
/// the only confirmation there is.
struct SettingsView: View {
    let model: SettingsModel
    /// Absent when this build has no API configured. Sync is optional, so the
    /// section is simply not shown rather than shown in a disabled state.
    var sync: SyncCoordinator?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            if model.loaded {
                sections
            } else {
                loading
            }
        }
        .background(Palette.surface)
        .task { model.load() }
    }

    private var header: some View {
        HStack(spacing: Space.xl) {
            Text("Settings")
                .font(Type.body.weight(.semibold))
                .foregroundStyle(Palette.fg)
            Spacer(minLength: Space.m)
            SettingsSavedNote(status: model.saveStatus)
        }
        .padding(.horizontal, Space.x5l)
        .padding(.vertical, Space.xl)
    }

    private var loading: some View {
        Text("Loading your preferences…")
            .font(Type.small)
            .foregroundStyle(Palette.fgFaint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Space.x5l)
    }

    // The window never grows to fit its content: the content scrolls inside it.
    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x5l) {
                // First, because signing in is the one thing here that changes what
                // every other section means. Absent entirely when this build has no
                // API configured — sync is optional, not merely disabled.
                if let sync {
                    AccountSection(
                        auth: sync.auth,
                        sync: sync.sync,
                        presentSignIn: { sync.presentSignIn?() }
                    )
                }
                general
                tracking
                reminders
                data
                screenCapture
                updates
            }
            .padding(Space.x4l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: General

    private var general: some View {
        SettingsSectionCard(
            title: "General",
            description: "How Deylee starts up and how it looks."
        ) {
            SettingsToggleRow(
                label: "Launch at login",
                description: "Starts Deylee in the background when you sign in.",
                isOn: model.prefs.launchAtLogin
            ) { next in
                model.setLaunchAtLogin(next)
            }

            SettingsHairline()

            SettingsToggleRow(
                label: "Show the mini window",
                description: "A small always-on-top clock. The menu bar already shows your running time, so this is optional.",
                isOn: model.prefs.showMiniWindow
            ) { next in
                model.write { try $0.write(.showMiniWindow, .bool(next)) }
            }

            SettingsHairline()

            SettingsRow(
                label: "Appearance",
                description: "System follows your desktop’s light or dark setting."
            ) {
                SettingsSegmentedControl(
                    accessibilityLabel: "Appearance",
                    selection: model.prefs.theme,
                    options: [
                        SettingsSegmentedOption(value: Theme.system, label: "System"),
                        SettingsSegmentedOption(value: Theme.light, label: "Light"),
                        SettingsSegmentedOption(value: Theme.dark, label: "Dark"),
                    ]
                ) { next in
                    model.write { try $0.write(.theme, .string(next.rawValue)) }
                }
            }

            SettingsHairline()

            SettingsRow(
                label: "Week starts on",
                description: "Used by the week totals in History."
            ) {
                SettingsSegmentedControl(
                    accessibilityLabel: "Week starts on",
                    selection: model.prefs.weekStartsOn,
                    options: [
                        SettingsSegmentedOption(value: WeekStart.sunday, label: "Sunday"),
                        SettingsSegmentedOption(value: WeekStart.monday, label: "Monday"),
                    ]
                ) { next in
                    model.write { try $0.write(.weekStartsOn, .number(Double(next.rawValue))) }
                }
            }
        }
    }

    // MARK: Tracking

    private var tracking: some View {
        SettingsSectionCard(
            title: "Tracking",
            description: "Your target, and when Deylee should question the time it is counting."
        ) {
            SettingsNumberFieldRow(
                label: "Daily target",
                description: "Drives the progress bar and the target-met markers in History.",
                value: model.prefs.dailyTargetHours,
                bounds: PreferenceLimits.dailyTargetMinHours...PreferenceLimits.dailyTargetMaxHours,
                // Half-hour targets are meaningful, and the value is clamped rather than
                // rounded, so 7.5 survives a trip through the field.
                step: 0.5,
                suffix: "hours"
            ) { next in
                model.write { try $0.write(.dailyTargetHours, .number(next)) }
            }

            SettingsHairline()

            SettingsToggleRow(
                label: "Detect when you step away",
                description: "While the timer runs, Deylee watches how long the machine has been untouched and asks whether to keep the time.",
                isOn: model.prefs.idleDetectionEnabled
            ) { next in
                model.write { try $0.write(.idleDetectionEnabled, .bool(next)) }
            }

            SettingsHairline()

            SettingsNumberFieldRow(
                label: "Ask after",
                description: model.prefs.idleDetectionEnabled
                    ? "How long the machine must sit untouched before Deylee asks."
                    : "Turn on “Detect when you step away” to change this.",
                value: Double(model.prefs.idleThresholdMinutes),
                bounds: Double(PreferenceLimits.idleThresholdMinMinutes)
                    ... Double(PreferenceLimits.idleThresholdMaxMinutes),
                suffix: "minutes",
                isEnabled: model.prefs.idleDetectionEnabled
            ) { next in
                model.write { try $0.write(.idleThresholdMinutes, .number(next)) }
            }

            SettingsHairline()

            SettingsToggleRow(
                label: "Pause when the computer sleeps",
                description: "The gap is held until you are back, then you choose whether it was a break.",
                isOn: model.prefs.autoPauseOnSleep
            ) { next in
                model.write { try $0.write(.autoPauseOnSleep, .bool(next)) }
            }

            SettingsHairline()

            SettingsToggleRow(
                label: "Pause when the screen locks",
                description: "Off by default — a lock during a call or a screensaver is not always a break.",
                isOn: model.prefs.autoPauseOnLock
            ) { next in
                model.write { try $0.write(.autoPauseOnLock, .bool(next)) }
            }
        }
    }

    // MARK: Screen capture

    /// The screen-capture section.
    ///
    /// Written to be read by somebody who is suspicious, because that is who opens it.
    /// The section states what is stored and how much of it, offers one button that
    /// deletes all of it, and never hides the fact that the images exist behind a
    /// summary that sounds smaller than it is.
    ///
    /// Everything below the toggle stays visible while capture is off rather than
    /// disappearing, so the retention window and the delete button can be found by a
    /// person who has *just* switched it off and wants the images gone too.
    private var screenCapture: some View {
        SettingsSectionCard(
            title: "Screen capture",
            description: "Off unless you turn it on. Nobody else can turn it on for you, "
                + "and there is no version of Deylee where they can."
        ) {
            SettingsToggleRow(
                label: "Capture my screen while the timer runs",
                description: "An image every few minutes while you are working — never on a break, "
                    + "never while paused, never while the timer is stopped. Turning this on asks "
                    + "macOS for permission and takes one image straight away, so you can see "
                    + "exactly what gets stored.",
                isOn: model.prefs.screenCaptureEnabled
            ) { next in
                model.write { try $0.write(.screenCaptureEnabled, .bool(next)) }
                // Only on the way on. Switching it off must not take a parting image.
                if next { model.onCaptureEnabled?() }
            }

            if model.prefs.screenCaptureEnabled, model.capturePermission == .denied {
                SettingsHairline()
                SettingsRow(
                    label: "macOS has not granted screen recording",
                    description: "The setting is on, but the system is refusing. Nothing is being "
                        + "captured until you allow it in System Settings."
                ) {
                    Button("Open System Settings") {
                        CaptureService.openSystemPrivacySettings()
                    }
                    .buttonStyle(.link)
                    .font(Type.small)
                }
            }

            SettingsHairline()

            SettingsNumberFieldRow(
                label: "Capture every",
                description: model.prefs.screenCaptureEnabled
                    ? "How often an image is taken while you are working."
                    : "Turn capture on to change this.",
                value: Double(model.prefs.screenCaptureIntervalMinutes),
                bounds: Double(PreferenceLimits.screenCaptureIntervalRange.lowerBound)
                    ... Double(PreferenceLimits.screenCaptureIntervalRange.upperBound),
                suffix: "minutes",
                isEnabled: model.prefs.screenCaptureEnabled
            ) { next in
                model.write { try $0.write(.screenCaptureIntervalMinutes, .number(next)) }
            }

            SettingsHairline()

            SettingsNumberFieldRow(
                label: "Keep them for",
                description: "Older images are deleted automatically. This applies to images "
                    + "already taken, so shortening it removes some immediately.",
                value: Double(model.prefs.screenCaptureRetentionDays),
                bounds: Double(PreferenceLimits.screenCaptureRetentionRange.lowerBound)
                    ... Double(PreferenceLimits.screenCaptureRetentionRange.upperBound),
                suffix: "days"
            ) { next in
                model.write { try $0.write(.screenCaptureRetentionDays, .number(next)) }
            }

            SettingsHairline()

            SettingsRow(
                label: "What is stored",
                description: model.captureFootprintDescription
            ) {
                HStack(spacing: Space.l) {
                    // Looking comes before deleting, in that order, because somebody
                    // deciding whether to keep these needs to see them first — and
                    // "delete everything" is a poor substitute for being shown what
                    // "everything" is.
                    Button("Review") { model.onReviewCaptures?() }
                        .buttonStyle(.link)
                        .font(Type.small)
                        .disabled(model.captureCount == 0)
                    Button("Delete all") { model.deleteAllCaptures() }
                        .buttonStyle(.link)
                        .font(Type.small)
                        .foregroundStyle(Palette.breakColor)
                        .disabled(model.captureCount == 0)
                }
            }
        }
        .onAppear { model.refreshCaptureFootprint() }
    }

    // MARK: Reminders

    private var reminders: some View {
        SettingsSectionCard(
            title: "Reminders",
            description: "One nudge a day, and only while the timer is still running."
        ) {
            SettingsToggleRow(
                label: "Remind me to stop",
                description: "Fires at most once per day, at the time below.",
                isOn: model.prefs.reminderEnabled
            ) { next in
                model.write { try $0.write(.reminderEnabled, .bool(next)) }
            }

            SettingsHairline()

            SettingsRow(
                label: "Reminder time",
                description: model.prefs.reminderEnabled
                    ? "Local time, on a 24-hour clock or your locale’s equivalent."
                    : "Turn reminders on to choose a time.",
                isEnabled: model.prefs.reminderEnabled
            ) {
                SettingsReminderTimeField(
                    time: model.reminderTime,
                    isEnabled: model.prefs.reminderEnabled
                ) { hour, minute in
                    model.writeReminderTime(hour: hour, minute: minute)
                }
            }
        }
    }

    // MARK: Data

    private var data: some View {
        SettingsSectionCard(
            title: "Data",
            // Was "Nothing is ever uploaded", which stopped being true the moment
            // sync existed, and then "nothing else does", which stopped being true
            // the moment screen capture could be switched on. Copy that quietly
            // contradicts the software is worse than none: this is the screen where
            // somebody checks, and the sentence has to survive being checked.
            description: "Your database lives on this machine. Signed out, it goes nowhere; "
                + "signed in, your hours sync to your account. Nothing else leaves unless "
                + "you switch it on yourself — screen capture is off until you turn it on."
        ) {
            dataFolderBlock
            SettingsHairline()
            dataActions
        }
    }

    private var dataFolderBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Data folder")
                .font(Type.body.weight(.medium))
                .foregroundStyle(Palette.fg)
            Text("Your database and preferences live here.")
                .font(Type.small)
                .foregroundStyle(Palette.fgFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xxs)
            // The path can be far wider than the window; truncating keeps the layout,
            // and the tooltip plus selectable text keep it usable.
            Text(model.dataFolderPath ?? "Locating…")
                .font(Type.small.monospaced())
                .foregroundStyle(Palette.fgMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(model.dataFolderPath ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control).fill(Palette.sunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )
                .padding(.top, Space.m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
    }

    private var dataActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Button("Reveal in file manager") { model.revealDataFolder() }
                Button(model.backup == .busy ? "Backing up…" : "Back up database…") {
                    model.backUpDatabase()
                }
                .disabled(model.backup == .busy)
            }
            .buttonStyle(DeyleeButtonStyle(variant: .secondary, size: .medium))

            switch model.backup {
            case .done(let path):
                (Text("Backed up to ") + Text(path).font(Type.small.monospaced()))
                    .font(Type.small)
                    .foregroundStyle(Palette.work)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.m)
            case .failed(let message):
                Text(message)
                    .font(Type.small)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.m)
            case .idle, .busy:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
    }

    // MARK: Updates

    private var updates: some View {
        SettingsSectionCard(
            title: "Updates",
            description: model.updatesSectionDescription
        ) {
            SettingsToggleRow(
                label: "Check for updates automatically",
                description: model.updateCheckDescription,
                isOn: model.prefs.updateCheckEnabled,
                isEnabled: model.canAutoUpdate
            ) { next in
                model.write { try $0.write(.updateCheckEnabled, .bool(next)) }
            }

            SettingsHairline()

            SettingsRow(
                label: model.versionLabel,
                description: model.versionDescription
            ) {
                SettingsUpdateLine(
                    status: model.updateStatus,
                    currentVersion: model.currentVersion,
                    canAutoUpdate: model.canAutoUpdate,
                    onCheck: { model.checkForUpdates() },
                    onDownload: { model.downloadUpdate() },
                    onInstall: { model.installUpdate() },
                    onOpenReleases: { model.openReleases() }
                )
            }
        }
    }
}

// MARK: - Header note

/// The one confirmation a write gets: a check and "Saved", or "Could not save".
private struct SettingsSavedNote: View {
    let status: SettingsSaveStatus

    var body: some View {
        HStack(spacing: Space.s) {
            if status != .failed {
                Image(systemName: "checkmark")
                    .font(Type.small.weight(.medium))
            }
            Text(status == .failed ? "Could not save" : "Saved")
                .font(Type.small)
        }
        .foregroundStyle(status == .failed ? Palette.danger : Palette.fgFaint)
        .opacity(status == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.5), value: status)
        .accessibilityElement(children: .combine)
        // Polite: the user is looking at the control they just changed, not at this.
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Section frame

/// One titled group of preferences.
///
/// Rows bring their own padding, so this supplies only the frame; a row written
/// anywhere else must match the same 8 pt rhythm to sit flush with them.
struct SettingsSectionCard<Content: View>: View {
    let title: String
    var description: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title)
                .padding(.horizontal, Space.xs)
            if let description {
                Text(description)
                    .font(Type.small)
                    .foregroundStyle(Palette.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.xs)
                    .padding(.top, Space.xs)
            }
            VStack(spacing: 0) { content }
                .padding(Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.raised))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )
                .padding(.top, Space.m)
        }
    }
}

/// The hairline between two rows of a settings card.
struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 1)
    }
}

/// A row's label and its explanation, the left-hand half of every row in the window.
private struct SettingsRowLabel: View {
    let label: String
    var description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(label)
                .font(Type.body.weight(.medium))
                .foregroundStyle(Palette.fg)
                .fixedSize(horizontal: false, vertical: true)
            if let description {
                Text(description)
                    .font(Type.small)
                    .foregroundStyle(Palette.fgFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}

/// A row whose control is not itself the row — a segmented control, a time field, the
/// update line.
struct SettingsRow<Control: View>: View {
    let label: String
    var description: String?
    var isEnabled = true
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Space.x3l) {
            SettingsRowLabel(label: label, description: description)
            control
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        // Disabled rows dim rather than change colour, so the layout never shifts.
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Toggle

/// A preference switch whose whole row is the control.
///
/// The hit target is the row rather than the 36 pt track: a switch this small is a
/// miss waiting to happen, and the label is what the user is actually aiming at.
struct SettingsToggleRow: View {
    let label: String
    var description: String?
    let isOn: Bool
    var isEnabled = true
    let action: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            action(!isOn)
        } label: {
            HStack(alignment: .top, spacing: Space.x3l) {
                SettingsRowLabel(label: label, description: description)
                SettingsToggleSwitch(isOn: isOn)
                    .padding(.top, Space.xxs)
            }
            .padding(Space.m)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(isHovering && isEnabled ? Palette.hover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .animation(Motion.control, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// The 36 × 20 track and its knob.
private struct SettingsToggleSwitch: View {
    let isOn: Bool

    private static let trackWidth: CGFloat = 36
    private static let trackHeight: CGFloat = 20
    private static let knobSize: CGFloat = 14
    private static let knobInset: CGFloat = 3
    private static let knobTravel: CGFloat = 16

    var body: some View {
        Capsule()
            // The off track is a tint of the muted ink rather than a surface colour, so
            // the white knob keeps its contrast in both themes.
            .fill(isOn ? Palette.accent : Palette.fgFaint.opacity(0.35))
            .frame(width: Self.trackWidth, height: Self.trackHeight)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .shadow(radius: 1, y: 1)
                    .offset(x: Self.knobInset + (isOn ? Self.knobTravel : 0))
            }
            .animation(Motion.control, value: isOn)
    }
}

// MARK: - Segmented control

struct SettingsSegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// A short, fixed set of choices, laid out as one control rather than a menu.
struct SettingsSegmentedControl<Value: Hashable>: View {
    let accessibilityLabel: String
    let selection: Value
    let options: [SettingsSegmentedOption<Value>]
    let action: (Value) -> Void

    @State private var hovering: Value?

    private static var itemHeight: CGFloat { 28 }

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(options) { option in
                item(option)
            }
        }
        .padding(Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.sunken))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .animation(Motion.control, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func item(_ option: SettingsSegmentedOption<Value>) -> some View {
        let isSelected = option.value == selection
        return Button {
            // Re-picking the current option would write a preference that did not
            // change, and flash a "Saved" the user did nothing to earn.
            if !isSelected { action(option.value) }
        } label: {
            Text(option.label)
                .font(Type.small.weight(.medium))
                .foregroundStyle(
                    isSelected || hovering == option.value ? Palette.fg : Palette.fgMuted
                )
                .frame(height: Self.itemHeight)
                .padding(.horizontal, Space.l)
                .contentShape(Rectangle())
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Radius.chip)
                            .fill(Palette.raised)
                            .shadow(radius: 1, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? option.value : nil }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Number field

/// A bounded number, as a text field between two steppers.
///
/// The field commits on blur or Enter rather than on every keystroke: half-typed text
/// on the way from "1" to "15" would otherwise be clamped out from under the user.
struct SettingsNumberFieldRow: View {
    let label: String
    var description: String?
    let value: Double
    let bounds: ClosedRange<Double>
    var step: Double = 1
    let suffix: String
    var isEnabled = true
    let action: (Double) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private static let fieldWidth: CGFloat = 48
    private static let stepperSize: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: Space.x3l) {
            SettingsRowLabel(label: label, description: description)
            cluster
        }
        .padding(Space.m)
        .opacity(isEnabled ? 1 : 0.45)
        .onAppear { draft = Self.format(value) }
        .onChange(of: value) { _, next in draft = Self.format(next) }
    }

    private var cluster: some View {
        HStack(spacing: Space.xs) {
            stepper(systemName: "minus", label: "Decrease \(label)", to: value - step)
                .disabled(value <= bounds.lowerBound)

            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(Type.body.weight(.medium).monospacedDigit())
                .foregroundStyle(Palette.fg)
                .frame(width: Self.fieldWidth)
                .focused($isFocused)
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) {
                    draft = Self.format(value)
                    return .handled
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitDraft() }
                }
                .accessibilityLabel(label)

            Text(suffix)
                .font(Type.small)
                .foregroundStyle(Palette.fgFaint)
                .padding(.trailing, Space.xs)

            stepper(systemName: "plus", label: "Increase \(label)", to: value + step)
                .disabled(value >= bounds.upperBound)
        }
        .padding(Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.raised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(isFocused ? Palette.accent : Palette.border, lineWidth: 1)
        )
        .animation(Motion.control, value: isFocused)
        .disabled(!isEnabled)
        .fixedSize()
    }

    private func stepper(systemName: String, label: String, to next: Double) -> some View {
        Button {
            commit(next)
        } label: {
            Image(systemName: systemName)
                .font(Type.small.weight(.medium))
                .frame(width: Self.stepperSize, height: Self.stepperSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsStepperStyle())
        .accessibilityLabel(label)
    }

    private func commit(_ next: Double) {
        let clamped = min(bounds.upperBound, max(bounds.lowerBound, next))
        draft = Self.format(clamped)
        if clamped != value { action(clamped) }
    }

    private func commitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        // Empty or nonsense input reverts rather than writing a NaN preference.
        guard let parsed = Double(trimmed), parsed.isFinite else {
            draft = Self.format(value)
            return
        }
        commit(parsed)
    }

    /// Prints 8 as "8" and 7.5 as "7.5". Swift's own `Double` description would put a
    /// decimal point on a whole-hour target the user never typed.
    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}

private struct SettingsStepperStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovering ? Palette.fg : Palette.fgMuted)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(isHovering ? Palette.hover : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { isHovering = $0 && isEnabled }
            .animation(Motion.control, value: isHovering)
    }
}

// MARK: - Reminder time

/// The reminder's hour and minute, as the platform's own time field.
///
/// Edited against a local draft and committed only when the field gives up focus.
/// A field-style picker reports a new value on every digit typed, so writing straight
/// through would persist each intermediate: someone correcting 17:30 to 09:30 types
/// `0` and the reminder is briefly set to 00:30 — and stays there if they click away
/// before the second digit. The draft is what keeps the two preferences underneath
/// from being half-written.
struct SettingsReminderTimeField: View {
    let time: Date
    let isEnabled: Bool
    let action: (Int, Int) -> Void

    @State private var draft: Date?
    @FocusState private var isFocused: Bool

    /// Matches the medium button and the number-field cluster it shares a card with.
    private static let fieldHeight: CGFloat = 36

    var body: some View {
        DatePicker(
            "Reminder time",
            selection: Binding(
                get: { draft ?? time },
                set: { draft = $0 }
            ),
            displayedComponents: .hourAndMinute
        )
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .onSubmit(commit)
        // A value the user did not type — the store changed under them — replaces the
        // draft, so the field never shows something the preferences no longer hold.
        .onChange(of: time) { _, _ in
            if !isFocused { draft = nil }
        }
        .datePickerStyle(.field)
        .labelsHidden()
        .font(Type.body.monospacedDigit())
        .foregroundStyle(Palette.fg)
        .textFieldStyle(.plain)
        .frame(height: Self.fieldHeight)
        .padding(.horizontal, Space.l)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.raised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .disabled(!isEnabled)
        .accessibilityLabel("Reminder time")
    }

    private func commit() {
        guard let draft else { return }
        self.draft = nil
        let parts = Calendar.current.dateComponents([.hour, .minute], from: draft)
        guard let hour = parts.hour, let minute = parts.minute else { return }
        action(hour, minute)
    }
}

// MARK: - Update line

/// One quiet line describing where an update has got to.
///
/// An update is the app's errand, not the user's, so this is the least loud thing on
/// screen: no colour alarm, no animation, no badge. The running green never appears
/// here — not even when an update is ready. A link promises a browser; a button
/// promises that Deylee does the thing itself, which is the only signal an unsigned
/// build gives that the update is the user's to finish.
struct SettingsUpdateLine: View {
    let status: SettingsUpdateStatus
    let currentVersion: String?
    let canAutoUpdate: Bool
    let onCheck: () -> Void
    let onDownload: () -> Void
    let onInstall: () -> Void
    let onOpenReleases: () -> Void

    /// The longest line — a version that has to be installed by hand — would otherwise
    /// push the action out of a 560 pt window; it wraps instead.
    private static let messageMaxWidth: CGFloat = 304

    var body: some View {
        HStack(spacing: Space.l) {
            Text(message)
                .font(Type.meta)
                .foregroundStyle(isQuiet ? Palette.fgFaint : Palette.fgMuted)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: Self.messageMaxWidth, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .help(detail ?? "")

            switch action {
            case .none:
                EmptyView()
            case .button(let label, let run):
                Button(label, action: run)
                    .buttonStyle(DeyleeButtonStyle(variant: .secondary, size: .small))
            case .link(let label, let run):
                Button(label, action: run)
                    .buttonStyle(SettingsLinkStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }

    private enum SettingsUpdateAction {
        case none
        case button(label: String, run: () -> Void)
        case link(label: String, run: () -> Void)
    }

    private var message: String {
        switch status {
        case .idle:
            return "Not checked yet"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            guard let currentVersion else { return "Up to date" }
            return "Up to date · v\(currentVersion)"
        case .available(let version):
            return "Version \(version) is available"
        case .downloading(let percent):
            return "Downloading… \(Self.percentLabel(percent))%"
        case .downloaded(let version):
            return "Version \(version) is ready"
        case .manual(let version):
            return "Version \(version) is available — this build can’t install it for you"
        case .unsupported(let reason):
            return reason
        case .failed:
            return "Couldn’t check for updates"
        }
    }

    /// Drops a contrast step on lines the user is not expected to act on. A failed
    /// check is styled *down* rather than up: the network is not the user's problem to
    /// solve, and a red line would ask them to treat it as one.
    private var isQuiet: Bool {
        switch status {
        case .idle, .checking, .downloading, .unsupported, .failed: true
        case .upToDate, .available, .downloaded, .manual: false
        }
    }

    private var detail: String? {
        if case .failed(let detail) = status { return detail }
        return nil
    }

    private var action: SettingsUpdateAction {
        switch status {
        case .idle, .upToDate:
            return .button(label: "Check now", run: onCheck)
        case .checking, .downloading:
            return .none
        case .available:
            // Offering a Download button on a build that cannot install it would be a
            // promise the platform will not keep, so it becomes the Releases page.
            return canAutoUpdate
                ? .button(label: "Download", run: onDownload)
                : .link(label: "Open Releases", run: onOpenReleases)
        case .downloaded:
            return .button(label: "Restart to update", run: onInstall)
        case .manual, .unsupported:
            return .link(label: "Open Releases", run: onOpenReleases)
        case .failed:
            return .button(label: "Try again", run: onCheck)
        }
    }

    /// Downloads report an unclamped float; the line only ever shows whole percent.
    private static func percentLabel(_ percent: Double) -> String {
        guard percent.isFinite else { return "0" }
        return String(Int(min(100, max(0, percent.rounded()))))
    }
}

/// A link, not a button: it promises a browser rather than an install.
private struct SettingsLinkStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Type.meta)
            .foregroundStyle(isHovering ? Palette.fg : Palette.fgMuted)
            .underline()
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(Motion.control, value: isHovering)
    }
}
