import SwiftUI
import DaylyKit

/// The state dot and its label, shared by the panel header and the mini window.
struct StateBadge: View {
    let state: TimerState
    var showLabel = true

    static func label(for state: TimerState) -> String {
        switch state {
        case .idle: "Idle"
        case .running: "Running"
        case .paused: "Paused"
        case .ended: "Day ended"
        }
    }

    static func color(for state: TimerState) -> Color {
        switch state {
        case .idle: Palette.fgFaint
        // Green means work is being counted, and nothing else in the app may use it.
        case .running: Palette.work
        case .paused: Palette.breakColor
        case .ended: Palette.accent
        }
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Circle()
                .fill(Self.color(for: state))
                .frame(width: 8, height: 8)
            if showLabel {
                Text(Self.label(for: state))
                    .font(Type.meta.weight(.medium))
                    .foregroundStyle(Palette.fgMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(for: state))
    }
}

enum ButtonVariant {
    case primary
    case secondary
    case ghost
    case danger
}

enum ButtonSize {
    case small
    case medium
    case large

    var height: CGFloat {
        switch self {
        case .small: 28
        case .medium: 36
        case .large: 44
        }
    }

    var font: Font {
        switch self {
        case .small: Type.small
        case .medium: Type.control
        case .large: Type.controlLarge
        }
    }
}

struct DaylyButtonStyle: ButtonStyle {
    var variant: ButtonVariant = .primary
    var size: ButtonSize = .medium
    var fillWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font.weight(.medium))
            .foregroundStyle(foreground)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .frame(height: size.height)
            .padding(.horizontal, size == .small ? Space.l : Space.xl)
            .background(
                RoundedRectangle(cornerRadius: Radius.control)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(border, lineWidth: 1)
            )
            // Disabled controls dim rather than change colour, so the layout never shifts.
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Motion.control, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: Palette.accentFg
        case .secondary: Palette.fg
        case .ghost: Palette.fgMuted
        case .danger: Palette.danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: pressed ? Palette.accentHover : Palette.accent
        case .secondary: pressed ? Palette.hover : Palette.raised
        case .ghost: pressed ? Palette.hover : .clear
        case .danger: Palette.dangerSoft
        }
    }

    private var border: Color {
        switch variant {
        case .primary, .ghost: .clear
        case .secondary: Palette.border
        case .danger: Palette.danger.opacity(0.4)
        }
    }
}

/// The one button whose label and action follow the timer state.
struct ActionButton: View {
    let state: TimerState
    var size: ButtonSize = .large
    var iconOnly = false
    let action: () -> Void

    var label: String {
        switch state {
        case .running: "Pause"
        case .paused: "Resume"
        case .ended: "Start again"
        case .idle: "Start"
        }
    }

    private var isPause: Bool { state == .running }

    private var variant: ButtonVariant {
        // Pausing is the one action that steps back, so it never gets primary weight.
        isPause ? .secondary : .primary
    }

    var body: some View {
        Button(action: action) {
            if iconOnly {
                icon
            } else {
                HStack(spacing: Space.s) {
                    icon
                    Text(label)
                }
            }
        }
        .buttonStyle(DaylyButtonStyle(variant: variant, size: size, fillWidth: !iconOnly))
        .accessibilityLabel(label)
        .help(label)
    }

    private var icon: some View {
        Image(systemName: isPause ? "pause.fill" : "play.fill")
            .font(.system(size: 14))
    }
}

/// Progress towards the daily target. Absent entirely when no target is set.
struct TargetProgressBar: View {
    /// Unclamped, so "past target" can change the colour without distorting the bar.
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.sunken)
                Capsule()
                    .fill(progress >= 1 ? Palette.work : Palette.accent)
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 6)
        .animation(Motion.progress, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Progress towards today's target")
        .accessibilityValue("\(Int((min(max(progress, 0), 1)) * 100)) percent")
    }
}

/// The `Work` / `Break` pill on a segment row.
struct TypeChip: View {
    let type: SegmentType

    var body: some View {
        Text(type == .work ? "Work" : "Break")
            .font(Type.meta.weight(.medium))
            .foregroundStyle(type == .work ? Palette.work : Palette.breakColor)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(type == .work ? Palette.workSoft : Palette.breakSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(
                        (type == .work ? Palette.work : Palette.breakColor).opacity(0.25),
                        lineWidth: 1
                    )
            )
    }
}

/// Dashed card shown where a list would otherwise be blank.
struct EmptyStateCard: View {
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: Space.s) {
            Text(title)
                .font(Type.control.weight(.medium))
                .foregroundStyle(Palette.fgMuted)
            Text(description)
                .font(Type.small)
                .foregroundStyle(Palette.fgFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.x4l)
        .padding(.horizontal, Space.xl)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.window)
                .strokeBorder(
                    Palette.border,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
    }
}

/// Uppercase section heading — `Today`, and the settings group titles.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Type.caps)
            .tracking(0.8)
            .foregroundStyle(Palette.fgFaint)
    }
}
