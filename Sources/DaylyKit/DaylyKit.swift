import Foundation

/// Core of Dayly: models, DST-correct day-boundary math, the SQLite store and the
/// timer engine live in this module. It must stay free of AppKit/SwiftUI so an iOS
/// target can sit on top of it later.
public enum DaylyKit {
    public static let version = "0.1.0"
}

/// An error that carries a reason worth showing someone.
///
/// `LocalizedError` is the half that matters: without it, `localizedDescription` goes
/// through the `NSError` bridge and answers "The operation couldn't be completed.
/// (DaylyKit.Database.Failure error 1.)", discarding the description entirely. Every
/// error in this module that a person might read conforms to this, so a caller can
/// simply use `localizedDescription` and get the real reason — and still get Cocoa's
/// own good message for the file and disk errors it did not raise itself.
public protocol DaylyError: Error, CustomStringConvertible, LocalizedError {}

extension DaylyError {
    public var errorDescription: String? { description }
}
