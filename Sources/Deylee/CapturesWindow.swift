import AppKit
import DeyleeKit
import ImageIO
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

    /// Grid-sized thumbnails, by capture id.
    ///
    /// Small enough to keep for a whole day — a few hundred kilobytes each rather than
    /// the several megabytes a decoded screenshot costs — which is the difference
    /// between caching these and caching the images themselves.
    private(set) var thumbnails: [Int64: NSImage] = [:]

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

    /// Decode one thumbnail, at the size the grid draws rather than the size it was
    /// captured at.
    ///
    /// The grid used to show a placeholder for every capture on the grounds that
    /// decoding a day of screenshots would make the window slow. It would — but only
    /// because `NSImage(data:)` decodes the whole thing. Asking ImageIO for a thumbnail
    /// decodes straight to the size wanted and never holds the full image at all.
    ///
    /// Called from the cell, so `LazyVGrid` only pays for rows somebody scrolls to.
    func loadThumbnail(for summary: CaptureSummary) {
        guard thumbnails[summary.id] == nil,
              let capture = try? repo.capture(id: summary.id),
              let image = Self.thumbnail(from: capture.bytes, maxPixel: 440)
        else { return }
        thumbnails[summary.id] = image
    }

    // ponytail: decoded on the main actor. It is a downsample rather than a full decode
    // and a screenful is a handful of cells, so it does not stutter; if a day of
    // captures ever grows enough to be felt, this moves off the actor and the cache
    // gains a bound.
    private static func thumbnail(from data: Data, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    // MARK: Moving between captures

    /// Where the open capture sits in the day, so the viewer can step either way.
    private var openedIndex: Int? {
        guard let opened else { return nil }
        return summaries.firstIndex { $0.id == opened.summary.id }
    }

    var canShowPrevious: Bool { (openedIndex ?? 0) > 0 }
    var canShowNext: Bool {
        guard let index = openedIndex else { return false }
        return index < summaries.count - 1
    }

    /// Earlier in the day. Looking through a day's captures without returning to the
    /// grid between each one is the whole point of opening one.
    func showPrevious() {
        guard let index = openedIndex, index > 0 else { return }
        open(summaries[index - 1])
    }

    func showNext() {
        guard let index = openedIndex, index < summaries.count - 1 else { return }
        open(summaries[index + 1])
    }

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
                            // Decoded at tile size rather than capture size, so a day
                            // of screenshots costs a downsample each instead of a full
                            // decode each — which is what a grid of identical grey
                            // placeholders was buying before.
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(Palette.raised)
                                .frame(height: 124)
                                .overlay {
                                    if let thumbnail = model.thumbnails[summary.id] {
                                        Image(nsImage: thumbnail)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } else {
                                        Image(systemName: "photo")
                                            .foregroundStyle(Palette.fgFaint)
                                    }
                                }
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: Radius.control, style: .continuous
                                    )
                                )
                                // Only rows somebody scrolls to are decoded.
                                .task { model.loadThumbnail(for: summary) }
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
                // Stepping through the day without going back to the grid between each
                // one, which is how anybody actually reads a set of captures. Arrow
                // keys do the same, because that is what hands reach for.
                Button { model.showPrevious() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!model.canShowPrevious)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous capture")

                Button { model.showNext() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!model.canShowNext)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next capture")

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
