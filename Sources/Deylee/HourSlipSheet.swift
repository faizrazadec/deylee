import DeyleeKit
import SwiftUI

/// Picks the days for an hour slip, then asks for it and saves the PDF.
///
/// Quick choices first — Today, Yesterday, Last 7 days — and Custom for a range of one's
/// own. The range is checked as it is picked (ended days only, at most 30), so the button
/// is disabled with the reason beside it rather than failing after a round trip.
struct HourSlipSheet: View {
    let target: HourSlipTarget
    /// The days a preset stands for, by the trusted clock; nil for Custom.
    let rangeFor: (HourSlipPreset) -> (DateKey, DateKey)?
    let problem: (DateKey, DateKey) -> String?
    let onCancel: () -> Void
    /// Returns the message to show, or nil once the slip was made and the save panel has
    /// taken over.
    let onCreate: (DateKey, DateKey) async -> String?

    @State private var preset: HourSlipPreset = .lastSevenDays
    @State private var from: Date
    @State private var to: Date
    @State private var error: String?
    @State private var isWorking = false

    init(
        target: HourSlipTarget,
        rangeFor: @escaping (HourSlipPreset) -> (DateKey, DateKey)?,
        problem: @escaping (DateKey, DateKey) -> String?,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (DateKey, DateKey) async -> String?
    ) {
        self.target = target
        self.rangeFor = rangeFor
        self.problem = problem
        self.onCancel = onCancel
        self.onCreate = onCreate
        _from = State(initialValue: Date(epochMs: startOfDay(target.from)))
        _to = State(initialValue: Date(epochMs: startOfDay(target.to)))
    }

    /// The days that will go on the slip: the preset's, or the picked ones for Custom.
    private var chosen: (DateKey, DateKey) {
        rangeFor(preset) ?? (dateKeyOf(from.epochMs), dateKeyOf(to.epochMs))
    }

    var body: some View {
        let (first, last) = chosen
        let rangeProblem = problem(first, last)

        // No frame of its own: HistoryModalCard sets the width, and a wider sheet shows
        // its own window around the card.
        HistoryModalCard(title: "Create hour slip") {
            VStack(alignment: .leading, spacing: Space.x3l) {
                Text(
                    """
                    A PDF of your claimed and witnessed hours, signed by Deylee's server. \
                    Its QR code lets anyone you give it to check it is genuine — the page \
                    they see shows your name, full email and these hours.
                    """
                )
                .font(Type.small)
                .foregroundStyle(Palette.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

                HistorySegmentedPicker(
                    options: HourSlipPreset.allCases,
                    label: \.label,
                    fillWidth: true,
                    accessibilityLabel: "Days",
                    selection: Binding(get: { preset }, set: { preset = $0; error = nil })
                )

                if preset == .custom {
                    HStack(spacing: Space.xl) {
                        DatePicker("From", selection: $from, displayedComponents: .date)
                        DatePicker("To", selection: $to, displayedComponents: .date)
                    }
                    .datePickerStyle(.field)
                    .font(Type.control)
                    .onChange(of: from) { error = nil }
                    .onChange(of: to) { error = nil }
                } else {
                    Text(first == last ? formatDateLong(first)
                         : "\(formatDateLong(first)) – \(formatDateLong(last))")
                        .font(Type.control)
                        .foregroundStyle(Palette.fg)
                }

                if let message = rangeProblem ?? error { HistoryErrorBox(message: message) }
            }
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(DeyleeButtonStyle(variant: .ghost))
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
            Button(isWorking ? "Creating…" : "Create and save…") {
                isWorking = true
                error = nil
                Task {
                    error = await onCreate(first, last)
                    isWorking = false
                }
            }
            .buttonStyle(DeyleeButtonStyle(variant: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || rangeProblem != nil)
        }
    }
}
