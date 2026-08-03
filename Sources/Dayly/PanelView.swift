import SwiftUI
import DaylyKit

/// Placeholder panel. The real layout comes from docs/MAC_REWRITE_SPEC.md.
struct PanelView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "timer")
                .font(.system(size: 32))
            Text("Dayly")
                .font(.title2.weight(.semibold))
            Text("Native rewrite scaffold \(DaylyKit.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 320, height: 400)
    }
}
