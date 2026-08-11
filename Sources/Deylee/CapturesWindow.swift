import AppKit
import DeyleeKit
import SwiftUI

/// What Deylee has captured, as images rather than as a number.
///
/// This window exists because the alternative failed a test the product sets itself.
/// `PRODUCT.md` §3 promises the person recorded stays in control, and Settings could
/// already tell them *how many* images existed and delete all of them at once — but
/// not show them one. "You may destroy these but not look at them" is a strange kind
/// of control, and the first question anybody asks about a screenshot feature is what
/// it actually captured, not how much disk it used.
///
/// It reads from the encrypted store like everything else. Images are never written to
/// disk as files: the bytes go from SQLCipher into an `NSImage` and no further, so
/// looking at a capture does not quietly create an unencrypted copy of it in a cache
/// folder somewhere.
@MainActor
final class CapturesWindow: NSObject, NSWindowDelegate {
    private static var current: CapturesWindow?

    private let window: NSWindow
    private let model: CapturesModel

    static func open(repo: Repository) {
        if let current {
            current.model.reload()
            current.focus()
            return
        }
        let window = CapturesWindow(repo: repo)
        current = window
        DockPresence.acquire()
        window.focus()
    }

    private init(repo: Repository) {
        let model = CapturesModel(repo: repo)
        self.model = model

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 900, height: 620)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Screen captures"
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.contentViewController = NSHostingController(rootView: CapturesView(model: model))
        window.setContentSize(NSSize(width: 900, height: 620))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        model.reload()
    }

    private func focus() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.releaseIfLastWindow()
        Self.current = nil
    }
}

/// The window's state.
@MainActor
@Observable
final class CapturesModel {
    private(set) var day: DateKey
    private(set) var summaries: [CaptureSummary] = []
    /// The image being looked at, decoded on demand. Only one is held: a day of
    /// captures is tens of megabytes and keeping them all decoded would put every
    /// screenshot of the day in memory to show one.
    private(set) var opened: (summary: CaptureSummary, image: NSImage)?

    @ObservationIgnored private let repo: Repository

    init(repo: Repository, day: DateKey = dateKeyOf(EpochMs(Date().timeIntervalSince1970 * 1000))) {
        self.repo = repo
        self.day = day
    }

    func reload() {
        summaries = (try? repo.captureSummaries(on: day)) ?? []
        // The open image may have just been deleted from under us.
        if let opened, !summaries.contains(where: { $0.id == opened.summary.id }) {
            self.opened = nil
        }
    }

    func show(_ day: DateKey) {
        self.day = day
        opened = nil
        reload()
    }

    func open(_ summary: CaptureSummary) {
        guard let capture = try? repo.capture(id: summary.id),
              let image = NSImage(data: capture.bytes)
        else { return }
        opened = (summary, image)
    }

    func close() { opened = nil }

    /// Delete the one being looked at, which is the only place a single capture can be
    /// deleted — deleting an image you are looking at is a decision; deleting one from a
    /// grid of thumbnails is a misclick.
    func deleteOpened() {
        guard let opened else { return }
        _ = try? repo.deleteCapture(
            opened.summary.id, now: EpochMs(Date().timeIntervalSince1970 * 1000)
        )
        self.opened = nil
        reload()
    }

    var title: String {
        summaries.isEmpty
            ? "Nothing captured on \(day.description)"
            : "\(summaries.count) capture\(summaries.count == 1 ? "" : "s") on \(day.description)"
    }
}

private struct CapturesView: View {
    @Bindable var model: CapturesModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.border)
            if let opened = model.opened {
                viewer(opened)
            } else if model.summaries.isEmpty {
                empty
            } else {
                grid
            }
        }
        .background(Palette.surface)
    }

    private var header: some View {
        HStack(spacing: Space.l) {
            Button {
                model.show(addDays(model.day, -1))
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.fgMuted)

            Text(model.title)
                .font(Type.controlLarge.weight(.medium))
                .foregroundStyle(Palette.fg)

            Button {
                model.show(addDays(model.day, 1))
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.fgMuted)

            Spacer()

            if model.opened != nil {
                Button("Back") { model.close() }
                    .buttonStyle(.link)
                    .font(Type.small)
            }
        }
        .padding(Space.x3l)
    }

    private var empty: some View {
        VStack(spacing: Space.l) {
            Text("No captures for this day.")
                .font(Type.body)
                .foregroundStyle(Palette.fgMuted)
            Text("Deylee only captures while the timer is running, and only if you switched it on.")
                .font(Type.small)
                .foregroundStyle(Palette.fgFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.x5l)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: Space.xl)],
                spacing: Space.xl
            ) {
                ForEach(model.summaries) { summary in
                    Button { model.open(summary) } label: {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            // A placeholder rather than a thumbnail: decoding every image
                            // in a day to fill a grid is the one thing that would make
                            // this window slow, and the timestamp is what people scan by.
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(Palette.raised)
                                .frame(height: 124)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundStyle(Palette.fgFaint)
                                )
                            Text(Self.clock(summary.capturedAt))
                                .font(Type.body)
                                .foregroundStyle(Palette.fg)
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(summary.byteCount), countStyle: .file))
                                .font(Type.meta)
                                .foregroundStyle(Palette.fgFaint)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.x3l)
        }
    }

    private func viewer(_ opened: (summary: CaptureSummary, image: NSImage)) -> some View {
        VStack(spacing: Space.l) {
            Image(nsImage: opened.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: Space.xl) {
                Text("Captured at \(Self.clock(opened.summary.capturedAt))")
                    .font(Type.small)
                    .foregroundStyle(Palette.fgMuted)
                Spacer()
                Button("Delete this capture") { model.deleteOpened() }
                    .buttonStyle(.link)
                    .font(Type.small)
                    .foregroundStyle(Palette.breakColor)
            }
        }
        .padding(Space.x3l)
    }

    private static func clock(_ at: EpochMs) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: Double(at) / 1000))
    }
}
