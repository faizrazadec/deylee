import Foundation

/// Export serialisation, ported from `src/main/services/ExportService.ts`.
///
/// Pure string building, no AppKit and no filesystem: the save panel and the write
/// belong to the window layer, which keeps both formats testable against literals.
///
/// Every row carries both the local wall-clock time (what the user recognises) and the
/// raw UTC epoch milliseconds (what round-trips exactly). A spreadsheet opened in
/// another timezone would silently rewrite the first; the second is the ground truth.
///
/// The column set is a public contract: somebody has a spreadsheet built on it, so a
/// renamed or reordered column is a silent data problem rather than a cosmetic change.

public let historyCsvHeader =
    "date,segment_type,started_at_local,ended_at_local,duration_minutes,"
    + "started_at_utc_ms,ended_at_utc_ms,note"

private let csvColumnCount = 8

/// RFC 4180: only these characters force a field to be quoted.
private let csvCharactersNeedingQuotes = CharacterSet(charactersIn: "\",\r\n")

/// CSV for a set of days. Days ascending, segments ascending, LF line endings and no
/// trailing newline — the exact bytes the Electron build wrote.
public func buildHistoryCsv(_ days: [DayDetail], in zone: TimeZone = .current) -> String {
    var lines = [historyCsvHeader]

    for detail in orderedDays(days) {
        let segments = orderedSegments(detail.segments)
        if segments.isEmpty {
            // A day the user opened and recorded nothing on is still a fact about the
            // range, so it gets a row rather than vanishing from the file.
            lines.append(csvRow(
                [detail.day.date.description]
                    + Array(repeating: "", count: csvColumnCount - 1)
            ))
            continue
        }
        for segment in segments {
            lines.append(csvRow(csvFields(detail.day.date, segment, in: zone)))
        }
    }

    return lines.joined(separator: "\n")
}

/// JSON for a set of days: pretty-printed with two-space indentation, keys in the order
/// the TypeScript interfaces declare them, so a diff against a file the Electron build
/// wrote is empty rather than a reshuffle.
public func buildHistoryJson(
    _ days: [DayDetail],
    range: DateRange,
    exportedAt: EpochMs = epochNow()
) -> String {
    let payload = JSONValue.object([
        ("exportedAt", .string(iso8601UTC(exportedAt))),
        ("range", .object([
            ("from", .string(range.from.description)),
            ("to", .string(range.to.description)),
        ])),
        ("days", .array(orderedDays(days).map { detail in
            .object([
                ("date", .string(detail.day.date.description)),
                ("targetMinutes", .int(Int64(detail.day.targetMinutes))),
                ("totals", .object([
                    ("workedMs", .int(detail.totals.workedMs)),
                    ("breakMs", .int(detail.totals.breakMs)),
                    ("firstStartAt", .optionalInt(detail.totals.firstStartAt)),
                    ("lastEndAt", .optionalInt(detail.totals.lastEndAt)),
                    ("segmentCount", .int(Int64(detail.totals.segmentCount))),
                    ("hasOpenSegment", .bool(detail.totals.hasOpenSegment)),
                ])),
                ("segments", .array(orderedSegments(detail.segments).map(segmentJSON))),
            ])
        })),
    ])
    return payload.rendered(indent: 0)
}

// MARK: - CSV internals

private func csvFields(_ date: DateKey, _ segment: Segment, in zone: TimeZone) -> [String] {
    // An open segment has no end, and its duration would depend on the instant of the
    // export, so both stay empty rather than baking "now" into the file.
    let endedAt = segment.endedAt
    return [
        date.description,
        segment.type.rawValue,
        formatClockSeconds(segment.startedAt, in: zone),
        endedAt.map { formatClockSeconds($0, in: zone) } ?? "",
        endedAt.map { durationMinutes(from: segment.startedAt, to: $0) } ?? "",
        String(segment.startedAt),
        endedAt.map(String.init) ?? "",
        segment.note ?? "",
    ]
}

/// Two decimals rather than whole minutes: rounding to the nearest minute would report
/// a 40-second segment as `0`, which reads as a bug in a spreadsheet. Trailing zeros are
/// dropped, so a round hour is `60` and not `60.00`.
private func durationMinutes(from startedAt: EpochMs, to endedAt: EpochMs) -> String {
    let minutes = Double(max(0, endedAt - startedAt)) / Double(MS_PER_MINUTE)
    var text = String(format: "%.2f", minutes)
    if text.contains(".") {
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
    }
    return text
}

private func csvRow(_ fields: [String]) -> String {
    fields.map(csvField).joined(separator: ",")
}

private func csvField(_ value: String) -> String {
    guard value.rangeOfCharacter(from: csvCharactersNeedingQuotes) != nil else { return value }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

// MARK: - JSON internals

/// A minimal ordered JSON tree.
///
/// `JSONEncoder` cannot express "these keys, in this order": it sorts them or emits them
/// in whatever order the encoder walked the type. Key order is not semantically load
/// bearing, but the export is a file people keep and diff, so it is reproduced.
private indirect enum JSONValue {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case null
    case object([(String, JSONValue)])
    case array([JSONValue])

    static func optionalInt(_ value: Int64?) -> JSONValue {
        value.map { .int($0) } ?? .null
    }

    static func optionalString(_ value: String?) -> JSONValue {
        value.map { .string($0) } ?? .null
    }

    /// Matches `JSON.stringify(value, null, 2)`: two spaces per level, `": "` after a
    /// key, and an empty object or array collapsed onto one line.
    func rendered(indent: Int) -> String {
        let pad = String(repeating: " ", count: indent * 2)
        let innerPad = String(repeating: " ", count: (indent + 1) * 2)
        switch self {
        case .string(let value): return quoted(value)
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object(let members):
            if members.isEmpty { return "{}" }
            let body = members
                .map { "\(innerPad)\(quoted($0.0)): \($0.1.rendered(indent: indent + 1))" }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        case .array(let elements):
            if elements.isEmpty { return "[]" }
            let body = elements
                .map { "\(innerPad)\($0.rendered(indent: indent + 1))" }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        }
    }

    private func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                // Everything below U+0020 has to be escaped to stay valid JSON; the rest
                // is emitted as-is, exactly as `JSON.stringify` does for non-ASCII.
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

private func segmentJSON(_ segment: Segment) -> JSONValue {
    .object([
        ("id", .int(segment.id)),
        ("dayId", .int(segment.dayId)),
        ("type", .string(segment.type.rawValue)),
        ("startedAt", .int(segment.startedAt)),
        ("endedAt", .optionalInt(segment.endedAt)),
        ("note", .optionalString(segment.note)),
        ("createdAt", .int(segment.createdAt)),
        ("updatedAt", .int(segment.updatedAt)),
    ])
}

/// `2026-08-03T09:12:34.567Z`, the shape `Date.prototype.toISOString` produces. The file
/// is read outside the app, where an epoch is opaque.
func iso8601UTC(_ ts: EpochMs) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = Date(epochMs: ts)
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    // Floored rather than truncated toward zero, so a pre-1970 instant keeps a
    // millisecond field in 0...999 instead of going negative.
    let ms = ts - Int64((Double(ts) / 1000).rounded(.down)) * 1000
    return String(
        format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
        c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, Int(ms)
    )
}

// MARK: - Ordering

private func orderedDays(_ days: [DayDetail]) -> [DayDetail] {
    days.sorted { $0.day.date < $1.day.date }
}

/// Swift's `sorted(by:)` is not guaranteed stable, so the row id breaks a tie between
/// two segments that start on the same millisecond. That is also the order the
/// repository reads them in, so a re-export of untouched data is byte-identical.
private func orderedSegments(_ segments: [Segment]) -> [Segment] {
    segments.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
}
