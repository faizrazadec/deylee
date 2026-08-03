import SwiftUI
import DaylyKit

/// Small pieces shared by the History surfaces: the Today chip, the two segmented
/// controls, the hover-revealed row actions and the modal card.

/// `July 2026`, in the host locale.
func historyMonthLabel(_ monthStart: DateKey, locale: Locale = .current) -> String {
    historyDateLabel(monthStart, template: "MMMM y", locale: locale)
}

/// `20 Jul`, in the host locale's day/month order.
func historyShortDateLabel(_ date: DateKey, locale: Locale = .current) -> String {
    historyDateLabel(date, template: "d MMM", locale: locale)
}

/// Formats a date key through a fixed GMT calendar at noon, the same trick
/// `formatDateLong` uses: the key names a calendar day, not an instant, and noon keeps
/// the label on the intended day even where local midnight does not exist.
private func historyDateLabel(_ date: DateKey, template: String, locale: Locale) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate(template)
    let noon = calendar.date(from: DateComponents(
        year: date.year, month: date.month, day: date.day, hour: 12
    ))!
    return formatter.string(from: noon)
}

/// Locale weekday abbreviations, rotated so column 0 is the configured week start.
func historyWeekdayLabels(weekStartsOn: WeekStart, locale: Locale = .current) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = locale
    let symbols = formatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    return (0..<7).map { column in symbols[(weekStartsOn.rawValue + column) % 7] }
}

/// True for the Saturday and Sunday columns, whichever day the week starts on.
func historyIsWeekendColumn(_ column: Int, weekStartsOn: WeekStart) -> Bool {
    let dayOfWeek = (weekStartsOn.rawValue + column) % 7
    return dayOfWeek == 0 || dayOfWeek == 6
}

/// The `Today` marker beside a date.
struct HistoryTodayChip: View {
    var body: some View {
        Text("Today")
            .font(Type.caps.weight(.medium))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Palette.accentSoft))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(Palette.accent.opacity(0.3), lineWidth: 1)
            )
    }
}

/// The sunken bordered segmented control from the control spec. Clicking the selected
/// option does nothing, so no no-op write and no unearned feedback.
struct HistorySegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    /// The selected option's text colour, so the segment-type picker can tint Work green
    /// and Break amber while the view switcher stays neutral.
    var tint: (Option) -> Color = { _ in Palette.fg }
    /// The selected option's fill.
    var fill: (Option) -> Color = { _ in Palette.raised }
    var fillWidth = false
    let accessibilityLabel: String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    if !isSelected { selection = option }
                } label: {
                    Text(label(option))
                        .font(Type.small.weight(.medium))
                        .foregroundStyle(isSelected ? tint(option) : Palette.fgMuted)
                        .frame(maxWidth: fillWidth ? .infinity : nil)
                        .frame(height: 28)
                        .padding(.horizontal, Space.xl)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.chip)
                                .fill(isSelected ? fill(option) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
}

/// A 24 pt glyph button, hidden until its row is hovered.
struct HistoryIconButton: View {
    let systemName: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(foreground)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Motion.control, value: isHovering)
        .accessibilityLabel(label)
        .help(label)
    }

    private var foreground: Color {
        guard isHovering else { return Palette.fgFaint }
        return isDestructive ? Palette.danger : Palette.fg
    }

    private var background: Color {
        guard isHovering else { return .clear }
        return isDestructive ? Palette.dangerSoft : Palette.sunken
    }
}

/// The modal shell: title bar, body, and a sunken footer holding the actions.
struct HistoryModalCard<Body: View, Footer: View>: View {
    let title: String
    @ViewBuilder let content: () -> Body
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(Type.control.weight(.semibold))
                    .foregroundStyle(Palette.fg)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.x3l)
            .padding(.vertical, Space.xl)
            Divider().overlay(Palette.border)

            content()
                .padding(Space.x3l)

            Divider().overlay(Palette.border)
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                footer()
            }
            .padding(.horizontal, Space.x3l)
            .padding(.vertical, Space.xl)
            .background(Palette.sunken)
        }
        .frame(width: 384)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.window))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.window)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
    }
}

/// The inline error box a modal shows when a mutation comes back rejected.
struct HistoryErrorBox: View {
    let message: String

    var body: some View {
        Text(message)
            .font(Type.meta)
            .foregroundStyle(Palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.dangerSoft))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(Palette.danger.opacity(0.3), lineWidth: 1)
            )
            .accessibilityAddTraits(.isStaticText)
    }
}
