import AppKit

@main
enum DaylyMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu-bar app: no dock icon. History/Settings windows will flip the
        // activation policy temporarily when they are open.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
