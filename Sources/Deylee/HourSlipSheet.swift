import DeyleeKit
import SwiftUI

/// Picks the days for an hour slip, then asks for it and saves the PDF.
///
/// The range is checked as it is picked — ended days only, at most 30 — so the button is
/// disabled with the reason beside it rather than failing after a round trip.
struct HourSlipSheet: View {
    let target: HourSlipTarget
    let problem: (DateKey, DateKey) -> String?
    let onCancel: () -> Void
    /// Returns the message to show, or nil once the slip was made and the save panel has
    /// taken over.
    let onCreate: (DateKey, DateKey) async -> String?

    @State private var from: Date
    @State private var to: Date
    @State private var error: String?
    @State private var isWorking = false

    init(
        target: HourSlipTarget,
        problem: @escaping (DateKey, DateKey) -> String?,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (DateKey, DateKey) async -> String?
    ) {
        self.target = target
        self.problem = problem
        self.onCancel = onCancel
        self.onCreate = onCreate
        _from = State(initialValue: Date(epochMs: startOfDay(target.from)))
        _to = State(initialValue: Date(epochMs: startOfDay(target.to)))
    }

    private var fromKey: DateKey { dateKeyOf(from.epochMs) }
    private var toKey: DateKey { dateKeyOf(to.epochMs) }

    var body: some View {
        let rangeProblem = problem(fromKey, toKey)

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

                HStack(spacing: Space.xl) {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                .datePickerStyle(.field)
                .font(Type.control)
                .onChange(of: from) { error = nil }
                .onChange(of: to) { error = nil }

                if let message = rangeProblem ?? error { HistoryErrorBox(message: message) }
            }
        } footer: {
            Button("Cancel", action: onCancel)
                .buttonStyle(DeyleeButtonStyle(variant: .ghost))
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
            Button(isWorking ? "Creating…" : "Create and save…") {
                isWorking = true
                Task {
                    error = await onCreate(fromKey, toKey)
                    isWorking = false
                }
            }
            .buttonStyle(DeyleeButtonStyle(variant: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || rangeProblem != nil)
        }
        .frame(width: 440)
    }
}
