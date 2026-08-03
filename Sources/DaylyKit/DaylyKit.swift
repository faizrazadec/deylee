/// Core of Dayly: models, DST-correct day-boundary math, the SQLite store and the
/// timer engine live in this module. It must stay free of AppKit/SwiftUI so an iOS
/// target can sit on top of it later.
public enum DaylyKit {
    public static let version = "0.1.0"
}
