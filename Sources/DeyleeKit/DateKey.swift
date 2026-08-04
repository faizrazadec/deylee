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
    public init?(_ string: String) {
        guard string.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        let parts = string.split(separator: "-").map { Int($0)! }
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
