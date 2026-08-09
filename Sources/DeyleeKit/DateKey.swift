import Foundation

/// A local calendar date, rendered as `YYYY-MM-DD`. The Swift counterpart of the
/// branded `DateKey` string in the Electron app: only ever produced from an instant
/// via `dateKeyOf`, or parsed from a string it itself printed.
public struct DateKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    init(unchecked year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Accepts only `YYYY-MM-DD` naming a real calendar date, like `isDateKey`.
    ///
    /// `[0-9]` rather than `\d`, which matters more than it looks. Swift's `\d` matches
    /// the whole Unicode `Nd` category while `Int(_:)` parses ASCII only, so a date in
    /// Arabic-Indic digits passed the guard and then force-unwrapped nil — a crash, on
    /// a value that arrives straight out of the server's JSON.
    ///
    /// The `compactMap` is the belt to that brace. This is a failable initialiser on
    /// data from the wire; anything it cannot read is a nil, never a trap.
    public init?(_ string: String) {
        guard string.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil else { return nil }
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var comps = DateComponents(year: year, month: month, day: day)
        comps.calendar = gmtCalendar
        guard comps.isValidDate else { return nil }
        self.init(unchecked: year, month: month, day: day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: DateKey, rhs: DateKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension DateKey: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = DateKey(raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "not a date key: \(raw)"
            ))
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
