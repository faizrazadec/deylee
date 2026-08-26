import SwiftUI
import DeyleeKit

/// The popover panel: today's totals, the state action, and today's segments.
///
/// Everything that ticks is recomputed from timestamps on a 1 Hz timeline rather
/// than incremented, so the numbers stay right across sleep, a clock change and
/// midnight.
struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.epochMs
            let live = liveTotals(model.snapshot, now: now)

            VStack(spacing: 0) {
                header
                mainColumn(live: live, now: now)
                Divider().overlay(Palette.border)
                footer
            }
            .frame(width: Layout.panelSize.width, height: Layout.panelSize.height)
            .background(Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.window)
                    .strokeBorder(Palette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.window))
            .deyleePrompts(model)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            StateBadge(state: model.snapshot.state)
            Spacer()
            Text(formatDateLong(model.snapshot.date))
                .font(Type.meta)
                .foregroundStyle(Palette.fgFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.x3l)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.m)
    }

    // MARK: - Main column

    private func mainColumn(live: LiveTotals, now: EpochMs) -> some View {
        VStack(spacing: Space.xl) {
            if !model.notices.isEmpty { NoticeStack(model: model) }
            hero(live: live)
            targetBlock(live: live)
            actions
            todaySection(now: now)
        }
        .padding(.horizontal, Space.x3l)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func hero(live: LiveTotals) -> some View {
        let text = formatHMS(live.workedMs)
        // The trailing `:SS` is set half-size so the eye lands on hours and minutes —
        // the seconds are motion, not information.
        let split = text.range(of: ":", options: .backwards)
        let head = split.map { String(text[text.startIndex..<$0.lowerBound]) } ?? text
        let tail = split.map { String(text[$0.lowerBound...]) } ?? ""

        return VStack(spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(head)
                    .font(Type.hero)
                    .tracking(-1)
                    .foregroundStyle(Palette.fg)
                Text(tail)
                    .font(Type.heroSeconds)
                    .foregroundStyle(Palette.fgDim)
            }
            subLine(live: live)
        }
        .frame(maxWidth: .infinity)
    }

    private func subLine(live: LiveTotals) -> some View {
        HStack(spacing: Space.xs) {
            Text("Break").foregroundStyle(Palette.fgFaint)
            Text(formatCompact(live.breakMs)).monospacedDigit()
            if let firstStartAt = model.snapshot.firstStartAt {
                Text("·").foregroundStyle(Palette.fgFaint)
                Text("since").foregroundStyle(Palette.fgFaint)
                Text(formatClock(firstStartAt)).monospacedDigit()
            }
        }
        .font(Type.small)
        .foregroundStyle(Palette.fgMuted)
    }

    @ViewBuilder
    private func targetBlock(live: LiveTotals) -> some View {
        VStack(spacing: Space.s) {
            if live.targetMs > 0 {
                TargetProgressBar(progress: live.targetProgress)
            }
            HStack {
                if live.targetMs > 0 {
                    Text("\(formatCompact(live.workedMs)) of \(formatCompact(live.targetMs))")
                } else {
                    Text("\(formatCompact(live.workedMs)) worked today")
                }
                Spacer()
                if live.targetMs > 0 {
                    Text(
                        live.remainingToTargetMs > 0
                            ? "\(formatCompact(live.remainingToTargetMs)) left"
                            : "Target met"
                    )
                }
            }
            .font(Type.metaTabular)
            .foregroundStyle(Palette.fgFaint)
        }
    }

    private var actions: some View {
        HStack(spacing: Space.m) {
            ActionButton(state: model.snapshot.state) { model.primaryAction() }
            if model.snapshot.state == .running || model.snapshot.state == .paused {
                Button("End day") { model.confirmEndDay() }
                    .buttonStyle(DeyleeButtonStyle(variant: .secondary, size: .large))
            }
        }
        .disabled(!model.hasLoaded)
    }

    private func todaySection(now: EpochMs) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionLabel(text: "Today")
            if model.todaySegments.isEmpty {
                EmptyStateCard(
                    title: "Nothing tracked yet",
                    description: "Press Start to open the day."
                )
            } else {
                ScrollView {
                    VStack(spacing: Space.s) {
                        ForEach(model.todaySegments) { segment in
                            SegmentRow(segment: segment, now: now)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        // Icons rather than words, so the footer stays quiet under the numbers that
        // matter. Each carries a tooltip and an accessibility label, because a glyph
        // with neither is a guess for a sighted user and nothing at all for VoiceOver.
        HStack(spacing: Space.xxs) {
            FooterButton(
                symbol: "clock.arrow.circlepath",
                label: "History",
                hint: "History — every day you have recorded",
                action: model.openHistory
            )
            Spacer()
            // In reach of the thing that just went wrong. Reporting a bug is something
            // people do in the second they notice it, and a trip through Settings is
            // long enough for the thought to pass.
            FooterButton(
                symbol: "ladybug",
                label: "Report a bug",
                hint: "Report a bug — opens a draft in your mail app",
                action: model.sendFeedback
            )
            FooterButton(
                symbol: "gearshape",
                label: "Settings",
                hint: "Settings",
                action: model.openSettings
            )
        }
        // The icon-only size, because .small carries the horizontal padding a word like
        // "History" needs and a glyph does not: 10pt either side, which held the bug and
        // the gear 24pt apart when they should read as one pair.
        .buttonStyle(DeyleeButtonStyle(variant: .ghost, size: .circle))
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
    }
}

/// One of the panel footer's glyphs.
///
/// A button with no words on it has to say what it is some other way: `help` for the
/// pointer, `accessibilityLabel` for VoiceOver. Bundling the three together means
/// neither can be forgotten when a fourth is added.
private struct FooterButton: View {
    let symbol: String
    let label: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .help(hint)
        .accessibilityLabel(label)
    }
}

/// One segment in the panel's list. Read-only here — editing lives in History.
struct SegmentRow: View {
    let segment: Segment
    let now: EpochMs

    var body: some View {
        HStack(spacing: Space.m) {
            TypeChip(type: segment.type)
            timeRange
            if let note = segment.note, !note.isEmpty {
                Text(note)
                    .font(Type.small)
                    .foregroundStyle(Palette.fgFaint)
                    .lineLimit(1)
                    .help(note)
            }
            Spacer(minLength: Space.xs)
            Text(formatCompact(spanDuration(segment, now: now)))
                .font(Type.control.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Palette.fg)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.control).fill(Palette.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .strokeBorder(
                    segment.isOpen ? Palette.accent.opacity(0.4) : Palette.border,
                    lineWidth: 1
                )
        )
    }

    private var timeRange: some View {
        HStack(spacing: Space.xs) {
            Text(formatClock(segment.startedAt))
            Text("–")
            if let endedAt = segment.endedAt {
                Text(formatClock(endedAt))
            } else {
                // A running segment reads as a word rather than a moving clock time:
                // "now" is the honest answer and does not twitch every second.
                Text("now")
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.accent)
            }
        }
        .font(Type.control)
        .monospacedDigit()
        .foregroundStyle(Palette.fgMuted)
    }
}
