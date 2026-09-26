import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DeyleeKit
import SwiftUI

/// The printed hour slip: one A4 page, drawn from SwiftUI straight into a PDF.
///
/// The figures are the server's, exactly as it signed them; nothing here is recomputed.
/// The QR code carries the check-page link, so anybody holding the paper can confirm it
/// was issued by the server and still matches the record — the email is masked on paper
/// and shown in full there.
struct HourSlipDocument: View {
    let slip: HourSlip
    let qr: CGImage?

    /// A4, in points.
    static let size = CGSize(width: 595, height: 842)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hour slip").font(.system(size: 22, weight: .semibold))
                        Text("Deylee").font(.system(size: 11)).foregroundStyle(PrintPalette.muted)
                    }
                    details
                }
                Spacer(minLength: 0)
                verification
            }
            table
            Spacer(minLength: 0)
            footnotes
        }
        .padding(40)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(PrintPalette.paper)
        .foregroundStyle(PrintPalette.ink)
        .environment(\.colorScheme, .light)
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Name", slip.name ?? "—")
            row("Email", maskedEmail(slip.email))
            row("Period", "\(long(slip.from)) – \(long(slip.to))")
            row("Time zone", slip.timeZone)
            row("Issued", Self.issued.string(from: Date(epochMs: slip.issuedAt)))
        }
        .font(.system(size: 10.5))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(PrintPalette.muted)
            Text(value)
        }
    }

    private var verification: some View {
        VStack(spacing: 6) {
            if let qr {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 118, height: 118)
            }
            Text("Scan to verify")
                .font(.system(size: 9, weight: .medium))
            Text("Signed by Deylee's server. The link shows the full email and these hours.")
                .font(.system(size: 7.5))
                .foregroundStyle(PrintPalette.muted)
                .multilineTextAlignment(.center)
                .frame(width: 130)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            tableRow("Day", "Claimed", "Witnessed", weight: .semibold, band: true)
            ForEach(slip.days, id: \.date) { day in
                tableRow(
                    long(day.date),
                    formatCompact(day.claimedMs),
                    formatCompact(day.witnessedMs) + (day.witnessedApproximate ? " *" : "")
                )
            }
            tableRow(
                "Total", formatCompact(slip.claimedMs), formatCompact(slip.witnessedMs),
                weight: .semibold, band: true
            )
        }
        .font(.system(size: 9.5).monospacedDigit())
        .overlay(Rectangle().stroke(PrintPalette.rule, lineWidth: 0.5))
    }

    private func tableRow(
        _ day: String, _ claimed: String, _ witnessed: String,
        weight: Font.Weight = .regular, band: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            Text(day).frame(maxWidth: .infinity, alignment: .leading)
            Text(claimed).frame(width: 110, alignment: .trailing)
            Text(witnessed).frame(width: 110, alignment: .trailing)
        }
        .fontWeight(weight)
        .padding(.horizontal, 10)
        .padding(.vertical, 3.5)
        .background(band ? PrintPalette.band : PrintPalette.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(PrintPalette.rule).frame(height: 0.5) }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                "Claimed is the work time recorded. Witnessed is time Deylee's server heard a "
                    + "running timer, stamped by its own clock — it cannot be added afterwards."
            )
            if slip.days.contains(where: \.witnessedApproximate) {
                Text(
                    "* Approximate: these days are old enough that only a daily total of "
                        + "witnessed time, by UTC date, is kept."
                )
            }
            Text(slip.url).foregroundStyle(PrintPalette.faint).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 8))
        .foregroundStyle(PrintPalette.muted)
    }

    private func long(_ date: String) -> String {
        DateKey(date).map { formatDateLong($0) } ?? date
    }

    private static let issued: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The slip's check link as a QR code, from Core Image's own generator — no dependency.
/// Scaled up with nearest-neighbour sampling so the modules stay square when printed.
func hourSlipQRCode(_ text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
}

/// The slip as PDF data, or nil if it could not be drawn.
@MainActor
func renderHourSlipPDF(_ slip: HourSlip) -> Data? {
    let renderer = ImageRenderer(content: HourSlipDocument(slip: slip, qr: hourSlipQRCode(slip.url)))
    renderer.proposedSize = ProposedViewSize(HourSlipDocument.size)
    let data = NSMutableData()
    renderer.render { size, draw in
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, [
                  kCGPDFContextTitle: "Hour slip",
                  kCGPDFContextCreator: "Deylee",
              ] as CFDictionary)
        else { return }
        pdf.beginPDFPage(nil)
        draw(pdf)
        pdf.endPDFPage()
        pdf.closePDF()
    }
    return data.length > 0 ? data as Data : nil
}
